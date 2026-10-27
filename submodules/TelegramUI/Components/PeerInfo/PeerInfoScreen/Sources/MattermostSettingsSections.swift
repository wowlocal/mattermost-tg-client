import Foundation
import UIKit
import Display
import TelegramCore
import TelegramPresentationData

// MATTERMOST: Settings root sections that only hold Telegram-only rows (docs/research/ui-inventory.md §2.1).
// Applied once in the section loop of `settingsItems`.
extension MattermostFeatures {
    static var hiddenSettingsSections: Set<SettingsSection> {
        var result = Set<SettingsSection>()
        if !MattermostFeatures.telegramPrivacy {
            // Phone number / 2FA password suggestions and the Premium grace-period notice.
            result.insert(.phone)
        }
        if !MattermostFeatures.premium {
            // TON wallet; Telegram Premium, Stars, GRAM, Business, Send a Gift.
            result.insert(.wallet)
            result.insert(.payment)
        }
        if !MattermostFeatures.mtprotoProxy {
            result.insert(.proxy)
        }
        if !MattermostFeatures.botWebApps {
            result.insert(.apps)
        }
        if !MattermostFeatures.passport {
            // Passport and Apple Watch.
            result.insert(.extra)
        }
        if !MattermostFeatures.telegramSupport {
            // Ask a Question, Telegram FAQ, Telegram Features: all wait on Telegram's server.
            result.insert(.support)
        }
        return result
    }
}

// MATTERMOST: the icon of the Settings row Saved Posts (Phase 3C). Mattermost saves posts with a
// flag ("flagged posts"), hence the flag.
enum MattermostSettingsIcons {
    static let savedPosts = renderSettingsIcon(name: "Item List/Icons/Flag", backgroundColors: [UIColor(rgb: 0xff9500)])
}
