import Foundation

/// The Telegram peer namespace a Mattermost entity is mapped into. Peer ids are allocated
/// sequentially per namespace, starting at 1.
public enum MattermostPeerNamespace: Int, Hashable, Sendable, CaseIterable {
    /// `Namespaces.Peer.CloudUser`: users. A DM is shown as the other user's peer (the self-DM
    /// as the own user), so DM channels don't get peer ids of their own (see `dm_channels`).
    case user = 0
    /// `Namespaces.Peer.CloudChannel`: public/private channels and group messages.
    case channel = 1
}

/// Peer ids that sequential allocation never hands out: Telegram's code treats these user ids specially
/// wherever it sees them (TelegramCore `PeerUtils.swift`: `isServicePeer`, `PeerId.isTelegramNotifications`,
/// `isReplies`, `isVerificationCodes`, `isImport`, `isAnonymousSavedMessages`, and the UI's checks for
/// 777000), e.g. as the "Telegram" service chat or the Replies chat. A Mattermost user mapped to one of
/// them would get that special treatment. Channel ids are not special-cased anywhere.
public enum ReservedPeerIds {
    /// `Namespaces.Peer.CloudUser` ids.
    public static let users: Set<Int64> = [
        0, // "no peer" (cache statistics skip it)
        225079, // `isImport` (chat import bot)
        333000, // `isServicePeer`
        489000, // `isVerificationCodes`
        708513, // `isReplies` (old Replies bot)
        777000, // service notifications (`isTelegramNotifications`, `isServicePeer`, many UI checks)
        2666000, // `anonymousSavedMessagesId` ("Author Hidden" in Saved Messages)
        1271266957 // `isReplies`
    ]

    public static func isReserved(_ peerId: Int64, in namespace: MattermostPeerNamespace) -> Bool {
        switch namespace {
        case .user:
            return users.contains(peerId)
        case .channel:
            return peerId == 0
        }
    }
}

/// What a row of the `peers` table is.
public enum MattermostPeerKind: String, Hashable, Sendable, CaseIterable {
    case user
    /// An open (`O`) or private (`P`) channel.
    case channel
    /// A group message channel (`G`).
    case groupMessage = "gm"

    public var namespace: MattermostPeerNamespace {
        switch self {
        case .user:
            return .user
        case .channel, .groupMessage:
            return .channel
        }
    }
}

/// A Mattermost user or channel and its Telegram peer id.
public struct MattermostPeer: Hashable, Sendable {
    public var mattermostId: String
    public var kind: MattermostPeerKind
    /// The `PeerId.Id` payload inside `namespace`.
    public var peerId: Int64
    public var teamId: String?

    public init(mattermostId: String, kind: MattermostPeerKind, peerId: Int64, teamId: String? = nil) {
        self.mattermostId = mattermostId
        self.kind = kind
        self.peerId = peerId
        self.teamId = teamId
    }

    public var namespace: MattermostPeerNamespace {
        return kind.namespace
    }
}

/// The account's server and session description (one row). The session token is not stored here.
public struct MattermostServerInfo: Hashable, Sendable {
    public var url: String
    /// The own user's Mattermost id.
    public var userId: String
    public var siteName: String?
    public var version: String?
    /// Server capabilities (config/license subset, feature flags) as JSON; opaque to the store.
    public var capabilitiesJSON: String?

    public init(url: String, userId: String, siteName: String? = nil, version: String? = nil, capabilitiesJSON: String? = nil) {
        self.url = url
        self.userId = userId
        self.siteName = siteName
        self.version = version
        self.capabilitiesJSON = capabilitiesJSON
    }
}

/// An outgoing post that hasn't been confirmed by the server yet: Mattermost's `pending_post_id`,
/// the Postbox message's `globallyUniqueId` and its id in the `Local` message namespace.
public struct MattermostPendingPost: Hashable, Sendable {
    public var pendingPostId: String
    public var channelId: String
    public var globallyUniqueId: Int64
    public var localMessageId: Int32

    public init(pendingPostId: String, channelId: String, globallyUniqueId: Int64, localMessageId: Int32) {
        self.pendingPostId = pendingPostId
        self.channelId = channelId
        self.globallyUniqueId = globallyUniqueId
        self.localMessageId = localMessageId
    }
}

/// Well-known keys of the `cursors` table.
public enum MattermostSyncCursorKey {
    /// Server time (ms) of the last completed bootstrap or catch-up.
    public static let lastSyncAt = "last_sync_at"
    /// WebSocket `connection_id`, for resuming the socket.
    public static let webSocketConnectionId = "ws_connection_id"
    /// Last WebSocket event `seq` received on that connection.
    public static let webSocketSequence = "ws_seq"
}

public enum MattermostSyncStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    /// An SQLite call failed. `code` is the extended result code.
    case sqlite(code: Int32, message: String)
    /// The file was written by a newer build (schema `found`); this build knows up to `supported`.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// The store has been closed.
    case closed
    /// The Mattermost id is already mapped in the other peer namespace.
    case peerNamespaceMismatch(mattermostId: String, existing: MattermostPeerKind, requested: MattermostPeerKind)
    /// The peer id is already used by another Mattermost id.
    case peerIdTaken(namespace: MattermostPeerNamespace, peerId: Int64, mattermostId: String)
    /// The own user already has a different peer id, so the reservation can't be honoured.
    case ownUserAlreadyAllocated(mattermostId: String, peerId: Int64)
    /// Peer ids must be positive.
    case invalidPeerId(Int64)

    public var description: String {
        switch self {
        case let .sqlite(code, message):
            return "SQLite error \(code): \(message)"
        case let .unsupportedSchemaVersion(found, supported):
            return "sync store schema \(found) is newer than the supported \(supported)"
        case .closed:
            return "sync store is closed"
        case let .peerNamespaceMismatch(mattermostId, existing, requested):
            return "\(mattermostId) is a \(existing.rawValue), not a \(requested.rawValue)"
        case let .peerIdTaken(namespace, peerId, mattermostId):
            return "peer id \(peerId) in namespace \(namespace) is taken by \(mattermostId)"
        case let .ownUserAlreadyAllocated(mattermostId, peerId):
            return "own user \(mattermostId) already has peer id \(peerId)"
        case let .invalidPeerId(peerId):
            return "invalid peer id \(peerId)"
        }
    }
}
