import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

extension MattermostAccountSync {
    struct ChannelSnapshot {
        var channels: [String: (channel: Channel, teamId: String)] = [:]
        var members: [String: ChannelMember] = [:]
        var categories: [String: OrderedSidebarCategories] = [:]
    }

    /// Loads every team's channels, memberships and (optionally) sidebar categories.
    func loadChannels(teams: [Team], categories: Bool) async throws -> ChannelSnapshot {
        var snapshot = ChannelSnapshot()
        for team in teams {
            async let channels = self.client.channels(teamId: team.id, includeDeleted: true)
            async let members = self.client.channelMembers(teamId: team.id)
            for channel in try await channels where snapshot.channels[channel.id] == nil {
                // DMs and GMs are listed in every team; they belong to none.
                snapshot.channels[channel.id] = (channel, channel.teamId.isEmpty ? "" : team.id)
            }
            for member in try await members {
                snapshot.members[member.channelId] = member
            }
            if categories {
                snapshot.categories[team.id] = try await self.client.sidebarCategories(teamId: team.id)
            }
        }
        return snapshot
    }

    /// First sync (design: "Bootstrap"): structure first (peers, chat list, read states, folders, pins),
    /// then the newest page of every channel, unread ones first. Later launches rewrite the structure only
    /// (it also rebuilds the in-memory channel state); the catch-up after connecting brings the posts.
    func bootstrap() async throws {
        let isFirstSync = await self.postbox.mmTransaction { _ in
            return self.store.cursor(MattermostCursorKey.bootstrapped) == nil
        }
        self.beginUpdating()
        defer {
            self.endUpdating()
        }
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let started = CFAbsoluteTimeGetCurrent()

        // 1. REST.
        let me = try await self.client.me()
        let preferences = try await self.client.preferences()
        // Collapsed reply threads (3B): decided before anything is written, since read states and messages
        // depend on it. Without the config (an old server), the last known server setting stays.
        let config = try? await self.client.clientConfig()
        let collapsedThreadsSetting = config?.collapsedThreads ?? self.state.with { $0.collapsedThreadsSetting }
        let collapsedThreadsChanged = self.updateCollapsedThreads(setting: collapsedThreadsSetting, preferences: preferences)
        // Rich content (3E): link previews, the image proxy, emoticons and inline LaTeX, before posts are written.
        self.setRichContent(self.richContent.withConfig(config).withPreferences(preferences), reason: "bootstrap")
        if let siteURL = config?.siteURL, !siteURL.isEmpty {
            self.state.with { $0.siteURL = siteURL }
        }
        let teams = try await self.client.teams().filter { $0.deleteAt == 0 }
        let snapshot = try await self.loadChannels(teams: teams, categories: true)

        let hiddenDirectUsers = Set(preferences.filter { $0.category == PreferenceCategory.directChannelShow && $0.value == "false" }.map { $0.name })
        let hiddenGroupChannels = Set(preferences.filter { $0.category == PreferenceCategory.groupChannelShow && $0.value == "false" }.map { $0.name })
        var included: [(channel: Channel, member: ChannelMember, teamId: String)] = []
        var userIds = Set<String>([me.id])
        for (channelId, item) in snapshot.channels {
            guard let member = snapshot.members[channelId] else {
                continue
            }
            switch item.channel.type {
            case .directMessage:
                guard let partnerId = item.channel.directMessagePartnerId(myUserId: me.id) else {
                    continue
                }
                if partnerId != me.id && hiddenDirectUsers.contains(partnerId) {
                    continue
                }
                userIds.insert(partnerId)
            case .groupMessage:
                if hiddenGroupChannels.contains(channelId) {
                    continue
                }
            default:
                break
            }
            included.append((item.channel, member, item.teamId))
        }
        var users: [User] = []
        let userIdList = Array(userIds)
        for start in stride(from: 0, to: userIdList.count, by: 100) {
            users.append(contentsOf: try await self.client.users(ids: Array(userIdList[start ..< min(userIdList.count, start + 100)])))
        }
        let statuses = (try? await self.client.userStatuses(ids: users.map { $0.id })) ?? []

        // 2. Structure, in one transaction.
        self.state.with { state in
            state.me = me
            state.teams = teams
        }
        // What the user may do with each channel (3D-2) goes into the channel peers.
        await self.loadRoles(me: me, channelRoles: included.map { $0.member.roles })
        var favoriteChannelIds: [String] = []
        var favoritesByTeam: [String: [String]] = [:]
        for team in teams {
            for category in snapshot.categories[team.id]?.orderedCategories ?? [] where category.type == .favorites {
                favoritesByTeam[team.id, default: []].append(contentsOf: category.channelIds)
                for channelId in category.channelIds where !favoriteChannelIds.contains(channelId) {
                    favoriteChannelIds.append(channelId)
                }
            }
        }
        self.state.with { $0.favoritesByTeam = favoritesByTeam }
        await self.postbox.mmTransaction { transaction in
            self.writeUsers(users, transaction: transaction)
            self.writePresences(statuses, transaction: transaction)
            for item in included {
                self.writeChannel(item.channel, member: item.member, teamId: item.teamId, transaction: transaction)
            }

            // The root and archive lists start with a hole that Telegram's `managedChatListHoles` fills from
            // `messages.getDialogs`; the list is complete locally.
            let seededHoles = telegramPostboxSeedConfiguration.initializeChatListWithHole
            for (groupId, seededHole) in [(PeerGroupId.root, seededHoles.topLevel), (Namespaces.PeerGroup.archive, seededHoles.groups)] {
                if let seededHole = seededHole {
                    transaction.replaceChatListHole(groupId: groupId, index: seededHole.index, hole: nil)
                }
                for hole in transaction.allChatListHoles(groupId: groupId) {
                    transaction.replaceChatListHole(groupId: groupId, index: hole.index, hole: nil)
                }
            }
            transaction.updatePreferencesEntry(key: PreferencesKeys.contactsSettings, { _ in
                return PreferencesEntry(ContactsSettings(synchronizeContacts: false))
            })

            // Favorites → pinned chats (`setPinnedItemIds` bypasses the interactive pin limit).
            let pinned = favoriteChannelIds.compactMap { channelId -> PinnedItemId? in
                return self.channelState(channelId).map { .peer($0.peerId) }
            }
            transaction.setPinnedItemIds(groupId: .root, itemIds: pinned)
        }
        await self.writeTeamFolders(teams: teams)
        let chatIds = included.map { $0.channel.id }
        self.addTask(Task { [weak self] in
            await self?.refreshMemberCounts(chatIds)
        })
        self.state.with { $0.isBootstrapped = true }
        self.bootstrapped.set(true)
        MMLog.log("bootstrap: structure written in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms: \(teams.count) teams, \(included.count) chats, \(users.count) users, \(favoriteChannelIds.count) favorites")

        if !isFirstSync {
            await self.finishCollapsedThreadsBootstrap(changed: collapsedThreadsChanged, isFirstSync: false)
            self.addTask(Task { [weak self] in
                await self?.finishRichContentBootstrap(isFirstSync: false)
            })
            self.state.with { $0.newestPagesLoaded = true }
            MMLog.log("bootstrap: already synced before; catch-up follows")
            return
        }

        // 3. Newest page per channel: unread first, then by last post.
        let ordered = included.sorted { lhs, rhs in
            let lhsUnread = lhs.channel.totalMsgCount - lhs.member.msgCount > 0
            let rhsUnread = rhs.channel.totalMsgCount - rhs.member.msgCount > 0
            if lhsUnread != rhsUnread {
                return lhsUnread
            }
            return lhs.channel.lastPostAt > rhs.channel.lastPostAt
        }.map { $0.channel.id }
        let failures = MMLocked<Int>(0)
        try await self.forEachConcurrently(ordered, limit: 4) { channelId in
            do {
                _ = try await self.loadPage(channelId: channelId, cursor: .latest, requestedRange: nil, resetReadState: true)
            } catch {
                failures.with { $0 += 1 }
                MMLog.log("bootstrap: newest page of \(channelId) failed: \(error)")
            }
        }
        if failures.current > 0 {
            // Their holes stay; opening the chat (or the next catch-up) loads them.
            MMLog.log("bootstrap: \(failures.current) newest pages failed")
        }

        await self.finishCollapsedThreadsBootstrap(changed: collapsedThreadsChanged, isFirstSync: true)
        await self.finishRichContentBootstrap(isFirstSync: true)
        self.state.with { $0.newestPagesLoaded = true }

        // 4. Live updates take over from here.
        await self.postbox.mmTransaction { _ in
            self.store.setCursor(MattermostCursorKey.lastSyncAt, String(startedAt))
            self.store.setCursor(MattermostCursorKey.bootstrapped, "1")
        }
        MMLog.log("bootstrap: done in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
    }

    /// After the bootstrap wrote its data: re-renders stored messages when collapsed reply threads changed while
    /// the app was not running (or data from before 3B needs the root tags), publishes the state, loads threads.
    func finishCollapsedThreadsBootstrap(changed: Bool, isFirstSync: Bool) async {
        if isFirstSync {
            // Everything was just written in the current state.
            await self.postbox.mmTransaction { _ in
                self.store.setCursor(MattermostAccountSync.threadLayoutCursor, MattermostAccountSync.threadLayoutVersion)
            }
        } else if changed {
            await self.reapplyCollapsedThreads()
        } else {
            await self.upgradeThreadLayoutIfNeeded()
        }
        self.publishCollapsedThreads()
        if self.isCollapsedThreads {
            self.addTask(Task { [weak self] in
                await self?.reloadAllThreads()
            })
        }
    }

    /// Runs `body` for every item with at most `limit` running at once.
    func forEachConcurrently<T: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async throws -> Void) async throws {
        var index = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            while index < items.count && index < limit {
                let item = items[index]
                group.addTask {
                    try await body(item)
                }
                index += 1
            }
            while try await group.next() != nil {
                if index < items.count {
                    let item = items[index]
                    group.addTask {
                        try await body(item)
                    }
                    index += 1
                }
            }
        }
    }

    /// One local-only folder per team (D3): the team's channels, every group message, and every DM through
    /// the user categories; the team's Favorites are the folder's pinned chats. Telegram's folder sync is never
    /// started; pin changes in a folder go to the team's Favorites (`startFolderPinObserver`).
    func writeTeamFolders(teams: [Team]) async {
        let favoritePeersByTeam: [String: [PeerId]] = self.state.with { state in
            var result: [String: [PeerId]] = [:]
            for (teamId, channelIds) in state.favoritesByTeam {
                result[teamId] = channelIds.compactMap { state.channels[$0]?.peerId }
            }
            return result
        }
        let (channelPeersByTeam, groupPeers): ([String: [PeerId]], [PeerId]) = self.state.with { state in
            var byTeam: [String: [PeerId]] = [:]
            var groups: [PeerId] = []
            for channelState in state.channels.values.sorted(by: { $0.channel.displayName < $1.channel.displayName }) {
                if channelState.channel.isArchived {
                    continue
                }
                if channelState.channel.type == .groupMessage {
                    groups.append(channelState.peerId)
                } else if channelState.kind == .channel, !channelState.teamId.isEmpty {
                    byTeam[channelState.teamId, default: []].append(channelState.peerId)
                }
            }
            return (byTeam, groups)
        }
        let existingFolderIds: [String: Int32] = await self.postbox.mmTransaction { _ in
            var result: [String: Int32] = [:]
            for team in teams {
                if let value = self.store.cursor(MattermostCursorKey.folderId(teamId: team.id)), let id = Int32(value) {
                    result[team.id] = id
                }
            }
            return result
        }
        let newFolderIds = MMLocked<[String: Int32]>([:])
        let engine = TelegramEngine(account: self.account)
        let _ = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let _ = engine.peers.updateChatListFiltersInteractively({ filters in
                var filters = filters
                for team in teams {
                    var include = ChatListFilterIncludePeers()
                    include.setPeers((channelPeersByTeam[team.id] ?? []) + groupPeers)
                    for peerId in (favoritePeersByTeam[team.id] ?? []).reversed() {
                        let _ = include.addPinnedPeer(peerId)
                    }
                    let pinnedPeers = include.pinnedPeers
                    self.state.with { $0.folderPins[team.id] = pinnedPeers }
                    let data = ChatListFilterData(
                        isShared: false,
                        hasSharedLinks: false,
                        categories: [.contacts, .nonContacts, .bots],
                        excludeMuted: false,
                        excludeRead: false,
                        excludeArchived: true,
                        includePeers: include,
                        excludePeers: [],
                        color: nil
                    )
                    let id: Int32
                    if let existing = existingFolderIds[team.id] ?? newFolderIds.with({ $0[team.id] }) {
                        id = existing
                    } else {
                        id = engine.peers.generateNewChatListFilterId(filters: filters)
                        newFolderIds.with { $0[team.id] = id }
                    }
                    let filter = ChatListFilter.filter(id: id, title: ChatFolderTitle(text: team.displayName, entities: [], enableAnimations: true), emoticon: nil, data: data)
                    if let index = filters.firstIndex(where: { $0.id == id }) {
                        filters[index] = filter
                    } else {
                        filters.append(filter)
                    }
                }
                return filters
            }).start(completed: {
                continuation.resume()
            })
        }
        let created = newFolderIds.current
        if !created.isEmpty {
            await self.postbox.mmTransaction { _ in
                for (teamId, id) in created {
                    self.store.setCursor(MattermostCursorKey.folderId(teamId: teamId), String(id))
                }
            }
        }
    }
}
