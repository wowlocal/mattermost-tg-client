import Foundation

/// Keys the notification service extension adds to a delivered notification's `userInfo` (next to the
/// push's own keys), and what the app reads back when the notification is tapped or answered.
public enum MattermostPushUserInfo {
    /// `AccountRecordId` value (Int64). Telegram's own key, so the app's foreground presentation
    /// (`accountIdFromNotification`) works unchanged.
    public static let accountId = "accountId"
    /// Set on every notification the extension built from a Mattermost push.
    public static let marker = "relay_mm"
    /// The account's server URL.
    public static let serverURL = "relay_server_url"
    /// Notification category with Reply and Mark as Read. Named after the server's `category`, so a push the
    /// extension could not rewrite (it ran out of time) still offers the actions.
    public static let messageCategory = "CAN_REPLY"
    public static let replyActionIdentifier = "reply"
    public static let markReadActionIdentifier = "relay_mark_read"

    /// The extension's additions for a push routed to `accountId`.
    public static func additions(accountId: Int64, serverURL: String) -> [String: Any] {
        return [
            self.accountId: accountId,
            self.marker: true,
            self.serverURL: serverURL
        ]
    }
}

/// A delivered Mattermost notification, as the app needs it for a tap or an action.
public struct MattermostNotificationTarget: Equatable, Sendable {
    public var accountId: Int64?
    public var serverId: String?
    public var serverURL: String?
    public var channelId: String
    public var postId: String?
    public var rootId: String?
    public var teamId: String?
    public var isCRTEnabled: Bool
    public var type: MattermostPushType

    public init(accountId: Int64?, serverId: String?, serverURL: String?, channelId: String, postId: String?, rootId: String?, teamId: String? = nil, isCRTEnabled: Bool = false, type: MattermostPushType) {
        self.accountId = accountId
        self.serverId = serverId
        self.serverURL = serverURL
        self.channelId = channelId
        self.postId = postId
        self.rootId = rootId
        self.teamId = teamId
        self.isCRTEnabled = isCRTEnabled
        self.type = type
    }

    /// Nil for Telegram notifications and for Mattermost pushes without a channel (`session`, `test`).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let payload = MattermostPushPayload(userInfo: userInfo), let channelId = payload.channelId else {
            return nil
        }
        var accountId: Int64?
        switch userInfo[MattermostPushUserInfo.accountId] {
        case let value as Int64:
            accountId = value
        case let value as NSNumber:
            accountId = value.int64Value
        case let value as String:
            accountId = Int64(value)
        default:
            accountId = nil
        }
        self.init(accountId: accountId, serverId: payload.serverId, serverURL: pushString(userInfo[MattermostPushUserInfo.serverURL]), channelId: channelId, postId: payload.postId, rootId: payload.rootId, teamId: payload.teamId, isCRTEnabled: payload.isCRTEnabled, type: payload.type)
    }

    /// The root of the thread to answer in: the push's root, else nothing (a reply to a post that is not in
    /// a thread goes to the channel, as Telegram's notification reply does).
    public var replyRootId: String? {
        guard let rootId = self.rootId, !rootId.isEmpty else {
            return nil
        }
        return rootId
    }
}

/// Which delivered notifications a `clear` push (or reading a channel in the app) removes.
public enum MattermostPushClear {
    /// Whether the delivered notification with `userInfo` belongs to the channel (or, for a collapsed-thread
    /// clear with a root, to that thread) of `clear`.
    ///
    /// `serverId` keeps channels of different servers apart (channel ids are random, so this is only a
    /// guard); `accountId`, when given, limits the clear to one account's notifications.
    public static func matches(userInfo: [AnyHashable: Any], channelId: String, rootId: String?, isCRTEnabled: Bool, serverId: String?, accountId: Int64?) -> Bool {
        guard let delivered = MattermostPushPayload(userInfo: userInfo), delivered.type == .message, delivered.channelId == channelId else {
            return false
        }
        if let serverId = serverId, let deliveredServerId = delivered.serverId, deliveredServerId != serverId {
            return false
        }
        if let accountId = accountId, let target = MattermostNotificationTarget(userInfo: userInfo), let deliveredAccountId = target.accountId, deliveredAccountId != accountId {
            return false
        }
        if isCRTEnabled {
            if let rootId = rootId, !rootId.isEmpty {
                // Reading a thread clears its replies only.
                return delivered.rootId == rootId
            }
            // Reading a channel with collapsed threads leaves thread replies alone.
            return !(delivered.isCRTEnabled && delivered.isThreadReply)
        }
        return true
    }
}
