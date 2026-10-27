import Foundation
import TelegramCore

// MATTERMOST: attach-menu buttons that stay reachable (docs/research/ui-inventory.md §1.10).
// Gallery, file, audio, location and contact map to Mattermost file uploads and messages; the rest
// are Telegram-only.
extension MattermostFeatures {
    public static func isAttachButtonEnabled(_ button: AttachmentButtonType) -> Bool {
        switch button {
        case .gallery, .file, .link, .audio:
            // Audio is a file picker for music files, uploaded like any other file.
            return true
        case .location, .contact:
            // Mattermost has no location or contact posts, and the sender uploads only images and files: these
            // messages were never posted. Hidden, which also leaves the location prompt and background mode unused.
            return false
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
        case .poll, .todo:
            return MattermostFeatures.polls
        case .richText:
            return MattermostFeatures.richTextPosts
        }
    }
}
