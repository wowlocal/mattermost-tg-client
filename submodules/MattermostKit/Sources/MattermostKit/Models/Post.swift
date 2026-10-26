import Foundation

public struct Post: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createAt: Int64
    public var updateAt: Int64
    /// Non-zero once the message has been edited.
    public var editAt: Int64
    public var deleteAt: Int64
    public var isPinned: Bool
    public var userId: String
    public var channelId: String
    /// Thread root post ID; empty for root posts.
    public var rootId: String
    public var originalId: String
    public var message: String
    /// Empty for regular posts; `system_*` for system messages,
    /// `system_ephemeral` for ephemeral posts.
    public var type: String
    /// Free-form props: `attachments`, `from_webhook`, `override_username`,
    /// `override_icon_url`, plugin data, ...
    public var props: [String: JSONValue]
    public var hashtags: String
    public var fileIds: [String]
    public var pendingPostId: String
    public var hasReactions: Bool
    public var remoteId: String?
    public var replyCount: Int64
    public var lastReplyAt: Int64
    /// Thread participants (collapsed reply threads, extended responses only).
    public var participants: [User]?
    /// Only set for thread roots when collapsed reply threads are on.
    public var isFollowing: Bool?
    public var metadata: PostMetadata?

    public init(
        id: String,
        createAt: Int64 = 0,
        updateAt: Int64 = 0,
        editAt: Int64 = 0,
        deleteAt: Int64 = 0,
        isPinned: Bool = false,
        userId: String = "",
        channelId: String = "",
        rootId: String = "",
        originalId: String = "",
        message: String = "",
        type: String = "",
        props: [String: JSONValue] = [:],
        hashtags: String = "",
        fileIds: [String] = [],
        pendingPostId: String = "",
        hasReactions: Bool = false,
        remoteId: String? = nil,
        replyCount: Int64 = 0,
        lastReplyAt: Int64 = 0,
        participants: [User]? = nil,
        isFollowing: Bool? = nil,
        metadata: PostMetadata? = nil
    ) {
        self.id = id
        self.createAt = createAt
        self.updateAt = updateAt
        self.editAt = editAt
        self.deleteAt = deleteAt
        self.isPinned = isPinned
        self.userId = userId
        self.channelId = channelId
        self.rootId = rootId
        self.originalId = originalId
        self.message = message
        self.type = type
        self.props = props
        self.hashtags = hashtags
        self.fileIds = fileIds
        self.pendingPostId = pendingPostId
        self.hasReactions = hasReactions
        self.remoteId = remoteId
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.participants = participants
        self.isFollowing = isFollowing
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createAt = "create_at"
        case updateAt = "update_at"
        case editAt = "edit_at"
        case deleteAt = "delete_at"
        case isPinned = "is_pinned"
        case userId = "user_id"
        case channelId = "channel_id"
        case rootId = "root_id"
        case originalId = "original_id"
        case message
        case type
        case props
        case hashtags
        case fileIds = "file_ids"
        case pendingPostId = "pending_post_id"
        case hasReactions = "has_reactions"
        case remoteId = "remote_id"
        case replyCount = "reply_count"
        case lastReplyAt = "last_reply_at"
        case participants
        case isFollowing = "is_following"
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createAt = c.int64(.createAt)
        updateAt = c.int64(.updateAt)
        editAt = c.int64(.editAt)
        deleteAt = c.int64(.deleteAt)
        isPinned = c.bool(.isPinned)
        userId = c.string(.userId)
        channelId = c.string(.channelId)
        rootId = c.string(.rootId)
        originalId = c.string(.originalId)
        message = c.string(.message)
        type = c.string(.type)
        props = c.jsonObject(.props)
        hashtags = c.string(.hashtags)
        fileIds = c.array(String.self, .fileIds)
        pendingPostId = c.string(.pendingPostId)
        hasReactions = c.bool(.hasReactions)
        remoteId = c.optionalString(.remoteId)
        replyCount = c.int64(.replyCount)
        lastReplyAt = c.int64(.lastReplyAt)
        participants = c.optionalArray(User.self, .participants)
        isFollowing = c.optionalBool(.isFollowing)
        metadata = c.lenient(PostMetadata.self, .metadata)
    }
}

extension Post {
    public var isDeleted: Bool { deleteAt > 0 }
    public var isEdited: Bool { editAt > 0 }
    public var isReply: Bool { !rootId.isEmpty }
    public var isSystemMessage: Bool { type.hasPrefix("system_") }
    public var isEphemeral: Bool { type == "system_ephemeral" }
    public var isFromWebhook: Bool { props["from_webhook"]?.boolValue == true }
    public var isFromBot: Bool { props["from_bot"]?.boolValue == true }

    /// `pending_post_id` in the format the official clients use:
    /// `"<userId>:<milliseconds>"`.
    public static func makePendingPostId(userId: String, date: Date = Date()) -> String {
        "\(userId):\(Int64(date.timeIntervalSince1970 * 1000))"
    }
}

public struct PostMetadata: Codable, Sendable, Equatable {
    public var embeds: [PostEmbed]
    public var emojis: [CustomEmoji]
    public var files: [FileInfo]
    /// Image URL → dimensions, for images referenced by embeds and markdown.
    public var images: [String: PostImage]
    public var reactions: [Reaction]
    public var priority: PostPriority?
    public var acknowledgements: [PostAcknowledgement]

    public init(
        embeds: [PostEmbed] = [],
        emojis: [CustomEmoji] = [],
        files: [FileInfo] = [],
        images: [String: PostImage] = [:],
        reactions: [Reaction] = [],
        priority: PostPriority? = nil,
        acknowledgements: [PostAcknowledgement] = []
    ) {
        self.embeds = embeds
        self.emojis = emojis
        self.files = files
        self.images = images
        self.reactions = reactions
        self.priority = priority
        self.acknowledgements = acknowledgements
    }

    enum CodingKeys: String, CodingKey {
        case embeds, emojis, files, images, reactions, priority, acknowledgements
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        embeds = c.array(PostEmbed.self, .embeds)
        emojis = c.array(CustomEmoji.self, .emojis)
        files = c.array(FileInfo.self, .files)
        images = c.dictionary(PostImage.self, .images)
        reactions = c.array(Reaction.self, .reactions)
        priority = c.lenient(PostPriority.self, .priority)
        acknowledgements = c.array(PostAcknowledgement.self, .acknowledgements)
    }
}

public struct PostEmbed: Codable, Sendable, Equatable {
    /// `image`, `message_attachment`, `opengraph`, `link`, `permalink`.
    public var type: String
    public var url: String
    public var data: JSONValue?

    public init(type: String, url: String = "", data: JSONValue? = nil) {
        self.type = type
        self.url = url
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case type, url, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.string(.type)
        url = c.string(.url)
        data = c.json(.data)
    }

    /// The link preview for `opengraph` embeds.
    public var openGraph: OpenGraph? {
        guard type == "opengraph", let data else { return nil }
        return try? data.decode(OpenGraph.self)
    }

    /// The linked post for `permalink` embeds (`EnablePermalinkPreviews`).
    public var permalink: PermalinkPreview? {
        guard type == "permalink", let data else { return nil }
        return try? data.decode(PermalinkPreview.self)
    }
}

/// A `permalink` embed: the post a message links to, with where it is.
public struct PermalinkPreview: Codable, Sendable, Equatable {
    public var postId: String
    /// Missing when the user can't read the linked post's channel.
    public var post: Post?
    public var teamName: String
    public var channelDisplayName: String
    /// `O`, `P`, `D`, `G`.
    public var channelType: String
    public var channelId: String

    public init(postId: String, post: Post? = nil, teamName: String = "", channelDisplayName: String = "", channelType: String = "", channelId: String = "") {
        self.postId = postId
        self.post = post
        self.teamName = teamName
        self.channelDisplayName = channelDisplayName
        self.channelType = channelType
        self.channelId = channelId
    }

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case post
        case teamName = "team_name"
        case channelDisplayName = "channel_display_name"
        case channelType = "channel_type"
        case channelId = "channel_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postId = c.string(.postId)
        post = c.lenient(Post.self, .post)
        teamName = c.string(.teamName)
        channelDisplayName = c.string(.channelDisplayName)
        channelType = c.string(.channelType)
        channelId = c.string(.channelId)
    }
}

public struct PostImage: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var format: String
    public var frameCount: Int

    public init(width: Int = 0, height: Int = 0, format: String = "", frameCount: Int = 0) {
        self.width = width
        self.height = height
        self.format = format
        self.frameCount = frameCount
    }

    enum CodingKeys: String, CodingKey {
        case width, height, format
        case frameCount = "frame_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = c.int(.width)
        height = c.int(.height)
        format = c.string(.format)
        frameCount = c.int(.frameCount)
    }
}

/// Message priority (Mattermost 7.7+).
public struct PostPriority: Codable, Sendable, Equatable {
    /// `""`, `"important"` or `"urgent"`.
    public var priority: String
    public var requestedAck: Bool
    public var persistentNotifications: Bool

    public init(priority: String = "", requestedAck: Bool = false, persistentNotifications: Bool = false) {
        self.priority = priority
        self.requestedAck = requestedAck
        self.persistentNotifications = persistentNotifications
    }

    enum CodingKeys: String, CodingKey {
        case priority
        case requestedAck = "requested_ack"
        case persistentNotifications = "persistent_notifications"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        priority = c.string(.priority)
        requestedAck = c.bool(.requestedAck)
        persistentNotifications = c.bool(.persistentNotifications)
    }
}

public struct PostAcknowledgement: Codable, Sendable, Equatable {
    public var userId: String
    public var postId: String
    public var acknowledgedAt: Int64

    public init(userId: String, postId: String, acknowledgedAt: Int64) {
        self.userId = userId
        self.postId = postId
        self.acknowledgedAt = acknowledgedAt
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case postId = "post_id"
        case acknowledgedAt = "acknowledged_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.string(.userId)
        postId = c.string(.postId)
        acknowledgedAt = c.int64(.acknowledgedAt)
    }
}

/// A page of posts. `order` lists post IDs newest first; `posts` may also
/// contain thread roots and replies that are not in `order`.
public struct PostList: Codable, Sendable, Equatable {
    public var order: [String]
    public var posts: [String: Post]
    public var nextPostId: String
    public var prevPostId: String
    /// Only sent by newer servers.
    public var hasNext: Bool?
    public var firstInaccessiblePostTime: Int64?

    public init(
        order: [String] = [],
        posts: [String: Post] = [:],
        nextPostId: String = "",
        prevPostId: String = "",
        hasNext: Bool? = nil,
        firstInaccessiblePostTime: Int64? = nil
    ) {
        self.order = order
        self.posts = posts
        self.nextPostId = nextPostId
        self.prevPostId = prevPostId
        self.hasNext = hasNext
        self.firstInaccessiblePostTime = firstInaccessiblePostTime
    }

    enum CodingKeys: String, CodingKey {
        case order, posts
        case nextPostId = "next_post_id"
        case prevPostId = "prev_post_id"
        case hasNext = "has_next"
        case firstInaccessiblePostTime = "first_inaccessible_post_time"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = c.array(String.self, .order)
        posts = c.dictionary(Post.self, .posts)
        nextPostId = c.string(.nextPostId)
        prevPostId = c.string(.prevPostId)
        hasNext = c.optionalBool(.hasNext)
        firstInaccessiblePostTime = c.optionalInt64(.firstInaccessiblePostTime)
    }

    /// Posts in `order` (newest first). IDs without a post are skipped.
    public var orderedPosts: [Post] {
        order.compactMap { posts[$0] }
    }
}

/// Response of `POST /teams/{team_id}/posts/search`.
public struct PostSearchResults: Codable, Sendable, Equatable {
    public var order: [String]
    public var posts: [String: Post]
    /// Post ID → matched terms, for highlighting.
    public var matches: [String: [String]]

    public init(order: [String] = [], posts: [String: Post] = [:], matches: [String: [String]] = [:]) {
        self.order = order
        self.posts = posts
        self.matches = matches
    }

    enum CodingKeys: String, CodingKey {
        case order, posts, matches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = c.array(String.self, .order)
        posts = c.dictionary(Post.self, .posts)
        matches = c.dictionary([String].self, .matches)
    }

    public var orderedPosts: [Post] {
        order.compactMap { posts[$0] }
    }
}
