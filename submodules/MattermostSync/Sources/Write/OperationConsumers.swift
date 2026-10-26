import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Runs `perform` for every key listed by a Postbox view, one task per key at a time (design: "Replacing
/// managed operations"). The interactive engine calls write to Postbox as before (pending reaction actions,
/// op logs, pending notification settings); these consumers take Telegram's managed operations' place.
///
/// `perform` must be idempotent (it re-reads its operation in a transaction) and return false to be retried
/// after `retryDelay`. A key still listed after its task finished runs again only if the view emitted while
/// it ran, so a stale view never spins.
final class KeyedOperationRunner<Key: Hashable> {
    private let queue = Queue()
    private let disposable = MetaDisposable()
    private let keys: Signal<[Key], NoError>
    private let retryDelay: Double
    private let perform: (Key) async -> Bool
    private var latest: [Key] = []
    private var active = Set<Key>()
    private var emittedWhileActive = Set<Key>()
    private var failedAt: [Key: Double] = [:]

    init(keys: Signal<[Key], NoError>, retryDelay: Double = 5.0, perform: @escaping (Key) async -> Bool) {
        self.keys = keys
        self.retryDelay = retryDelay
        self.perform = perform
    }

    deinit {
        self.disposable.dispose()
    }

    func start() {
        self.disposable.set((self.keys
        |> deliverOn(self.queue)).start(next: { [weak self] keys in
            guard let self = self else {
                return
            }
            self.latest = keys
            for key in keys where self.active.contains(key) {
                self.emittedWhileActive.insert(key)
            }
            self.update()
        }))
    }

    private func update() {
        let now = CFAbsoluteTimeGetCurrent()
        for key in self.latest where !self.active.contains(key) {
            if let failedAt = self.failedAt[key], now < failedAt + self.retryDelay {
                self.queue.after(failedAt + self.retryDelay - now + 0.05, { [weak self] in
                    self?.update()
                })
                continue
            }
            self.active.insert(key)
            let perform = self.perform
            Task { [weak self] in
                let succeeded = await perform(key)
                self?.queue.async {
                    guard let self = self else {
                        return
                    }
                    self.active.remove(key)
                    let emitted = self.emittedWhileActive.remove(key) != nil
                    if succeeded {
                        self.failedAt[key] = nil
                        if !emitted {
                            self.latest.removeAll(where: { $0 == key })
                        }
                    } else {
                        self.failedAt[key] = CFAbsoluteTimeGetCurrent()
                    }
                    self.update()
                }
            }
        }
    }
}

/// An op-log entry (`PeerMergedOperationLogEntry` identity).
struct OperationLogKey: Hashable {
    let peerId: PeerId
    let tagLocalIndex: Int32
}

extension MattermostAccountSync {
    func startOperationConsumers() {
        let postbox = self.postbox

        let reactionsKey = PostboxViewKey.pendingMessageActions(type: .updateReaction)
        let reactions = KeyedOperationRunner<MessageId>(keys: postbox.combinedView(keys: [reactionsKey]) |> map { views -> [MessageId] in
            return (views.views[reactionsKey] as? PendingMessageActionsView)?.entries.map { $0.id } ?? []
        }, perform: { [weak self] messageId in
            return await self?.pushReactions(messageId: messageId) ?? true
        })

        let deletions = KeyedOperationRunner<OperationLogKey>(keys: postbox.mergedOperationLogView(tag: OperationLogTags.CloudChatRemoveMessages, limit: 20) |> map { view -> [OperationLogKey] in
            return view.entries.map { OperationLogKey(peerId: $0.peerId, tagLocalIndex: $0.tagLocalIndex) }
        }, perform: { [weak self] key in
            return await self?.pushDeletion(key) ?? true
        })

        let notificationsKey = PostboxViewKey.pendingPeerNotificationSettings
        let notifications = KeyedOperationRunner<PeerId>(keys: postbox.combinedView(keys: [notificationsKey]) |> map { views -> [PeerId] in
            guard let view = views.views[notificationsKey] as? PendingPeerNotificationSettingsView else {
                return []
            }
            return Array(view.entries.keys)
        }, perform: { [weak self] peerId in
            return await self?.pushNotificationSettings(peerId: peerId) ?? true
        })

        let pins = KeyedOperationRunner<OperationLogKey>(keys: postbox.mergedOperationLogView(tag: OperationLogTags.SynchronizePinnedChats, limit: 10) |> map { view -> [OperationLogKey] in
            return view.entries.map { OperationLogKey(peerId: $0.peerId, tagLocalIndex: $0.tagLocalIndex) }
        }, perform: { [weak self] key in
            return await self?.pushPinnedChats(key) ?? true
        })

        self.operationRunners = [reactions, deletions, notifications, pins]
        reactions.start()
        deletions.start()
        notifications.start()
        pins.start()

        self.startFolderPinObserver()

        self.addDisposable((self.account.mattermostLocalInputActivities()
        |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { [weak self] activities in
            self?.pushTyping(activities)
        }))
    }

    // MARK: Reactions

    /// A pending `.updateReaction` action: the message's `PendingReactionsMessageAttribute` is the wanted set
    /// of own reactions. Adds and removes the difference on the server (Mattermost allows several per user),
    /// then folds the result into `ReactionsMessageAttribute` and drops the pending attribute. A failed call
    /// leaves that reaction as the server has it (the optimistic state rolls back).
    func pushReactions(messageId: MessageId) async -> Bool {
        let ownPeerId = self.ownPeerId
        let reactionsSourceId = self.primaryMessageId(for: messageId) ?? messageId
        let snapshot: (wanted: [MessageReaction.Reaction], mine: [MessageReaction.Reaction])? = await self.postbox.mmTransaction { transaction in
            guard let message = transaction.getMessage(messageId), let pending = message.attributes.first(where: { $0 is PendingReactionsMessageAttribute }) as? PendingReactionsMessageAttribute else {
                transaction.setPendingMessageAction(type: .updateReaction, id: messageId, action: nil)
                return nil
            }
            var mine: [MessageReaction.Reaction] = []
            if let reactions = (transaction.getMessage(reactionsSourceId) ?? message).attributes.first(where: { $0 is ReactionsMessageAttribute }) as? ReactionsMessageAttribute {
                for peer in reactions.recentPeers where (peer.isMy || peer.peerId == ownPeerId) && !mine.contains(peer.value) {
                    mine.append(peer.value)
                }
            }
            return (pending.reactions.map { $0.value }, mine)
        }
        guard let snapshot = snapshot else {
            return true
        }
        let toAdd = snapshot.wanted.filter { !snapshot.mine.contains($0) }
        let toRemove = snapshot.mine.filter { !snapshot.wanted.contains($0) }
        var added: [MessageReaction.Reaction] = []
        var removed: [MessageReaction.Reaction] = []
        var failures: [String] = []
        if let reference = self.postReference(for: messageId) {
            for value in toAdd {
                guard let name = SyntheticConfiguration.emojiName(for: value) else {
                    failures.append("unsupported reaction \(value)")
                    continue
                }
                do {
                    try await self.retryingTransient("reaction +\(name) on \(reference.postId)", isStillWanted: { await self.messageExists(messageId) }) {
                        try await self.client.addReaction(userId: self.ownUserId, postId: reference.postId, emojiName: name)
                    }
                    added.append(value)
                    MMLog.log("reactions: +\(name) on \(reference.postId)")
                } catch {
                    failures.append("+\(name): \(describeError(error))")
                }
            }
            if !toRemove.isEmpty {
                // The server may store an alias (`thumbsup` for 👍): remove whatever name it has for the emoji.
                let serverReactions = (try? await self.client.post(id: reference.postId))?.metadata?.reactions ?? []
                for value in toRemove {
                    var names = serverReactions.filter { $0.userId == self.ownUserId && PostConverter.reactionValue($0.emojiName) == value }.map { $0.emojiName }
                    if names.isEmpty, let name = SyntheticConfiguration.emojiName(for: value) {
                        names = [name]
                    }
                    do {
                        for name in names {
                            try await self.retryingTransient("reaction -\(name) on \(reference.postId)", isStillWanted: { await self.messageExists(messageId) }) {
                                try await self.client.removeReaction(postId: reference.postId, emojiName: name)
                            }
                            MMLog.log("reactions: -\(name) on \(reference.postId)")
                        }
                        removed.append(value)
                    } catch {
                        failures.append("-\(names.joined(separator: ",")): \(describeError(error))")
                    }
                }
            }
        } else if !toAdd.isEmpty || !toRemove.isEmpty {
            failures.append("message \(messageId) has no post")
        }

        let now = Int32(Date().timeIntervalSince1970)
        let addedValues = added
        let removedValues = removed
        // A multi-file post keeps its reactions on its primary message (the one Telegram shows them from).
        let primaryId = self.primaryMessageId(for: messageId) ?? messageId
        await self.postbox.mmTransaction { transaction in
            func applied(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
                var attributes = attributes
                var recentPeers: [ReactionsMessageAttribute.RecentPeer] = []
                if let index = attributes.firstIndex(where: { $0 is ReactionsMessageAttribute }) {
                    recentPeers = (attributes[index] as! ReactionsMessageAttribute).recentPeers
                    attributes.remove(at: index)
                }
                recentPeers.removeAll(where: { ($0.isMy || $0.peerId == ownPeerId) && removedValues.contains($0.value) })
                for value in addedValues where !recentPeers.contains(where: { ($0.isMy || $0.peerId == ownPeerId) && $0.value == value }) {
                    recentPeers.append(ReactionsMessageAttribute.RecentPeer(value: value, isLarge: false, isUnseen: false, isMy: true, peerId: ownPeerId, timestamp: now))
                }
                if let attribute = PostConverter.reactionsAttribute(recentPeers: recentPeers) {
                    attributes.append(attribute)
                }
                return attributes
            }
            var finished = false
            if primaryId != messageId {
                transaction.updateMessage(primaryId, update: { current in
                    return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: applied(current.attributes)))
                })
            }
            transaction.updateMessage(messageId, update: { current in
                var attributes = primaryId == messageId ? applied(current.attributes) : current.attributes.filter { !($0 is ReactionsMessageAttribute) }
                // Done unless the user changed the reactions again meanwhile (then this runs once more).
                if let index = attributes.firstIndex(where: { $0 is PendingReactionsMessageAttribute }), (attributes[index] as! PendingReactionsMessageAttribute).reactions.map({ $0.value }) == snapshot.wanted {
                    attributes.remove(at: index)
                    finished = true
                }
                return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: attributes))
            })
            if finished || !transaction.messageExists(id: messageId) {
                transaction.setPendingMessageAction(type: .updateReaction, id: messageId, action: nil)
            }
        }
        if !failures.isEmpty {
            MMLog.log("reactions: \(messageId) failed: \(failures.joined(separator: "; "))")
            self.notice(.reactionFailed)
        }
        return true
    }

    // MARK: Delete

    /// `CloudChatRemoveMessages` op log (`deleteMessagesInteractively`): "delete for everyone" deletes the posts
    /// on the server (`DELETE /posts/{id}`; offline, it waits). A post the user may not delete (403) is put
    /// back and the user is told. "Delete for me" stays local: Mattermost has no per-user deletion.
    func pushDeletion(_ key: OperationLogKey) async -> Bool {
        let contents: PostboxCoding? = await self.postbox.mmTransaction { transaction in
            var contents: PostboxCoding?
            transaction.operationLogEnumerateEntries(peerId: key.peerId, tag: OperationLogTags.CloudChatRemoveMessages, { entry in
                if entry.tagLocalIndex == key.tagLocalIndex {
                    contents = entry.contents
                    return false
                }
                return true
            })
            return contents
        }
        guard let contents = contents else {
            return true
        }
        if let operation = contents as? CloudChatRemoveMessagesOperation {
            if operation.type == .forEveryone {
                for messageId in operation.messageIds where messageId.namespace == Namespaces.Message.Cloud {
                    guard let reference = self.postReference(for: messageId) else {
                        continue
                    }
                    do {
                        try await self.retryingTransient("delete \(reference.postId)", isStillWanted: { true }) {
                            try await self.client.deletePost(id: reference.postId)
                        }
                        let count: Int = await self.postbox.mmTransaction { transaction in
                            return self.removePostsLocally([reference.postId], channelId: reference.channelId, transaction: transaction)
                        }
                        MMLog.log("delete: post \(reference.postId) deleted (\(count) local message(s) removed, with thread replies)")
                    } catch let error as MattermostError {
                        if case .notFound = error {
                            await self.postbox.mmTransaction { transaction in
                                _ = self.removePostsLocally([reference.postId], channelId: reference.channelId, transaction: transaction)
                            }
                            MMLog.log("delete: post \(reference.postId) was already gone")
                            continue
                        }
                        MMLog.log("delete: post \(reference.postId) failed (\(error.statusCode.map(String.init) ?? "-")): \(describeError(error)); restoring it")
                        await self.restorePost(reference)
                        if case .forbidden = error {
                            self.notice(.deleteForbidden)
                        } else {
                            self.notice(.deleteFailed(detail: describeError(error)))
                        }
                    } catch {
                        await self.restorePost(reference)
                        self.notice(.deleteFailed(detail: describeError(error)))
                    }
                }
            } else {
                MMLog.log("delete: \(operation.messageIds.count) message(s) deleted on this device only")
            }
        } else if let operation = contents as? CloudChatRemoveChatOperation {
            // Leave Group / Delete Chat (3D-2): leave the channel, or close the DM or group message.
            await self.removeChat(peerId: operation.peerId)
        } else {
            MMLog.log("delete: \(type(of: contents)) is not supported by Mattermost; dropped")
        }
        await self.postbox.mmTransaction { transaction in
            let _ = transaction.operationLogRemoveEntry(peerId: key.peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: key.tagLocalIndex)
        }
        return true
    }

    /// Puts a post back after a delete the server refused.
    func restorePost(_ reference: (channelId: String, postId: String)) async {
        guard let post = try? await self.client.post(id: reference.postId) else {
            return
        }
        await self.ensureUsers(referencedUserIds([post]))
        await self.postbox.mmTransaction { transaction in
            self.writeMessages(channelId: reference.channelId, posts: [post], transaction: transaction)
        }
    }

    /// Tombstones posts and the replies of deleted thread roots (Mattermost deletes a whole thread with its
    /// root and announces only the root), and removes their messages. Returns the number of removed messages.
    @discardableResult
    func removePostsLocally(_ postIds: [String], channelId: String, transaction: Transaction) -> Int {
        guard let channelState = self.channelState(channelId) else {
            return 0
        }
        let replies = self.store.threadReplies(rootPostIds: postIds, channelId: channelId).values.flatMap { $0 }.filter { !$0.isDeleted }.map { $0.postId }
        var store = self.storeRef()
        var newlyDeleted: [MessageIdEntry] = []
        let _ = self.store.idMapTransaction {
            newlyDeleted = self.allocator.markDeleted(postIds + replies, channelId: channelId, store: &store)
        }
        let ids = newlyDeleted.map { MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: $0.localId) }
        if !ids.isEmpty {
            transaction.deleteMessages(ids, forEachMedia: nil)
        }
        return ids.count
    }

    // MARK: Mute

    /// Pending notification settings (`updatePeerMuteSetting`): mute is the channel member's
    /// `mark_unread: mention`, unmute `mark_unread: all`, as Mattermost's own clients do (the server then
    /// skips push/desktop notifications for the muted channel except mentions). Mattermost has no timed mute:
    /// any mute is until unmuted.
    func pushNotificationSettings(peerId: PeerId) async -> Bool {
        let settings: TelegramPeerNotificationSettings? = await self.postbox.mmTransaction { transaction in
            return transaction.getPendingPeerNotificationSettings(peerId) as? TelegramPeerNotificationSettings
        }
        guard let settings = settings else {
            return true
        }
        guard let channelId = self.channelId(forPeerId: peerId) else {
            await self.postbox.mmTransaction { transaction in
                transaction.updatePendingPeerNotificationSettings(peerId: peerId, settings: nil)
            }
            return true
        }
        var muted = false
        if case let .muted(until) = settings.muteState, until > Int32(Date().timeIntervalSince1970) {
            muted = true
        }
        let props = ["mark_unread": muted ? "mention" : "all"]
        do {
            try await self.retryingTransient("notify props of \(channelId)", isStillWanted: { true }) {
                try await self.client.updateChannelNotifyProps(channelId: channelId, props: props)
            }
            await self.postbox.mmTransaction { transaction in
                let applied = settings.withUpdatedMuteState(muted ? .muted(until: Int32.max) : .unmuted)
                transaction.updateCurrentPeerNotificationSettings([peerId: applied])
                if let pending = transaction.getPendingPeerNotificationSettings(peerId), pending.isEqual(to: settings) {
                    transaction.updatePendingPeerNotificationSettings(peerId: peerId, settings: nil)
                }
                self.state.with { state in
                    state.channels[channelId]?.member.notifyProps["mark_unread"] = props["mark_unread"]
                }
            }
            MMLog.log("mute: \(channelId) \(muted ? "muted" : "unmuted")")
        } catch {
            await self.postbox.mmTransaction { transaction in
                transaction.updatePendingPeerNotificationSettings(peerId: peerId, settings: nil)
            }
            self.notice(.notificationsFailed(detail: describeError(error)))
        }
        return true
    }

    // MARK: Favorites

    /// `SynchronizePinnedChats` op log (pin/unpin in the chat list): pinned chats are the Favorites sidebar
    /// category. The entry holds the pinned list before the first unsynced change, so only the chats the user
    /// pinned or unpinned since are changed on the server.
    func pushPinnedChats(_ key: OperationLogKey) async -> Bool {
        let snapshot: (previous: [PinnedItemId], current: [PinnedItemId], isRoot: Bool)? = await self.postbox.mmTransaction { transaction in
            var operation: SynchronizePinnedChatsOperation?
            transaction.operationLogEnumerateEntries(peerId: key.peerId, tag: OperationLogTags.SynchronizePinnedChats, { entry in
                if entry.tagLocalIndex == key.tagLocalIndex {
                    operation = entry.contents as? SynchronizePinnedChatsOperation
                    return false
                }
                return true
            })
            guard let operation = operation else {
                return nil
            }
            let isRoot = key.peerId.id._internalGetInt64Value() == Int64(PeerGroupId.root.rawValue)
            return (operation.previousItemIds, transaction.getPinnedItemIds(groupId: .root), isRoot)
        }
        guard let snapshot = snapshot else {
            return true
        }
        if snapshot.isRoot {
            func channelIds(_ items: [PinnedItemId]) -> [String] {
                return items.compactMap { item -> String? in
                    guard case let .peer(peerId) = item else {
                        return nil
                    }
                    return self.channelId(forPeerId: peerId)
                }
            }
            let previous = channelIds(snapshot.previous)
            let current = channelIds(snapshot.current)
            let added = current.filter { !previous.contains($0) }
            let removed = previous.filter { !current.contains($0) }
            if !added.isEmpty || !removed.isEmpty {
                do {
                    try await self.updateFavorites(added: added, removed: removed)
                    MMLog.log("favorites: +\(added) -\(removed)")
                } catch let error as MattermostError where error.isTransient {
                    return false
                } catch {
                    self.notice(.favoritesFailed(detail: describeError(error)))
                }
            }
        }
        await self.postbox.mmTransaction { transaction in
            let _ = transaction.operationLogRemoveEntry(peerId: key.peerId, tag: OperationLogTags.SynchronizePinnedChats, tagLocalIndex: key.tagLocalIndex)
        }
        return true
    }

    /// Moves channels into or out of each team's Favorites category (one `PUT` per team with every changed
    /// category: the server does not move a channel out of its previous category by itself). A DM or group
    /// message is in every team's sidebar, so it is (un)favorited in all of them.
    func updateFavorites(added: [String], removed: [String], onlyTeamId: String? = nil) async throws {
        let teams = self.state.with { $0.teams }
        for team in teams where onlyTeamId == nil || team.id == onlyTeamId {
            func belongs(_ channelId: String) -> Bool {
                guard let channelState = self.channelState(channelId) else {
                    return false
                }
                return channelState.teamId.isEmpty || channelState.teamId == team.id || channelState.kind != .channel
            }
            let categories: OrderedSidebarCategories
            do {
                categories = try await self.client.sidebarCategories(teamId: team.id)
            } catch let error as MattermostError {
                if case .notFound = error {
                    // Servers before sidebar categories: the `favorite_channel` preference.
                    try await self.updateFavoritePreferences(added: added, removed: removed)
                    return
                }
                throw error
            }
            guard var favorites = categories.categories.first(where: { $0.type == .favorites }) else {
                continue
            }
            var changed: [String: SidebarCategory] = [:]
            func category(_ id: String) -> SidebarCategory? {
                return changed[id] ?? categories.categories.first(where: { $0.id == id })
            }
            for channelId in added.reversed() where belongs(channelId) && !favorites.channelIds.contains(channelId) {
                for source in categories.categories where source.type != .favorites && source.channelIds.contains(channelId) {
                    if var updated = category(source.id) {
                        updated.channelIds.removeAll(where: { $0 == channelId })
                        changed[source.id] = updated
                    }
                }
                favorites.channelIds.insert(channelId, at: 0)
            }
            for channelId in removed where favorites.channelIds.contains(channelId) {
                favorites.channelIds.removeAll(where: { $0 == channelId })
                let isDirect = self.channelState(channelId).map { $0.channel.type == .directMessage || $0.channel.type == .groupMessage } ?? false
                let defaultKind: SidebarCategory.Kind = isDirect ? .directMessages : .channels
                if let target = categories.categories.first(where: { $0.type == defaultKind }), var updated = category(target.id), !updated.channelIds.contains(channelId) {
                    updated.channelIds.insert(channelId, at: 0)
                    changed[target.id] = updated
                }
            }
            let original = categories.categories.first(where: { $0.id == favorites.id })
            if original?.channelIds != favorites.channelIds {
                changed[favorites.id] = favorites
            }
            if !changed.isEmpty {
                try await self.retryingTransient("favorites in \(team.name)", isStillWanted: { true }) {
                    try await self.client.updateSidebarCategories(Array(changed.values), teamId: team.id)
                }
            }
        }
    }

    private func updateFavoritePreferences(added: [String], removed: [String]) async throws {
        if !added.isEmpty {
            try await self.client.savePreferences(added.map { Preference(userId: self.ownUserId, category: PreferenceCategory.favoriteChannel, name: $0, value: "true") })
        }
        if !removed.isEmpty {
            try await self.client.deletePreferences(removed.map { Preference(userId: self.ownUserId, category: PreferenceCategory.favoriteChannel, name: $0, value: "true") })
        }
    }

    /// Favorites changed on the server (another client, or our own `PUT`): pinned chats follow, unless a local
    /// pin change is still waiting to be pushed.
    func refreshFavorites() async {
        let rootOperationsPeerId = PeerId(namespace: PeerId.Namespace._internalFromInt32Value(0), id: PeerId.Id._internalFromInt64Value(Int64(PeerGroupId.root.rawValue)))
        let hasPendingChanges: Bool = await self.postbox.mmTransaction { transaction in
            var found = false
            transaction.operationLogEnumerateEntries(peerId: rootOperationsPeerId, tag: OperationLogTags.SynchronizePinnedChats, { _ in
                found = true
                return false
            })
            return found
        }
        if hasPendingChanges {
            return
        }
        var favoriteChannelIds: [String] = []
        var favoritesByTeam: [String: [String]] = [:]
        let teams = self.state.with({ $0.teams })
        for team in teams {
            guard let categories = try? await self.client.sidebarCategories(teamId: team.id) else {
                return
            }
            for category in categories.orderedCategories where category.type == .favorites {
                favoritesByTeam[team.id, default: []].append(contentsOf: category.channelIds)
                for channelId in category.channelIds where !favoriteChannelIds.contains(channelId) {
                    favoriteChannelIds.append(channelId)
                }
            }
        }
        let foldersChanged: Bool = self.state.with { state in
            let changed = state.favoritesByTeam != favoritesByTeam
            state.favoritesByTeam = favoritesByTeam
            return changed
        }
        if foldersChanged {
            await self.writeTeamFolders(teams: teams)
        }
        await self.postbox.mmTransaction { transaction in
            let pinned = favoriteChannelIds.compactMap { channelId -> PinnedItemId? in
                return self.channelState(channelId).map { .peer($0.peerId) }
            }
            if pinned != transaction.getPinnedItemIds(groupId: .root) {
                transaction.setPinnedItemIds(groupId: .root, itemIds: pinned)
                MMLog.log("favorites: \(pinned.count) pinned chats from the server")
            }
        }
    }

    /// Pin changes inside a team folder (`toggleItemPinned(.filter(...))`, which only edits the local folder)
    /// go to that team's Favorites category.
    func startFolderPinObserver() {
        let queue = Queue()
        // Consecutive emissions are compared; a state that `writeTeamFolders` wrote (`folderPins`) is ours.
        var lastSeen: [String: [PeerId]] = [:]
        self.addDisposable((TelegramEngine(account: self.account).peers.updatedChatListFilters()
        |> deliverOn(queue)).start(next: { [weak self] filters in
            guard let self = self else {
                return
            }
            var changes: [(teamId: String, previous: [PeerId], current: [PeerId])] = []
            for team in self.state.with({ $0.teams }) {
                guard let value = self.store.cursor(MattermostCursorKey.folderId(teamId: team.id)), let folderId = Int32(value) else {
                    continue
                }
                guard let filter = filters.first(where: { $0.id == folderId }), case let .filter(_, _, _, data) = filter else {
                    continue
                }
                let current = data.includePeers.pinnedPeers
                let previous = lastSeen[team.id]
                lastSeen[team.id] = current
                guard let previousPins = previous, Set(previousPins) != Set(current) else {
                    continue
                }
                let isOurWrite: Bool = self.state.with { state in
                    if let written = state.folderPins[team.id], Set(written) == Set(current) {
                        return true
                    }
                    state.folderPins[team.id] = current
                    return false
                }
                if !isOurWrite {
                    changes.append((team.id, previousPins, current))
                }
            }
            for change in changes {
                let added = change.current.filter { !change.previous.contains($0) }.compactMap { self.channelId(forPeerId: $0) }
                let removed = change.previous.filter { !change.current.contains($0) }.compactMap { self.channelId(forPeerId: $0) }
                if added.isEmpty && removed.isEmpty {
                    continue
                }
                Task {
                    do {
                        try await self.updateFavorites(added: added, removed: removed, onlyTeamId: change.teamId)
                        self.state.with { state in
                            var favorites = state.favoritesByTeam[change.teamId] ?? []
                            favorites.removeAll(where: { removed.contains($0) })
                            favorites.insert(contentsOf: added.filter { !favorites.contains($0) }, at: 0)
                            state.favoritesByTeam[change.teamId] = favorites
                        }
                        MMLog.log("favorites: team \(change.teamId) folder +\(added) -\(removed)")
                    } catch {
                        self.notice(.favoritesFailed(detail: describeError(error)))
                    }
                }
            }
        }))
    }

    // MARK: Typing

    /// The user's own typing (`Account.mattermostLocalInputActivities`) as WebSocket `user_typing`, with the
    /// thread root as `parent_id` in a thread, at most once per the server's
    /// `TimeBetweenUserTypingUpdatesMilliseconds` per chat while the user keeps typing.
    func pushTyping(_ activities: [PeerActivitySpace: (activity: PeerInputActivity, updateId: Int32)]) {
        let now = CFAbsoluteTimeGetCurrent()
        let interval = self.typingInterval.current
        var toSend: [PeerActivitySpace] = []
        self.typingSent.with { sent in
            for space in sent.keys where activities[space] == nil {
                sent[space] = nil
            }
            for (space, value) in activities {
                guard case .typingText = value.activity else {
                    continue
                }
                if let last = sent[space], last.updateId == value.updateId || now - last.time < interval {
                    continue
                }
                sent[space] = (now, value.updateId)
                toSend.append(space)
            }
        }
        guard let socket = self.socket else {
            return
        }
        for space in toSend {
            guard let channelId = self.channelId(forPeerId: space.peerId) else {
                continue
            }
            var parentId: String?
            if case let .thread(threadId) = space.category, let rootLocalId = Int32(exactly: threadId), threadId != 1 {
                parentId = self.postReference(for: MessageId(peerId: space.peerId, namespace: Namespaces.Message.Cloud, id: rootLocalId))?.postId
            }
            Task {
                do {
                    try await socket.userTyping(channelId: channelId, parentId: parentId)
                    MMLog.log("typing: sent for \(channelId)\(parentId.map { " (thread \($0))" } ?? "")")
                } catch {
                    MMLog.log("typing: not sent for \(channelId): \(error)")
                }
            }
        }
    }
}
