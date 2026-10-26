import Foundation
import TelegramCore
import PeerInfoPaneNode

// MATTERMOST: peer-info panes of Telegram-only features (docs/research/ui-inventory.md §1.18).
// Applied once where `PeerInfoScreenData` stores its panes.
extension MattermostFeatures {
    static func allowsPeerInfoPane(_ pane: PeerInfoPaneKey) -> Bool {
        switch pane {
        case .stories, .storyArchive:
            return MattermostFeatures.stories
        case .gifts:
            return MattermostFeatures.premium
        case .botPreview, .similarBots:
            return MattermostFeatures.botWebApps
        case .similarChannels:
            return MattermostFeatures.broadcastChannels
        case .gifs:
            return MattermostFeatures.stickersAndGifs
        case .members, .media, .savedMessagesChats, .savedMessages, .files, .music, .voice, .links, .polls, .groupsInCommon:
            return true
        }
    }
}
