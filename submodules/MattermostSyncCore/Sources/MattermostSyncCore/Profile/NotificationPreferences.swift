import Foundation

// Mattermost's notification preferences as typed values (Phase 3F): the user's `notify_props` (Settings →
// Notifications) and a channel member's `notify_props` (the channel's notification settings). Each type reads the
// props map the server returns and writes back the full map with only its keys changed, so keys it doesn't know
// (desktop, email, …) survive.

/// What triggers a push (`push`, and per channel).
public enum PushLevel: String, CaseIterable, Sendable {
    case all
    case mention
    case none
}

/// The user's push and mention settings.
public struct UserNotificationPreferences: Equatable, Sendable {
    /// When the user's status is this or lower, pushes are sent (`push_status`).
    public enum PushStatus: String, CaseIterable, Sendable {
        /// Online, away or offline: always.
        case online
        /// Away or offline.
        case away
        /// Offline only.
        case offline
    }

    public enum ThreadReplies: String, CaseIterable, Sendable {
        /// Every reply in followed threads.
        case all
        /// Only replies that mention the user.
        case mention
    }

    public var push: PushLevel
    public var pushStatus: PushStatus
    public var pushThreads: ThreadReplies
    /// Extra mention keywords (besides `@username`), in the order the user entered them.
    public var mentionKeys: [String]
    /// The first name counts as a mention (case sensitive on the server).
    public var firstNameMentions: Bool
    /// `@channel`, `@all` and `@here` count as mentions.
    public var channelMentions: Bool

    /// The server's defaults for a new user.
    public init(push: PushLevel = .mention, pushStatus: PushStatus = .online, pushThreads: ThreadReplies = .all, mentionKeys: [String] = [], firstNameMentions: Bool = false, channelMentions: Bool = true) {
        self.push = push
        self.pushStatus = pushStatus
        self.pushThreads = pushThreads
        self.mentionKeys = mentionKeys
        self.firstNameMentions = firstNameMentions
        self.channelMentions = channelMentions
    }

    public init(props: [String: String]) {
        let defaults = UserNotificationPreferences()
        self.push = props["push"].flatMap(PushLevel.init(rawValue:)) ?? defaults.push
        self.pushStatus = props["push_status"].flatMap(PushStatus.init(rawValue:)) ?? defaults.pushStatus
        self.pushThreads = props["push_threads"].flatMap(ThreadReplies.init(rawValue:)) ?? defaults.pushThreads
        self.mentionKeys = Self.parseMentionKeys(props["mention_keys"] ?? "")
        self.firstNameMentions = props["first_name"] == "true"
        self.channelMentions = props["channel"].map { $0 != "false" } ?? defaults.channelMentions
    }

    /// `props` with this value's keys replaced (others kept).
    public func props(updating props: [String: String]) -> [String: String] {
        var result = props
        result["push"] = self.push.rawValue
        result["push_status"] = self.pushStatus.rawValue
        result["push_threads"] = self.pushThreads.rawValue
        result["mention_keys"] = Self.joinMentionKeys(self.mentionKeys)
        result["first_name"] = self.firstNameMentions ? "true" : "false"
        result["channel"] = self.channelMentions ? "true" : "false"
        return result
    }

    /// Comma-separated keys: trimmed, empty ones dropped, duplicates (ignoring case) removed.
    public static func parseMentionKeys(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in text.split(separator: ",") {
            let key = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty || seen.contains(key.lowercased()) {
                continue
            }
            seen.insert(key.lowercased())
            result.append(key)
        }
        return result
    }

    public static func joinMentionKeys(_ keys: [String]) -> String {
        return parseMentionKeys(keys.joined(separator: ",")).joined(separator: ",")
    }
}

/// A channel's notification settings for the user (channel member `notify_props`).
public struct ChannelNotificationPreferences: Equatable, Sendable {
    /// Pushes for this channel; nil follows the user's setting (`"default"`).
    public var push: PushLevel?
    /// Replies in followed threads of this channel; nil follows the user's setting.
    public var pushThreads: UserNotificationPreferences.ThreadReplies?
    /// `@channel`/`@all`/`@here` ignored here; nil follows the user's setting (`"default"`).
    public var ignoreChannelMentions: Bool?
    /// Muted (`mark_unread: mention`).
    public var muted: Bool
    /// Follow every new thread in the channel.
    public var autoFollowThreads: Bool

    public init(push: PushLevel? = nil, pushThreads: UserNotificationPreferences.ThreadReplies? = nil, ignoreChannelMentions: Bool? = nil, muted: Bool = false, autoFollowThreads: Bool = false) {
        self.push = push
        self.pushThreads = pushThreads
        self.ignoreChannelMentions = ignoreChannelMentions
        self.muted = muted
        self.autoFollowThreads = autoFollowThreads
    }

    public init(props: [String: String]) {
        self.push = props["push"].flatMap(PushLevel.init(rawValue:))
        self.pushThreads = props["push_threads"].flatMap(UserNotificationPreferences.ThreadReplies.init(rawValue:))
        switch props["ignore_channel_mentions"] {
        case "on":
            self.ignoreChannelMentions = true
        case "off":
            self.ignoreChannelMentions = false
        default:
            self.ignoreChannelMentions = nil
        }
        self.muted = props["mark_unread"] == "mention"
        self.autoFollowThreads = props["channel_auto_follow_threads"] == "on"
    }

    /// The props to send to `PUT /channels/{id}/members/{user}/notify_props` (the server merges them).
    public var props: [String: String] {
        var result: [String: String] = [:]
        result["push"] = self.push?.rawValue ?? "default"
        if let pushThreads = self.pushThreads {
            result["push_threads"] = pushThreads.rawValue
        }
        switch self.ignoreChannelMentions {
        case true?:
            result["ignore_channel_mentions"] = "on"
        case false?:
            result["ignore_channel_mentions"] = "off"
        case nil:
            result["ignore_channel_mentions"] = "default"
        }
        result["mark_unread"] = self.muted ? "mention" : "all"
        result["channel_auto_follow_threads"] = self.autoFollowThreads ? "on" : "off"
        return result
    }

    /// The push level in effect: the channel's, else the user's.
    public func effectivePush(user: UserNotificationPreferences) -> PushLevel {
        return self.push ?? user.push
    }
}
