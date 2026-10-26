import Foundation
import TelegramCore
import AccountContext

// MATTERMOST: deep links and resolved URLs into hidden Telegram-only features
// (docs/research/ui-inventory.md §1.18). Checked once at the top of `openResolvedUrlImpl`. Lives in
// TelegramUI, its only caller, so that changing it does not rebuild every AccountContext dependant.
// The switch is exhaustive on purpose: a new upstream case fails the build here.
extension MattermostFeatures {
    static func allows(_ resolvedUrl: ResolvedUrl) -> Bool {
        switch resolvedUrl {
        case .externalUrl, .peer, .inaccessiblePeer, .channelMessage, .replyThreadMessage, .replyThread, .instantView, .localization, .share, .wallpaper, .theme, .messageLink, .unknownDeepLink, .chats(.search), .chats(.edit), .chats(nil), .compose(.group), .compose(nil):
            return true
        case .chats(.emojiStatus):
            return MattermostFeatures.premium
        case .compose(.channel):
            return MattermostFeatures.broadcastChannels
        case .compose(.contact), .contacts:
            return MattermostFeatures.contacts
        case .stickerPack, .importStickers:
            return MattermostFeatures.stickersAndGifs
        case .proxy, .webProxy:
            return MattermostFeatures.mtprotoProxy
        case .joinCall, .joinVoiceChat:
            return MattermostFeatures.calls
        case .urlAuth, .botStart, .groupBotStart, .gameStart, .startAttach, .oauth, .createBot:
            return MattermostFeatures.botWebApps
        case .invoice:
            return MattermostFeatures.payments
        case .premiumOffer, .starsTopup, .boost, .premiumGiftCode, .premiumMultiGift, .auction, .stars, .ton, .sendGift, .giftCollection, .sendGrams, .collectible:
            return MattermostFeatures.premium
        case .story, .shareStory, .storyFolder, .postStory:
            return MattermostFeatures.stories
        case .textStyle:
            return MattermostFeatures.aiCompose
        case .join, .chatFolder:
            // t.me invite links and shared folders.
            return MattermostFeatures.tmeLinks
        case .confirmationCode, .cancelAccountReset:
            // Telegram account login and reset.
            return MattermostFeatures.telegramPrivacy
        case let .settings(section):
            switch section {
            case .legacy(.theme), .legacy(.enableLog):
                return true
            case .legacy(.devices):
                return true
            case .legacy(.autoremoveMessages):
                return MattermostFeatures.telegramChatSettings
            case .legacy(.phonePrivacy), .legacy(.loginEmail):
                return MattermostFeatures.telegramPrivacy
            case .path:
                return true
            }
        }
    }
}
