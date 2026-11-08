import Foundation
import Postbox
import TelegramCore
import MattermostKit
import RelayCallsCore

public struct MattermostCallTarget: Sendable {
    public let serverURL: URL
    public let sessionToken: String
    public let channelId: String
    public let title: String
}

/// What the call adapters need of an account to build `RelayDirectCall`/`RelayGroupCall` controllers.
public struct MattermostRelayCallsAccount {
    public let accountId: AccountRecordId
    public let ownUserId: String
    public let ownPeerId: PeerId
    /// This install's stable device id for the account (`device_id`, the device part of LiveKit identities).
    public let deviceId: String
    public let serverURL: URL
    public let client: RelayCallsClient

    /// This device's LiveKit identity.
    public var identity: RelayParticipantIdentity {
        return RelayParticipantIdentity(userId: self.ownUserId, deviceId: self.deviceId)
    }
}

/// The Mattermost channel behind a chat, as calls see it.
public struct MattermostRelayCallChannel: Equatable {
    public let channelId: String
    /// The chat: the partner's user peer for a DM, the channel peer otherwise.
    public let peerId: PeerId
    /// `direct` for a DM (rings the other user), `group` for a group message (rings the members), `channel` otherwise.
    public let kind: RelayCallKind
    /// A DM's other user.
    public let peerUserId: String?
    public let title: String
}

extension MattermostSync {
    public static func callTarget(accountId: AccountRecordId, peerId: PeerId) async throws -> MattermostCallTarget {
        guard let sync = self.sync(accountId: accountId), peerId != sync.ownPeerId else {
            throw MattermostDirectoryError.server("This conversation is not available for calls.")
        }
        if sync.channelId(forPeerId: peerId) == nil, sync.userId(forPeerId: peerId) != nil {
            _ = try await sync.openDirectMessage(userPeerId: peerId)
        }
        guard let channelId = sync.channelId(forPeerId: peerId), let channel = sync.channelState(channelId),
              !channel.channel.isArchived, let token = sync.client.token else {
            throw MattermostDirectoryError.server("This conversation is not ready for calls. Please try again.")
        }
        let title: String
        if let userId = channel.channel.directMessagePartnerId(myUserId: sync.ownUserId), let user = sync.state.with({ $0.users[userId] }) {
            let name = (user.firstName + " " + user.lastName).trimmingCharacters(in: .whitespaces)
            title = name.isEmpty ? user.username : name
        } else {
            title = channel.channel.displayName.isEmpty ? "Voice call" : channel.channel.displayName
        }
        return MattermostCallTarget(serverURL: sync.client.serverURL, sessionToken: token, channelId: channelId, title: title)
    }

    // MARK: Relay calls (docs/livekit-calls-native-ui.md)

    /// The account's calls context: own user, device id and a plugin client (the account's session token and pinned
    /// `URLSession`, looked up per request). Nil without a running sync (logged out, session expired).
    public static func relayCallsAccount(accountId: AccountRecordId) -> MattermostRelayCallsAccount? {
        guard let sync = self.sync(accountId: accountId), !sync.isStopped else {
            return nil
        }
        return MattermostRelayCallsAccount(accountId: accountId, ownUserId: sync.ownUserId, ownPeerId: sync.ownPeerId, deviceId: sync.relayCallsDeviceId, serverURL: sync.client.serverURL, client: sync.relayCallsClient())
    }

    /// A plugin client for the account.
    public static func relayCallsClient(accountId: AccountRecordId) -> RelayCallsClient? {
        return self.sync(accountId: accountId)?.relayCallsClient()
    }

    /// This install's stable device id for the account.
    public static func relayCallsDeviceId(accountId: AccountRecordId) -> String? {
        return self.sync(accountId: accountId)?.relayCallsDeviceId
    }

    /// The account a VoIP push is for (its `recipient_id`, which is unique across servers).
    public static func relayCallAccountId(push: RelayCallPush) -> AccountRecordId? {
        guard !push.recipientId.isEmpty else {
            return nil
        }
        return self.registeredAccount(userId: push.recipientId, serverURL: push.serverURL)
    }

    /// The channel of a chat for a call; opens the DM with a user who has none yet. Archived channels and the own
    /// chat (Saved Messages) cannot be called.
    public static func relayCallChannel(accountId: AccountRecordId, peerId: PeerId) async throws -> MattermostRelayCallChannel {
        guard let sync = self.sync(accountId: accountId), peerId != sync.ownPeerId else {
            throw RelayCallsError.invalidChannel
        }
        if sync.channelId(forPeerId: peerId) == nil, sync.userId(forPeerId: peerId) != nil {
            _ = try await sync.openDirectMessage(userPeerId: peerId)
        }
        guard let channelId = sync.channelId(forPeerId: peerId), let channel = self.relayCallChannel(sync: sync, channelId: channelId), sync.channelState(channelId)?.channel.isArchived != true else {
            throw RelayCallsError.invalidChannel
        }
        return channel
    }

    /// The chat of a call's channel (an incoming ring, a join panel), without network.
    public static func relayCallChannel(accountId: AccountRecordId, channelId: String) -> MattermostRelayCallChannel? {
        guard let sync = self.sync(accountId: accountId) else {
            return nil
        }
        return self.relayCallChannel(sync: sync, channelId: channelId)
    }

    private static func relayCallChannel(sync: MattermostAccountSync, channelId: String) -> MattermostRelayCallChannel? {
        guard let peerId = sync.relayCallPeerId(channelId: channelId) else {
            return nil
        }
        if let channelState = sync.channelState(channelId) {
            let channel = channelState.channel
            switch channel.type {
            case .directMessage:
                let partner = channel.directMessagePartnerId(myUserId: sync.ownUserId)
                let user = partner.flatMap { id in sync.state.with { $0.users[id] } }
                return MattermostRelayCallChannel(channelId: channelId, peerId: peerId, kind: .direct, peerUserId: partner, title: user.map { sync.displayName(of: $0) } ?? "")
            case .groupMessage:
                return MattermostRelayCallChannel(channelId: channelId, peerId: peerId, kind: .group, peerUserId: nil, title: sync.groupMessageTitle(channel))
            default:
                return MattermostRelayCallChannel(channelId: channelId, peerId: peerId, kind: .channel, peerUserId: nil, title: channel.displayName.isEmpty ? channel.name : channel.displayName)
            }
        }
        // Before the bootstrap: from the store's id map.
        if let partner = sync.store.directChannelUserId(channelId: channelId) {
            let user = sync.state.with { $0.users[partner] }
            return MattermostRelayCallChannel(channelId: channelId, peerId: peerId, kind: .direct, peerUserId: partner, title: user.map { sync.displayName(of: $0) } ?? "")
        }
        let kind: RelayCallKind = sync.store.peer(mattermostId: channelId)?.kind == .groupMessage ? .group : .channel
        return MattermostRelayCallChannel(channelId: channelId, peerId: peerId, kind: kind, peerUserId: nil, title: "")
    }

    /// The chat of a Mattermost user (their DM's peer), if the user is known here; the own user's peer for the own id.
    public static func relayCallPeerId(accountId: AccountRecordId, userId: String) -> PeerId? {
        return self.sync(accountId: accountId)?.userPeerId(userId)
    }

    /// The user of a LiveKit participant identity (`<user id>:<device id>`).
    public static func relayCallPeerId(accountId: AccountRecordId, participantIdentity: String) -> PeerId? {
        guard let identity = RelayParticipantIdentity(participantIdentity) else {
            return nil
        }
        return self.relayCallPeerId(accountId: accountId, userId: identity.userId)
    }

    /// The Mattermost user of a user peer.
    public static func relayCallUserId(accountId: AccountRecordId, peerId: PeerId) -> String? {
        return self.sync(accountId: accountId)?.userId(forPeerId: peerId)
    }

    /// Loads users (call participants, a caller) that the account has not written yet, so that their peers exist.
    public static func ensureRelayCallUsers(accountId: AccountRecordId, userIds: [String]) async {
        await self.sync(accountId: accountId)?.ensureUsers(Set(userIds))
    }
}
