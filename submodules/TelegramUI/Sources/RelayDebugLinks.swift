import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatControllerInteraction
import MattermostSync
import MattermostUI

// MATTERMOST: debug only (Phase 3E). Rich content and link commands of the debug remote (`tools/relay-remote.py`),
// for checks without UI automation; each goes through the code path a tap uses:
// - `links`: the visible chat's messages with their link previews (site, title, text, image), link entities and
//   heading entities;
// - `tap-link` (`url`; `concealed=1` for a link whose text differs from its target): a tap on a link in the
//   visible chat (`ChatControllerInteraction.openUrl`), then where it led (`last-link`);
// - `tap-preview` (`post`): a tap on the message's link preview card (its url, as the card opens it);
// - `copy-link` (`post`): the message menu's Copy Link, then the pasteboard; `share-link` (`post`): Share Link;
// - `last-link`: the last link opened in the app and its destination, plus the chat now on top.
extension TelegramRootController {
    func relayDebugInstallLinkCommands() {
        #if DEBUG
        let previous = MattermostDebugChatCommands.handler
        MattermostDebugChatCommands.handler = { [weak self] action, command, completion in
            if let self, let context = self.chatListController?.context, self.relayDebugRunLinkCommand(context: context, action: action, command: command, completion: completion) {
                return true
            }
            return previous?(action, command, completion) ?? false
        }
        #endif
    }

    #if DEBUG
    private var relayLinksTopChat: ChatControllerImpl? {
        return self.viewControllers.last as? ChatControllerImpl
    }

    private func relayDebugTopState(context: AccountContext) -> [String: Any] {
        var result: [String: Any] = ["account": Int(context.account.id.int64)]
        if let chat = self.relayLinksTopChat {
            result["chatPeerId"] = chat.chatLocation.peerId.map { "\($0.toInt64())" } ?? ""
            result["chatThreadId"] = chat.chatLocation.threadId.map { Int($0) } ?? 0
            var visible: [String] = []
            chat.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
                if let item = itemNode.item {
                    visible.append(MattermostSync.debugPostId(accountId: context.account.id, messageId: item.message.id) ?? "?")
                }
            }
            result["visiblePosts"] = visible
        } else {
            result["top"] = self.viewControllers.last.map { "\(type(of: $0))" } ?? ""
        }
        if let (target, destination) = mattermostDebugLastLink {
            result["lastLink"] = ["account": Int(target.accountId.int64), "route": "\(target.route)", "destination": "\(destination)"]
        }
        return result
    }

    private func relayDebugMessage(context: AccountContext, postId: String?) -> Message? {
        guard let chat = self.relayLinksTopChat, let postId = postId, let messageId = MattermostSync.debugMessageId(accountId: context.account.id, postId: postId) else {
            return nil
        }
        return chat.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId)?._asMessage()
    }

    private func relayDebugRunLinkCommand(context: AccountContext, action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let after: (Double, @escaping () -> Void) -> Void = { delay, f in
            Queue.mainQueue().after(delay, f)
        }
        switch action {
        case "links":
            guard let chat = self.relayLinksTopChat else {
                completion(false, "no chat", [:])
                return true
            }
            var messages: [[String: Any]] = []
            chat.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
                guard let item = itemNode.item else {
                    return
                }
                let message = item.message
                var entry: [String: Any] = [
                    "post": MattermostSync.debugPostId(accountId: context.account.id, messageId: message.id) ?? "?",
                    "text": String(message.text.prefix(200)),
                    "webPageTag": message.tags.contains(.webPage)
                ]
                var entities: [String] = []
                for attribute in message.attributes {
                    if let attribute = attribute as? TextEntitiesMessageAttribute {
                        for entity in attribute.entities {
                            let text = (message.text as NSString).substring(with: NSRange(location: entity.range.lowerBound, length: min(entity.range.count, (message.text as NSString).length - entity.range.lowerBound)))
                            switch entity.type {
                            case .Url, .TextUrl, .Pre, .Custom, .Code:
                                entities.append("\(entity.type) \(text.prefix(60))")
                            default:
                                break
                            }
                        }
                    }
                    if let attribute = attribute as? WebpagePreviewMessageAttribute {
                        entry["previewAttribute"] = "forceLargeMedia=\(attribute.forceLargeMedia.map { "\($0)" } ?? "nil") isSafe=\(attribute.isSafe)"
                    }
                }
                entry["entities"] = entities
                for media in message.media {
                    if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
                        var preview: [String: Any] = [
                            "url": content.url,
                            "type": content.type ?? "",
                            "site": content.websiteName ?? "",
                            "title": content.title ?? "",
                            "text": content.text ?? "",
                            "large": content.isMediaLargeByDefault.map { "\($0)" } ?? "nil"
                        ]
                        if let image = content.image, let representation = image.representations.last {
                            preview["image"] = "\(representation.dimensions.width)x\(representation.dimensions.height) \((representation.resource as? MattermostURLImageResource)?.url ?? "\(type(of: representation.resource))")"
                        }
                        entry["preview"] = preview
                    }
                }
                messages.append(entry)
            }
            completion(true, nil, ["messages": messages])
        case "tap-link":
            guard let chat = self.relayLinksTopChat, let url = command["url"] as? String else {
                completion(false, "no chat or url", [:])
                return true
            }
            mattermostDebugLastLink = nil
            chat.controllerInteraction?.openUrl(ChatControllerInteraction.OpenUrl(url: url, concealed: (command["concealed"] as? String) == "1"))
            after(3.0) { [weak self] in
                completion(true, nil, self?.relayDebugTopState(context: context) ?? [:])
            }
        case "tap-preview":
            guard let chat = self.relayLinksTopChat, let message = self.relayDebugMessage(context: context, postId: command["post"] as? String) else {
                completion(false, "no chat or message", [:])
                return true
            }
            guard let webpage = message.media.first(where: { $0 is TelegramMediaWebpage }) as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content else {
                completion(false, "no link preview", [:])
                return true
            }
            mattermostDebugLastLink = nil
            // As the card's activateAction does: the url, concealed unless the text contains it or it is safe.
            let isSafe = message.webpagePreviewAttribute?.isSafe ?? false
            chat.controllerInteraction?.openUrl(ChatControllerInteraction.OpenUrl(url: content.url, concealed: !message.text.contains(content.url) && !isSafe))
            after(3.0) { [weak self] in
                completion(true, nil, self?.relayDebugTopState(context: context) ?? [:])
            }
        case "copy-link":
            guard let message = self.relayDebugMessage(context: context, postId: command["post"] as? String), let link = MattermostSync.permalink(accountId: context.account.id, messageId: message.id) else {
                completion(false, "no message or permalink", [:])
                return true
            }
            UIPasteboard.general.string = ""
            mattermostCopyPermalink(link, context: context, displayUndo: { [weak self] content in
                self?.relayLinksTopChat?.controllerInteraction?.displayUndo(content)
            })
            after(1.0) {
                completion(true, nil, ["pasteboard": UIPasteboard.general.string ?? ""])
            }
        case "share-link":
            guard let message = self.relayDebugMessage(context: context, postId: command["post"] as? String), let link = MattermostSync.permalink(accountId: context.account.id, messageId: message.id) else {
                completion(false, "no message or permalink", [:])
                return true
            }
            mattermostSharePermalink(link, context: context)
            after(2.0) {
                completion(true, nil, ["link": link])
            }
        case "open-url":
            // A URL from the system (another app, `simctl openurl` after SpringBoard's "Open in Relay?"): the app
            // delegate's `application(_:open:options:)`, as iOS calls it.
            guard let string = command["url"] as? String, let url = URL(string: string), let delegate = UIApplication.shared.delegate else {
                completion(false, "bad url", [:])
                return true
            }
            mattermostDebugLastLink = nil
            var handled = true
            if (command["via"] as? String) == "system" {
                // Through iOS (`UIApplication.open`), which hands the app's own scheme back to it.
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                handled = delegate.application?(UIApplication.shared, open: url, options: [:]) ?? false
            }
            after(3.0) { [weak self] in
                var state = self?.relayDebugTopState(context: context) ?? [:]
                state["handled"] = handled
                completion(true, nil, state)
            }
        case "last-link":
            completion(true, nil, self.relayDebugTopState(context: context))
        default:
            return false
        }
        return true
    }
    #endif
}
