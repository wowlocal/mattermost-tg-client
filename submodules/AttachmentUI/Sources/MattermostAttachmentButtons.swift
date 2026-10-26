import Foundation
import TelegramCore

// MATTERMOST: attach-menu buttons that stay reachable (docs/research/ui-inventory.md §1.10).
// Gallery, file, location and contact map to Mattermost file uploads and messages; the rest are
// Telegram-only.
extension MattermostFeatures {
    public static func isAttachButtonEnabled(_ button: AttachmentButtonType) -> Bool {
        switch button {
        case .gallery, .file, .location, .contact, .link:
            return true
        case .app, .standalone:
            return MattermostFeatures.botWebApps
        case .gift, .money:
            return MattermostFeatures.premium
        case .quickReply:
            return MattermostFeatures.business
        case .sticker:
            return MattermostFeatures.stickersAndGifs
        case .emoji:
            return MattermostFeatures.customEmoji
        case .poll, .todo, .audio, .richText:
            // Telegram polls, checklists, music messages and rich-text posts have no Mattermost
            // representation yet (polls are a Mattermost plugin; audio goes through "File").
            return !MattermostBackend.isEnabled
        }
    }
}
