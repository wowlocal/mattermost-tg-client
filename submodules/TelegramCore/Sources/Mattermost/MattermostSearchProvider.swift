import Foundation
import Postbox
import SwiftSignalKit

// MATTERMOST: finding things (Phase 3C): message search, people and channel search, pinning.
//
// Telegram's search UI (chat list search, search in chat, hashtag search, shared media search) asks
// `searchMessages`/`searchPeers`, which call `messages.search`, `messages.searchGlobal` and `contacts.search`;
// pin and unpin call `messages.updatePinnedMessage`. While `MattermostBackend.isEnabled` these functions ask the
// account's search provider instead. MattermostSync implements it (`POST /teams/{id}/posts/search`,
// `/users/search`, `/teams/{id}/channels/search`, `/posts/{id}/pin`) and installs it with
// `Account.mattermostSetSearchProvider`.

/// One page of a message search. The messages are stored in Postbox before the page is delivered (written
/// through the sync's normal page-write path, so opening a result loads the history around it).
public struct MattermostSearchPage {
    /// Newest first.
    public var messageIds: [MessageId]
    /// The server's count when it says (search pages don't), else the messages found so far.
    public var totalCount: Int32
    /// The page to ask for next; nil when this was the last one.
    public var nextPage: Int32?

    public init(messageIds: [MessageId], totalCount: Int32, nextPage: Int32?) {
        self.messageIds = messageIds
        self.totalCount = totalCount
        self.nextPage = nextPage
    }

    public static let empty = MattermostSearchPage(messageIds: [], totalCount: 0, nextPage: nil)
}

public protocol MattermostSearchProvider: AnyObject {
    /// A page of results (`page` 0 first) for `query` (Mattermost modifiers included) within `location`.
    func searchMessages(location: SearchMessagesLocation, query: String, page: Int32, limit: Int32) -> Signal<MattermostSearchPage, NoError>
    /// People and channels: the user's own chats first (`myResults`), then users and public channels found on
    /// the server (`otherResults`). Peers are written to Postbox (or are in-memory previews) before delivery.
    func searchPeers(query: String, scope: TelegramSearchPeersScope) -> Signal<(myResults: [FoundPeer], otherResults: [FoundPeer]), NoError>
    /// Pins or unpins a message's post; true when the server accepted it (the message's `.pinned` tag follows).
    func updatePinned(messageId: MessageId, pinned: Bool) -> Signal<Bool, NoError>
    /// Unpins every pinned post of a chat (or of a thread).
    func unpinAll(peerId: PeerId, threadId: Int64?) -> Signal<Bool, NoError>
}

private final class MattermostSearchProviderBox {
    weak var provider: MattermostSearchProvider?

    init(_ provider: MattermostSearchProvider) {
        self.provider = provider
    }
}

/// Providers by account peer id (search functions get the account, `_internal_searchPeers` only its peer id).
private let mattermostSearchProviders = Atomic<[PeerId: MattermostSearchProviderBox]>(value: [:])

public extension Account {
    /// Installs MattermostSync's search provider for this account (replaces an earlier one).
    func mattermostSetSearchProvider(_ provider: MattermostSearchProvider) {
        let accountPeerId = self.peerId
        let _ = mattermostSearchProviders.modify { providers in
            var providers = providers
            providers[accountPeerId] = MattermostSearchProviderBox(provider)
            return providers
        }
    }
}

private func mattermostSearchProvider(accountPeerId: PeerId) -> MattermostSearchProvider? {
    return mattermostSearchProviders.with { $0[accountPeerId]?.provider }
}

func mattermostSearchPage(accountPeerId: PeerId, location: SearchMessagesLocation, query: String, page: Int32, limit: Int32) -> Signal<MattermostSearchPage, NoError> {
    guard let provider = mattermostSearchProvider(accountPeerId: accountPeerId) else {
        // The account's sync isn't running (session expired, still starting): nothing found.
        return .single(.empty)
    }
    return provider.searchMessages(location: location, query: query, page: page, limit: limit)
}

func mattermostSearchPeers(accountPeerId: PeerId, query: String, scope: TelegramSearchPeersScope) -> Signal<([FoundPeer], [FoundPeer]), NoError> {
    guard let provider = mattermostSearchProvider(accountPeerId: accountPeerId) else {
        return .single(([], []))
    }
    return provider.searchPeers(query: query, scope: scope)
    |> map { result -> ([FoundPeer], [FoundPeer]) in
        return (result.myResults, result.otherResults)
    }
}

func mattermostUpdatePinnedMessage(accountPeerId: PeerId, update: PinnedMessageUpdate) -> Signal<Void, UpdatePinnedMessageError> {
    guard let provider = mattermostSearchProvider(accountPeerId: accountPeerId) else {
        return .fail(.generic)
    }
    let signal: Signal<Bool, NoError>
    switch update {
    case let .pin(id, _, _):
        signal = provider.updatePinned(messageId: id, pinned: true)
    case let .clear(id):
        signal = provider.updatePinned(messageId: id, pinned: false)
    }
    return signal
    |> castError(UpdatePinnedMessageError.self)
    |> mapToSignal { done -> Signal<Void, UpdatePinnedMessageError> in
        return done ? .single(Void()) : .fail(.generic)
    }
}

func mattermostUnpinAllMessages(accountPeerId: PeerId, peerId: PeerId, threadId: Int64?) -> Signal<Never, UpdatePinnedMessageError> {
    guard let provider = mattermostSearchProvider(accountPeerId: accountPeerId) else {
        return .fail(.generic)
    }
    return provider.unpinAll(peerId: peerId, threadId: threadId)
    |> castError(UpdatePinnedMessageError.self)
    |> mapToSignal { done -> Signal<Never, UpdatePinnedMessageError> in
        return done ? .complete() : .fail(.generic)
    }
}
