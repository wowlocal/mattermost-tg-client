import Foundation

/// A followed thread (collapsed reply threads).
public struct UserThread: Codable, Sendable, Equatable, Identifiable {
    /// The root post ID.
    public var id: String
    public var replyCount: Int64
    public var lastReplyAt: Int64
    public var lastViewedAt: Int64
    public var participants: [User]
    /// The root post.
    public var post: Post?
    public var unreadReplies: Int64
    public var unreadMentions: Int64
    public var isUrgent: Bool
    public var deleteAt: Int64

    public init(
        id: String,
        replyCount: Int64 = 0,
        lastReplyAt: Int64 = 0,
        lastViewedAt: Int64 = 0,
        participants: [User] = [],
        post: Post? = nil,
        unreadReplies: Int64 = 0,
        unreadMentions: Int64 = 0,
        isUrgent: Bool = false,
        deleteAt: Int64 = 0
    ) {
        self.id = id
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.lastViewedAt = lastViewedAt
        self.participants = participants
        self.post = post
        self.unreadReplies = unreadReplies
        self.unreadMentions = unreadMentions
        self.isUrgent = isUrgent
        self.deleteAt = deleteAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case replyCount = "reply_count"
        case lastReplyAt = "last_reply_at"
        case lastViewedAt = "last_viewed_at"
        case participants
        case post
        case unreadReplies = "unread_replies"
        case unreadMentions = "unread_mentions"
        case isUrgent = "is_urgent"
        case deleteAt = "delete_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        replyCount = c.int64(.replyCount)
        lastReplyAt = c.int64(.lastReplyAt)
        lastViewedAt = c.int64(.lastViewedAt)
        participants = c.array(User.self, .participants)
        post = c.lenient(Post.self, .post)
        unreadReplies = c.int64(.unreadReplies)
        unreadMentions = c.int64(.unreadMentions)
        isUrgent = c.bool(.isUrgent)
        deleteAt = c.int64(.deleteAt)
    }
}

/// Response of `GET /users/{user_id}/teams/{team_id}/threads`.
public struct ThreadList: Codable, Sendable, Equatable {
    public var total: Int64
    public var totalUnreadThreads: Int64
    public var totalUnreadMentions: Int64
    public var totalUnreadUrgentMentions: Int64
    public var threads: [UserThread]

    public init(
        total: Int64 = 0,
        totalUnreadThreads: Int64 = 0,
        totalUnreadMentions: Int64 = 0,
        totalUnreadUrgentMentions: Int64 = 0,
        threads: [UserThread] = []
    ) {
        self.total = total
        self.totalUnreadThreads = totalUnreadThreads
        self.totalUnreadMentions = totalUnreadMentions
        self.totalUnreadUrgentMentions = totalUnreadUrgentMentions
        self.threads = threads
    }

    enum CodingKeys: String, CodingKey {
        case total
        case totalUnreadThreads = "total_unread_threads"
        case totalUnreadMentions = "total_unread_mentions"
        case totalUnreadUrgentMentions = "total_unread_urgent_mentions"
        case threads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = c.int64(.total)
        totalUnreadThreads = c.int64(.totalUnreadThreads)
        totalUnreadMentions = c.int64(.totalUnreadMentions)
        totalUnreadUrgentMentions = c.int64(.totalUnreadUrgentMentions)
        threads = c.array(UserThread.self, .threads)
    }
}
