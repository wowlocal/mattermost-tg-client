import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

extension MattermostAccountSync {
    /// Catches up (below), or waits for the catch-up that is already running (Phase 4B: a reconnect, the app
    /// becoming active and a background refresh can ask at the same time).
    func catchUp() async {
        let task = self.catchUpInFlight.with { current -> Task<Void, Never> in
            if let current = current {
                return current
            }
            let task = Task { [weak self] in
                await self?.performCatchUp()
                self?.catchUpInFlight.with { $0 = nil }
            }
            current = task
            return task
        }
        await task.value
    }

    /// After a WebSocket connection that was not resumed (the server did not replay missed events), when the app
    /// becomes active after a while, or from a background refresh: reload channels and memberships, then the posts
    /// created, edited or deleted since `last_sync_at` of every channel with a new post (`last_post_at`).
    ///
    /// Phase 4B: channels without a new post get no request (600 `since=` requests took 6 s on a local server).
    /// Their read state still follows the server's counters; edits, deletions and reactions they may have had
    /// are loaded when the chat opens, or by the next catch-up that fetches the channel (`StaleChannels`).
    /// Channels the user was added to meanwhile are written together, not one by one.
    private func performCatchUp() async {
        guard self.state.with({ $0.isBootstrapped }) else {
            return
        }
        let since: Int64? = await self.postbox.mmTransaction { _ in
            return self.store.cursor(MattermostCursorKey.lastSyncAt).flatMap { Int64($0) }
        }
        guard let since = since else {
            return
        }
        self.loadStaleChannelsIfNeeded()
        self.beginUpdating()
        defer {
            self.endUpdating()
        }
        let started = CFAbsoluteTimeGetCurrent()
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let teams = self.state.with { $0.teams }
            let snapshot = try await self.loadChannels(teams: teams, categories: false)
            var added: [(channel: Channel, member: ChannelMember, teamId: String)] = []
            var active: [String] = []
            var quiet: [String] = []
            var readStateChanged: [String] = []
            for (channelId, item) in snapshot.channels {
                guard let member = snapshot.members[channelId] else {
                    continue
                }
                if let previous = self.channelState(channelId) {
                    let mentionCount = self.memberMentionCount(member)
                    self.state.with { state in
                        state.channels[channelId]?.channel = item.channel
                        state.channels[channelId]?.member = member
                        state.channels[channelId]?.mentionCount = mentionCount
                    }
                    let old = previous.member
                    if old.lastViewedAt != member.lastViewedAt || old.msgCount != member.msgCount || old.msgCountRoot != member.msgCountRoot || old.mentionCount != member.mentionCount || old.mentionCountRoot != member.mentionCountRoot || previous.channel.totalMsgCount != item.channel.totalMsgCount || previous.channel.totalMsgCountRoot != item.channel.totalMsgCountRoot {
                        readStateChanged.append(channelId)
                    }
                } else {
                    added.append((item.channel, member, item.teamId))
                }
                if item.channel.lastPostAt > since {
                    active.append(channelId)
                } else {
                    quiet.append(channelId)
                }
            }
            if !added.isEmpty {
                await self.addChannels(added)
            }
            active = active.filter { self.channelState($0) != nil }
            quiet = quiet.filter { self.channelState($0) != nil }
            // Read on another device, or counters moved: the badges follow without asking for posts.
            let quietSet = Set(quiet)
            let readOnly = readStateChanged.filter { quietSet.contains($0) }
            if !readOnly.isEmpty {
                await self.postbox.mmTransaction { transaction in
                    for channelId in readOnly {
                        self.applyServerReadState(channelId: channelId, transaction: transaction)
                    }
                }
            }
            self.markStale(quiet, since: since)
            let changed = MMLocked<Int>(0)
            try await self.forEachConcurrently(active, limit: 6) { channelId in
                do {
                    let channelSince = self.catchUpSince(channelId, since: since)
                    let list = try await self.client.posts(channelId: channelId, since: channelSince)
                    let count = await self.applySince(channelId: channelId, list: list, since: channelSince)
                    changed.with { $0 += count }
                } catch {
                    MMLog.log("catch-up: \(channelId) failed: \(error)")
                    self.markStale([channelId], since: since)
                }
            }
            self.clearStale(active)
            // A small overlap: posts saved in the same millisecond as the request would otherwise be missed.
            await self.postbox.mmTransaction { _ in
                self.store.setCursor(MattermostCursorKey.lastSyncAt, String(startedAt - 2000))
            }
            let staleCount = self.staleChannels.with { $0?.since.count ?? 0 }
            MMLog.log("catch-up since \(since): \(snapshot.channels.count) channels, \(active.count) with new posts (\(changed.current) posts), \(readOnly.count) read states, \(added.count) added, \(staleCount) stale, in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        } catch {
            MMLog.log("catch-up failed: \(error)")
        }
    }

    /// Channels the user was added to while the WebSocket was away, written in one transaction (each would
    /// otherwise be loaded and written on its own, `refreshChannel`).
    private func addChannels(_ items: [(channel: Channel, member: ChannelMember, teamId: String)]) async {
        let ownUserId = self.ownUserId
        await self.ensureUsers(Set(items.compactMap { $0.channel.directMessagePartnerId(myUserId: ownUserId) }))
        await self.ensureRoles(items.map { $0.member.roles })
        await self.postbox.mmTransaction { transaction in
            for item in items {
                self.writeChannel(item.channel, member: item.member, teamId: item.teamId, transaction: transaction)
            }
        }
        if items.contains(where: { $0.channel.type != .directMessage }) {
            await self.writeTeamFolders(teams: self.state.with { $0.teams })
        }
        MMLog.log("catch-up: \(items.count) channel(s) added")
    }

    /// Applies a `since=` result: deletions, edits of loaded posts, and new posts (appended to the live
    /// history). More new posts than a page: the newest island stops being live and a hole opens above it, so
    /// the chat loads them like any other history.
    func applySince(channelId: String, list: PostList, since: Int64) async -> Int {
        let posts = list.posts.values.sorted(by: { $0.createAt < $1.createAt })
        if posts.isEmpty {
            await self.postbox.mmTransaction { transaction in
                self.applyServerReadState(channelId: channelId, transaction: transaction)
            }
            return 0
        }
        await self.ensureUsers(referencedUserIds(posts))
        let needsLatestPage = MMLocked<Bool>(false)
        let count = await self.postbox.mmTransaction { transaction -> Int in
            guard let channelState = self.channelState(channelId) else {
                return 0
            }
            var store = self.storeRef()
            let ids = posts.map { $0.id }
            let known = self.store.entries(channelId: channelId, postIds: ids)
            let deleted = posts.filter { $0.deleteAt > 0 }.map { $0.id }
            var newlyDeleted: [MessageIdEntry] = []
            if !deleted.isEmpty {
                let _ = self.store.idMapTransaction {
                    newlyDeleted = self.allocator.markDeleted(deleted, channelId: channelId, store: &store)
                }
                transaction.deleteMessages(newlyDeleted.map { MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: $0.localId) }, forEachMedia: nil)
            }
            let live = posts.filter { $0.deleteAt == 0 }
            let edited = live.filter { known[$0.id] != nil }
            let fresh = live.filter { known[$0.id] == nil && $0.createAt > since }
            if !edited.isEmpty {
                self.writeMessages(channelId: channelId, posts: edited, transaction: transaction)
            }
            if fresh.count > self.perPage && self.storeRef().islands(channelId: channelId).isEmpty {
                // A channel with nothing loaded yet (joined while the app was not running): load its newest
                // page like the bootstrap does. Opening a hole here would leave it looking empty, since the
                // ID map has no island to keep a hole next to.
                needsLatestPage.with { $0 = true }
            } else if fresh.count > self.perPage {
                let _ = self.store.idMapTransaction {
                    self.allocator.invalidateLatest(channelId: channelId, store: &store)
                }
                let top = self.store.entries(channelId: channelId, olderThan: nil, limit: 1).first?.localId ?? 0
                self.syncHoles(channelId: channelId, channelState: channelState, ranges: [(top + 1) ... self.maxLocalId], transaction: transaction)
            } else if !fresh.isEmpty {
                self.write(PageWrite(channelId: channelId, kind: .singles, run: fresh), transaction: transaction)
            }
            self.applyServerReadState(channelId: channelId, transaction: transaction)
            return deleted.count + edited.count + fresh.count
        }
        // Roots of new replies: their reply counts (the `since=` list says 0 for every root).
        await self.refreshThreadRoots(channelId: channelId, posts: posts.filter { $0.createAt > since })
        if needsLatestPage.current {
            do {
                try await self.loadPage(channelId: channelId, cursor: .latest, requestedRange: nil, resetReadState: true)
            } catch {
                MMLog.log("catch-up: newest page of \(channelId) failed: \(error)")
            }
        }
        return count
    }
}
