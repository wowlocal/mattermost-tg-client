import Foundation

/// What a `call_state` event reports a user (device) did.
public enum RelayCallStateAction: String, Codable, Sendable, Hashable {
    case received
    case accepted
    case declined
    case busy
    case missed
    case cancelled
    case hangup
    case joined
    case left
}

/// A Relay calls event: the plugin's WebSocket events (`custom_org.relaychat.calls_<name>`), plus the active calls
/// MattermostSync fetches after every (re)connect (events are not replayed).
public enum RelayCallsEvent: Sendable, Equatable {
    /// `incoming`: the user is invited (each of the user's sessions gets it).
    case incoming(call: RelayCall, caller: RelayCaller)
    /// `call_state`: a device of the caller or of an invitee answered, declined, joined, left…
    case callState(call: RelayCall, userId: String, deviceId: String, action: RelayCallStateAction)
    /// `call_updated`: participants or state changed (channel members).
    case callUpdated(RelayCall)
    /// `call_ended`: state `ended`, with `end_reason`.
    case callEnded(RelayCall)
    /// Not a WebSocket event: `GET /calls/active` after the socket (re)connected. Every ringing or active call in the
    /// user's channels; a call missing from it has ended (or was forgotten) while the socket was away.
    case activeCalls([RelayCall])

    /// The Mattermost event name prefix of the plugin's events.
    public static let eventPrefix = "custom_org.relaychat.calls_"

    /// Whether a WebSocket event name is one of the plugin's.
    public static func isRelayCallsEvent(_ eventName: String) -> Bool {
        return eventName.hasPrefix(Self.eventPrefix)
    }

    /// The call the event is about (nil for `activeCalls`).
    public var call: RelayCall? {
        switch self {
        case let .incoming(call, _), let .callState(call, _, _, _):
            return call
        case let .callUpdated(call), let .callEnded(call):
            return call
        case .activeCalls:
            return nil
        }
    }

    /// Decodes a plugin WebSocket event: `eventName` is the Mattermost event name, `data` its `data` object as JSON.
    /// Returns nil for other events and for malformed data. Nested objects may also arrive as JSON-encoded strings.
    public static func decode(eventName: String, data: Data) -> RelayCallsEvent? {
        guard eventName.hasPrefix(Self.eventPrefix) else {
            return nil
        }
        let name = String(eventName.dropFirst(Self.eventPrefix.count))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        switch name {
        case "incoming":
            guard let call: RelayCall = Self.decodeNested(object["call"]) else {
                return nil
            }
            let caller: RelayCaller = Self.decodeNested(object["caller"]) ?? RelayCaller(id: call.startedBy)
            return .incoming(call: call, caller: caller)
        case "call_state":
            guard let call: RelayCall = Self.decodeNested(object["call"]), let rawAction = object["action"] as? String, let action = RelayCallStateAction(rawValue: rawAction) else {
                return nil
            }
            return .callState(call: call, userId: object["user_id"] as? String ?? "", deviceId: object["device_id"] as? String ?? "", action: action)
        case "call_updated":
            guard let call: RelayCall = Self.decodeNested(object["call"]) else {
                return nil
            }
            return .callUpdated(call)
        case "call_ended":
            if var call: RelayCall = Self.decodeNested(object["call"]) {
                call.state = .ended
                if call.endReason == nil {
                    call.endReason = .ended
                }
                return .callEnded(call)
            }
            // Version 1: `{channel_id, call_id}`.
            guard let channelId = object["channel_id"] as? String, let callId = object["call_id"] as? String, !channelId.isEmpty, !callId.isEmpty else {
                return nil
            }
            return .callEnded(RelayCall(id: callId, channelId: channelId, state: .ended, endReason: .ended))
        default:
            return nil
        }
    }

    private static func decodeNested<T: Decodable>(_ value: Any?) -> T? {
        let data: Data?
        switch value {
        case let string as String:
            data = string.data(using: .utf8)
        case let value? where JSONSerialization.isValidJSONObject(value):
            data = try? JSONSerialization.data(withJSONObject: value)
        default:
            data = nil
        }
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
