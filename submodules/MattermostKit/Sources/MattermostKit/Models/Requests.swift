import Foundation

/// Body of `POST /posts`.
public struct PostDraft: Codable, Sendable, Equatable {
    public var channelId: String
    public var message: String
    /// Thread root ID; empty for a new root post.
    public var rootId: String
    public var fileIds: [String]
    /// Client-generated ID used to match the created post (and its `posted`
    /// WebSocket event) to the local pending message.
    public var pendingPostId: String
    public var props: [String: JSONValue]
    public var priority: PostPriority?

    public init(
        channelId: String,
        message: String,
        rootId: String = "",
        fileIds: [String] = [],
        pendingPostId: String = "",
        props: [String: JSONValue] = [:],
        priority: PostPriority? = nil
    ) {
        self.channelId = channelId
        self.message = message
        self.rootId = rootId
        self.fileIds = fileIds
        self.pendingPostId = pendingPostId
        self.props = props
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case message
        case rootId = "root_id"
        case fileIds = "file_ids"
        case pendingPostId = "pending_post_id"
        case props
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelId = c.string(.channelId)
        message = c.string(.message)
        rootId = c.string(.rootId)
        fileIds = c.array(String.self, .fileIds)
        pendingPostId = c.string(.pendingPostId)
        props = c.jsonObject(.props)
        priority = c.lenient(PostMetadata.self, .metadata)?.priority
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelId, forKey: .channelId)
        try c.encode(message, forKey: .message)
        if !rootId.isEmpty { try c.encode(rootId, forKey: .rootId) }
        if !fileIds.isEmpty { try c.encode(fileIds, forKey: .fileIds) }
        if !pendingPostId.isEmpty { try c.encode(pendingPostId, forKey: .pendingPostId) }
        if !props.isEmpty { try c.encode(props, forKey: .props) }
        if let priority {
            var metadata = c.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata)
            try metadata.encode(priority, forKey: .priority)
        }
    }

    private enum MetadataKeys: String, CodingKey {
        case priority
    }
}

/// Body of `PUT /posts/{post_id}/patch`. Nil fields are left unchanged.
public struct PostPatch: Codable, Sendable, Equatable {
    public var message: String?
    public var isPinned: Bool?
    public var fileIds: [String]?
    public var hasReactions: Bool?
    public var props: [String: JSONValue]?

    public init(
        message: String? = nil,
        isPinned: Bool? = nil,
        fileIds: [String]? = nil,
        hasReactions: Bool? = nil,
        props: [String: JSONValue]? = nil
    ) {
        self.message = message
        self.isPinned = isPinned
        self.fileIds = fileIds
        self.hasReactions = hasReactions
        self.props = props
    }

    enum CodingKeys: String, CodingKey {
        case message
        case isPinned = "is_pinned"
        case fileIds = "file_ids"
        case hasReactions = "has_reactions"
        case props
    }
}

/// Body of `POST /channels`.
public struct ChannelDraft: Codable, Sendable, Equatable {
    public var teamId: String
    /// URL name: lowercase letters, digits, `-` and `_`.
    public var name: String
    public var displayName: String
    /// `.publicChannel` or `.privateChannel`.
    public var type: ChannelType
    public var purpose: String
    public var header: String

    public init(teamId: String, name: String, displayName: String, type: ChannelType = .publicChannel, purpose: String = "", header: String = "") {
        self.teamId = teamId
        self.name = name
        self.displayName = displayName
        self.type = type
        self.purpose = purpose
        self.header = header
    }

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case name
        case displayName = "display_name"
        case type, purpose, header
    }
}

/// Body of `POST /teams/{team_id}/posts/search`.
public struct PostSearchOptions: Codable, Sendable, Equatable {
    /// Search terms, including modifiers such as `from:` and `in:`.
    public var terms: String
    public var isOrSearch: Bool
    /// Seconds east of UTC, used for `on:`/`before:`/`after:` modifiers.
    public var timeZoneOffset: Int
    public var includeDeletedChannels: Bool
    public var page: Int
    public var perPage: Int

    public init(
        terms: String,
        isOrSearch: Bool = false,
        timeZoneOffset: Int = TimeZone.current.secondsFromGMT(),
        includeDeletedChannels: Bool = false,
        page: Int = 0,
        perPage: Int = 60
    ) {
        self.terms = terms
        self.isOrSearch = isOrSearch
        self.timeZoneOffset = timeZoneOffset
        self.includeDeletedChannels = includeDeletedChannels
        self.page = page
        self.perPage = perPage
    }

    enum CodingKeys: String, CodingKey {
        case terms
        case isOrSearch = "is_or_search"
        case timeZoneOffset = "time_zone_offset"
        case includeDeletedChannels = "include_deleted_channels"
        case page
        case perPage = "per_page"
    }
}

/// Body of `POST /users/search`. Nil fields are omitted.
public struct UserSearchOptions: Codable, Sendable, Equatable {
    public var term: String
    public var teamId: String?
    public var notInTeamId: String?
    public var inChannelId: String?
    public var notInChannelId: String?
    public var allowInactive: Bool?
    public var withoutTeam: Bool?
    public var limit: Int?

    public init(
        term: String,
        teamId: String? = nil,
        notInTeamId: String? = nil,
        inChannelId: String? = nil,
        notInChannelId: String? = nil,
        allowInactive: Bool? = nil,
        withoutTeam: Bool? = nil,
        limit: Int? = nil
    ) {
        self.term = term
        self.teamId = teamId
        self.notInTeamId = notInTeamId
        self.inChannelId = inChannelId
        self.notInChannelId = notInChannelId
        self.allowInactive = allowInactive
        self.withoutTeam = withoutTeam
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case term
        case teamId = "team_id"
        case notInTeamId = "not_in_team_id"
        case inChannelId = "in_channel_id"
        case notInChannelId = "not_in_channel_id"
        case allowInactive = "allow_inactive"
        case withoutTeam = "without_team"
        case limit
    }
}

/// Query options for `GET /posts/{post_id}/thread`. Paging fields are only
/// honoured by newer servers; older servers return the whole thread.
public struct PostThreadOptions: Sendable, Equatable {
    public enum Direction: String, Sendable {
        case up
        case down
    }

    public var perPage: Int?
    public var fromPost: String?
    public var fromCreateAt: Int64?
    public var direction: Direction?
    public var skipFetchThreads: Bool
    public var collapsedThreads: Bool
    public var collapsedThreadsExtended: Bool

    public init(
        perPage: Int? = nil,
        fromPost: String? = nil,
        fromCreateAt: Int64? = nil,
        direction: Direction? = nil,
        skipFetchThreads: Bool = false,
        collapsedThreads: Bool = false,
        collapsedThreadsExtended: Bool = false
    ) {
        self.perPage = perPage
        self.fromPost = fromPost
        self.fromCreateAt = fromCreateAt
        self.direction = direction
        self.skipFetchThreads = skipFetchThreads
        self.collapsedThreads = collapsedThreads
        self.collapsedThreadsExtended = collapsedThreadsExtended
    }
}

/// Query options for `GET /users/{user_id}/teams/{team_id}/threads`.
public struct UserThreadsOptions: Sendable, Equatable {
    /// Only threads updated after this time (ms).
    public var since: Int64?
    /// Thread ID cursor: threads older than this one.
    public var before: String?
    /// Thread ID cursor: threads newer than this one.
    public var after: String?
    public var perPage: Int?
    /// Include full participant user objects.
    public var extended: Bool
    public var includeDeleted: Bool
    public var unreadOnly: Bool
    /// Only return the totals, not the threads.
    public var totalsOnly: Bool
    /// Only return the threads, not the totals.
    public var threadsOnly: Bool

    public init(
        since: Int64? = nil,
        before: String? = nil,
        after: String? = nil,
        perPage: Int? = nil,
        extended: Bool = false,
        includeDeleted: Bool = false,
        unreadOnly: Bool = false,
        totalsOnly: Bool = false,
        threadsOnly: Bool = false
    ) {
        self.since = since
        self.before = before
        self.after = after
        self.perPage = perPage
        self.extended = extended
        self.includeDeleted = includeDeleted
        self.unreadOnly = unreadOnly
        self.totalsOnly = totalsOnly
        self.threadsOnly = threadsOnly
    }
}
