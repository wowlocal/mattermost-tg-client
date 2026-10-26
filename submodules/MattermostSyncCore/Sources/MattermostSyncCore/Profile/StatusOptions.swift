import Foundation

// Own status, custom status and profile rules (Phase 3F). Pure functions of the input and a calendar, so the
// app's screens and the tests agree on every boundary.

/// How long "Do Not Disturb" lasts, as Mattermost's clients offer it.
public enum DoNotDisturbDuration: Hashable, Sendable {
    /// Until switched off ("Don't clear").
    case indefinitely
    case thirtyMinutes
    case oneHour
    case twoHours
    /// Tomorrow at 9:00 in the user's time zone.
    case tomorrow
    case until(Date)

    public static let presets: [DoNotDisturbDuration] = [.indefinitely, .thirtyMinutes, .oneHour, .twoHours, .tomorrow]

    /// `dnd_end_time` for `PUT /users/{id}/status` (Unix seconds), nil for no end. The server truncates it to the
    /// minute.
    public func endTime(now: Date, calendar: Calendar = .current) -> Int64? {
        let end: Date
        switch self {
        case .indefinitely:
            return nil
        case .thirtyMinutes:
            end = now.addingTimeInterval(30 * 60)
        case .oneHour:
            end = now.addingTimeInterval(60 * 60)
        case .twoHours:
            end = now.addingTimeInterval(2 * 60 * 60)
        case .tomorrow:
            let startOfToday = calendar.startOfDay(for: now)
            guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday), let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: startOfTomorrow) else {
                return Int64(now.timeIntervalSince1970) + 24 * 60 * 60
            }
            end = nine
        case let .until(date):
            end = date
        }
        return Int64(end.timeIntervalSince1970.rounded(.down))
    }
}

/// When a custom status clears itself; the raw values are Mattermost's `duration` strings.
public enum CustomStatusDuration: Hashable, Sendable {
    case dontClear
    case thirtyMinutes
    case oneHour
    case fourHours
    case today
    case thisWeek
    case dateAndTime(Date)

    public static let presets: [CustomStatusDuration] = [.dontClear, .thirtyMinutes, .oneHour, .fourHours, .today, .thisWeek]

    public var apiValue: String {
        switch self {
        case .dontClear: return ""
        case .thirtyMinutes: return "thirty_minutes"
        case .oneHour: return "one_hour"
        case .fourHours: return "four_hours"
        case .today: return "today"
        case .thisWeek: return "this_week"
        case .dateAndTime: return "date_and_time"
        }
    }

    /// The preset for an API value (`date_and_time` needs its date: nil).
    public init?(apiValue: String) {
        switch apiValue {
        case "": self = .dontClear
        case "thirty_minutes": self = .thirtyMinutes
        case "one_hour": self = .oneHour
        case "four_hours": self = .fourHours
        case "today": self = .today
        case "this_week": self = .thisWeek
        default: return nil
        }
    }

    /// The expiry Mattermost's clients compute: relative ones from now, `today` at the end of the day and
    /// `this_week` at the end of the week (the calendar's last weekday, 23:59:59); nil for "don't clear".
    public func expiry(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .dontClear:
            return nil
        case .thirtyMinutes:
            return now.addingTimeInterval(30 * 60)
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .fourHours:
            return now.addingTimeInterval(4 * 60 * 60)
        case .today:
            return Self.endOfDay(now, calendar: calendar)
        case .thisWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return Self.endOfDay(now, calendar: calendar)
            }
            return week.end.addingTimeInterval(-1)
        case let .dateAndTime(date):
            return date
        }
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        return next.addingTimeInterval(-1)
    }

    /// `expires_at` as the server stores it (RFC 3339 in UTC), empty for no expiry.
    public func expiresAtString(now: Date, calendar: Calendar = .current) -> String {
        guard let expiry = self.expiry(now: now, calendar: calendar) else {
            return ""
        }
        return Self.rfc3339(expiry)
    }

    public static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// A suggested custom status (Mattermost's defaults).
public struct CustomStatusSuggestion: Hashable, Sendable {
    /// The emoji's name, as Mattermost stores it.
    public let emoji: String
    public let text: String
    public let duration: CustomStatusDuration

    public init(emoji: String, text: String, duration: CustomStatusDuration) {
        self.emoji = emoji
        self.text = text
        self.duration = duration
    }

    /// The webapp's and mobile app's default suggestions, in their order.
    public static let defaults: [CustomStatusSuggestion] = [
        CustomStatusSuggestion(emoji: "calendar", text: "In a meeting", duration: .oneHour),
        CustomStatusSuggestion(emoji: "hamburger", text: "Out for lunch", duration: .thirtyMinutes),
        CustomStatusSuggestion(emoji: "sneezing_face", text: "Out sick", duration: .today),
        CustomStatusSuggestion(emoji: "house", text: "Working from home", duration: .today),
        CustomStatusSuggestion(emoji: "palm_tree", text: "On a vacation", duration: .thisWeek)
    ]
}

/// Custom status limits.
public enum CustomStatusRules {
    /// The server's `CustomStatusTextMaxRunes`.
    public static let textMaxLength = 100
    /// The emoji the clients show when a status has text but no emoji.
    public static let defaultEmoji = "speech_balloon"
}

/// Username rules of Mattermost's clients (the server allows up to 64 characters; the clients 22).
public enum UsernameRules {
    public enum Problem: Equatable, Sendable {
        case tooShort
        case tooLong
        case mustStartWithLetter
        case invalidCharacters
        case reserved
    }

    public static let minLength = 3
    public static let maxLength = 22
    public static let reserved: Set<String> = ["valet", "all", "channel", "here", "matterbot", "system"]

    /// The problem with `username` (lowercase it first, as the clients do), or nil.
    public static func validate(_ username: String) -> Problem? {
        if username.count < minLength {
            return .tooShort
        }
        if username.count > maxLength {
            return .tooLong
        }
        guard let first = username.unicodeScalars.first, ("a" ... "z").contains(first) else {
            if username.unicodeScalars.allSatisfy({ isAllowed($0) }) {
                return .mustStartWithLetter
            }
            return .invalidCharacters
        }
        if !username.unicodeScalars.allSatisfy({ isAllowed($0) }) {
            return .invalidCharacters
        }
        if reserved.contains(username) {
            return .reserved
        }
        return nil
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        return ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
    }
}

/// Which profile fields the user may change: users of an SSO/LDAP/SAML login can't change their username or
/// email, and fields synced from LDAP/SAML attributes (`Ldap*AttributeSet` / `Saml*AttributeSet` in the client
/// config) are read-only for those users.
public struct ProfileFieldAccess: Equatable, Sendable {
    public var firstName: Bool
    public var lastName: Bool
    public var nickname: Bool
    public var position: Bool
    public var username: Bool
    public var email: Bool
    public var picture: Bool

    public init(firstName: Bool = true, lastName: Bool = true, nickname: Bool = true, position: Bool = true, username: Bool = true, email: Bool = true, picture: Bool = true) {
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.position = position
        self.username = username
        self.email = email
        self.picture = picture
    }

    /// - Parameters:
    ///   - authService: the user's `auth_service` (`""` for email/username logins, `ldap`, `saml`, `gitlab`, …).
    ///   - config: the client config's values (`"true"` / `"false"`).
    public static func resolve(authService: String, config: [String: String]) -> ProfileFieldAccess {
        let service = authService.lowercased()
        guard !service.isEmpty, service != "email" else {
            return ProfileFieldAccess()
        }
        func synced(_ attribute: String) -> Bool {
            switch service {
            case "ldap":
                return config["Ldap\(attribute)AttributeSet"] == "true"
            case "saml":
                return config["Saml\(attribute)AttributeSet"] == "true"
            default:
                return false
            }
        }
        return ProfileFieldAccess(
            firstName: !synced("FirstName"),
            lastName: !synced("LastName"),
            nickname: !synced("Nickname"),
            position: !synced("Position"),
            username: false,
            email: false,
            picture: service != "ldap" || config["LdapPictureAttributeSet"] != "true"
        )
    }
}
