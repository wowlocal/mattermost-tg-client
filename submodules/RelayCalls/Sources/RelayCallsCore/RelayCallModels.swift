import Foundation

// Wire models of the Relay calls plugin (`org.relaychat.calls`, contract version 2; docs/livekit-calls-native-ui.md
// "Wire contract"). Decoding is lenient where version 1 servers omit a field: a version 1 call is an active channel
// call. Times are Unix milliseconds.

/// Which Mattermost channel type a call belongs to: `direct` (DM, rings the other user), `group` (group message,
/// rings every other member), `channel` (public/private channel, nobody rings; members join from the panel).
public enum RelayCallKind: String, Codable, Sendable, Hashable {
    case direct
    case group
    case channel
}

public enum RelayCallState: String, Codable, Sendable, Hashable {
    case ringing
    case active
    case ended
}

public enum RelayCallEndReason: String, Codable, Sendable, Hashable {
    /// Nobody answered before the ring timeout.
    case missed
    /// The caller hung up before anyone answered.
    case cancelled
    /// The callee (`direct`) declined.
    case declined
    /// Every invitee was busy.
    case busy
    /// A participant of an answered `direct` call hung up.
    case hangup
    /// Ended for everyone, or the room emptied.
    case ended
    case failed
}

/// What an invitee of a `direct`/`group` call did with the ring.
public enum RelayInviteeState: String, Codable, Sendable, Hashable {
    case ringing
    /// A device of the invitee shows the call.
    case received
    case accepted
    case declined
    case busy
    case missed

    /// The invitee's devices should still ring.
    public var isRinging: Bool {
        return self == .ringing || self == .received
    }
}

/// A call as the plugin reports it.
public struct RelayCall: Codable, Equatable, Sendable {
    public var id: String
    public var channelId: String
    /// The LiveKit room name.
    public var room: String
    public var kind: RelayCallKind
    public var state: RelayCallState
    /// The caller asked for a video call (`direct`/`group` rings).
    public var video: Bool
    /// The user who started (or rang) the call.
    public var startedBy: String
    public var startedAt: Int64
    /// Only while ringing.
    public var ringExpiresAt: Int64?
    /// Only when ended.
    public var endReason: RelayCallEndReason?
    public var endAt: Int64?
    /// Only when ended; counts from the first answer.
    public var durationMs: Int64?
    /// Connected devices (what version 1 clients read).
    public var participants: Int
    /// Distinct connected users.
    public var participantIds: [String]
    /// Present for `direct`/`group`.
    public var invitees: [String: RelayInviteeState]?
    public var postId: String?
    /// Whether the requesting user may end the call for everyone.
    public var canEnd: Bool

    public init(
        id: String,
        channelId: String,
        room: String = "",
        kind: RelayCallKind = .channel,
        state: RelayCallState = .active,
        video: Bool = false,
        startedBy: String = "",
        startedAt: Int64 = 0,
        ringExpiresAt: Int64? = nil,
        endReason: RelayCallEndReason? = nil,
        endAt: Int64? = nil,
        durationMs: Int64? = nil,
        participants: Int = 0,
        participantIds: [String] = [],
        invitees: [String: RelayInviteeState]? = nil,
        postId: String? = nil,
        canEnd: Bool = false
    ) {
        self.id = id
        self.channelId = channelId
        self.room = room
        self.kind = kind
        self.state = state
        self.video = video
        self.startedBy = startedBy
        self.startedAt = startedAt
        self.ringExpiresAt = ringExpiresAt
        self.endReason = endReason
        self.endAt = endAt
        self.durationMs = durationMs
        self.participants = participants
        self.participantIds = participantIds
        self.invitees = invitees
        self.postId = postId
        self.canEnd = canEnd
    }

    enum CodingKeys: String, CodingKey {
        case id, room, kind, state, video, participants, invitees
        case channelId = "channel_id"
        case startedBy = "started_by"
        case startedAt = "started_at"
        case ringExpiresAt = "ring_expires_at"
        case endReason = "end_reason"
        case endAt = "end_at"
        case durationMs = "duration_ms"
        case participantIds = "participant_ids"
        case postId = "post_id"
        case canEnd = "can_end"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.channelId = try c.decode(String.self, forKey: .channelId)
        self.room = (try? c.decodeIfPresent(String.self, forKey: .room)) ?? ""
        self.kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { RelayCallKind(rawValue: $0) } ?? .channel
        self.state = (try? c.decodeIfPresent(String.self, forKey: .state)).flatMap { RelayCallState(rawValue: $0) } ?? .active
        self.video = (try? c.decodeIfPresent(Bool.self, forKey: .video)) ?? false
        self.startedBy = (try? c.decodeIfPresent(String.self, forKey: .startedBy)) ?? ""
        self.startedAt = c.relayInt64(.startedAt) ?? 0
        self.ringExpiresAt = c.relayInt64(.ringExpiresAt).flatMap { $0 > 0 ? $0 : nil }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .endReason), !raw.isEmpty {
            // An end reason this client does not know yet still ends the call.
            self.endReason = RelayCallEndReason(rawValue: raw) ?? .ended
        } else {
            self.endReason = nil
        }
        self.endAt = c.relayInt64(.endAt).flatMap { $0 > 0 ? $0 : nil }
        self.durationMs = c.relayInt64(.durationMs)
        self.participants = Int(c.relayInt64(.participants) ?? 0)
        self.participantIds = (try? c.decodeIfPresent([String].self, forKey: .participantIds)) ?? []
        if let raw = try? c.decodeIfPresent([String: String].self, forKey: .invitees) {
            var invitees: [String: RelayInviteeState] = [:]
            for (userId, value) in raw {
                invitees[userId] = RelayInviteeState(rawValue: value) ?? .missed
            }
            self.invitees = invitees
        } else {
            self.invitees = nil
        }
        let postId = (try? c.decodeIfPresent(String.self, forKey: .postId)) ?? nil
        self.postId = postId?.isEmpty == true ? nil : postId
        self.canEnd = (try? c.decodeIfPresent(Bool.self, forKey: .canEnd)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.channelId, forKey: .channelId)
        try c.encode(self.room, forKey: .room)
        try c.encode(self.kind, forKey: .kind)
        try c.encode(self.state, forKey: .state)
        try c.encode(self.video, forKey: .video)
        try c.encode(self.startedBy, forKey: .startedBy)
        try c.encode(self.startedAt, forKey: .startedAt)
        try c.encodeIfPresent(self.ringExpiresAt, forKey: .ringExpiresAt)
        try c.encodeIfPresent(self.endReason, forKey: .endReason)
        try c.encodeIfPresent(self.endAt, forKey: .endAt)
        try c.encodeIfPresent(self.durationMs, forKey: .durationMs)
        try c.encode(self.participants, forKey: .participants)
        try c.encode(self.participantIds, forKey: .participantIds)
        try c.encodeIfPresent(self.invitees, forKey: .invitees)
        try c.encodeIfPresent(self.postId, forKey: .postId)
        try c.encode(self.canEnd, forKey: .canEnd)
    }

    /// Whether `userId`'s devices should ring for this call (`invitees[userId]` is `ringing` or `received`).
    public func isRinging(for userId: String) -> Bool {
        return self.state == .ringing && self.invitees?[userId]?.isRinging == true
    }

    /// Whether the call is still running (ringing or active).
    public var isLive: Bool {
        return self.state != .ended
    }

    /// `ringExpiresAt` as a date.
    public var ringExpiryDate: Date? {
        return self.ringExpiresAt.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
    }
}

/// The answer of `join`, `ring` and `accept`: a LiveKit address, a room token for this device, and the call.
public struct RelayCallJoin: Decodable, Sendable, Equatable {
    public let url: String
    public let token: String
    public let call: RelayCall

    public init(url: String, token: String, call: RelayCall) {
        self.url = url
        self.token = token
        self.call = call
    }
}

/// `GET /config`.
public struct RelayCallsConfiguration: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let version: Int
    public let maxParticipants: Int
    public let screenSharing: Bool
    /// Version 2: camera video is allowed.
    public let camera: Bool
    /// Version 2: `direct`/`group` channels ring.
    public let ringing: Bool
    public let ringTimeoutSeconds: Int

    public init(enabled: Bool, version: Int, maxParticipants: Int, screenSharing: Bool, camera: Bool = false, ringing: Bool = false, ringTimeoutSeconds: Int = 45) {
        self.enabled = enabled
        self.version = version
        self.maxParticipants = maxParticipants
        self.screenSharing = screenSharing
        self.camera = camera
        self.ringing = ringing
        self.ringTimeoutSeconds = ringTimeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case enabled, version, camera, ringing
        case maxParticipants = "max_participants"
        case screenSharing = "screen_sharing"
        case ringTimeoutSeconds = "ring_timeout_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.version = Int(c.relayInt64(.version) ?? 1)
        self.maxParticipants = Int(c.relayInt64(.maxParticipants) ?? 0)
        self.screenSharing = (try? c.decodeIfPresent(Bool.self, forKey: .screenSharing)) ?? false
        self.camera = (try? c.decodeIfPresent(Bool.self, forKey: .camera)) ?? false
        self.ringing = (try? c.decodeIfPresent(Bool.self, forKey: .ringing)) ?? false
        let timeout = Int(c.relayInt64(.ringTimeoutSeconds) ?? 0)
        self.ringTimeoutSeconds = timeout > 0 ? timeout : 45
    }

    /// The plugin speaks version 2 (rings, accept/decline, active calls, call records).
    public var supportsRinging: Bool {
        return self.enabled && self.version >= 2 && self.ringing
    }
}

/// The caller of an `incoming` event.
public struct RelayCaller: Codable, Sendable, Equatable {
    public var id: String
    public var username: String
    public var displayName: String

    public init(id: String, username: String = "", displayName: String = "") {
        self.id = id
        self.username = username
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        self.displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
    }
}

/// What `decline` tells the caller.
public enum RelayDeclineReason: String, Codable, Sendable {
    case declined
    /// This device is in another call.
    case busy
}

/// The APNs environment of a VoIP token (`POST /devices/voip`).
public enum RelayVoIPEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

/// The `relay_call` dictionary of a VoIP push (iOS PushKit).
public struct RelayCallPush: Codable, Sendable, Equatable {
    public var version: Int
    public var callId: String
    public var channelId: String
    public var callerId: String
    public var callerName: String
    public var video: Bool
    public var ringExpiresAt: Int64?
    /// The Mattermost `SiteURL`: which account the ring is for, with `recipientId`.
    public var serverURL: String
    public var recipientId: String

    public init(version: Int = 2, callId: String, channelId: String, callerId: String, callerName: String, video: Bool, ringExpiresAt: Int64?, serverURL: String, recipientId: String) {
        self.version = version
        self.callId = callId
        self.channelId = channelId
        self.callerId = callerId
        self.callerName = callerName
        self.video = video
        self.ringExpiresAt = ringExpiresAt
        self.serverURL = serverURL
        self.recipientId = recipientId
    }

    enum CodingKeys: String, CodingKey {
        case video
        case version = "v"
        case callId = "call_id"
        case channelId = "channel_id"
        case callerId = "caller_id"
        case callerName = "caller_name"
        case ringExpiresAt = "ring_expires_at"
        case serverURL = "server_url"
        case recipientId = "recipient_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = Int(c.relayInt64(.version) ?? 2)
        self.callId = try c.decode(String.self, forKey: .callId)
        self.channelId = try c.decode(String.self, forKey: .channelId)
        self.callerId = (try? c.decodeIfPresent(String.self, forKey: .callerId)) ?? ""
        self.callerName = (try? c.decodeIfPresent(String.self, forKey: .callerName)) ?? ""
        self.video = (try? c.decodeIfPresent(Bool.self, forKey: .video)) ?? false
        self.ringExpiresAt = c.relayInt64(.ringExpiresAt).flatMap { $0 > 0 ? $0 : nil }
        self.serverURL = (try? c.decodeIfPresent(String.self, forKey: .serverURL)) ?? ""
        self.recipientId = (try? c.decodeIfPresent(String.self, forKey: .recipientId)) ?? ""
    }

    /// The `relay_call` entry of a PushKit payload (`PKPushPayload.dictionaryPayload`), or nil when the push is not a
    /// Relay ring.
    public init?(payload: [AnyHashable: Any]) {
        guard let value = payload["relay_call"], JSONSerialization.isValidJSONObject(value) || value is String else {
            return nil
        }
        let data: Data?
        if let string = value as? String {
            data = string.data(using: .utf8)
        } else {
            data = try? JSONSerialization.data(withJSONObject: value)
        }
        guard let data, let push = try? JSONDecoder().decode(RelayCallPush.self, from: data), !push.callId.isEmpty, !push.channelId.isEmpty else {
            return nil
        }
        self = push
    }

    public var ringExpiryDate: Date? {
        return self.ringExpiresAt.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
    }
}

/// A LiveKit participant identity: `<user id>:<device id>`.
public struct RelayParticipantIdentity: Hashable, Sendable, CustomStringConvertible {
    public let userId: String
    public let deviceId: String

    public init(userId: String, deviceId: String) {
        self.userId = userId
        self.deviceId = deviceId
    }

    /// Parses `<user id>:<device id>`; nil for identities without a user part.
    public init?(_ identity: String) {
        guard let separator = identity.firstIndex(of: ":") else {
            return nil
        }
        let userId = String(identity[identity.startIndex ..< separator])
        let deviceId = String(identity[identity.index(after: separator)...])
        guard !userId.isEmpty else {
            return nil
        }
        self.userId = userId
        self.deviceId = deviceId
    }

    public var stringValue: String {
        return self.userId + ":" + self.deviceId
    }

    public var description: String {
        return self.stringValue
    }
}

extension KeyedDecodingContainer {
    /// An integer sent as a JSON number (integral or not) or a numeric string.
    func relayInt64(_ key: Key) -> Int64? {
        if let value = try? self.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? self.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int64(value)
        }
        if let value = try? self.decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}
