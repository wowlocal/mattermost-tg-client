import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

extension MattermostAccountSync {
    /// After a WebSocket connection that was not resumed (the server did not replay missed events): reload
    /// channels and memberships, then every channel's posts created, edited or deleted since `last_sync_at`.
    func catchUp() async {
        guard self.state.with({ $0.isBootstrapped }) else {
            return
        }
        let since: Int64? = await self.postbox.mmTransaction { _ in
            return self.store.cursor(MattermostCursorKey.lastSyncAt).flatMap { Int64($0) }
        }
        guard let since = since else {
            return
        }
        self.beginUpdating()
        defer {
            self.endUpdating()
        }
        let started = CFAbsoluteTimeGetCurrent()
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let teams = self.state.with { $0.teams }
            let snapshot = try await self.loadChannels(teams: teams, categories: false)
            var channelIds: [String] = []
            for (channelId, item) in snapshot.channels {
                guard let member = snapshot.members[channelId] else {
                    continue
                }
                if self.channelState(channelId) == nil {
                    await self.refreshChannel(channelId)
                } else {
                    let mentionCount = self.memberMentionCount(member)
                    self.state.with { state in
                        state.channels[channelId]?.channel = item.channel
                        state.channels[channelId]?.member = member
                        state.channels[channelId]?.mentionCount = mentionCount
                    }
                }
                if self.channelState(channelId) != nil {
                    channelIds.append(channelId)
                }
            }
            let changed = MMLocked<Int>(0)
            try await self.forEachConcurrently(channelIds, limit: 6) { channelId in
                do {
                    let list = try await self.client.posts(channelId: channelId, since: since)
                    let count = await self.applySince(channelId: channelId, list: list, since: since)
                    changed.with { $0 += count }
                } catch {
                    MMLog.log("catch-up: \(channelId) failed: \(error)")
                }
            }
            // A small overlap: posts saved in the same millisecond as the request would otherwise be missed.
            await self.postbox.mmTransaction { _ in
                self.store.setCursor(MattermostCursorKey.lastSyncAt, String(startedAt - 2000))
            }
            MMLog.log("catch-up since \(since): \(channelIds.count) channels, \(changed.current) posts in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        } catch {
            MMLog.log("catch-up failed: \(error)")
        }
    }

    /// Applies a `since=` result: deletions, edits of loaded posts, and new posts (appended to the live
    /// history). More new posts than a page: the newest island stops being live and a hole opens above it, so
    /// the chat loads them like any other history.
    private func applySince(channelId: String, list: PostList, since: Int64) async -> Int {
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
