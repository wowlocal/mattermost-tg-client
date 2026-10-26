import Foundation
import Postbox

// MATTERMOST: the composer's `/` suggestions show Mattermost slash commands in Telegram's command panel, which
// lists `PeerCommand`s (TelegramUI `MattermostComposerQueries.swift`). Its memberwise init is internal.
public extension PeerCommand {
    init(mattermostPeer peer: EnginePeer, command: BotCommand) {
        self.init(peer: peer, command: command)
    }
}
