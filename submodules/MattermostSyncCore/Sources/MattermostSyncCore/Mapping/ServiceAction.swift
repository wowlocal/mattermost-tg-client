import Foundation

/// A user referenced by a system post. Either field may be missing in older posts.
public struct ServiceUserRef: Hashable, Sendable {
    public var userId: String?
    public var username: String?

    public init(userId: String?, username: String?) {
        self.userId = userId?.isEmpty == true ? nil : userId
        self.username = username?.isEmpty == true ? nil : username
    }
}

/// Mattermost system posts mapped to a service-message action (Telegram's `TelegramMediaAction`
/// needs a Mattermost variant that carries this).
public enum ServiceAction: Hashable, Sendable {
    case joinedChannel(user: ServiceUserRef, isGuest: Bool)
    case leftChannel(user: ServiceUserRef)
    case addedToChannel(actor: ServiceUserRef, added: ServiceUserRef, isGuest: Bool)
    case removedFromChannel(actor: ServiceUserRef, removed: ServiceUserRef)
    case joinedTeam(user: ServiceUserRef)
    case leftTeam(user: ServiceUserRef)
    case addedToTeam(actor: ServiceUserRef, added: ServiceUserRef)
    case removedFromTeam(actor: ServiceUserRef, removed: ServiceUserRef)
    case headerChanged(actor: ServiceUserRef, oldHeader: String, newHeader: String)
    case purposeChanged(actor: ServiceUserRef, oldPurpose: String, newPurpose: String)
    case displayNameChanged(actor: ServiceUserRef, oldName: String, newName: String)
    case channelArchived(actor: ServiceUserRef)
    case channelRestored(actor: ServiceUserRef)
    case convertedToPrivate(actor: ServiceUserRef)
    case privacyChanged(actor: ServiceUserRef, message: String)
    case channelMoved(actor: ServiceUserRef, message: String)
    case convertedFromGroupMessage(actor: ServiceUserRef, message: String)
    /// `system_generic`, `system_ephemeral` and unknown `system_*` types: show the server text.
    case generic(text: String)
    /// Plugin post types (`custom_*`) the app can't render; show the text with a fallback badge.
    case unsupported(type: String, text: String)

    /// Maps a post's `type`, author and `props` (string values) to a service action.
    /// Returns nil for posts that render as ordinary messages: `""`, `me` (render italic),
    /// `system_auto_responder` (an "automatic reply" badge on a normal bubble) and `reminder`.
    public static func from(type: String, userId: String, message: String, props: [String: String]) -> ServiceAction? {
        func user(_ idKey: String?, _ nameKey: String?) -> ServiceUserRef {
            return ServiceUserRef(userId: idKey.flatMap { props[$0] }, username: nameKey.flatMap { props[$0] })
        }
        let author = ServiceUserRef(userId: userId, username: props["username"])
        let actor: ServiceUserRef = {
            let explicit = user("userId", "username")
            return explicit.userId == nil ? ServiceUserRef(userId: userId, username: explicit.username) : explicit
        }()

        switch type {
        case "", "me", "system_auto_responder", "reminder":
            return nil
        case "system_join_channel":
            return .joinedChannel(user: author, isGuest: false)
        case "system_guest_join_channel":
            return .joinedChannel(user: author, isGuest: true)
        case "system_leave_channel":
            return .leftChannel(user: author)
        case "system_add_to_channel":
            return .addedToChannel(actor: actor, added: user("addedUserId", "addedUsername"), isGuest: false)
        case "system_add_guest_to_chan":
            return .addedToChannel(actor: actor, added: user("addedUserId", "addedUsername"), isGuest: true)
        case "system_remove_from_channel":
            return .removedFromChannel(actor: ServiceUserRef(userId: userId, username: nil), removed: user("removedUserId", "removedUsername"))
        case "system_join_team":
            return .joinedTeam(user: author)
        case "system_leave_team":
            return .leftTeam(user: author)
        case "system_add_to_team":
            return .addedToTeam(actor: actor, added: user("addedUserId", "addedUsername"))
        case "system_remove_from_team":
            let removed = user("removedUserId", "removedUsername")
            if removed.userId == nil && removed.username == nil {
                // Older servers: the removed user is the author.
                return .removedFromTeam(actor: ServiceUserRef(userId: nil, username: nil), removed: author)
            }
            return .removedFromTeam(actor: actor, removed: removed)
        case "system_header_change":
            return .headerChanged(actor: author, oldHeader: props["old_header"] ?? "", newHeader: props["new_header"] ?? "")
        case "system_purpose_change":
            return .purposeChanged(actor: author, oldPurpose: props["old_purpose"] ?? "", newPurpose: props["new_purpose"] ?? "")
        case "system_displayname_change":
            return .displayNameChanged(actor: author, oldName: props["old_displayname"] ?? "", newName: props["new_displayname"] ?? "")
        case "system_channel_deleted":
            return .channelArchived(actor: author)
        case "system_channel_restored":
            return .channelRestored(actor: author)
        case "system_convert_channel":
            return .convertedToPrivate(actor: author)
        case "system_change_chan_privacy":
            return .privacyChanged(actor: author, message: message)
        case "system_move_channel":
            return .channelMoved(actor: author, message: message)
        case "system_gm_to_channel":
            return .convertedFromGroupMessage(actor: author, message: message)
        default:
            if type.hasPrefix("system_") {
                return .generic(text: message)
            }
            return .unsupported(type: type, text: message)
        }
    }

    /// True for post types that are system messages (`system_*`).
    public static func isSystemPostType(_ type: String) -> Bool {
        return type.hasPrefix("system_") && type != "system_auto_responder"
    }

    /// English fallback text for chat-list previews and notifications. `name` turns a user
    /// reference into a display name (e.g. `@username` or the full name).
    public func fallbackText(name: (ServiceUserRef) -> String) -> String {
        return formattedText(name: name).text
    }

    /// The service-message text with the ranges of the user names (for mention entities) and of
    /// quoted values such as a new header (for emphasis).
    public func formattedText(name: (ServiceUserRef) -> String) -> ServiceMessageText {
        var builder = ServiceMessageText()
        func user(_ ref: ServiceUserRef) {
            builder.appendMention(name(ref), user: ref)
        }
        func text(_ value: String) {
            builder.append(value)
        }
        func quoted(_ value: String) {
            builder.appendEmphasized(value)
        }
        switch self {
        case let .joinedChannel(ref, isGuest):
            user(ref)
            text(isGuest ? " joined the channel as a guest." : " joined the channel.")
        case let .leftChannel(ref):
            user(ref)
            text(" left the channel.")
        case let .addedToChannel(actor, added, isGuest):
            user(added)
            text(isGuest ? " was added to the channel as a guest by " : " was added to the channel by ")
            user(actor)
            text(".")
        case let .removedFromChannel(_, removed):
            user(removed)
            text(" was removed from the channel.")
        case let .joinedTeam(ref):
            user(ref)
            text(" joined the team.")
        case let .leftTeam(ref):
            user(ref)
            text(" left the team.")
        case let .addedToTeam(actor, added):
            user(added)
            text(" was added to the team by ")
            user(actor)
            text(".")
        case let .removedFromTeam(_, removed):
            user(removed)
            text(" was removed from the team.")
        case let .headerChanged(actor, oldHeader, newHeader):
            user(actor)
            if newHeader.isEmpty {
                text(" removed the channel header (was: ")
                quoted(oldHeader)
                text(")")
            } else if oldHeader.isEmpty {
                text(" updated the channel header to: ")
                quoted(newHeader)
            } else {
                text(" updated the channel header from: ")
                quoted(oldHeader)
                text(" to: ")
                quoted(newHeader)
            }
        case let .purposeChanged(actor, oldPurpose, newPurpose):
            user(actor)
            if newPurpose.isEmpty {
                text(" removed the channel purpose (was: ")
                quoted(oldPurpose)
                text(")")
            } else if oldPurpose.isEmpty {
                text(" updated the channel purpose to: ")
                quoted(newPurpose)
            } else {
                text(" updated the channel purpose from: ")
                quoted(oldPurpose)
                text(" to: ")
                quoted(newPurpose)
            }
        case let .displayNameChanged(actor, oldName, newName):
            user(actor)
            text(" updated the channel display name from: ")
            quoted(oldName)
            text(" to: ")
            quoted(newName)
        case let .channelArchived(actor):
            user(actor)
            text(" archived the channel.")
        case let .channelRestored(actor):
            user(actor)
            text(" unarchived the channel.")
        case let .convertedToPrivate(actor):
            user(actor)
            text(" converted the channel to a private channel.")
        case let .privacyChanged(_, message), let .channelMoved(_, message), let .convertedFromGroupMessage(_, message):
            text(message)
        case let .generic(value):
            text(value)
        case let .unsupported(_, value):
            text(value)
        }
        return builder
    }
}

/// Service-message text with the user names and quoted values marked. Ranges are UTF-16 offsets,
/// like `TextEntity` ranges.
public struct ServiceMessageText: Hashable, Sendable {
    public struct Mention: Hashable, Sendable {
        public var range: Range<Int>
        public var user: ServiceUserRef
    }

    public private(set) var text: String = ""
    public private(set) var mentions: [Mention] = []
    public private(set) var emphasized: [Range<Int>] = []
    private var length = 0

    public init() {
    }

    mutating func append(_ value: String) {
        text += value
        length += value.utf16.count
    }

    mutating func appendMention(_ value: String, user: ServiceUserRef) {
        let start = length
        append(value)
        if length > start {
            mentions.append(Mention(range: start ..< length, user: user))
        }
    }

    mutating func appendEmphasized(_ value: String) {
        let start = length
        append(value)
        if length > start {
            emphasized.append(start ..< length)
        }
    }
}
