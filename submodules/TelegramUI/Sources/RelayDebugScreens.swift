import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import PeerInfoScreen
import SettingsUI
import ChatMessageItemView

// MATTERMOST: debug only. Opens a screen at launch so screenshots can be taken without UI automation:
//
//   SIMCTL_CHILD_RELAY_DEBUG_OPEN_SCREEN=<screen> xcrun simctl launch <udid> org.relaychat.Relay
//
// - `settings`: the Settings tab;
// - `privacy`, `data`, `notifications`, `appearance`, `about`: Settings sub-screens;
// - `compose`: the New Message screen;
// - `peerinfo`, `attach`: the profile of / the attach menu in the chat that the Spike A hook opened
//   (combine with `SIMCTL_CHILD_RELAY_DEBUG_OPEN_CHAT=dm|ios-team|…`);
// - `reactions`: the context menu with the reaction picker of the newest message in that chat.
// Further screens can be added below; Release builds compile none of this.
extension TelegramRootController {
    func relayDebugOpenScreenIfRequested() {
        #if DEBUG
        guard let screen = ProcessInfo.processInfo.environment["RELAY_DEBUG_OPEN_SCREEN"], !screen.isEmpty else {
            return
        }
        Queue.mainQueue().after(1.5, { [weak self] in
            self?.relayDebugOpenScreen(screen)
        })
        #endif
    }

    #if DEBUG
    private func relayDebugOpenScreen(_ screen: String) {
        switch screen {
        case "settings":
            if let rootTabController = self.rootTabController, let index = rootTabController.controllers.firstIndex(where: { $0 is PeerInfoScreenImpl }) {
                rootTabController.selectedIndex = index
            }
        case "compose":
            self.openRootCompose()
        case "privacy", "data", "notifications", "appearance", "about":
            guard let context = self.chatListController?.context else {
                return
            }
            if let rootTabController = self.rootTabController, let index = rootTabController.controllers.firstIndex(where: { $0 is PeerInfoScreenImpl }) {
                rootTabController.selectedIndex = index
            }
            let controller: ViewController
            switch screen {
            case "privacy":
                controller = relayPrivacyAndSecurityController(context: context)
            case "data":
                controller = dataAndStorageController(context: context)
            case "notifications":
                controller = notificationsAndSoundsController(context: context, exceptionsList: nil, focusOnItemTag: nil)
            case "about":
                controller = relayAboutController(context: context)
            default:
                controller = themeSettingsController(context: context)
            }
            self.pushViewController(controller)
        case "peerinfo", "attach":
            // The chat is opened by the Spike A hook (`RELAY_DEBUG_OPEN_CHAT`) one second after launch.
            Queue.mainQueue().after(1.5, { [weak self] in
                guard let self, let chatController = self.viewControllers.last as? ChatControllerImpl else {
                    return
                }
                if screen == "attach" {
                    chatController.presentAttachmentMenu(subject: .default)
                    return
                }
                guard let peerId = chatController.chatLocation.peerId else {
                    return
                }
                let context = chatController.context
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                    guard let self, let peer, let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: true, requestsContext: nil) else {
                        return
                    }
                    self.pushViewController(controller)
                })
            })
        case "reactions":
            // MATTERMOST: the message context menu (reaction picker) of the newest message in the chat that
            // `RELAY_DEBUG_OPEN_CHAT` opened, as a long press would open it.
            self.relayDebugOpenNewestMessageMenu(attempt: 0)
        default:
            break
        }
    }

    private func relayDebugOpenNewestMessageMenu(attempt: Int) {
        Queue.mainQueue().after(1.0, { [weak self] in
            guard let self else {
                return
            }
            var newest: ChatMessageItemView?
            if let chatController = self.viewControllers.last as? ChatControllerImpl {
                chatController.chatDisplayNode.historyNode.forEachItemNode { node in
                    guard let itemNode = node as? ChatMessageItemView, let item = itemNode.item else {
                        return
                    }
                    if let current = newest?.item, current.message.index > item.message.index {
                        return
                    }
                    newest = itemNode
                }
            }
            if let newest {
                newest.openMessageContextMenu()
            } else if attempt < 20 {
                self.relayDebugOpenNewestMessageMenu(attempt: attempt + 1)
            }
        })
    }
    #endif
}
