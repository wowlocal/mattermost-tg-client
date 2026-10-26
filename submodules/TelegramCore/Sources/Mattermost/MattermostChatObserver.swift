import Foundation
import Postbox
import SwiftSignalKit

// MATTERMOST: what Telegram does over MTProto while a chat or a profile is on screen (Phase 4B).
//
// Telegram refreshes a peer's cached data (`users.getFullUser`, `channels.getFullChannel`, `messages.getPeerSettings`)
// when a peer view opens and every five minutes after (`AccountViewTracker.updateCachedPeerData`), and polls a channel
// while its history is open (`polledChannel`). While `MattermostBackend.isEnabled` neither reaches the network; the
// account's chat observer is told instead, so MattermostSync can refresh what it keeps lazily (a channel's member
// count, a channel the last catch-up skipped). MattermostSync installs it with `Account.mattermostSetChatObserver`.
public protocol MattermostChatObserver: AnyObject {
    /// A peer view wants the peer's cached data (a chat title, a profile); at most every five minutes per peer.
    func peerDataRequested(peerId: PeerId)
    /// A history view of the chat opened (the chat screen, a thread, a profile's media tab).
    func chatHistoryOpened(peerId: PeerId)
    /// Where a thread view of a Mattermost thread starts (4F): its first unread reply, with the unread separator
    /// above it, when the user follows the thread and it has unread replies (Postbox keeps no read state for
    /// these threads). Called inside a Postbox transaction.
    func threadReadState(peerId: PeerId, threadId: Int64, transaction: Transaction) -> MattermostThreadReadState?
}

/// See `MattermostChatObserver.threadReadState`.
public struct MattermostThreadReadState: Equatable {
    /// The first unread reply (Cloud namespace): the view opens there.
    public var firstUnreadMessageId: MessageId
    /// Unread replies (incoming, after the thread's last view).
    public var unreadCount: Int32

    public init(firstUnreadMessageId: MessageId, unreadCount: Int32) {
        self.firstUnreadMessageId = firstUnreadMessageId
        self.unreadCount = unreadCount
    }
}

private final class MattermostChatObserverBox {
    weak var observer: MattermostChatObserver?

    init(_ observer: MattermostChatObserver) {
        self.observer = observer
    }
}

/// Observers by account peer id (distinct per account).
private let mattermostChatObservers = Atomic<[PeerId: MattermostChatObserverBox]>(value: [:])

public extension Account {
    /// Installs MattermostSync's chat observer for this account (replaces an earlier one).
    func mattermostSetChatObserver(_ observer: MattermostChatObserver) {
        let accountPeerId = self.peerId
        let _ = mattermostChatObservers.modify { observers in
            var observers = observers
            observers[accountPeerId] = MattermostChatObserverBox(observer)
            return observers
        }
    }
}

func mattermostPeerDataRequested(accountPeerId: PeerId, peerId: PeerId) {
    mattermostChatObservers.with({ $0[accountPeerId]?.observer })?.peerDataRequested(peerId: peerId)
}

func mattermostChatHistoryOpened(accountPeerId: PeerId, peerId: PeerId) {
    mattermostChatObservers.with({ $0[accountPeerId]?.observer })?.chatHistoryOpened(peerId: peerId)
}

func mattermostThreadReadState(accountPeerId: PeerId, peerId: PeerId, threadId: Int64, transaction: Transaction) -> MattermostThreadReadState? {
    return mattermostChatObservers.with({ $0[accountPeerId]?.observer })?.threadReadState(peerId: peerId, threadId: threadId, transaction: transaction)
}
