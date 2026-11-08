import Foundation

/// The record of a Relay call (`docs/livekit-calls-native-ui.md`, "Call records"): the calls plugin posts one
/// `custom_relay_call` post per call and updates it when the call ends, with
/// `props.relay_call = {v, call_id, kind, video, state, started_by, end_reason, duration_ms, started_at, end_at}`.
/// Relay shows it as Telegram's call service message (MattermostSync maps it to `TelegramMediaAction`).
public struct RelayCallRecord: Hashable, Sendable {
    public static let postType = "custom_relay_call"
    public static let propsKey = "relay_call"

    public enum Kind: String, Hashable, Sendable {
        case direct
        case group
        case channel
    }

    public enum State: String, Hashable, Sendable {
        case ringing
        case active
        case ended
    }

    /// Telegram's call discard reasons (`PhoneCallDiscardReason`), as the plugin's end reasons map onto them.
    public enum DiscardReason: Hashable, Sendable {
        /// Not answered (missed, or cancelled by the caller): "Missed Call" / "Cancelled Call".
        case missed
        /// Declined or busy (Telegram's decline): "Missed Call" / "Cancelled Call".
        case busy
        /// Answered and hung up.
        case hangup
        /// The call failed.
        case disconnect
    }

    public var version: Int
    public var callId: String
    public var kind: Kind
    public var video: Bool
    public var state: State
    public var startedBy: String
    /// `missed|cancelled|declined|busy|hangup|ended|failed`; nil until the call ended.
    public var endReason: String?
    public var durationMs: Int64?
    public var startedAt: Int64?
    public var endAt: Int64?

    public init(version: Int = 2, callId: String, kind: Kind, video: Bool = false, state: State, startedBy: String = "", endReason: String? = nil, durationMs: Int64? = nil, startedAt: Int64? = nil, endAt: Int64? = nil) {
        self.version = version
        self.callId = callId
        self.kind = kind
        self.video = video
        self.state = state
        self.startedBy = startedBy
        self.endReason = endReason
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.endAt = endAt
    }

    /// The record of a post: its `type` must be `custom_relay_call` and `props.relay_call` an object (or that object
    /// as a JSON string) with a call id.
    public init?(postType: String, propsValue: Any?) {
        guard postType == Self.postType else {
            return nil
        }
        var object = propsValue as? [String: Any]
        if object == nil, let string = propsValue as? String, let data = string.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let object, let callId = object["call_id"] as? String, !callId.isEmpty else {
            return nil
        }
        func int64(_ key: String) -> Int64? {
            switch object[key] {
            case let number as NSNumber:
                return number.int64Value
            case let string as String:
                return Int64(string)
            default:
                return nil
            }
        }
        self.version = int64("v").map { Int($0) } ?? 2
        self.callId = callId
        self.kind = (object["kind"] as? String).flatMap { Kind(rawValue: $0) } ?? .channel
        self.video = (object["video"] as? Bool) ?? ((object["video"] as? NSNumber)?.boolValue ?? false)
        let endReason = (object["end_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.endReason = endReason
        self.state = (object["state"] as? String).flatMap { State(rawValue: $0) } ?? (endReason != nil ? .ended : .active)
        self.startedBy = object["started_by"] as? String ?? ""
        self.durationMs = int64("duration_ms")
        self.startedAt = int64("started_at").flatMap { $0 > 0 ? $0 : nil }
        self.endAt = int64("end_at").flatMap { $0 > 0 ? $0 : nil }
    }

    /// A `direct` call (Telegram's 1:1 call message); `group`/`channel` calls show as group call messages.
    public var isDirect: Bool {
        return self.kind == .direct
    }

    public var isEnded: Bool {
        return self.state == .ended
    }

    /// nil while the call runs.
    public var discardReason: DiscardReason? {
        guard self.isEnded else {
            return nil
        }
        switch self.endReason ?? "ended" {
        case "missed", "cancelled":
            return .missed
        case "declined", "busy":
            return .busy
        case "failed":
            return .disconnect
        default:
            return .hangup
        }
    }

    /// Whole seconds of the answered call; nil while it runs or when it was never answered.
    public var durationSeconds: Int32? {
        guard self.isEnded, let durationMs = self.durationMs, durationMs > 0 else {
            return nil
        }
        return Int32(clamping: durationMs / 1000)
    }

    /// A stable 64-bit id of the call (Telegram's call and group call ids): FNV-1a of the plugin's call id, positive
    /// and non-zero.
    public static func telegramCallId(_ callId: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in callId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let value = Int64(bitPattern: hash & UInt64(Int64.max))
        return value == 0 ? 1 : value
    }

    public var telegramCallId: Int64 {
        return Self.telegramCallId(self.callId)
    }

    /// English text for previews and notifications.
    public func fallbackText(isOutgoing: Bool) -> String {
        let noun = self.video ? "video call" : "call"
        if !self.isDirect {
            if self.isEnded {
                return self.durationSeconds.map { "\(self.video ? "Video call" : "Call") ended (\(Self.durationText($0)))" } ?? "\(self.video ? "Video call" : "Call") ended"
            }
            return "\(self.video ? "Video call" : "Call") started"
        }
        switch self.discardReason {
        case .missed?, .busy?:
            return isOutgoing ? "Cancelled \(noun)" : "Missed \(noun)"
        case nil:
            return isOutgoing ? "Outgoing \(noun)" : "Incoming \(noun)"
        default:
            let title = isOutgoing ? "Outgoing \(noun)" : "Incoming \(noun)"
            return self.durationSeconds.map { "\(title) (\(Self.durationText($0)))" } ?? title
        }
    }

    static func durationText(_ seconds: Int32) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }
}
