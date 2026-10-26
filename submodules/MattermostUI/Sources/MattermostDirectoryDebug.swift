import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import MattermostSync

/// **Debug builds only.** The debug remote's Phase 3D-2 commands (directory and membership), each through the code
/// path of the tap it stands for (`tools/relay-remote.py`, docs/BUILD.md "Phase 3D-2"):
/// - `new-message`: the chat list's compose button (`ChatListController.activateCompose`);
/// - `directory`: the visible directory screen (compose, group message, add members, browse, preview, new channel,
///   channel settings) and its state;
/// - `directory-do` (`do`, plus its arguments): a tap on that screen — `search` (`text`), `tap` (`username` or
///   channel `name`), `submit` (Create / Add / Save), `more` (next page), `new-group`, `new-channel`, `browse`,
///   `archived` (`value`), `team` (`team`), `join`, `set` (`field`: name/url/purpose/header/private, `value`),
///   `convert`, `archive`, `unarchive`, `confirm-archive`;
/// - `alert` (`do`: `confirm` or `cancel`): a button of the confirmation alert these screens showed;
/// - `info-*` (`peerinfo`, `info-edit`, `info-add-member`, `info-member` (`username`, `do`: menu/promote/remove/remove-confirmed),
///   `info-leave`, `info-state`): the profile of the visible chat, registered by PeerInfoScreen
///   (`MattermostDirectoryDebug.peerInfo`).
public enum MattermostDirectoryDebug {
    private static weak var screen: MattermostDirectoryListController?

    /// Installed by the visible channel profile (PeerInfoScreen, debug builds): runs `info-*` commands.
    public static var peerInfo: ((_ action: String, _ command: [String: Any], _ completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool)?

    private static weak var alert: ViewController?
    private static var alertConfirm: (() -> Void)?

    /// A confirmation alert of these screens (archive, convert, remove a member): the remote's `alert` command
    /// presses its buttons (`do=confirm` runs the button's own action).
    static func alertPresented(_ alert: ViewController, confirm: @escaping () -> Void) {
        #if DEBUG
        self.alert = alert
        self.alertConfirm = confirm
        #endif
    }

    static func screenAppeared(_ controller: MattermostDirectoryListController) {
        #if DEBUG
        self.screen = controller
        #endif
    }

    static func handle(sharedContext: SharedAccountContext?, action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        #if DEBUG
        let after: (Double, @escaping () -> Void) -> Void = { delay, f in
            Queue.mainQueue().after(delay, f)
        }
        switch action {
        case "new-message":
            guard let root = sharedContext?.mainWindow?.viewController as? TelegramRootControllerInterface, let chatList = root.getChatsController() as? ChatListController else {
                completion(false, "no chat list", [:])
                return true
            }
            root.popToRoot(animated: false)
            chatList.activateCompose()
            after(1.5) {
                completion(true, nil, self.describe())
            }
            return true
        case "directory":
            completion(self.screen != nil, self.screen == nil ? "no directory screen" : nil, self.describe())
            return true
        case "directory-do":
            guard let screen = self.screen, let name = command["do"] as? String, let run = screen.debugActions[name] else {
                completion(false, "no screen or unknown action", self.describe())
                return true
            }
            run(command)
            after((command["wait"] as? Double) ?? 1.5) {
                completion(true, nil, self.describe())
            }
            return true
        case "alert":
            guard let alert = self.alert else {
                completion(false, "no alert", [:])
                return true
            }
            let confirm = (command["do"] as? String) == "confirm" ? self.alertConfirm : nil
            self.alert = nil
            self.alertConfirm = nil
            alert.dismiss()
            confirm?()
            after(2.0) {
                completion(true, nil, self.describe())
            }
            return true
        case "peerinfo":
            // The chat title's tap: the profile of the chat on top.
            guard let sharedContext, let navigationController = sharedContext.mainWindow?.viewController as? NavigationController, let chat = navigationController.viewControllers.last as? ChatController, let peerId = chat.chatLocation.peerId else {
                completion(false, "no chat on top", [:])
                return true
            }
            let _ = (sharedContext.activeAccountContexts
            |> take(1)
            |> mapToSignal { primary, _, _ -> Signal<(AccountContext, EnginePeer)?, NoError> in
                guard let context = primary else {
                    return .single(nil)
                }
                return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                |> map { peer in peer.flatMap { (context, $0) } }
            }
            |> deliverOnMainQueue).startStandalone(next: { value in
                guard let (context, peer) = value, let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: true, requestsContext: nil) else {
                    completion(false, "no profile", [:])
                    return
                }
                navigationController.pushViewController(controller)
                after(1.5) {
                    completion(true, nil, [:])
                }
            })
            return true
        default:
            if action.hasPrefix("info-"), let handler = self.peerInfo {
                return handler(action, command, completion)
            }
            return false
        }
        #else
        return false
        #endif
    }

    private static func describe() -> [String: Any] {
        guard let screen = self.screen else {
            return [:]
        }
        var result = screen.debugState?() ?? [:]
        result["visible"] = screen.isNodeLoaded && screen.view.window != nil
        result["top"] = (screen.navigationController as? NavigationController)?.viewControllers.last.map { "\(type(of: $0))" } ?? ""
        return result
    }
}
