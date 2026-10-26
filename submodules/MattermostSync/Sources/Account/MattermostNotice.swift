import Foundation

/// A user-facing message about a failed write, shown as a toast (`MattermostSync.notices`). MattermostSync has no
/// strings: the app turns a notice into text in the user's language (`MattermostSync.noticeText`, installed by
/// MattermostUI from `Relay.strings`, Phase 4C); `englishText` is the fallback and what the log shows. `detail` is
/// the error's own description (the server's message, or the system's).
public enum MattermostNotice: Equatable {
    case uploadFailed(detail: String)
    case sendChatMissing
    case sendFailed(detail: String)
    case editTooEarly
    case editFailed(detail: String)
    case reactionFailed
    case deleteForbidden
    case deleteFailed(detail: String)
    case notificationsFailed(detail: String)
    case favoritesFailed(detail: String)
    case leaveFailed(detail: String)
    case pinFailed
    case unpinFailed
    case unpinAllFailed
    case saveFailed
    case unsaveFailed
    case followFailed(detail: String)
    case unfollowFailed(detail: String)

    public var englishText: String {
        switch self {
        case let .uploadFailed(detail):
            return "Couldn't upload the attachment: \(detail)"
        case .sendChatMissing:
            return "Couldn't send the message: this chat is not on the server."
        case let .sendFailed(detail):
            return "Couldn't send the message: \(detail)"
        case .editTooEarly:
            return "This message can't be edited yet."
        case let .editFailed(detail):
            return "Couldn't edit the message: \(detail)"
        case .reactionFailed:
            return "Couldn't update the reaction."
        case .deleteForbidden:
            return "You can't delete this message."
        case let .deleteFailed(detail):
            return "Couldn't delete the message: \(detail)"
        case let .notificationsFailed(detail):
            return "Couldn't change notifications: \(detail)"
        case let .favoritesFailed(detail):
            return "Couldn't update favorites: \(detail)"
        case let .leaveFailed(detail):
            return "Couldn't leave the channel: \(detail)"
        case .pinFailed:
            return "The message couldn't be pinned."
        case .unpinFailed:
            return "The message couldn't be unpinned."
        case .unpinAllFailed:
            return "The messages couldn't be unpinned."
        case .saveFailed:
            return "The message couldn't be saved."
        case .unsaveFailed:
            return "The message couldn't be removed from Saved."
        case let .followFailed(detail):
            return "Couldn't follow the thread: \(detail)"
        case let .unfollowFailed(detail):
            return "Couldn't unfollow the thread: \(detail)"
        }
    }
}

extension MattermostSync {
    /// The text of a notice in the app's language; set once at launch by MattermostUI. Without it, English.
    public static var noticeText: ((MattermostNotice) -> String)?
}

extension MattermostAccountSync {
    func notice(_ notice: MattermostNotice) {
        self.notice(MattermostSync.noticeText?(notice) ?? notice.englishText)
    }
}
