import Foundation

public struct User: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createAt: Int64
    public var updateAt: Int64
    /// Non-zero for deactivated users.
    public var deleteAt: Int64
    public var username: String
    public var authService: String
    public var email: String
    public var emailVerified: Bool
    public var nickname: String
    public var firstName: String
    public var lastName: String
    public var position: String
    /// Space-separated role names, e.g. `"system_user system_admin"`.
    public var roles: String
    public var locale: String
    public var props: [String: String]
    public var notifyProps: [String: String]
    /// Keys `useAutomaticTimezone`, `automaticTimezone`, `manualTimezone`.
    public var timezone: [String: String]
    /// Changes whenever the avatar changes; use it to invalidate cached images.
    public var lastPictureUpdate: Int64
    /// Only sent to admins or for the current user on some server versions.
    public var lastActivityAt: Int64?
    public var isBot: Bool
    public var botDescription: String
    public var botLastIconUpdate: Int64
    public var mfaActive: Bool
    public var remoteId: String?

    public init(
        id: String,
        createAt: Int64 = 0,
        updateAt: Int64 = 0,
        deleteAt: Int64 = 0,
        username: String = "",
        authService: String = "",
        email: String = "",
        emailVerified: Bool = false,
        nickname: String = "",
        firstName: String = "",
        lastName: String = "",
        position: String = "",
        roles: String = "",
        locale: String = "",
        props: [String: String] = [:],
        notifyProps: [String: String] = [:],
        timezone: [String: String] = [:],
        lastPictureUpdate: Int64 = 0,
        lastActivityAt: Int64? = nil,
        isBot: Bool = false,
        botDescription: String = "",
        botLastIconUpdate: Int64 = 0,
        mfaActive: Bool = false,
        remoteId: String? = nil
    ) {
        self.id = id
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
        self.username = username
        self.authService = authService
        self.email = email
        self.emailVerified = emailVerified
        self.nickname = nickname
        self.firstName = firstName
        self.lastName = lastName
        self.position = position
        self.roles = roles
        self.locale = locale
        self.props = props
        self.notifyProps = notifyProps
        self.timezone = timezone
        self.lastPictureUpdate = lastPictureUpdate
        self.lastActivityAt = lastActivityAt
        self.isBot = isBot
        self.botDescription = botDescription
        self.botLastIconUpdate = botLastIconUpdate
        self.mfaActive = mfaActive
        self.remoteId = remoteId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
        case username
        case authService = "auth_service"
        case email
        case emailVerified = "email_verified"
        case nickname
        case firstName = "first_name"
        case lastName = "last_name"
        case position
        case roles
        case locale
        case props
        case notifyProps = "notify_props"
        case timezone
        case lastPictureUpdate = "last_picture_update"
        case lastActivityAt = "last_activity_at"
        case isBot = "is_bot"
        case botDescription = "bot_description"
        case botLastIconUpdate = "bot_last_icon_update"
        case mfaActive = "mfa_active"
        case remoteId = "remote_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createAt = c.int64(.createAt)
        updateAt = c.int64(.updateAt)
        deleteAt = c.int64(.deleteAt)
        username = c.string(.username)
        authService = c.string(.authService)
        email = c.string(.email)
        emailVerified = c.bool(.emailVerified)
        nickname = c.string(.nickname)
        firstName = c.string(.firstName)
        lastName = c.string(.lastName)
        position = c.string(.position)
        roles = c.string(.roles)
        locale = c.string(.locale)
        props = c.stringMap(.props)
        notifyProps = c.stringMap(.notifyProps)
        timezone = c.stringMap(.timezone)
        lastPictureUpdate = c.int64(.lastPictureUpdate)
        lastActivityAt = c.optionalInt64(.lastActivityAt)
        isBot = c.bool(.isBot)
        botDescription = c.string(.botDescription)
        botLastIconUpdate = c.int64(.botLastIconUpdate)
        mfaActive = c.bool(.mfaActive)
        remoteId = c.optionalString(.remoteId)
    }
}

extension User {
    public var isDeactivated: Bool { deleteAt > 0 }

    public var roleList: [String] {
        roles.split(separator: " ").map(String.init)
    }

    public var isSystemAdmin: Bool { roleList.contains("system_admin") }
    public var isGuest: Bool { roleList.contains("system_guest") }

    /// "First Last", trimmed; empty if neither is set.
    public var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The name to show for this user, following the server's
    /// `TeammateNameDisplay` setting, falling back to the username.
    public func displayName(_ setting: TeammateNameDisplay = .username) -> String {
        switch setting {
        case .username:
            return username
        case .nicknameOrFullName:
            if !nickname.isEmpty { return nickname }
            return fullName.isEmpty ? username : fullName
        case .fullName:
            return fullName.isEmpty ? username : fullName
        }
    }

    /// The custom status stored in `props["customStatus"]` (a JSON string).
    public var customStatus: UserCustomStatus? {
        guard let raw = props["customStatus"], !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(UserCustomStatus.self, from: Data(raw.utf8))
    }
}

/// Values of the `TeammateNameDisplay` client config / display preference.
public enum TeammateNameDisplay: String, Sendable, CaseIterable {
    case username = "username"
    case nicknameOrFullName = "nickname_full_name"
    case fullName = "full_name"
}

public struct UserCustomStatus: Codable, Sendable, Equatable {
    public var emoji: String
    public var text: String
    /// e.g. `"thirty_minutes"`, `"today"`, `"date_and_time"`, `""`.
    public var duration: String
    /// RFC 3339 timestamp string, empty when the status does not expire.
    public var expiresAt: String

    public init(emoji: String = "", text: String = "", duration: String = "", expiresAt: String = "") {
        self.emoji = emoji
        self.text = text
        self.duration = duration
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case emoji, text, duration
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoji = c.string(.emoji)
        text = c.string(.text)
        duration = c.string(.duration)
        expiresAt = c.string(.expiresAt)
    }
}

/// Response of `GET /users/autocomplete`.
public struct UserAutocomplete: Codable, Sendable, Equatable {
    public var users: [User]
    /// Only present when autocompleting within a channel.
    public var outOfChannel: [User]

    public init(users: [User] = [], outOfChannel: [User] = []) {
        self.users = users
        self.outOfChannel = outOfChannel
    }

    enum CodingKeys: String, CodingKey {
        case users
        case outOfChannel = "out_of_channel"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = c.array(User.self, .users)
        outOfChannel = c.array(User.self, .outOfChannel)
    }
}
