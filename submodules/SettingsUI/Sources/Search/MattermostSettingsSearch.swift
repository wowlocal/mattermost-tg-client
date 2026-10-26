import Foundation
import TelegramCore

// MATTERMOST: which settings-search results stay reachable (docs/research/ui-inventory.md §1.18, §2.5).
// Applied once to the assembled list in `settingsSearchableItems`.
extension MattermostFeatures {
    static func settingsSearchAllows(_ icon: SettingsSearchableItemIcon) -> Bool {
        switch icon {
        case .profile, .savedMessages, .notifications, .privacy, .data, .appearance, .language, .chatFolders, .devices, .myProfile, .powerSaving:
            return true
        case .proxy:
            return MattermostFeatures.mtprotoProxy
        case .calls:
            return MattermostFeatures.calls
        case .stickers:
            return MattermostFeatures.stickersAndGifs
        case .passport, .watch:
            return MattermostFeatures.passport
        case .support, .faq, .tips:
            return MattermostFeatures.telegramSupport
        case .deleteAccount:
            return MattermostFeatures.telegramPrivacy
        case .premium, .stars, .ton, .gift:
            return MattermostFeatures.premium
        case .business:
            return MattermostFeatures.business
        case .stories:
            return MattermostFeatures.stories
        }
    }

    /// Item ids (and their sub-items) that lead to hidden features inside kept categories.
    private static var hiddenSettingsSearchIdPrefixes: [String] {
        var result: [String] = []
        if !MattermostFeatures.tmeLinks {
            result += ["edit/username", "qr-code", "devices/link-desktop"]
        }
        if !MattermostFeatures.contacts {
            result += ["edit/change-number", "notifications/new-contacts"]
        }
        if !MattermostFeatures.premium {
            result += ["edit/your-color", "emoji-status", "profile-color", "my-profile/gifts"]
        }
        if !MattermostFeatures.customEmoji {
            result += ["profile-photo/use-emoji"]
        }
        if !MattermostFeatures.broadcastChannels {
            result += ["edit/channel", "notifications/channels", "notifications/include-channels", "data/save-to-photos/channels"]
        }
        if !MattermostFeatures.stories {
            result += ["my-profile/posts", "my-profile/archived-posts", "notifications/stories", "notifications/reactions/stories", "data/auto-download/mobile/stories", "data/auto-download/wifi/stories"]
        }
        if !MattermostFeatures.calls {
            result += ["data/less-data-calls"]
        }
        if !MattermostFeatures.mtprotoProxy {
            result += ["data/proxy"]
        }
        if !MattermostFeatures.telegramPrivacy {
            result += ["edit/birthday", "data/show-18-content"]
        }
        if !MattermostFeatures.stickersAndGifs {
            result += ["appearance/stickers-and-emoji"]
        }
        if !MattermostFeatures.alternateAppIcons {
            result += ["appearance/app-icon"]
        }
        if !MattermostFeatures.translation {
            result += ["language/show-button", "language/translate-chats", "language/do-not-translate"]
        }
        if !MattermostFeatures.chatListSuggestions {
            result += ["folders/add-recommended"]
        }
        return result
    }

    static func settingsSearchAllows(_ item: SettingsSearchableItem) -> Bool {
        if !MattermostFeatures.settingsSearchAllows(item.icon) {
            return false
        }
        guard let id = item.id.base as? String else {
            return true
        }
        // Privacy and Security keeps only the passcode and the link-opening browser (§2.3).
        if !MattermostFeatures.telegramPrivacy && id.hasPrefix("privacy") {
            return id.hasPrefix("privacy/passcode") || id == "privacy/open-links"
        }
        for prefix in MattermostFeatures.hiddenSettingsSearchIdPrefixes {
            if id == prefix || id.hasPrefix(prefix + "/") {
                return false
            }
        }
        return true
    }
}
