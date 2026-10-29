import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Replaces `managedSynchronizePeerReadStates`: when the chat screen marks messages read (Postbox queues a
/// `.Push` read-state operation), tell the server — `POST /channels/members/me/view` when everything is
/// read, otherwise `set_unread` at the first unread post — and confirm the operation.
final class ReadStatePusher {
    private let queue = Queue()
    private weak var sync: MattermostAccountSync?
    private let postbox: Postbox
    private let disposable = MetaDisposable()
    private var active = Set<PeerId>()
    private var latest: [PeerId: PeerReadStateSynchronizationOperation] = [:]

    init(sync: MattermostAccountSync) {
        self.sync = sync
        self.postbox = sync.postbox
    }

    deinit {
        self.disposable.dispose()
    }

    func start() {
        self.disposable.set((self.postbox.synchronizePeerReadStatesView()
        |> deliverOn(self.queue)).start(next: { [weak self] view in
            self?.latest = view.operations
            self?.update()
        }))
    }

    private func update() {
        for (peerId, operation) in self.latest where !self.active.contains(peerId) {
            self.active.insert(peerId)
            Task { [weak self] in
                let result = await self?.sync?.pushReadState(peerId: peerId, operation: operation)
                if result == false {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                self?.queue.async {
                    guard let self = self else {
                        return
                    }
                    self.active.remove(peerId)
                    self.update()
                }
            }
        }
    }
}

extension MattermostAccountSync {
    /// Returns false when the server call failed (the operation stays queued and is retried).
    func pushReadState(peerId: PeerId, operation: PeerReadStateSynchronizationOperation) async -> Bool {
        guard case .Push = operation, let channelId = self.channelId(forPeerId: peerId) else {
            // Validation requests come from Telegram's own sync; nothing to validate against here.
            await self.postbox.mmTransaction { transaction in
                transaction.confirmSynchronizedIncomingReadState(peerId)
            }
            return true
        }
        let target: (maxRead: Int32, count: Int32, nextPostId: String?)? = await self.postbox.mmTransaction { transaction in
            guard let states = transaction.getPeerReadStates(peerId), let cloud = states.first(where: { $0.0 == Namespaces.Message.Cloud })?.1, case let .idBased(maxIncomingReadId, _, _, count, _) = cloud else {
                return nil
            }
            // The next post (a read multi-file post's other parts don't count).
            let next = self.store.entries(channelId: channelId, fromLocalId: maxIncomingReadId + 1, ascending: true, limit: 128).first(where: { !$0.isDeleted && $0.partIndex == 0 })
            return (maxIncomingReadId, count, next?.postId)
        }
        guard let target = target else {
            await self.postbox.mmTransaction { transaction in
                transaction.confirmSynchronizedIncomingReadState(peerId)
            }
            return true
        }
        do {
            if target.count == 0 || target.nextPostId == nil {
                _ = try await self.client.viewChannel(channelId: channelId)
                // Phase 3A: the server sends no `clear` push to the session that read the channel. With replies
                // inline, reading the channel reads its threads too; with collapsed reply threads it doesn't.
                MattermostSync.removeDeliveredNotifications(channelId: channelId, rootId: nil, isCRTEnabled: self.isCollapsedThreads, serverId: self.server.diagnosticId, accountId: self.account.id.int64)
            } else if let nextPostId = target.nextPostId {
                _ = try await self.client.markPostUnread(postId: nextPostId)
            }
            let member = try await self.client.channelMember(channelId: channelId)
            let mentionCount = self.memberMentionCount(member)
            let current: Bool = await self.postbox.mmTransaction { transaction in
                self.state.with { state in
                    state.channels[channelId]?.member = member
                    state.channels[channelId]?.mentionCount = mentionCount
                }
                // More was read while the server calls ran (scrolling down a long unread run): the operation now
                // stands for the newer read, so it stays queued and is pushed next. Confirming it here dropped
                // that read, and the server's count for the older position (the mention below it still unread)
                // stayed on the badge, with nothing left to push.
                guard let states = transaction.getPeerReadStates(peerId), let cloud = states.first(where: { $0.0 == Namespaces.Message.Cloud })?.1, case let .idBased(maxIncomingReadId, _, _, count, _) = cloud, maxIncomingReadId == target.maxRead, count == target.count else {
                    return false
                }
                transaction.confirmSynchronizedIncomingReadState(peerId)
                // Before the count: removing a tag lowers the stored count.
                self.clearReadMentionTags(peerId: peerId, maxReadId: target.maxRead, transaction: transaction)
                if let channelState = self.channelState(channelId) {
                    self.applyMentionCount(channelState.mentionCount, peerId: peerId, transaction: transaction)
                }
                return true
            }
            MMLog.log("read: pushed \(channelId) read up to local id \(target.maxRead) (\(target.count) unread left, server last_viewed_at \(member.lastViewedAt))\(current ? "" : "; read further meanwhile, pushing again")")
            return true
        } catch {
            MMLog.log("read: push for \(channelId) failed: \(error)")
            return false
        }
    }
}
