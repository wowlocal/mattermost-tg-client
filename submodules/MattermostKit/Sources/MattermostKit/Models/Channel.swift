import Foundation

/// Channel type (`O`, `P`, `D`, `G`). Unknown values are preserved.
public enum ChannelType: Sendable, Hashable, Codable, RawRepresentable {
    case publicChannel
    case privateChannel
    case directMessage
    case groupMessage
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "O": self = .publicChannel
        case "P": self = .privateChannel
        case "D": self = .directMessage
        case "G": self = .groupMessage
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .publicChannel: return "O"
        case .privateChannel: return "P"
        case .directMessage: return "D"
        case .groupMessage: return "G"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Channel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createAt: Int64
    public var updateAt: Int64
    /// Non-zero for archived channels.
    public var deleteAt: Int64
    /// Empty for DMs and GMs.
    public var teamId: String
    public var type: ChannelType
    public var displayName: String
    /// URL name; for DMs `"<userIdA>__<userIdB>"`.
    public var name: String
    public var header: String
    public var purpose: String
    public var lastPostAt: Int64
    public var lastRootPostAt: Int64
    public var totalMsgCount: Int64
    public var totalMsgCountRoot: Int64
    public var extraUpdateAt: Int64
    public var creatorId: String
    public var schemeId: String?
    public var props: [String: JSONValue]
    public var groupConstrained: Bool?
    public var shared: Bool?
    public var policyId: String?

    public init(
        id: String,
        createAt: Int64 = 0,
        updateAt: Int64 = 0,
        deleteAt: Int64 = 0,
        teamId: String = "",
        type: ChannelType = .publicChannel,
        displayName: String = "",
        name: String = "",
        header: String = "",
        purpose: String = "",
        lastPostAt: Int64 = 0,
        lastRootPostAt: Int64 = 0,
        totalMsgCount: Int64 = 0,
        totalMsgCountRoot: Int64 = 0,
        extraUpdateAt: Int64 = 0,
        creatorId: String = "",
        schemeId: String? = nil,
        props: [String: JSONValue] = [:],
        groupConstrained: Bool? = nil,
        shared: Bool? = nil,
        policyId: String? = nil
    ) {
        self.id = id
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
        self.teamId = teamId
        self.type = type
        self.displayName = displayName
        self.name = name
        self.header = header
        self.purpose = purpose
        self.lastPostAt = lastPostAt
        self.lastRootPostAt = lastRootPostAt
        self.totalMsgCount = totalMsgCount
        self.totalMsgCountRoot = totalMsgCountRoot
        self.extraUpdateAt = extraUpdateAt
        self.creatorId = creatorId
        self.schemeId = schemeId
        self.props = props
        self.groupConstrained = groupConstrained
        self.shared = shared
        self.policyId = policyId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
        case teamId = "team_id"
        case type
        case displayName = "display_name"
        case name
        case header
        case purpose
        case lastPostAt = "last_post_at"
        case lastRootPostAt = "last_root_post_at"
        case totalMsgCount = "total_msg_count"
        case totalMsgCountRoot = "total_msg_count_root"
        case extraUpdateAt = "extra_update_at"
        case creatorId = "creator_id"
        case schemeId = "scheme_id"
        case props
        case groupConstrained = "group_constrained"
        case shared
        case policyId = "policy_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createAt = c.int64(.createAt)
        updateAt = c.int64(.updateAt)
        deleteAt = c.int64(.deleteAt)
        teamId = c.string(.teamId)
        type = ChannelType(rawValue: c.string(.type))
        displayName = c.string(.displayName)
        name = c.string(.name)
        header = c.string(.header)
        purpose = c.string(.purpose)
        lastPostAt = c.int64(.lastPostAt)
        lastRootPostAt = c.int64(.lastRootPostAt)
        totalMsgCount = c.int64(.totalMsgCount)
        totalMsgCountRoot = c.int64(.totalMsgCountRoot)
        extraUpdateAt = c.int64(.extraUpdateAt)
        creatorId = c.string(.creatorId)
        schemeId = c.optionalString(.schemeId)
        props = c.jsonObject(.props)
        groupConstrained = c.optionalBool(.groupConstrained)
        shared = c.optionalBool(.shared)
        policyId = c.optionalString(.policyId)
    }
}

extension Channel {
    public var isArchived: Bool { deleteAt > 0 }

    /// The two user IDs encoded in a DM channel's name (`"a__b"`); nil for
    /// other channel types.
    public var directMessageUserIds: (String, String)? {
        guard type == .directMessage else { return nil }
        let parts = name.components(separatedBy: "__")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// The other participant of a DM. Returns `myUserId` for a self-DM.
    public func directMessagePartnerId(myUserId: String) -> String? {
        guard let (first, second) = directMessageUserIds else { return nil }
        if first == myUserId { return second }
        if second == myUserId { return first }
        return nil
    }
}

public struct ChannelMember: Codable, Sendable, Equatable {
    public var channelId: String
    public var userId: String
    public var roles: String
    public var lastViewedAt: Int64
    public var msgCount: Int64
    public var msgCountRoot: Int64
    public var mentionCount: Int64
    public var mentionCountRoot: Int64
    public var urgentMentionCount: Int64
    /// Keys such as `desktop`, `push`, `email`, `mark_unread`,
    /// `ignore_channel_mentions`.
    public var notifyProps: [String: String]
    public var lastUpdateAt: Int64
    public var schemeGuest: Bool
    public var schemeUser: Bool
    public var schemeAdmin: Bool
    public var explicitRoles: String

    public init(
        channelId: String,
        userId: String,
        roles: String = "",
        lastViewedAt: Int64 = 0,
        msgCount: Int64 = 0,
        msgCountRoot: Int64 = 0,
        mentionCount: Int64 = 0,
        mentionCountRoot: Int64 = 0,
        urgentMentionCount: Int64 = 0,
        notifyProps: [String: String] = [:],
        lastUpdateAt: Int64 = 0,
        schemeGuest: Bool = false,
        schemeUser: Bool = true,
        schemeAdmin: Bool = false,
        explicitRoles: String = ""
    ) {
        self.channelId = channelId
        self.userId = userId
        self.roles = roles
        self.lastViewedAt = lastViewedAt
        self.msgCount = msgCount
        self.msgCountRoot = msgCountRoot
        self.mentionCount = mentionCount
        self.mentionCountRoot = mentionCountRoot
        self.urgentMentionCount = urgentMentionCount
        self.notifyProps = notifyProps
        self.lastUpdateAt = lastUpdateAt
        self.schemeGuest = schemeGuest
        self.schemeUser = schemeUser
        self.schemeAdmin = schemeAdmin
        self.explicitRoles = explicitRoles
    }

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case userId = "user_id"
        case roles
        case lastViewedAt = "last_viewed_at"
        case msgCount = "msg_count"
        case msgCountRoot = "msg_count_root"
        case mentionCount = "mention_count"
        case mentionCountRoot = "mention_count_root"
        case urgentMentionCount = "urgent_mention_count"
        case notifyProps = "notify_props"
        case lastUpdateAt = "last_update_at"
        case schemeGuest = "scheme_guest"
        case schemeUser = "scheme_user"
        case schemeAdmin = "scheme_admin"
        case explicitRoles = "explicit_roles"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelId = c.string(.channelId)
        userId = c.string(.userId)
        roles = c.string(.roles)
        lastViewedAt = c.int64(.lastViewedAt)
        msgCount = c.int64(.msgCount)
        msgCountRoot = c.int64(.msgCountRoot)
        mentionCount = c.int64(.mentionCount)
        mentionCountRoot = c.int64(.mentionCountRoot)
        urgentMentionCount = c.int64(.urgentMentionCount)
        notifyProps = c.stringMap(.notifyProps)
        lastUpdateAt = c.int64(.lastUpdateAt)
        schemeGuest = c.bool(.schemeGuest)
        schemeUser = c.bool(.schemeUser)
        schemeAdmin = c.bool(.schemeAdmin)
        explicitRoles = c.string(.explicitRoles)
    }
}

extension ChannelMember {
    /// `notify_props.mark_unread == "mention"`: the channel is muted.
    public var isMuted: Bool { notifyProps["mark_unread"] == "mention" }
}

/// Response of `POST /channels/members/{user_id}/view`.
public struct ChannelViewResponse: Codable, Sendable, Equatable {
    public var status: String
    /// Channel ID → new `last_viewed_at`.
    public var lastViewedAtTimes: [String: Int64]

    public init(status: String = "OK", lastViewedAtTimes: [String: Int64] = [:]) {
        self.status = status
        self.lastViewedAtTimes = lastViewedAtTimes
    }

    enum CodingKeys: String, CodingKey {
        case status
        case lastViewedAtTimes = "last_viewed_at_times"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.string(.status)
        lastViewedAtTimes = c.jsonObject(.lastViewedAtTimes).compactMapValues { $0.int64Value }
    }
}

/// Response of `POST /users/{user_id}/posts/{post_id}/set_unread`.
public struct ChannelUnreadAt: Codable, Sendable, Equatable {
    public var teamId: String
    public var userId: String
    public var channelId: String
    public var msgCount: Int64
    public var msgCountRoot: Int64
    public var mentionCount: Int64
    public var mentionCountRoot: Int64
    public var urgentMentionCount: Int64
    public var lastViewedAt: Int64
    public var notifyProps: [String: String]

    public init(
        teamId: String = "",
        userId: String = "",
        channelId: String = "",
        msgCount: Int64 = 0,
        msgCountRoot: Int64 = 0,
        mentionCount: Int64 = 0,
        mentionCountRoot: Int64 = 0,
        urgentMentionCount: Int64 = 0,
        lastViewedAt: Int64 = 0,
        notifyProps: [String: String] = [:]
    ) {
        self.teamId = teamId
        self.userId = userId
        self.channelId = channelId
        self.msgCount = msgCount
        self.msgCountRoot = msgCountRoot
        self.mentionCount = mentionCount
        self.mentionCountRoot = mentionCountRoot
        self.urgentMentionCount = urgentMentionCount
        self.lastViewedAt = lastViewedAt
        self.notifyProps = notifyProps
    }

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case userId = "user_id"
        case channelId = "channel_id"
        case msgCount = "msg_count"
        case msgCountRoot = "msg_count_root"
        case mentionCount = "mention_count"
        case mentionCountRoot = "mention_count_root"
        case urgentMentionCount = "urgent_mention_count"
        case lastViewedAt = "last_viewed_at"
        case notifyProps = "notify_props"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamId = c.string(.teamId)
        userId = c.string(.userId)
        channelId = c.string(.channelId)
        msgCount = c.int64(.msgCount)
        msgCountRoot = c.int64(.msgCountRoot)
        mentionCount = c.int64(.mentionCount)
        mentionCountRoot = c.int64(.mentionCountRoot)
        urgentMentionCount = c.int64(.urgentMentionCount)
        lastViewedAt = c.int64(.lastViewedAt)
        notifyProps = c.stringMap(.notifyProps)
    }
}
