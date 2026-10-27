import Foundation
import Display
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import AlertUI
import PresentationDataUtils
import MattermostSync

// MATTERMOST: Telegram's Forward as Mattermost's forward (4H, MattermostSync `Forwards.swift`). A forward that shows
// its sender's name goes as the forwarded post's permalink, which Mattermost previews; Mattermost allows that for
// posts of private channels, DMs and GMs only within their own channel (nobody else could open the preview), so the
// forward picker refuses other chats with the web app's words before anything is forwarded.

extension ChatControllerImpl {
    /// True (and an alert on `controller`) when Mattermost doesn't allow forwarding `messages` to `targetPeerIds`.
    /// Only messages of other people count: the user's own messages are forwarded as copies by default (Telegram's
    /// "hide sender name"), which may go anywhere.
    func mattermostRefuseForward(messages: [EngineRawMessage], targetPeerIds: [EnginePeer.Id], controller: ViewController?) -> Bool {
        guard MattermostBackend.isEnabled else {
            return false
        }
        let accountPeerId = self.context.account.peerId
        let forwarded = messages.filter { $0.author?.id != accountPeerId && $0.id.namespace == Namespaces.Message.Cloud }
        let sourcePeerIds = Set(forwarded.map { $0.id.peerId })
        for sourcePeerId in sourcePeerIds {
            guard let restriction = MattermostForwards.restriction(accountId: self.context.account.id, sourcePeerId: sourcePeerId, targetPeerIds: targetPeerIds) else {
                continue
            }
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let strings = presentationData.strings
            let title = forwarded.first(where: { $0.id.peerId == sourcePeerId }).flatMap { $0.peers[sourcePeerId] }.map { EnginePeer($0).displayTitle(strings: strings, displayOrder: presentationData.nameDisplayOrder) } ?? ""
            let text: String
            switch restriction {
            case .privateChannel:
                text = strings.Relay_Forward_PrivateChannel(title).string
            case .privateConversation:
                text = strings.Relay_Forward_PrivateConversation(title).string
            }
            let alert = textAlertController(context: self.context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})])
            if let controller {
                controller.present(alert, in: .window(.root))
            } else {
                self.present(alert, in: .window(.root))
            }
            return true
        }
        return false
    }
}
