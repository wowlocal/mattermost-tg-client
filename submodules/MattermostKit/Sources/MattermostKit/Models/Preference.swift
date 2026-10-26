import Foundation

public struct Preference: Codable, Sendable, Equatable, Hashable {
    public var userId: String
    public var category: String
    public var name: String
    public var value: String

    public init(userId: String, category: String, name: String, value: String) {
        self.userId = userId
        self.category = category
        self.name = name
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case category, name, value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.string(.userId)
        category = c.string(.category)
        name = c.string(.name)
        value = c.string(.value)
    }
}

/// Well-known preference categories.
public enum PreferenceCategory {
    /// `name` = channel ID, `value` = `"true"`. Legacy favorites (pre sidebar categories).
    public static let favoriteChannel = "favorite_channel"
    /// Saved ("flagged") posts: `name` = post ID, `value` = `"true"`.
    public static let flaggedPost = "flagged_post"
    /// `name` = other user ID, `value` = `"true"`/`"false"`.
    public static let directChannelShow = "direct_channel_show"
    /// `name` = GM channel ID, `value` = `"true"`/`"false"`.
    public static let groupChannelShow = "group_channel_show"
    /// `name` = `"name_format"`, `"collapsed_reply_threads"`, `"use_military_time"`, ...
    public static let displaySettings = "display_settings"
    public static let notifications = "notifications"
    /// Recently used emoji (`name` = `"recent_emojis"`).
    public static let emoji = "emoji"
    public static let customStatus = "custom_status"
}
