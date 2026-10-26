import Foundation

/// A login session of the user (`GET /users/{user_id}/sessions`). The server never returns the token.
public struct Session: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createAt: Int64
    /// 0 when the session does not expire.
    public var expiresAt: Int64
    public var lastActivityAt: Int64
    public var userId: String
    /// The push device attached to the session (`"<platform>:<token>"`), empty for none.
    public var deviceId: String
    public var roles: String
    public var isOAuth: Bool
    /// `platform`, `os`, `browser` (parsed from the user agent at login), `isMobile`, `csrf`, `type`
    /// (`UserAccessToken` for personal access tokens), …
    public var props: [String: String]

    public init(
        id: String,
        createAt: Int64 = 0,
        expiresAt: Int64 = 0,
        lastActivityAt: Int64 = 0,
        userId: String = "",
        deviceId: String = "",
        roles: String = "",
        isOAuth: Bool = false,
        props: [String: String] = [:]
    ) {
        self.id = id
        self.createAt = createAt
        self.expiresAt = expiresAt
        self.lastActivityAt = lastActivityAt
        self.userId = userId
        self.deviceId = deviceId
        self.roles = roles
        self.isOAuth = isOAuth
        self.props = props
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createAt = "create_at"
        case expiresAt = "expires_at"
        case lastActivityAt = "last_activity_at"
        case userId = "user_id"
        case deviceId = "device_id"
        case roles
        case isOAuth = "is_oauth"
        case props
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createAt = c.int64(.createAt)
        expiresAt = c.int64(.expiresAt)
        lastActivityAt = c.int64(.lastActivityAt)
        userId = c.string(.userId)
        deviceId = c.string(.deviceId)
        roles = c.string(.roles)
        isOAuth = c.bool(.isOAuth)
        props = c.stringMap(.props)
    }
}

extension Session {
    /// The session's CSRF token (also sent as the `MMCSRF` cookie at login): tells the current session
    /// apart, since the list never includes tokens.
    public var csrfToken: String? {
        return props["csrf"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A personal access token rather than a login.
    public var isAccessToken: Bool {
        return props["type"] == "UserAccessToken"
    }

    public var isMobile: Bool {
        return props["isMobile"] == "true" || !deviceId.isEmpty
    }
}
