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

    func startOutgoingReadPolling() {
        self.addTask(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                if self.isConnected.current && self.presenceActive.current { await self.pollOutgoingReadReceipts() }
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
        let candidates = await self.postbox.mmTransaction { transaction -> [DirectMessageReceiptPollCandidate] in
            return snapshot.compactMap { state, user in
                let channelId = state.channel.id
                guard let entry = self.store.entries(channelId: channelId, olderThan: nil, limit: 1).first,
                      !entry.isDeleted, entry.localId > self.outgoingReadMaxId(channelId: channelId),
                      let message = transaction.getMessage(MessageId(peerId: state.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)),
                      !message.flags.contains(.Incoming), message.author?.id == self.ownPeerId else { return nil }
                let migration = !message.mattermostReadReceiptEligible && self.store.cursor("dm_receipt_layout_1:\(channelId)") == nil
                guard message.mattermostReadReceiptEligible || migration else { return nil }
                return DirectMessageReceiptPollCandidate(channelId: channelId, postId: entry.postId, isOwn: true, isBot: user.isBot, visible: visible.contains(state.peerId), recentlyWritten: interests.written[channelId] != nil, priority: interests.histories[state.peerId] != nil ? 2 : interests.list.contains(state.peerId) ? 1 : 0, needsMigration: migration)
            }
        }
        guard let candidate = self.receiptScheduler.with({ $0.next(candidates, now: now) }), let state = self.channelState(candidate.channelId), let partner = state.channel.directMessagePartnerId(myUserId: self.ownUserId) else { return }
        let channelId = candidate.channelId
        var confirmed = false
        var eligible = true
        defer {
            self.receiptScheduler.with { $0.completed(candidate, confirmed: confirmed, eligible: eligible, now: ProcessInfo.processInfo.systemUptime) }
        }
        do {
            if candidate.needsMigration {
                let page = try await self.client.posts(channelId: channelId, perPage: self.perPage)
                let migrated = await self.postbox.mmTransaction { transaction -> Bool in
                    let result = self.write(PageWrite(channelId: channelId, kind: .singles, run: page.orderedPosts), transaction: transaction)
                    if !result.failed { self.store.setCursor("dm_receipt_layout_1:\(channelId)", "1") }
                    return !result.failed
                }
                guard migrated else { return }
                eligible = await self.postbox.mmTransaction { transaction in
                    guard let entry = self.store.entries(channelId: channelId, postIds: [candidate.postId])[candidate.postId],
                          let message = transaction.getMessage(MessageId(peerId: state.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)) else { return false }
                    return message.mattermostReadReceiptEligible
                }
                guard eligible else { return }
            }
            guard !Task.isCancelled, !self.isStopped, self.presenceActive.current else { return }
            let channel = try await self.client.channel(id: channelId)
            let members = try await self.client.channelMembers(channelId: channelId, page: 0, perPage: 3)
            guard channel.type == .directMessage, members.count == 2, let member = members.first(where: { $0.userId == partner }),
                  DirectMessageReadReceipt.isCaughtUp(total: channel.totalMsgCount, totalRoots: channel.totalMsgCountRoot, viewed: member.msgCount, viewedRoots: member.msgCountRoot) else { return }
            await self.postbox.mmTransaction { transaction in
                guard let entry = self.store.entries(channelId: channelId, postIds: [candidate.postId])[candidate.postId], entry.localId > self.outgoingReadMaxId(channelId: channelId) else { return }
                let checkpoint = DirectMessageReadCheckpoint(key: entry.key)
                guard let data = try? JSONEncoder().encode(checkpoint), let text = String(data: data, encoding: .utf8) else { return }
                self.store.setCursor(self.outgoingReadCursor(channelId), text)
                transaction.applyOutgoingReadMaxId(MessageId(peerId: state.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
                MMLog.log("read receipt: DM \(channelId) through \(candidate.postId), counters \(member.msgCount)/\(channel.totalMsgCount) roots \(member.msgCountRoot)/\(channel.totalMsgCountRoot)")
            }
            confirmed = true
        } catch {
            MMLog.log("read receipt: DM \(channelId) sample failed: \(error)")
        }
    }
}

struct ReceiptPollInterests {
    var histories: [PeerId: Int] = [:]
    var list = Set<PeerId>()
    var written: [String: Double] = [:]
}
