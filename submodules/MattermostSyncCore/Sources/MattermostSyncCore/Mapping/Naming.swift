import Foundation

/// How Relay names users (4H): Mattermost's "Teammate Name Display" (`display_settings` / `name_format`, else the
/// server's `TeammateNameDisplay`), applied to the names a user's Telegram peer carries, so every screen that shows
/// a peer's name (chat titles, chat list rows, message authors, the mention list, member lists, profiles) follows it.
public enum UserDisplayName {
    public static let usernameFormat = "username"
    public static let nicknameFullNameFormat = "nickname_full_name"
    public static let fullNameFormat = "full_name"

    /// The first and last name of a user's peer in `format`, with Mattermost's fallbacks (`User.GetDisplayName`):
    /// `full_name` → first and last name (Telegram's own name order and initials), else the username;
    /// `nickname_full_name` → the nickname, else the full name, else the username; `username` (and anything
    /// unknown) → the username.
    public static func peerNames(username: String, firstName: String, lastName: String, nickname: String, format: String) -> (first: String, last: String?) {
        let first = firstName.trimmingCharacters(in: .whitespaces)
        let last = lastName.trimmingCharacters(in: .whitespaces)
        let nickname = nickname.trimmingCharacters(in: .whitespaces)
        func fullName() -> (first: String, last: String?) {
            if first.isEmpty && last.isEmpty {
                return (username, nil)
            }
            if first.isEmpty {
                return (last, nil)
            }
            return (first, last.isEmpty ? nil : last)
        }
        switch format {
        case self.fullNameFormat:
            return fullName()
        case self.nicknameFullNameFormat:
            return nickname.isEmpty ? fullName() : (nickname, nil)
        default:
            return (username, nil)
        }
    }

    /// The display name as one string (`peerNames` joined by a space).
    public static func displayName(username: String, firstName: String, lastName: String, nickname: String, format: String) -> String {
        let names = self.peerNames(username: username, firstName: firstName, lastName: lastName, nickname: nickname, format: format)
        return [names.first, names.last ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A group message's title as Mattermost's clients build it (`getGroupDisplayNameFromUserIds`): the other
    /// members' display names, sorted (numbers numerically, case-insensitively), joined by ", ".
    public static func groupTitle(_ names: [String]) -> String {
        return names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).joined(separator: ", ")
    }

    /// The members of a group message as the server names them: its `display_name` is the members' usernames
    /// (the user's own included), joined by ", ".
    public static func groupUsernames(displayName: String) -> [String] {
        return displayName.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// `@all`, `@channel` and `@here` in a message about to be sent (4H): Mattermost's clients ask before notifying a
/// whole channel. Mentions in code (spans and blocks) and in links don't count, as the markdown renders them.
public enum ChannelWideMention {
    /// The channel-wide mentions in `text` (markdown as typed), in order of first appearance.
    public static func mentions(in text: String) -> [SpecialMentionKind] {
        if !text.contains("@") {
            return []
        }
        var result: [SpecialMentionKind] = []
        for entity in MattermostMarkdown.parse(text).entities {
            if case let .specialMention(kind) = entity.type, !result.contains(kind) {
                result.append(kind)
            }
        }
        return result
    }

    /// Mattermost's threshold (`Constants.NOTIFY_ALL_MEMBERS`): a channel with more members than this asks first.
    public static let confirmationMemberThreshold = 5

    /// Whether to ask (the web app's check, 11.7): the server's `EnableConfirmNotificationsToChannel`, the
    /// user's `use_channel_mentions` permission in the channel, more members than the threshold, and a
    /// channel-wide mention in the text.
    public static func needsConfirmation(mentions: [SpecialMentionKind], memberCount: Int, confirmationEnabled: Bool, canUseChannelMentions: Bool) -> Bool {
        return confirmationEnabled && canUseChannelMentions && memberCount > self.confirmationMemberThreshold && !mentions.isEmpty
    }
}
