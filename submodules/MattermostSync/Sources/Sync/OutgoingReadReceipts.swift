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
        return MattermostSync.applicationInForeground.current && MattermostSync.receiptVisibleAccounts.with { $0.contains(self.account.id) }
        #else
        return MattermostSync.receiptDisplayVisible.current
        #endif
    }

    private func receiptRoot(state: ChannelState) async -> (root: DirectMessageReceiptPost?, hasMore: Bool) {
        return await self.postbox.mmTransaction { transaction in
            let channelId = state.channel.id
            let watermark = self.outgoingReadMaxId(channelId: channelId)
            var scan = self.receiptScans.with { $0[channelId] } ?? ReceiptRootScan(revision: state.channel.lastPostAt, watermark: watermark)
            if scan.revision != state.channel.lastPostAt || scan.watermark != watermark {
                scan = ReceiptRootScan(revision: state.channel.lastPostAt, watermark: watermark)
            }
            var inspected = 0
            while inspected < 180 {
                let entries = self.store.entries(channelId: channelId, olderThan: scan.before, limit: 60)
                inspected += entries.count
                for entry in entries {
                    guard entry.localId > watermark, !entry.isDeleted,
                          let message = transaction.getMessage(MessageId(peerId: state.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)),
                          !message.flags.contains(.Incoming), message.author?.id == self.ownPeerId else { continue }
                    let eligible = message.mattermostReadReceiptEligible
                    let needsMigration = !eligible && message.tags.contains(.mattermostRootPost) && self.store.cursor("dm_receipt_checked_2:\(entry.postId)") == nil
                    if eligible || needsMigration {
                        self.receiptScans.with { $0[channelId] = nil }
                        return (DirectMessageReceiptPost(postId: entry.postId, localId: entry.localId, isOwn: true, eligible: eligible, needsMigration: needsMigration), false)
                    }
                }
                guard entries.count == 60, let last = entries.last, last.localId > watermark else {
                    self.receiptScans.with { $0[channelId] = nil }
                    return (nil, false)
                }
                scan.before = last.key
            }
            self.receiptScans.with { $0[channelId] = scan }
            MMLog.log("read receipt: DM \(channelId) scan yielded after \(inspected) entries")
            return (nil, true)
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
        let visible = interests.list.union(interests.focused.keys)
        let snapshot = self.state.with { state in
            state.channels.values.filter { $0.kind == .direct && (visible.contains($0.peerId) || interests.written[$0.channel.id] != nil) }.compactMap { channel -> (ChannelState, User)? in
                guard let partner = channel.channel.directMessagePartnerId(myUserId: self.ownUserId), let user = state.users[partner], !user.isDeactivated else { return nil }
                return (channel, user)
            }
        }
        guard !snapshot.isEmpty else { return }
        let candidates = snapshot.map { channel, user in
            DirectMessageReceiptPollCandidate(channelId: channel.channel.id, revision: channel.channel.lastPostAt, isBot: user.isBot, priority: interests.focused[channel.peerId] != nil ? 2 : interests.list.contains(channel.peerId) ? 1 : 0, opened: interests.opened[channel.peerId] ?? 0, written: interests.written[channel.channel.id] ?? 0)
        }
        guard let candidate = self.receiptScheduler.with({ $0.next(candidates, now: now) }), let state = self.channelState(candidate.channelId), let partner = state.channel.directMessagePartnerId(myUserId: self.ownUserId) else { return }
        let channelId = candidate.channelId
        var outcome = DirectMessageReceiptPollResult.retryable
        defer {
            self.receiptScheduler.with { $0.completed(candidate, result: outcome, now: ProcessInfo.processInfo.systemUptime) }
        }
        do {
            let selection = await self.receiptRoot(state: state)
            guard var root = selection.root else { outcome = selection.hasMore ? .aborted : .noPending; return }
            let cost = root.needsMigration ? 3 : 2
            guard self.receiptScheduler.with({ $0.reserveRequests(cost, for: candidate, now: ProcessInfo.processInfo.systemUptime) }) else { return }
            if root.needsMigration {
                let post = try await self.client.post(id: root.postId)
                let migrated = await self.postbox.mmTransaction { transaction in
                    let result = self.write(PageWrite(channelId: channelId, kind: .singles, run: [post]), transaction: transaction)
                    if !result.failed { self.store.setCursor("dm_receipt_checked_2:\(post.id)", "1") }
                    return result
                }
                guard !migrated.failed else { return }
                let nextSelection = await self.receiptRoot(state: state)
                guard let updated = nextSelection.root else { outcome = nextSelection.hasMore ? .aborted : .noPending; return }
                guard !updated.needsMigration else { return }
                root = updated
            }
            let postId = root.postId
            guard !Task.isCancelled, !self.isStopped, self.receiptPollingVisible else { outcome = .aborted; return }
            let channel = try await self.client.channel(id: channelId)
            let members = try await self.client.channelMembers(channelId: channelId, page: 0, perPage: 3)
            guard channel.type == .directMessage, members.count == 2, let member = members.first(where: { $0.userId == partner }) else { outcome = .noPending; return }
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
            if let error = error as? MattermostError, !error.isTransient, error != .cancelled { outcome = .noPending }
            MMLog.log("read receipt: DM \(channelId) sample failed: \(error)")
        }
    }
}

struct ReceiptPollInterests {
    var opened: [PeerId: Int] = [:]
    var focused: [PeerId: Int] = [:]
    var list = Set<PeerId>()
    var written: [String: Double] = [:]
}

struct ReceiptRootScan {
    var revision: Int64
    var watermark: Int32
    var before: PostOrderKey?
}
