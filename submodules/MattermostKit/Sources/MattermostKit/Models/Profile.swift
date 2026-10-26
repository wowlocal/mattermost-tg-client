import Foundation

/// Body of `PUT /users/{user_id}/patch`: only the fields that are set are changed (Phase 3F).
///
/// Changing `email` needs the user's current `password` (the server checks it). `notifyProps` replaces the
/// user's whole notify props map, so send the full map with the changed keys.
public struct UserPatch: Encodable, Sendable, Equatable {
    public var username: String?
    public var nickname: String?
    public var firstName: String?
    public var lastName: String?
    public var position: String?
    public var email: String?
    public var password: String?
    public var notifyProps: [String: String]?

    public init(
        username: String? = nil,
        nickname: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        position: String? = nil,
        email: String? = nil,
        password: String? = nil,
        notifyProps: [String: String]? = nil
    ) {
        self.username = username
        self.nickname = nickname
        self.firstName = firstName
        self.lastName = lastName
        self.position = position
        self.email = email
        self.password = password
        self.notifyProps = notifyProps
    }

    public var isEmpty: Bool {
        return username == nil && nickname == nil && firstName == nil && lastName == nil && position == nil && email == nil && notifyProps == nil
    }

    enum CodingKeys: String, CodingKey {
        case username, nickname, position, email, password
        case firstName = "first_name"
        case lastName = "last_name"
        case notifyProps = "notify_props"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(firstName, forKey: .firstName)
        try c.encodeIfPresent(lastName, forKey: .lastName)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encodeIfPresent(notifyProps, forKey: .notifyProps)
    }
}

/// Body of `PUT /users/{user_id}/status`.
struct UserStatusUpdate: Encodable, Sendable {
    var userId: String
    var status: String
    /// Unix seconds; only sent for `dnd` with an end.
    var dndEndTime: Int64?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status
        case dndEndTime = "dnd_end_time"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userId, forKey: .userId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(dndEndTime, forKey: .dndEndTime)
    }
}

/// Well-known keys of a user's `notify_props` (Phase 3F, Settings → Notifications).
public enum UserNotifyProp {
    /// Push notifications: `"all"`, `"mention"` or `"none"`.
    public static let push = "push"
    /// Push when the user is `"online"`, `"away"` or `"offline"` (that status and lower ones).
    public static let pushStatus = "push_status"
    /// Push for replies in followed threads (collapsed reply threads): `"all"` or `"mention"`.
    public static let pushThreads = "push_threads"
    /// Comma-separated mention keywords (case insensitive), besides the username.
    public static let mentionKeys = "mention_keys"
    /// `"true"`: the first name counts as a mention.
    public static let firstName = "first_name"
    /// `"true"`: `@channel`, `@all` and `@here` count as mentions.
    public static let channel = "channel"
    /// Reply notifications without collapsed threads: `"any"`, `"root"` or `"never"`.
    public static let comments = "comments"
}

/// Well-known keys of a channel member's `notify_props`.
public enum ChannelNotifyProp {
    /// `"default"` (the user's setting), `"all"`, `"mention"` or `"none"`.
    public static let push = "push"
    /// `"all"` or `"mention"` (with collapsed reply threads); absent means the user's setting.
    public static let pushThreads = "push_threads"
    /// `"default"`, `"on"` or `"off"`.
    public static let ignoreChannelMentions = "ignore_channel_mentions"
    /// `"all"`, or `"mention"` when the channel is muted.
    public static let markUnread = "mark_unread"
    /// `"on"` or `"off"`: follow every new thread in the channel.
    public static let autoFollowThreads = "channel_auto_follow_threads"
}

extension Array where Element == Preference {
    /// The recently used custom statuses (`custom_status` / `recent_custom_statuses`), newest first.
    public var recentCustomStatuses: [UserCustomStatus] {
        guard let preference = first(where: { $0.category == PreferenceCategory.customStatus && $0.name == "recent_custom_statuses" }), let data = preference.value.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([UserCustomStatus].self, from: data)) ?? []
    }
}
