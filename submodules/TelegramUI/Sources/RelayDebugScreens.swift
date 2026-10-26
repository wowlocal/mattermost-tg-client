import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import PeerInfoScreen
import SettingsUI
import MattermostUI
import ChatMessageItemView

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

// MATTERMOST: debug only. Opens a screen at launch so screenshots can be taken without UI automation:
//
//   SIMCTL_CHILD_RELAY_DEBUG_OPEN_SCREEN=<screen> xcrun simctl launch <udid> org.relaychat.Relay
//
// - `settings`: the Settings tab;
// - `privacy`, `data`, `notifications`, `appearance`, `about`, `devices`, `openlinks` (Open Links In),
//   `reaction-notifications`: Settings sub-screens;
// - `compose`: the New Message screen;
// - `peerinfo`, `attach`: the profile of / the attach menu in the chat that the Spike A hook opened
//   (combine with `SIMCTL_CHILD_RELAY_DEBUG_OPEN_CHAT=dm|ios-team|…`);
// - `authorinfo`: the profile of the newest message's author in that chat;
// - `settings:add-account`: Settings → Add Account through the Settings handler;
// - `reactions`: the context menu with the reaction picker of the newest message in that chat;
// - `button:<title>`: taps the inline button with that title on the newest message that has it, through the
//   chat's `requestMessageActionCallback` as a tap does (a menu's option: `RELAY_DEBUG_SELECT_OPTION`).
// Further screens can be added below; Release builds compile none of this.
extension TelegramRootController {
    func relayDebugOpenScreenIfRequested() {
        #if DEBUG
        // Phase 3D: the composer driver of the debug remote (RelayDebugComposer.swift).
        RelayDebugComposer.install(rootController: self)
        self.relayDebugInstallChatCommands()
        // Phase 3C: search, saved posts, mentions, pinning (RelayDebugSearch.swift).
        self.relayDebugInstallSearchCommands()
        // Phase 3F: own status, profile, notification preferences, sharing (RelayDebugProfile.swift).
        self.relayDebugInstallProfileCommands()
        // Phase 3E: link previews, links, Copy Link (RelayDebugLinks.swift).
        self.relayDebugInstallLinkCommands()
        // Phase 4B: scroll smoothness probes (RelayDebugPerf.swift).
        self.relayDebugInstallPerfCommands()
        guard let screen = ProcessInfo.processInfo.environment["RELAY_DEBUG_OPEN_SCREEN"], !screen.isEmpty else {
            return
        }
        Queue.mainQueue().after(1.5, { [weak self] in
            self?.relayDebugOpenScreen(screen)
        })
        #endif
    }

    #if DEBUG
    func relayDebugOpenScreen(_ screen: String) {
        switch screen {
        case "settings":
            if let rootTabController = self.rootTabController, let index = rootTabController.controllers.firstIndex(where: { $0 is PeerInfoScreenImpl }) {
                rootTabController.selectedIndex = index
            }
        case "compose":
            self.openRootCompose()
        case "privacy", "data", "notifications", "appearance", "about", "devices", "openlinks", "reaction-notifications", "passcode", "diagnostics":
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
            case "devices":
                controller = mattermostDevicesController(context: context)
            case "openlinks":
                controller = webBrowserSettingsController(context: context)
            case "reaction-notifications":
                controller = reactionNotificationSettingsController(context: context)
            case "passcode":
                // Phase 4G: Privacy and Security → Passcode (without asking for the passcode first).
                controller = passcodeOptionsController(context: context)
            case "diagnostics":
                // Phase 4G: About Relay → Diagnostics.
                guard let diagnostics = MattermostUIHooks.makeDiagnosticsController?(context) else {
                    return
                }
                controller = diagnostics
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
        case "authorinfo":
            // The profile of the newest message's author in the chat that `RELAY_DEBUG_OPEN_CHAT` opened, as a
            // tap on the author's avatar opens it (e.g. a webhook's name override).
            Queue.mainQueue().after(2.5, { [weak self] in
                guard let self, let chatController = self.viewControllers.last as? ChatControllerImpl else {
                    return
                }
                var newest: Message?
                chatController.chatDisplayNode.historyNode.forEachItemNode { node in
                    guard let itemNode = node as? ChatMessageItemView, let item = itemNode.item, item.message.author != nil else {
                        return
                    }
                    if let current = newest, current.index > item.message.index {
                        return
                    }
                    newest = item.message
                }
                guard let author = newest?.author, let controller = chatController.context.sharedContext.makePeerInfoController(context: chatController.context, updatedPresentationData: nil, peer: EnginePeer(author), mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else {
                    return
                }
                self.pushViewController(controller)
            })
        case "settings:add-account":
            // Settings → Add Account, through the Settings screen's own handler (account limit included).
            if let rootTabController = self.rootTabController, let index = rootTabController.controllers.firstIndex(where: { $0 is PeerInfoScreenImpl }) {
                rootTabController.selectedIndex = index
                (rootTabController.controllers[index] as? PeerInfoScreenImpl)?.relayDebugOpenAddAccount()
            }
        case "reactions":
            // MATTERMOST: the message context menu (reaction picker) of the newest message in the chat that
            // `RELAY_DEBUG_OPEN_CHAT` opened, as a long press would open it.
            self.relayDebugOpenNewestMessageMenu(attempt: 0)
        default:
            if screen.hasPrefix("button:") {
                self.relayDebugTapButton(title: String(screen.dropFirst("button:".count)), attempt: 0)
            }
        }
    }

    private func relayDebugTapButton(title: String, attempt: Int) {
        Queue.mainQueue().after(1.0, { [weak self] in
            guard let self else {
                return
            }
            var target: (ChatMessageItemView, MemoryBuffer)?
            if let chatController = self.viewControllers.last as? ChatControllerImpl {
                chatController.chatDisplayNode.historyNode.forEachItemNode { node in
                    guard let itemNode = node as? ChatMessageItemView, let item = itemNode.item else {
                        return
                    }
                    if let current = target?.0.item, current.message.index > item.message.index {
                        return
                    }
                    for attribute in item.message.attributes {
                        guard let markup = attribute as? ReplyMarkupMessageAttribute else {
                            continue
                        }
                        for row in markup.rows {
                            for button in row.buttons where button.title == title {
                                if case let .callback(_, data) = button.action {
                                    target = (itemNode, data)
                                }
                            }
                        }
                    }
                }
            }
            if let (itemNode, data) = target, let item = itemNode.item {
                item.controllerInteraction.requestMessageActionCallback(item.message, data, false, false, nil)
            } else if attempt < 20 {
                self.relayDebugTapButton(title: title, attempt: attempt + 1)
            }
        })
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

/// Phase 4B: seconds since this process was started (cold-start timing; `[Relay] perf:` log lines).
func relayDebugProcessAge() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
        return 0.0
    }
    let start = info.kp_proc.p_starttime
    return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000.0)
}
#endif
