import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import TelegramPresentationData
import PresentationDataUtils
import UndoUI
import AppBundle
import ChatControllerInteraction
import MattermostSync
import MattermostUI

// MATTERMOST: links and permalinks (Phase 3E).
// - A link into a signed-in Mattermost server (`https://<server>/<team>/pl/<post>`, `/channels/<name>`,
//   `/messages/@user`, `/threads/<root>`, `/_redirect/…`) and `relay://<host>[:port]/…` / `mattermost://…` links open
//   in the app: the post in its chat (in its thread when collapsed reply threads hide it), the channel (a join prompt
//   for a public channel the user isn't in), the DM. The account that owns the server is used (switching accounts
//   when it isn't the current one). Hooked into the external-URL opener (`openCheckedExternalUrl`, which every link
//   tap and every URL from the system reaches) and `openUserGeneratedUrl` (no "Open this link?" prompt for them).
// - The message menu's Copy Link and Share Link give the post's permalink.

/// Whether `url` is a link into a signed-in Mattermost server (opened in the app, without the link prompt).
func mattermostIsInAppLink(context: AccountContext, url: String) -> Bool {
    guard MattermostBackend.isEnabled else {
        return false
    }
    return MattermostSync.linkTarget(url: url, preferredAccountId: context.account.id) != nil
}

/// Opens a Mattermost link in the app; false when `url` isn't one (it then opens as usual).
func mattermostOpenLink(context: AccountContext, url: String, navigationController: NavigationController?) -> Bool {
    guard MattermostBackend.isEnabled, let target = MattermostSync.linkTarget(url: url, preferredAccountId: context.account.id) else {
        return false
    }
    let _ = (MattermostSync.linkDestination(target: target)
    |> deliverOnMainQueue).startStandalone(next: { destination in
        mattermostOpen(destination, target: target, context: context, navigationController: navigationController ?? context.sharedContext.mainWindow?.viewController as? NavigationController)
    })
    return true
}

private func mattermostOpen(_ destination: MattermostLinkDestination, target: MattermostLinkTarget, context: AccountContext, navigationController: NavigationController?) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    #if DEBUG
    mattermostDebugLastLink = (target, destination)
    #endif
    if target.accountId != context.account.id {
        // Another account's server: switch to it, then open (a hidden reply opens its thread there, see
        // `mattermostNavigateToChat`).
        switch destination {
        case let .message(peerId, _, messageId):
            context.sharedContext.navigateToChat(accountId: target.accountId, peerId: peerId, messageId: messageId)
            return
        case let .chat(peerId):
            context.sharedContext.navigateToChat(accountId: target.accountId, peerId: peerId, messageId: nil)
            return
        case .failed:
            break
        }
    }
    guard let navigationController = navigationController else {
        return
    }
    switch destination {
    case let .message(peerId, threadId, messageId):
        if let threadId = threadId {
            mattermostOpenThread(context: context, navigationController: navigationController, peerId: peerId, threadId: threadId, messageId: messageId)
            return
        }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).startStandalone(next: { peer in
            guard let peer = peer else {
                return
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), subject: .message(id: .id(messageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false), keepStack: .always))
        })
    case let .chat(peerId):
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).startStandalone(next: { peer in
            guard let peer = peer else {
                return
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), keepStack: .always))
        })
    case let .failed(failure):
        let text: String
        switch failure {
        case .postNotFound:
            text = strings.Relay_Link_PostNotFound
        case .channelNotFound:
            text = strings.Relay_Link_ChannelNotFound
        case .userNotFound:
            text = strings.Relay_Link_UserNotFound
        case .unreachable:
            text = strings.Relay_Link_Unreachable
        }
        let alert = textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})])
        if let top = navigationController.topViewController as? ViewController {
            top.present(alert, in: .window(.root))
        } else {
            navigationController.presentOverlay(controller: alert)
        }
    }
}

#if DEBUG
/// Debug remote (`RelayDebugLinks`): the last link opened in the app and where it led.
var mattermostDebugLastLink: (target: MattermostLinkTarget, destination: MattermostLinkDestination)?
#endif

/// Copy Link and Share Link for a message's context menu (posts on the server only).
func mattermostPermalinkContextMenuItems(context: AccountContext, message: Message, controllerInteraction: ChatControllerInteraction, strings: PresentationStrings) -> [ContextMenuItem] {
    guard MattermostBackend.isEnabled, !(message.media.first is TelegramMediaAction), let link = MattermostSync.permalink(accountId: context.account.id, messageId: message.id) else {
        return []
    }
    return [
        .action(ContextMenuActionItem(text: strings.Conversation_ContextMenuCopyLink, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Link"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            mattermostCopyPermalink(link, context: context, displayUndo: { content in
                controllerInteraction.displayUndo(content)
            })
        })),
        .action(ContextMenuActionItem(text: strings.Relay_Link_Share, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Share"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            mattermostSharePermalink(link, context: context)
        }))
    ]
}

func mattermostCopyPermalink(_ link: String, context: AccountContext, displayUndo: @escaping (UndoOverlayContent) -> Void) {
    UIPasteboard.general.string = link
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    Queue.mainQueue().after(0.2, {
        displayUndo(.linkCopied(title: nil, text: presentationData.strings.Conversation_LinkCopied))
    })
}

/// The system share sheet with the permalink (Telegram's own share sheet sends to Telegram chats).
func mattermostSharePermalink(_ link: String, context: AccountContext) {
    guard let url = URL(string: link) else {
        return
    }
    let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let window = context.sharedContext.mainWindow?.viewController?.view.window {
        activityController.popoverPresentationController?.sourceView = window
        activityController.popoverPresentationController?.sourceRect = CGRect(origin: CGPoint(x: window.bounds.midX, y: window.bounds.maxY), size: CGSize(width: 1, height: 1))
    }
    context.sharedContext.applicationBindings.presentNativeController(activityController)
}
