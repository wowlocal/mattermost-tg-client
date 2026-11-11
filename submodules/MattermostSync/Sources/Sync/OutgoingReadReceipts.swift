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
                if self.isConnected.current { await self.pollOutgoingReadReceipts() }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        })
    }

    func pollOutgoingReadReceipts() async {
        let channels = self.state.with { $0.channels.values.filter { $0.kind == .direct }.map { $0.channel.id } }.sorted()
        for channelId in channels {
            guard !Task.isCancelled, !self.isStopped else { return }
            do {
                guard let state = self.channelState(channelId), let partner = state.channel.directMessagePartnerId(myUserId: self.ownUserId) else { continue }
                let layoutCursor = "dm_receipt_layout_1:\(channelId)"
                if self.store.cursor(layoutCursor) == nil {
                    let page = try await self.client.posts(channelId: channelId, perPage: self.perPage)
                    await self.postbox.mmTransaction { transaction in
                        let result = self.write(PageWrite(channelId: channelId, kind: .singles, run: page.orderedPosts), transaction: transaction)
                        if !result.failed {
                            self.store.setCursor(layoutCursor, "1")
                        }
                    }
                }
                let candidate = await self.postbox.mmTransaction { _ -> MessageIdEntry? in
                    guard let entry = self.store.entries(channelId: channelId, olderThan: nil, limit: 1).first,
                          entry.localId > self.outgoingReadMaxId(channelId: channelId) else { return nil }
                    return entry
                }
                guard let candidate else { continue }
                // Freeze the known post boundary before sampling counters. Later sends cannot enter this receipt.
                let channel = try await self.client.channel(id: channelId)
                let members = try await self.client.channelMembers(channelId: channelId, page: 0, perPage: 3)
                guard channel.type == .directMessage, members.count == 2, let member = members.first(where: { $0.userId == partner }),
                      DirectMessageReadReceipt.isCaughtUp(total: channel.totalMsgCount, totalRoots: channel.totalMsgCountRoot, viewed: member.msgCount, viewedRoots: member.msgCountRoot) else { continue }
                await self.postbox.mmTransaction { transaction in
                    let previous = self.outgoingReadMaxId(channelId: channelId)
                    guard let entry = self.store.entries(channelId: channelId, postIds: [candidate.postId])[candidate.postId], entry.localId > previous else { return }
                    let checkpoint = DirectMessageReadCheckpoint(key: candidate.key)
                    guard let data = try? JSONEncoder().encode(checkpoint), let text = String(data: data, encoding: .utf8) else { return }
                    self.store.setCursor(self.outgoingReadCursor(channelId), text)
                    transaction.applyOutgoingReadMaxId(MessageId(peerId: state.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
                    MMLog.log("read receipt: DM \(channelId) through \(candidate.postId), counters \(member.msgCount)/\(channel.totalMsgCount) roots \(member.msgCountRoot)/\(channel.totalMsgCountRoot)")
                }
            } catch {
                MMLog.log("read receipt: DM \(channelId) sample failed: \(error)")
            }
        }
    }
}
