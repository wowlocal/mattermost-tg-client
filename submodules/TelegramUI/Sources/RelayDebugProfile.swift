import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import PeerInfoScreen
import MattermostSync
import MattermostUI

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

// MATTERMOST: debug only (Phase 3F). Own status, custom status, profile, notification preferences and sharing commands
// of the debug remote (`tools/relay-remote.py`), each through the code path a tap runs:
// - `profile-state`: the account's own status, custom status, profile fields and notification preferences as the
//   app has them (compare with REST);
// - `settings-row` (`row`: status, custom-status, edit, avatar, notifications, username, email): the Settings row;
//   the screen it opens is then `directory` / `directory-do` (its `debugActions`);
// - `status-menu`: the Settings tab's long-press status items; `status-menu-show` presents that menu;
//   `status-menu-pick` (`title`, `sub` for a Do Not Disturb duration): runs the item's action;
// - `edit-profile` (`do`: begin, set, done, cancel; `field`: first, last, nickname, position; `value`);
// - `avatar` (`do`: set (a generated picture), remove): through the Settings photo handler;
// - `chat-notifications`: the visible chat's profile → Notifications → Customize;
// - `share-test` (`chat` as `chat` names it; `text`, `url`, `images`, `files`, `thread` root post id): the share extension's posting (`MattermostShareExtension`) with generated items, as the extension
//   runs it for the other app's items (the current account).
extension TelegramRootController {
    func relayDebugInstallProfileCommands() {
        #if DEBUG
        let previous = MattermostDebugChatCommands.handler
        MattermostDebugChatCommands.handler = { [weak self] action, command, completion in
            if let self, let context = self.chatListController?.context, self.relayDebugRunProfileCommand(context: context, action: action, command: command, completion: completion) {
                return true
            }
            return previous?(action, command, completion) ?? false
        }
        #endif
    }

    #if DEBUG
    private var relaySettingsScreen: PeerInfoScreenImpl? {
        guard let rootTabController = self.rootTabController, let index = rootTabController.controllers.firstIndex(where: { $0 is PeerInfoScreenImpl }) else {
            return nil
        }
        rootTabController.selectedIndex = index
        return rootTabController.controllers[index] as? PeerInfoScreenImpl
    }

    private func relayProfileState(context: AccountContext) -> [String: Any] {
        let accountId = context.account.id
        var result: [String: Any] = ["account": "\(accountId.int64)"]
        if let own = MattermostProfile.currentOwnStatus(accountId: accountId) {
            result["status"] = own.status.rawValue
            result["manual"] = own.isManual
            result["dndEnd"] = own.dndEnd.map { Int($0.timeIntervalSince1970) } ?? 0
            if let custom = own.customStatus {
                result["customStatus"] = ["emoji": custom.emojiName, "display": custom.emoji, "text": custom.text, "duration": custom.duration, "expiresAt": custom.expiresAt.map { Int($0.timeIntervalSince1970) } ?? 0]
            }
        }
        if let fields = MattermostProfile.currentOwnProfileFields(accountId: accountId) {
            result["fields"] = ["username": fields.username, "first": fields.firstName, "last": fields.lastName, "nickname": fields.nickname, "position": fields.position, "email": fields.email, "hasPicture": fields.hasPicture, "customStatusesEnabled": fields.customStatusesEnabled]
        }
        result["top"] = self.viewControllers.last.map { "\(type(of: $0))" } ?? ""
        return result
    }

    private func relayGeneratedImage(text: String) -> UIImage {
        let size = CGSize(width: 600.0, height: 600.0)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(rgb: 0x2f80ed).cgColor, UIColor(rgb: 0x9b51e0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 160.0), .foregroundColor: UIColor.white]
            let string = NSAttributedString(string: text, attributes: attributes)
            let bounds = string.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil)
            string.draw(at: CGPoint(x: (size.width - bounds.width) / 2.0, y: (size.height - bounds.height) / 2.0))
        }
    }

    private func relayDebugRunProfileCommand(context: AccountContext, action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let after: (Double, @escaping () -> Void) -> Void = { delay, f in
            Queue.mainQueue().after(delay, f)
        }
        switch action {
        case "profile-state":
            completion(true, nil, self.relayProfileState(context: context))
            return true
        case "settings-row":
            guard let settings = self.relaySettingsScreen, let row = command["row"] as? String else {
                completion(false, "no Settings screen", [:])
                return true
            }
            if (command["keep"] as? String) != "1" {
                self.popToRoot(animated: false)
            }
            let ok = settings.relayDebugOpenSettingsRow(row)
            after(1.5) {
                completion(ok, ok ? nil : "unknown row", self.relayProfileState(context: context))
            }
            return true
        case "status-menu":
            guard let settings = self.relaySettingsScreen else {
                completion(false, "no Settings screen", [:])
                return true
            }
            completion(true, nil, ["items": settings.relayDebugStatusMenu()])
            return true
        case "status-menu-show":
            guard let settings = self.relaySettingsScreen else {
                completion(false, "no Settings screen", [:])
                return true
            }
            settings.relayDebugPresentStatusMenu()
            after(1.0) {
                completion(true, nil, ["items": settings.relayDebugStatusMenu()])
            }
            return true
        case "status-menu-pick":
            guard let settings = self.relaySettingsScreen, let title = command["title"] as? String else {
                completion(false, "no Settings screen or title", [:])
                return true
            }
            let ok = settings.relayDebugPickStatusMenu(title: title, subtitle: command["sub"] as? String)
            after(2.0) {
                completion(ok, ok ? nil : "no such item", self.relayProfileState(context: context))
            }
            return true
        case "edit-profile":
            guard let settings = self.relaySettingsScreen else {
                completion(false, "no Settings screen", [:])
                return true
            }
            let result = settings.relayDebugEditProfile(action: (command["do"] as? String) ?? "", field: command["field"] as? String, value: command["value"] as? String)
            after((command["do"] as? String) == "done" ? 2.5 : 1.0) {
                var state = self.relayProfileState(context: context)
                state["edit"] = settings.relayDebugEditProfile(action: "", field: nil, value: nil)
                let _ = result
                completion(true, nil, state)
            }
            return true
        case "avatar":
            guard let settings = self.relaySettingsScreen else {
                completion(false, "no Settings screen", [:])
                return true
            }
            if (command["do"] as? String) == "remove" {
                settings.relayDebugSetProfilePhoto(nil)
            } else {
                settings.relayDebugSetProfilePhoto(self.relayGeneratedImage(text: (command["text"] as? String) ?? "3F"))
            }
            after(3.0) {
                completion(true, nil, self.relayProfileState(context: context))
            }
            return true
        case "chat-notifications":
            guard let profile = self.viewControllers.last as? PeerInfoScreenImpl else {
                completion(false, "no profile on top (use peerinfo first)", [:])
                return true
            }
            let ok = profile.relayDebugOpenChatNotificationSettings()
            after(1.5) {
                completion(ok, ok ? nil : "not a Mattermost chat", [:])
            }
            return true
        case "share-test":
            // The current account (switch accounts with the remote's `switch` first).
            let accountId = context.account.id
            let shareContext = context
            guard let query = command["chat"] as? String, let peerId = MattermostSync.debugChatPeerId(accountId: accountId, query: query) else {
                completion(false, "no chat", [:])
                return true
            }
            var items: [[String: Any]] = []
            if let text = command["text"] as? String {
                items.append(["text": text])
            }
            if let url = (command["url"] as? String).flatMap(URL.init(string:)) {
                items.append(["url": url])
            }
            for index in 0 ..< (Int((command["images"] as? String) ?? "") ?? 0) {
                items.append(["image": self.relayGeneratedImage(text: "\(index + 1)")])
            }
            for index in 0 ..< (Int((command["files"] as? String) ?? "") ?? 0) {
                items.append(["data": Data("Shared file \(index + 1) from the share extension's code path.\n".utf8), "fileName": "shared-\(index + 1).txt", "mimeType": "text/plain"])
            }
            var threadIds: [PeerId: Int64] = [:]
            if let root = command["thread"] as? String, let messageId = MattermostSync.debugMessageId(accountId: accountId, postId: root) {
                threadIds[peerId] = Int64(messageId.id)
            }
            let content = MattermostShareExtension.content(items: items)
            let started = CFAbsoluteTimeGetCurrent()
            var progress: [Float] = []
            let _ = (MattermostShareExtension.share(accountId: accountId, rootPath: shareContext.sharedContext.basePath, peerIds: [peerId], threadIds: threadIds, comment: (command["comment"] as? String) ?? "", content: content)
            |> deliverOnMainQueue).startStandalone(next: { status in
                if case let .progress(value) = status {
                    progress.append(value)
                }
            }, error: { error in
                completion(false, "\(error)", ["rootPath": shareContext.sharedContext.basePath])
            }, completed: {
                var result = MattermostShareExtension.summary(content)
                result["progressUpdates"] = progress.count
                result["lastProgress"] = progress.last ?? 0
                result["ms"] = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                result["thread"] = threadIds[peerId] != nil
                completion(true, nil, result)
            })
            return true
        default:
            return false
        }
    }
    #endif
}
#endif
