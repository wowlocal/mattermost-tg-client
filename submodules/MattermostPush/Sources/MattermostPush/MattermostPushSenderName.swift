import Foundation

/// The name a notification shows for its sender (4F): the user's display name as the recipient's display setting
/// names users (Mattermost's `User.GetDisplayName`), instead of the server's `sender_name`, which is "@bob" whenever
/// the server's `TeammateNameDisplay` (or the recipient's setting) is the username.
///
/// The app writes the recipient account's effective format into its sync store (`nameFormatCursor`); the
/// notification service extension reads it and the sender (`GET /users/{id}`, cached).
public enum MattermostPushSenderName {
    /// Sync store cursor with the account's effective name format (one of the formats below).
    public static let nameFormatCursor = "push_name_format"

    public static let usernameFormat = "username"
    public static let nicknameFullNameFormat = "nickname_full_name"
    public static let fullNameFormat = "full_name"

    /// The effective format: the user's `display_settings` / `name_format` preference, else the server's
    /// `TeammateNameDisplay`, else the username; the server's setting when `LockTeammateNameDisplay` is on (as the
    /// server decides it for its own push text, `GetNotificationNameFormat`).
    public static func nameFormat(preference: String?, serverDefault: String?, locked: Bool) -> String {
        let known = [usernameFormat, nicknameFullNameFormat, fullNameFormat]
        let server = serverDefault.flatMap { known.contains($0) ? $0 : nil } ?? usernameFormat
        if locked {
            return server
        }
        if let preference = preference, known.contains(preference) {
            return preference
        }
        return server
    }

    /// Mattermost's display name of a user in `format`: the nickname (`nickname_full_name`), the full name
    /// (`full_name` and `nickname_full_name`), falling back to the username.
    public static func displayName(username: String, firstName: String, lastName: String, nickname: String, format: String) -> String {
        let fullName = [firstName, lastName].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let nickname = nickname.trimmingCharacters(in: .whitespaces)
        switch format {
        case nicknameFullNameFormat:
            if !nickname.isEmpty {
                return nickname
            }
            return fullName.isEmpty ? username : fullName
        case fullNameFormat:
            return fullName.isEmpty ? username : fullName
        default:
            return username
        }
    }
}
