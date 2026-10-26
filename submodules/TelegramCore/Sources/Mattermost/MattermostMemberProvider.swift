import Foundation
import Postbox
import SwiftSignalKit

// MATTERMOST: member lists of channels and group messages.
//
// Telegram loads supergroup members with `channels.getParticipants` (`_internal_channelMembers`), which feeds
// the group info Members pane and its search, `searchPeerMembers` (mention and "from:" suggestions), the admin
// and bot lists, and the small groups' online counts. While `MattermostBackend.isEnabled`, that function asks
// the account's member provider instead. MattermostSync implements it (`GET /channels/{id}/members` and user
// lookups) and installs it with `Account.mattermostSetMemberProvider`.
public protocol MattermostMemberProvider: AnyObject {
    /// A page of a channel's members in `category` (`offset`/`limit` as `channels.getParticipants` pages).
    /// The peers are written to Postbox before the page is delivered.
    func channelMembers(peerId: PeerId, category: ChannelMembersCategory, offset: Int32, limit: Int32) -> Signal<[RenderedChannelParticipant]?, NoError>
}

private final class MattermostMemberProviderBox {
    weak var provider: MattermostMemberProvider?

    init(_ provider: MattermostMemberProvider) {
        self.provider = provider
    }
}

/// Providers by account peer id (the only account handle `_internal_channelMembers` gets).
private let mattermostMemberProviders = Atomic<[PeerId: MattermostMemberProviderBox]>(value: [:])

public extension Account {
    /// Installs MattermostSync's member provider for this account (replaces an earlier one).
    func mattermostSetMemberProvider(_ provider: MattermostMemberProvider) {
        let accountPeerId = self.peerId
        let _ = mattermostMemberProviders.modify { providers in
            var providers = providers
            providers[accountPeerId] = MattermostMemberProviderBox(provider)
            return providers
        }
    }
}

func mattermostChannelMembers(accountPeerId: PeerId, peerId: PeerId, category: ChannelMembersCategory, offset: Int32, limit: Int32) -> Signal<[RenderedChannelParticipant]?, NoError> {
    guard let provider = mattermostMemberProviders.with({ $0[accountPeerId]?.provider }) else {
        // The account's sync isn't running (session expired, still starting): no members yet.
        return .single([])
    }
    return provider.channelMembers(peerId: peerId, category: category, offset: offset, limit: limit)
}
