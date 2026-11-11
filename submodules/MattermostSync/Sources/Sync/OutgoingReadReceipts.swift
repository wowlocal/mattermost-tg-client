import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

extension MattermostAccountSync {
    private func outgoingReadCursor(_ channelId: String) -> String { "dm_read_receipt_1:\(channelId)" }

    func outgoingReadMaxId(channelId: String) -> Int32 {
        guard let text = self.store.cursor(self.outgoingReadCursor(channelId)), let data = text.data(using: .utf8),
              let checkpoint = try? JSONDecoder().decode(DirectMessageReadCheckpoint.self, from: data) else { return 0 }
        return self.store.entries(channelId: channelId, postIds: [checkpoint.postId])[checkpoint.postId]?.localId
            ?? self.store.entries(channelId: channelId, olderThan: checkpoint.key, limit: 1).first?.localId ?? 0
    }

    var receiptPollingVisible: Bool {
        #if os(iOS)
        return MattermostSync.applicationInForeground.current
        #else
        return MattermostSync.receiptDisplayVisible.current
        #endif
    }

    private func receiptRoot(state: ChannelState) async -> DirectMessageReceiptPost? {
        return await self.postbox.mmTransaction { transaction in
            let watermark = self.outgoingReadMaxId(channelId: state.channel.id)
            var before: PostOrderKey?
            while true {
                let entries = self.store.entries(channelId: state.channel.id, olderThan: before, limit: 60)
                let posts = entries.compactMap { entry -> DirectMessageReceiptPost? in
                    guard entry.localId > watermark else { return nil }
                    let message = transaction.getMessage(MessageId(peerId: state.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
                    return DirectMessageReceiptPost(postId: entry.postId, localId: entry.localId, isOwn: message.map { !$0.flags.contains(.Incoming) && $0.author?.id == self.ownPeerId } ?? false, isDeleted: entry.isDeleted, eligible: message?.mattermostReadReceiptEligible ?? false, needsMigration: !entry.isDeleted && message?.mattermostReadReceiptEligible == false && message?.tags.contains(.mattermostRootPost) == true && self.store.cursor("dm_receipt_checked_2:\(entry.postId)") == nil)
                }
                if let root = DirectMessageReceiptPost.newestUnconfirmedRoot(in: posts, after: watermark) { return root }
                guard entries.count == 60, let last = entries.last, last.localId > watermark else { return nil }
                before = last.key
            }
        }
    }

    func startOutgoingReadPolling() {
        self.addTask(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                if self.isConnected.current && self.receiptPollingVisible { await self.pollOutgoingReadReceipts() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
    }

    func pollOutgoingReadReceipts() async {
        let now = ProcessInfo.processInfo.systemUptime
        let interests = self.receiptInterests.with { interests -> ReceiptPollInterests in
            interests.written = interests.written.filter { now - $0.value < 900 }
            return interests
        }
        let visible = interests.list.union(interests.histories.keys)
        let snapshot = self.state.with { state in
            state.channels.values.filter { $0.kind == .direct && (visible.contains($0.peerId) || interests.written[$0.channel.id] != nil) }.compactMap { channel -> (ChannelState, User)? in
                guard let partner = channel.channel.directMessagePartnerId(myUserId: self.ownUserId), let user = state.users[partner], !user.isDeactivated else { return nil }
                return (channel, user)
            }
        }
        guard !snapshot.isEmpty else { return }
        let candidates = snapshot.map { channel, user in
            DirectMessageReceiptPollCandidate(channelId: channel.channel.id, revision: channel.channel.lastPostAt, isBot: user.isBot, priority: interests.histories[channel.peerId] != nil ? 2 : interests.list.contains(channel.peerId) ? 1 : 0, opened: interests.opened[channel.peerId] ?? 0)
        }
        guard let candidate = self.receiptScheduler.with({ $0.next(candidates, now: now) }), let state = self.channelState(candidate.channelId), let partner = state.channel.directMessagePartnerId(myUserId: self.ownUserId) else { return }
        let channelId = candidate.channelId
        var outcome = DirectMessageReceiptPollResult.retryable
        defer {
            self.receiptScheduler.with { $0.completed(candidate, result: outcome, now: ProcessInfo.processInfo.systemUptime) }
        }
        do {
            guard var root = await self.receiptRoot(state: state) else { outcome = .noPending; return }
            let cost = root.needsMigration ? 3 : 2
            guard self.receiptScheduler.with({ $0.reserveRequests(cost, now: ProcessInfo.processInfo.systemUptime) }) else { return }
            if root.needsMigration {
                let post = try await self.client.post(id: root.postId)
                let migrated = await self.postbox.mmTransaction { transaction in
                    let result = self.write(PageWrite(channelId: channelId, kind: .singles, run: [post]), transaction: transaction)
                    if !result.failed { self.store.setCursor("dm_receipt_checked_2:\(post.id)", "1") }
                    return result
                }
                guard !migrated.failed else { return }
                guard let updated = await self.receiptRoot(state: state) else { outcome = .noPending; return }
                guard !updated.needsMigration else { return }
                root = updated
            }
            let postId = root.postId
            guard !Task.isCancelled, !self.isStopped, self.receiptPollingVisible else { outcome = .aborted; return }
            let channel = try await self.client.channel(id: channelId)
            let members = try await self.client.channelMembers(channelId: channelId, page: 0, perPage: 3)
            guard channel.type == .directMessage, members.count == 2, let member = members.first(where: { $0.userId == partner }) else { return }
            guard DirectMessageReadReceipt.isCaughtUp(total: channel.totalMsgCount, totalRoots: channel.totalMsgCountRoot, viewed: member.msgCount, viewedRoots: member.msgCountRoot) else { outcome = .unconfirmed; return }
            await self.postbox.mmTransaction { transaction in
                guard let entry = self.store.entries(channelId: channelId, postIds: [postId])[postId], entry.localId > self.outgoingReadMaxId(channelId: channelId) else { return }
                let checkpoint = DirectMessageReadCheckpoint(key: entry.key)
                guard let data = try? JSONEncoder().encode(checkpoint), let text = String(data: data, encoding: .utf8) else { return }
                self.store.setCursor(self.outgoingReadCursor(channelId), text)
                transaction.applyOutgoingReadMaxId(MessageId(peerId: state.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
                MMLog.log("read receipt: DM \(channelId) through \(postId), counters \(member.msgCount)/\(channel.totalMsgCount) roots \(member.msgCountRoot)/\(channel.totalMsgCountRoot)")
            }
            outcome = .confirmed
        } catch {
            MMLog.log("read receipt: DM \(channelId) sample failed: \(error)")
        }
    }
}

struct ReceiptPollInterests {
    var opened: [PeerId: Int] = [:]
    var histories: [PeerId: Int] = [:]
    var list = Set<PeerId>()
    var written: [String: Double] = [:]
}
