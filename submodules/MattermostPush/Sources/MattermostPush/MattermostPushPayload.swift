import Foundation

/// The `type` of a Mattermost push (`model.PushType*` on the server).
public enum MattermostPushType: Equatable, Hashable, Sendable {
    /// A post the user should hear about. Also used for ID-only pushes (`isIdLoaded`).
    case message
    /// The user read a channel (or a thread) elsewhere: remove its delivered notifications. Sent as a
    /// background push (`content-available`, no alert), so the app handles it, not the extension.
    case clear
    /// The badge changed. The proxy sends only `aps.badge`; iOS applies it without running any code.
    case updateBadge
    /// The session ended: log in again.
    case session
    /// "Send a test notification" from the System Console.
    case test
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "message":
            self = .message
        case "clear":
            self = .clear
        case "update_badge":
            self = .updateBadge
        case "session":
            self = .session
        case "test":
            self = .test
        default:
            self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .message:
            return "message"
        case .clear:
            return "clear"
        case .updateBadge:
            return "update_badge"
        case .session:
            return "session"
        case .test:
            return "test"
        case let .other(value):
            return value
        }
    }
}

/// A Mattermost push as it reaches the device: the APNs payload built by `mattermost-push-proxy`
/// (`server/apple_notification_server.go`, `SendNotification`, verified against 6.6.0) from the server's
/// `model.PushNotification`.
///
/// The proxy moves `message` into `aps.alert` (`body`, plus `title` = `channel_name` for `version` "v2"),
/// sets `aps.thread-id` (the root post for collapsed-thread replies, else the channel), and copies the other
/// fields as top-level keys: `type`, `sub_type`, `server_id`, `ack_id`, `is_crt_enabled`, `channel_id`,
/// `team_id`, `sender_id`, `sender_name`, `post_id`, `root_id`, `channel_name`, `version`,
/// `override_username`, `override_icon_url`, `from_webhook`, `signature` and, for ID-only pushes,
/// `id_loaded`. There is **no user id**: several accounts on one server are told apart by
/// `MattermostPushRouter`.
public struct MattermostPushPayload: Equatable, Sendable {
    public var type: MattermostPushType
    public var subType: String?
    /// `"v2"` from current servers.
    public var version: String?
    /// The server's telemetry id (`DiagnosticId` in the client config); identifies the server, not the user.
    public var serverId: String?
    public var ackId: String?
    public var postId: String?
    public var channelId: String?
    public var rootId: String?
    public var teamId: String?
    public var senderId: String?
    /// The sender as the recipient's "teammate name display" setting shows them, or the webhook's
    /// `override_username`.
    public var senderName: String?
    public var overrideUsername: String?
    public var overrideIconURL: String?
    public var isFromWebhook: Bool
    /// The channel as the recipient sees it (the other user's name for a DM; "Reply in …" for a collapsed
    /// thread reply). Absent with the "generic, no channel" push contents setting.
    public var channelName: String?
    /// `aps.alert.title`.
    public var alertTitle: String?
    /// `aps.alert.body` (or a plain-string `aps.alert`): the text the server built for the push contents
    /// setting ("full": `"sender: text"` in channels, the text alone in DMs).
    public var message: String?
    public var badge: Int?
    public var category: String?
    public var sound: String?
    public var threadIdentifier: String?
    public var isIdLoaded: Bool
    public var isCRTEnabled: Bool
    public var signature: String?

    public init(type: MattermostPushType, subType: String? = nil, version: String? = nil, serverId: String? = nil, ackId: String? = nil, postId: String? = nil, channelId: String? = nil, rootId: String? = nil, teamId: String? = nil, senderId: String? = nil, senderName: String? = nil, overrideUsername: String? = nil, overrideIconURL: String? = nil, isFromWebhook: Bool = false, channelName: String? = nil, alertTitle: String? = nil, message: String? = nil, badge: Int? = nil, category: String? = nil, sound: String? = nil, threadIdentifier: String? = nil, isIdLoaded: Bool = false, isCRTEnabled: Bool = false, signature: String? = nil) {
        self.type = type
        self.subType = subType
        self.version = version
        self.serverId = serverId
        self.ackId = ackId
        self.postId = postId
        self.channelId = channelId
        self.rootId = rootId
        self.teamId = teamId
        self.senderId = senderId
        self.senderName = senderName
        self.overrideUsername = overrideUsername
        self.overrideIconURL = overrideIconURL
        self.isFromWebhook = isFromWebhook
        self.channelName = channelName
        self.alertTitle = alertTitle
        self.message = message
        self.badge = badge
        self.category = category
        self.sound = sound
        self.threadIdentifier = threadIdentifier
        self.isIdLoaded = isIdLoaded
        self.isCRTEnabled = isCRTEnabled
        self.signature = signature
    }

    /// Whether `userInfo` is a Mattermost push (and not a Telegram one, which carries its encrypted
    /// payload in `p`).
    public static func isMattermostPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["p"] == nil, let type = userInfo["type"] as? String, !type.isEmpty else {
            return false
        }
        return userInfo["server_id"] != nil || userInfo["ack_id"] != nil || userInfo["version"] != nil
    }

    /// Parses a notification's `userInfo` (the whole APNs payload). Nil when it is not a Mattermost push.
    public init?(userInfo: [AnyHashable: Any]) {
        guard MattermostPushPayload.isMattermostPush(userInfo), let type = pushString(userInfo["type"]) else {
            return nil
        }
        let aps = userInfo["aps"] as? [AnyHashable: Any] ?? [:]
        var alertTitle: String?
        var message: String?
        if let alert = aps["alert"] as? [AnyHashable: Any] {
            alertTitle = pushString(alert["title"])
            message = pushString(alert["body"])
        } else if let alert = pushString(aps["alert"]) {
            message = alert
        }
        // ID-only pushes put their placeholder text in `message` when the extension rewrote the payload
        // (an acknowledged ID-only push returns a `model.PushNotification`).
        if message == nil {
            message = pushString(userInfo["message"])
        }
        self.init(
            type: MattermostPushType(rawValue: type),
            subType: pushString(userInfo["sub_type"]),
            version: pushString(userInfo["version"]),
            serverId: pushString(userInfo["server_id"]),
            ackId: pushString(userInfo["ack_id"]),
            postId: pushString(userInfo["post_id"]),
            channelId: pushString(userInfo["channel_id"]),
            rootId: pushString(userInfo["root_id"]),
            teamId: pushString(userInfo["team_id"]),
            senderId: pushString(userInfo["sender_id"]),
            senderName: pushString(userInfo["sender_name"]),
            overrideUsername: pushString(userInfo["override_username"]),
            overrideIconURL: pushString(userInfo["override_icon_url"]),
            isFromWebhook: pushBool(userInfo["from_webhook"]),
            channelName: pushString(userInfo["channel_name"]),
            alertTitle: alertTitle,
            message: message,
            badge: pushInt(aps["badge"]) ?? pushInt(userInfo["badge"]),
            category: pushString(aps["category"]) ?? pushString(userInfo["category"]),
            sound: pushString(aps["sound"]),
            threadIdentifier: pushString(aps["thread-id"]),
            isIdLoaded: pushBool(userInfo["id_loaded"]) || pushBool(userInfo["is_id_loaded"]),
            isCRTEnabled: pushBool(userInfo["is_crt_enabled"]),
            signature: pushString(userInfo["signature"])
        )
    }

    /// Fills in what an acknowledged ID-only push returned (`POST /notifications/ack` with `is_id_loaded`
    /// answers with the full `model.PushNotification`, whose keys match the server's JSON).
    public mutating func merge(idLoadedResponse response: [String: Any]) {
        if let value = pushString(response["message"]) {
            self.message = value
        }
        if let value = pushString(response["channel_name"]) {
            self.channelName = value
        }
        if let value = pushString(response["sender_name"]) {
            self.senderName = value
        }
        if let value = pushString(response["sender_id"]) {
            self.senderId = value
        }
        if let value = pushString(response["root_id"]) {
            self.rootId = value
        }
        if let value = pushString(response["channel_id"]) {
            self.channelId = value
        }
        if let value = pushString(response["team_id"]) {
            self.teamId = value
        }
        if let value = pushString(response["override_username"]) {
            self.overrideUsername = value
        }
        if let value = pushString(response["override_icon_url"]) {
            self.overrideIconURL = value
        }
        if let value = pushInt(response["badge"]) {
            self.badge = value
        }
        if response["is_crt_enabled"] != nil {
            self.isCRTEnabled = pushBool(response["is_crt_enabled"])
        }
        self.isIdLoaded = false
    }

    /// Whether this push is a reply in a thread (a post with a root).
    public var isThreadReply: Bool {
        return !(self.rootId ?? "").isEmpty
    }
}

func pushString(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        return value.isEmpty ? nil : value
    case let value as NSNumber:
        return value.stringValue
    default:
        return nil
    }
}

func pushInt(_ value: Any?) -> Int? {
    switch value {
    case let value as NSNumber:
        return value.intValue
    case let value as String:
        return Int(value)
    default:
        return nil
    }
}

func pushBool(_ value: Any?) -> Bool {
    switch value {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    case let value as String:
        return value == "true" || value == "1"
    default:
        return false
    }
}
