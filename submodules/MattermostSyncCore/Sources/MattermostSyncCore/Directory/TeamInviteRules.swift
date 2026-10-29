import Foundation

/// How the user can bring people into a team (Invite People), as the server allows it:
/// - the invite link `<server>/signup_user_complete/?id=<invite_id>`: the server sends a team's `invite_id` only to
///   users who may invite (`invite_user`) or manage the team, so an empty one means no link;
/// - adding users who already have an account (`POST /teams/{id}/members/batch`): `add_user_to_team`;
/// - email invitations (`POST /teams/{id}/invite/email`): `EnableEmailInvitations`, `invite_user` and
///   `add_user_to_team`.
/// A team synced with LDAP groups takes its members from the groups: no link and no email invitations (the server
/// refuses users outside the groups one by one). The app hides what is not allowed; the server still decides.
public enum TeamInviteRules {
    public struct Result: Equatable {
        public var canShareLink = false
        public var canAddMembers = false
        public var canInviteByEmail = false

        public init() {
        }

        public var allowsAnything: Bool {
            return self.canShareLink || self.canAddMembers || self.canInviteByEmail
        }
    }

    /// - Parameter permissions: the union of the user's system and team role permissions; nil while the roles are
    ///   unknown (then everything the server's settings allow is offered and the server decides).
    public static func evaluate(permissions: Set<String>?, inviteId: String, groupConstrained: Bool, emailInvitationsEnabled: Bool) -> Result {
        let has: (String) -> Bool = { name in
            guard let permissions else {
                return true
            }
            return permissions.contains(name) || permissions.contains("manage_system")
        }
        var result = Result()
        result.canShareLink = !inviteId.isEmpty && !groupConstrained
        result.canAddMembers = has("add_user_to_team")
        result.canInviteByEmail = emailInvitationsEnabled && !groupConstrained && has("invite_user") && has("add_user_to_team")
        return result
    }

    /// `<server>/signup_user_complete/?id=<invite_id>`, as Mattermost's apps share it.
    public static func inviteLink(serverURL: String, inviteId: String) -> String {
        var base = serverURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base + "/signup_user_complete/?id=" + inviteId
    }

    /// The addresses typed for email invitations: separated by commas, semicolons or whitespace (pasted lists),
    /// each once (case-insensitively, first spelling kept); `invalid` are the entries that aren't addresses.
    public static func emailAddresses(_ text: String) -> (valid: [String], invalid: [String]) {
        var separators = CharacterSet.whitespacesAndNewlines
        separators.insert(charactersIn: ",;")
        var valid: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()
        // `Dana Scully <dana@example.com>` and `"Mulder, Fox" <fox@example.com>` pasted from a mail app: only the
        // address inside the brackets (quoted names go first, they may hold separators).
        var plain = text
        for (pattern, template) in [("\"[^\"]*\"", " "), ("[^,;<>\\n]*<([^<>\\s]+)>", " $1 ")] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                plain = expression.stringByReplacingMatches(in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: template)
            }
        }
        for part in plain.components(separatedBy: separators) {
            var entry = part.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            if entry.isEmpty {
                continue
            }
            if entry.lowercased().hasPrefix("mailto:") {
                entry = String(entry.dropFirst("mailto:".count))
            }
            guard seen.insert(entry.lowercased()).inserted else {
                continue
            }
            if self.isEmailAddress(entry) {
                valid.append(entry)
            } else {
                invalid.append(entry)
            }
        }
        return (valid, invalid)
    }

    /// One `@` between a non-empty local part and a domain with a dot that neither starts nor ends it (the
    /// server checks the address properly).
    static func isEmailAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, value.count <= 128 else {
            return false
        }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else {
            return false
        }
        return !value.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "<" || $0 == ">" })
    }
}
