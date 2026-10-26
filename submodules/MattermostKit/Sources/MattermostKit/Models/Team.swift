import Foundation

public struct Team: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createAt: Int64
    public var updateAt: Int64
    public var deleteAt: Int64
    public var displayName: String
    public var name: String
    public var description: String
    public var email: String
    /// `"O"` (open) or `"I"` (invite only).
    public var type: String
    public var companyName: String
    public var allowedDomains: String
    public var inviteId: String
    public var allowOpenInvite: Bool
    public var lastTeamIconUpdate: Int64
    public var schemeId: String?
    public var groupConstrained: Bool?
    public var policyId: String?

    public init(
        id: String,
        createAt: Int64 = 0,
        updateAt: Int64 = 0,
        deleteAt: Int64 = 0,
        displayName: String = "",
        name: String = "",
        description: String = "",
        email: String = "",
        type: String = "O",
        companyName: String = "",
        allowedDomains: String = "",
        inviteId: String = "",
        allowOpenInvite: Bool = false,
        lastTeamIconUpdate: Int64 = 0,
        schemeId: String? = nil,
        groupConstrained: Bool? = nil,
        policyId: String? = nil
    ) {
        self.id = id
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
        self.displayName = displayName
        self.name = name
        self.description = description
        self.email = email
        self.type = type
        self.companyName = companyName
        self.allowedDomains = allowedDomains
        self.inviteId = inviteId
        self.allowOpenInvite = allowOpenInvite
        self.lastTeamIconUpdate = lastTeamIconUpdate
        self.schemeId = schemeId
        self.groupConstrained = groupConstrained
        self.policyId = policyId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
        case displayName = "display_name"
        case name
        case description
        case email
        case type
        case companyName = "company_name"
        case allowedDomains = "allowed_domains"
        case inviteId = "invite_id"
        case allowOpenInvite = "allow_open_invite"
        case lastTeamIconUpdate = "last_team_icon_update"
        case schemeId = "scheme_id"
        case groupConstrained = "group_constrained"
        case policyId = "policy_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createAt = c.int64(.createAt)
        updateAt = c.int64(.updateAt)
        deleteAt = c.int64(.deleteAt)
        displayName = c.string(.displayName)
        name = c.string(.name)
        description = c.string(.description)
        email = c.string(.email)
        type = c.string(.type)
        companyName = c.string(.companyName)
        allowedDomains = c.string(.allowedDomains)
        inviteId = c.string(.inviteId)
        allowOpenInvite = c.bool(.allowOpenInvite)
        lastTeamIconUpdate = c.int64(.lastTeamIconUpdate)
        schemeId = c.optionalString(.schemeId)
        groupConstrained = c.optionalBool(.groupConstrained)
        policyId = c.optionalString(.policyId)
    }
}

public struct TeamMember: Codable, Sendable, Equatable {
    public var teamId: String
    public var userId: String
    public var roles: String
    /// Non-zero when the user has left the team.
    public var deleteAt: Int64
    public var schemeGuest: Bool
    public var schemeUser: Bool
    public var schemeAdmin: Bool
    public var explicitRoles: String
    public var createAt: Int64?

    public init(
        teamId: String,
        userId: String,
        roles: String = "",
        deleteAt: Int64 = 0,
        schemeGuest: Bool = false,
        schemeUser: Bool = true,
        schemeAdmin: Bool = false,
        explicitRoles: String = "",
        createAt: Int64? = nil
    ) {
        self.teamId = teamId
        self.userId = userId
        self.roles = roles
        self.deleteAt = deleteAt
        self.schemeGuest = schemeGuest
        self.schemeUser = schemeUser
        self.schemeAdmin = schemeAdmin
        self.explicitRoles = explicitRoles
        self.createAt = createAt
    }

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case userId = "user_id"
        case roles
        case deleteAt = "delete_at"
        case schemeGuest = "scheme_guest"
        case schemeUser = "scheme_user"
        case schemeAdmin = "scheme_admin"
        case explicitRoles = "explicit_roles"
        case createAt = "create_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamId = c.string(.teamId)
        userId = c.string(.userId)
        roles = c.string(.roles)
        deleteAt = c.int64(.deleteAt)
        schemeGuest = c.bool(.schemeGuest)
        schemeUser = c.bool(.schemeUser)
        schemeAdmin = c.bool(.schemeAdmin)
        explicitRoles = c.string(.explicitRoles)
        createAt = c.optionalInt64(.createAt)
    }
}

/// Unread totals for one team (`GET /users/{user_id}/teams/unread`).
public struct TeamUnread: Codable, Sendable, Equatable {
    public var teamId: String
    public var msgCount: Int64
    public var mentionCount: Int64
    public var msgCountRoot: Int64
    public var mentionCountRoot: Int64
    public var threadCount: Int64
    public var threadMentionCount: Int64
    public var threadUrgentMentionCount: Int64

    public init(
        teamId: String,
        msgCount: Int64 = 0,
        mentionCount: Int64 = 0,
        msgCountRoot: Int64 = 0,
        mentionCountRoot: Int64 = 0,
        threadCount: Int64 = 0,
        threadMentionCount: Int64 = 0,
        threadUrgentMentionCount: Int64 = 0
    ) {
        self.teamId = teamId
        self.msgCount = msgCount
        self.mentionCount = mentionCount
        self.msgCountRoot = msgCountRoot
        self.mentionCountRoot = mentionCountRoot
        self.threadCount = threadCount
        self.threadMentionCount = threadMentionCount
        self.threadUrgentMentionCount = threadUrgentMentionCount
    }

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case msgCount = "msg_count"
        case mentionCount = "mention_count"
        case msgCountRoot = "msg_count_root"
        case mentionCountRoot = "mention_count_root"
        case threadCount = "thread_count"
        case threadMentionCount = "thread_mention_count"
        case threadUrgentMentionCount = "thread_urgent_mention_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamId = c.string(.teamId)
        msgCount = c.int64(.msgCount)
        mentionCount = c.int64(.mentionCount)
        msgCountRoot = c.int64(.msgCountRoot)
        mentionCountRoot = c.int64(.mentionCountRoot)
        threadCount = c.int64(.threadCount)
        threadMentionCount = c.int64(.threadMentionCount)
        threadUrgentMentionCount = c.int64(.threadUrgentMentionCount)
    }
}
