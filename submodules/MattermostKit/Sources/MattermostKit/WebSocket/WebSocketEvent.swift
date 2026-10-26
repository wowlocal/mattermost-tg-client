import Foundation

/// Known WebSocket event names. Unknown names are preserved in `.unknown`.
public enum WebSocketEventType: Sendable, Hashable, RawRepresentable {
    case hello
    case posted
    case postEdited
    case postDeleted
    case postUnread
    case reactionAdded
    case reactionRemoved
    case channelViewed
    case multipleChannelsViewed
    case typing
    case statusChange
    case userUpdated
    case newUser
    case channelCreated
    case channelUpdated
    case channelConverted
    case channelDeleted
    case channelRestored
    case channelMemberUpdated
    case userAdded
    case userRemoved
    case addedToTeam
    case leaveTeam
    case updateTeam
    case directAdded
    case groupAdded
    case preferenceChanged
    case preferencesChanged
    case preferencesDeleted
    case sidebarCategoryCreated
    case sidebarCategoryUpdated
    case sidebarCategoryDeleted
    case sidebarCategoryOrderUpdated
    case threadUpdated
    case threadReadChanged
    case threadFollowChanged
    case emojiAdded
    case ephemeralMessage
    case openDialog
    case configChanged
    case licenseChanged
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "hello": self = .hello
        case "posted": self = .posted
        case "post_edited": self = .postEdited
        case "post_deleted": self = .postDeleted
        case "post_unread": self = .postUnread
        case "reaction_added": self = .reactionAdded
        case "reaction_removed": self = .reactionRemoved
        case "channel_viewed": self = .channelViewed
        case "multiple_channels_viewed": self = .multipleChannelsViewed
        case "typing": self = .typing
        case "status_change": self = .statusChange
        case "user_updated": self = .userUpdated
        case "new_user": self = .newUser
        case "channel_created": self = .channelCreated
        case "channel_updated": self = .channelUpdated
        case "channel_converted": self = .channelConverted
        case "channel_deleted": self = .channelDeleted
        case "channel_restored": self = .channelRestored
        case "channel_member_updated": self = .channelMemberUpdated
        case "user_added": self = .userAdded
        case "user_removed": self = .userRemoved
        case "added_to_team": self = .addedToTeam
        case "leave_team": self = .leaveTeam
        case "update_team": self = .updateTeam
        case "direct_added": self = .directAdded
        case "group_added": self = .groupAdded
        case "preference_changed": self = .preferenceChanged
        case "preferences_changed": self = .preferencesChanged
        case "preferences_deleted": self = .preferencesDeleted
        case "sidebar_category_created": self = .sidebarCategoryCreated
        case "sidebar_category_updated": self = .sidebarCategoryUpdated
        case "sidebar_category_deleted": self = .sidebarCategoryDeleted
        case "sidebar_category_order_updated": self = .sidebarCategoryOrderUpdated
        case "thread_updated": self = .threadUpdated
        case "thread_read_changed": self = .threadReadChanged
        case "thread_follow_changed": self = .threadFollowChanged
        case "emoji_added": self = .emojiAdded
        case "ephemeral_message": self = .ephemeralMessage
        case "open_dialog": self = .openDialog
        case "config_changed": self = .configChanged
        case "license_changed": self = .licenseChanged
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .hello: return "hello"
        case .posted: return "posted"
        case .postEdited: return "post_edited"
        case .postDeleted: return "post_deleted"
        case .postUnread: return "post_unread"
        case .reactionAdded: return "reaction_added"
        case .reactionRemoved: return "reaction_removed"
        case .channelViewed: return "channel_viewed"
        case .multipleChannelsViewed: return "multiple_channels_viewed"
        case .typing: return "typing"
        case .statusChange: return "status_change"
        case .userUpdated: return "user_updated"
        case .newUser: return "new_user"
        case .channelCreated: return "channel_created"
        case .channelUpdated: return "channel_updated"
        case .channelConverted: return "channel_converted"
        case .channelDeleted: return "channel_deleted"
        case .channelRestored: return "channel_restored"
        case .channelMemberUpdated: return "channel_member_updated"
        case .userAdded: return "user_added"
        case .userRemoved: return "user_removed"
        case .addedToTeam: return "added_to_team"
        case .leaveTeam: return "leave_team"
        case .updateTeam: return "update_team"
        case .directAdded: return "direct_added"
        case .groupAdded: return "group_added"
        case .preferenceChanged: return "preference_changed"
        case .preferencesChanged: return "preferences_changed"
        case .preferencesDeleted: return "preferences_deleted"
        case .sidebarCategoryCreated: return "sidebar_category_created"
        case .sidebarCategoryUpdated: return "sidebar_category_updated"
        case .sidebarCategoryDeleted: return "sidebar_category_deleted"
        case .sidebarCategoryOrderUpdated: return "sidebar_category_order_updated"
        case .threadUpdated: return "thread_updated"
        case .threadReadChanged: return "thread_read_changed"
        case .threadFollowChanged: return "thread_follow_changed"
        case .emojiAdded: return "emoji_added"
        case .ephemeralMessage: return "ephemeral_message"
        case .openDialog: return "open_dialog"
        case .configChanged: return "config_changed"
        case .licenseChanged: return "license_changed"
        case .unknown(let name): return name
        }
    }
}

/// Who an event was sent to.
public struct WebSocketBroadcast: Codable, Sendable, Equatable {
    public var userId: String
    public var channelId: String
    public var teamId: String
    public var omitUsers: [String: Bool]
    public var connectionId: String
    public var omitConnectionId: String

    public init(userId: String = "", channelId: String = "", teamId: String = "", omitUsers: [String: Bool] = [:], connectionId: String = "", omitConnectionId: String = "") {
        self.userId = userId
        self.channelId = channelId
        self.teamId = teamId
        self.omitUsers = omitUsers
        self.connectionId = connectionId
        self.omitConnectionId = omitConnectionId
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case channelId = "channel_id"
        case teamId = "team_id"
        case omitUsers = "omit_users"
        case connectionId = "connection_id"
        case omitConnectionId = "omit_connection_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.string(.userId)
        channelId = c.string(.channelId)
        teamId = c.string(.teamId)
        omitUsers = c.jsonObject(.omitUsers).compactMapValues { $0.boolValue }
        connectionId = c.string(.connectionId)
        omitConnectionId = c.string(.omitConnectionId)
    }
}

/// A server-initiated WebSocket event.
public struct WebSocketEvent: Codable, Sendable, Equatable {
    public var event: String
    public var data: [String: JSONValue]
    public var broadcast: WebSocketBroadcast
    /// Per-connection sequence number; the client tracks it to resume.
    public var seq: Int64?

    public init(event: String, data: [String: JSONValue] = [:], broadcast: WebSocketBroadcast = WebSocketBroadcast(), seq: Int64? = nil) {
        self.event = event
        self.data = data
        self.broadcast = broadcast
        self.seq = seq
    }

    enum CodingKeys: String, CodingKey {
        case event, data, broadcast, seq
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        data = c.jsonObject(.data)
        broadcast = c.lenient(WebSocketBroadcast.self, .broadcast) ?? WebSocketBroadcast()
        seq = c.optionalInt64(.seq)
    }

    public var type: WebSocketEventType { WebSocketEventType(rawValue: event) }

    /// Decodes `data[key]`, which Mattermost often sends as a JSON-encoded
    /// string (e.g. `post`, `reaction`, `channel`, `thread`).
    public func decodeEmbedded<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let value = data[key], !value.isNull else { return nil }
        return try? value.decodeEmbedded(T.self)
    }
}

/// The reply to a client action (`seq_reply` frames).
public struct WebSocketResponse: Codable, Sendable, Equatable {
    /// `"OK"` or `"FAIL"`.
    public var status: String
    public var seqReply: Int64
    public var data: [String: JSONValue]
    public var error: AppError?

    public init(status: String, seqReply: Int64, data: [String: JSONValue] = [:], error: AppError? = nil) {
        self.status = status
        self.seqReply = seqReply
        self.data = data
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case status
        case seqReply = "seq_reply"
        case data, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.string(.status)
        guard let seqReply = c.optionalInt64(.seqReply) else {
            throw DecodingError.keyNotFound(CodingKeys.seqReply, .init(codingPath: c.codingPath, debugDescription: "Missing seq_reply"))
        }
        self.seqReply = seqReply
        data = c.jsonObject(.data)
        error = c.lenient(AppError.self, .error)
    }

    public var isOK: Bool { status.uppercased() == "OK" }
}

/// A parsed WebSocket frame.
public enum WebSocketMessage: Sendable, Equatable {
    case event(WebSocketEvent)
    case response(WebSocketResponse)

    /// Parses a text frame. Nil for frames that are neither an event nor an
    /// action reply.
    public init?(text: String) {
        self.init(data: Data(text.utf8))
    }

    public init?(data: Data) {
        guard let object = (try? JSONValue.parse(data))?.objectValue else { return nil }
        let decoder = JSONDecoder()
        if object["seq_reply"] != nil, let response = try? decoder.decode(WebSocketResponse.self, from: data) {
            self = .response(response)
        } else if object["event"]?.stringValue != nil, let event = try? decoder.decode(WebSocketEvent.self, from: data) {
            self = .event(event)
        } else {
            return nil
        }
    }
}

// MARK: - Typed event payloads

public struct HelloEvent: Sendable, Equatable {
    public var connectionId: String
    /// e.g. `"9.11.1.12345.abcdef.true"`; see `ServerVersion`.
    public var serverVersion: String?
}

public struct PostedEvent: Sendable, Equatable {
    public var post: Post
    public var channelType: ChannelType?
    public var channelName: String?
    public var channelDisplayName: String?
    public var teamId: String?
    /// e.g. `"@alice"`.
    public var senderName: String?
    /// IDs of users mentioned by the post.
    public var mentions: [String]
    /// IDs of users following the thread (collapsed reply threads).
    public var followers: [String]
    public var setOnline: Bool?
}

public struct TypingEvent: Sendable, Equatable {
    public var userId: String
    public var channelId: String
    /// Thread root ID when typing in a thread; empty otherwise.
    public var parentId: String
}

public struct StatusChangeEvent: Sendable, Equatable {
    public var userId: String
    public var status: UserStatus.Status
}

public struct ChannelViewedEvent: Sendable, Equatable {
    public var channelId: String
    /// The user who viewed the channel (the current user, on another device).
    public var userId: String
}

/// Channels the current user marked read (usually on another device), from
/// either `channel_viewed` or `multiple_channels_viewed`.
public struct ChannelsViewedEvent: Sendable, Equatable {
    /// Sorted channel IDs.
    public var channelIds: [String]
    /// Channel ID → new `last_viewed_at` (ms). Empty for `channel_viewed`,
    /// which carries no timestamp.
    public var lastViewedAt: [String: Int64]
}

extension WebSocketEvent {
    public var hello: HelloEvent? {
        guard type == .hello, let connectionId = data["connection_id"]?.stringValue else { return nil }
        return HelloEvent(connectionId: connectionId, serverVersion: data["server_version"]?.stringValue)
    }

    public var posted: PostedEvent? {
        guard type == .posted, let post = decodeEmbedded(Post.self, key: "post") else { return nil }
        return PostedEvent(
            post: post,
            channelType: data["channel_type"]?.stringValue.map(ChannelType.init(rawValue:)),
            channelName: data["channel_name"]?.stringValue,
            channelDisplayName: data["channel_display_name"]?.stringValue,
            teamId: data["team_id"]?.stringValue,
            senderName: data["sender_name"]?.stringValue,
            mentions: decodeEmbedded([String].self, key: "mentions") ?? [],
            followers: decodeEmbedded([String].self, key: "followers") ?? [],
            setOnline: data["set_online"]?.boolValue
        )
    }

    /// The edited post (`post_edited`).
    public var editedPost: Post? {
        guard type == .postEdited else { return nil }
        return decodeEmbedded(Post.self, key: "post")
    }

    /// The deleted post (`post_deleted`); `deleteAt` may be 0 on some versions.
    public var deletedPost: Post? {
        guard type == .postDeleted else { return nil }
        return decodeEmbedded(Post.self, key: "post")
    }

    /// The reaction of a `reaction_added` or `reaction_removed` event.
    public var reaction: Reaction? {
        guard type == .reactionAdded || type == .reactionRemoved else { return nil }
        return decodeEmbedded(Reaction.self, key: "reaction")
    }

    public var channelViewed: ChannelViewedEvent? {
        guard type == .channelViewed, let channelId = data["channel_id"]?.stringValue else { return nil }
        return ChannelViewedEvent(channelId: channelId, userId: broadcast.userId)
    }

    /// Channel ID → `last_viewed_at` (`multiple_channels_viewed`).
    public var multipleChannelsViewed: [String: Int64]? {
        guard type == .multipleChannelsViewed else { return nil }
        return decodeEmbedded([String: JSONValue].self, key: "channel_times")?.compactMapValues { $0.int64Value }
    }

    /// Read-on-another-device for every server version: `channel_viewed`
    /// (older servers) and `multiple_channels_viewed` (Mattermost 11.x sends
    /// only this one, also for a single channel).
    public var channelsViewed: ChannelsViewedEvent? {
        if let single = channelViewed {
            return ChannelsViewedEvent(channelIds: [single.channelId], lastViewedAt: [:])
        }
        if let times = multipleChannelsViewed {
            return ChannelsViewedEvent(channelIds: times.keys.sorted(), lastViewedAt: times)
        }
        return nil
    }

    /// The dialog an integration asks to open (`open_dialog`; `data.dialog` is a JSON string).
    public var openDialog: OpenDialogRequest? {
        guard type == .openDialog else { return nil }
        return decodeEmbedded(OpenDialogRequest.self, key: "dialog")
    }

    public var typing: TypingEvent? {
        guard type == .typing, let userId = data["user_id"]?.stringValue else { return nil }
        return TypingEvent(userId: userId, channelId: broadcast.channelId, parentId: data["parent_id"]?.stringValue ?? "")
    }

    public var statusChange: StatusChangeEvent? {
        guard type == .statusChange,
              let userId = data["user_id"]?.stringValue,
              let status = data["status"]?.stringValue
        else { return nil }
        return StatusChangeEvent(userId: userId, status: UserStatus.Status(rawValue: status))
    }

    /// The thread of a `thread_updated` event.
    public var updatedThread: UserThread? {
        guard type == .threadUpdated else { return nil }
        return decodeEmbedded(UserThread.self, key: "thread")
    }
}
