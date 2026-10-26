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

// MATTERMOST: finding things (Phase 3C) in the chat screen and around it.
// - Opening a message from search, Saved Posts or Recent Mentions goes through `navigateToChatController`: a reply
//   that collapsed reply threads hide from its chat opens in its thread at the reply, and a public channel found by
//   search that the user hasn't joined asks to join first.
// - The message menu offers Save Post / Remove from Saved (Mattermost's flagged posts).
// - Pin and Unpin keep Telegram's menu items and run through TelegramCore's search provider seam (`POST
//   /posts/{id}/pin`); Mattermost has no "pin and notify", so the choice Telegram offers in groups is skipped.

/// `navigateToChatControllerImpl` for Mattermost; true when it handled the navigation.
func mattermostNavigateToChat(_ params: NavigateToChatControllerParams) -> Bool {
    guard MattermostBackend.isEnabled, case let .peer(peer) = params.chatLocation else {
        return false
    }
    let context = params.context
    if case let .message(subject, _, _, _)? = params.subject, case let .id(messageId) = subject, let root = MattermostSync.collapsedThreadRoot(accountId: context.account.id, messageId: messageId) {
        params.purposefulAction?()
        mattermostOpenThread(context: context, navigationController: params.navigationController, peerId: root.peerId, threadId: Int64(root.id), messageId: messageId)
        return true
    }
    if case .channel = peer, MattermostSync.isPreviewChannel(accountId: context.account.id, peerId: peer.id) {
        // 3D-2: the channel's preview (purpose, header, recent messages) with Join; the join prompt without one.
        if let channelId = MattermostDirectory.previewChannelId(accountId: context.account.id, peerId: peer.id) {
            params.purposefulAction?()
            params.navigationController.pushViewController(mattermostChannelPreviewController(context: context, channelId: channelId))
        } else {
            mattermostAskToJoin(params: params, peer: peer)
        }
        return true
    }
    return false
}

private func mattermostAskToJoin(params: NavigateToChatControllerParams, peer: EnginePeer) {
    let context = params.context
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    let present: (ViewController) -> Void = { controller in
        if let top = params.navigationController.topViewController as? ViewController {
            top.present(controller, in: .window(.root))
        } else {
            params.navigationController.presentOverlay(controller: controller)
        }
    }
    let join: () -> Void = {
        let _ = (MattermostSync.joinPublicChannel(accountId: context.account.id, peerId: peer.id)
        |> mapToSignal { peerId -> Signal<EnginePeer?, NoError> in
            guard let peerId = peerId else {
                return .single(nil)
            }
            return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        }
        |> deliverOnMainQueue).startStandalone(next: { joined in
            guard let joined = joined else {
                present(textAlertController(context: context, title: nil, text: strings.Relay_Search_JoinFailed, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]))
                return
            }
            params.purposefulAction?()
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: params.navigationController, context: context, chatLocation: .peer(joined), subject: params.subject, keepStack: params.keepStack, options: params.options))
        })
    }
    let alert = textAlertController(context: context, title: strings.Relay_Search_JoinTitle(peer.compactDisplayTitle).string, text: strings.Relay_Search_JoinText, actions: [
        TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
        TextAlertAction(type: .defaultAction, title: strings.Relay_Search_Join, action: join)
    ])
    #if DEBUG
    mattermostDebugJoinAlert = (alert, join)
    #endif
    present(alert)
}

#if DEBUG
/// Debug remote (`RelayDebugSearch`, `join-confirm`): the visible join alert and its Join action.
var mattermostDebugJoinAlert: (alert: ViewController, join: () -> Void)?
#endif

/// Save Post / Remove from Saved for a message's context menu (Mattermost posts only).
func mattermostSavedPostContextMenuItems(context: AccountContext, message: Message, controllerInteraction: ChatControllerInteraction, strings: PresentationStrings) -> [ContextMenuItem] {
    guard MattermostBackend.isEnabled, message.id.namespace == Namespaces.Message.Cloud, let saved = MattermostSync.isPostSaved(accountId: context.account.id, messageId: message.id) else {
        return []
    }
    return [.action(ContextMenuActionItem(text: saved ? strings.Relay_Saved_Unsave : strings.Relay_Saved_Save, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: saved ? "Chat/Context Menu/Unfave" : "Chat/Context Menu/Fave"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        f(.default)
        mattermostSetPostSaved(context: context, messageId: message.id, saved: !saved, present: { controller in
            controllerInteraction.presentControllerInCurrent(controller, nil)
        })
    }))]
}

func mattermostSetPostSaved(context: AccountContext, messageId: EngineMessage.Id, saved: Bool, present: @escaping (ViewController) -> Void) {
    let _ = (MattermostSync.setPostSaved(accountId: context.account.id, messageId: messageId, saved: saved)
    |> deliverOnMainQueue).startStandalone(next: { done in
        guard done else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let text = saved ? presentationData.strings.Relay_Saved_Saved : presentationData.strings.Relay_Saved_Removed
        present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    })
}
