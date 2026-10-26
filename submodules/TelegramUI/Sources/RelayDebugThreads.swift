import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatMessageItemView
import ChatMessageItem
import MattermostSync
import MattermostUI

// MATTERMOST: debug only (Phase 3B). Chat-screen commands of the debug remote (`tools/relay-remote.py`), for
// checks without UI automation; each goes through the code path a tap uses:
// - `chat` (`query`): opens a chat as the chat list does;
// - `post` (`post`): a permalink: the post's thread at it (a reply, collapsed threads on) or its chat at it;
// - `replies` (`post`: a root, or `index`: the n-th visible root with a replies button, newest first): the
//   "N replies" button's action (`openMessageReplies`);
// - `threads` (`team`: a team id, default the first): the chat list's threads button;
// - `follow`, `unfollow`: Follow / Unfollow Thread in the visible thread;
// - `scroll` (`to`: `top` or `bottom`) in the visible chat;
// - `visible`: the visible chat's messages (post ids, thread ids, reply buttons, texts);
// - `menu` (`post`): the message's context menu, as a long press opens it;
// - `check-thread` (`post`: a root): loads the thread and compares it with the server's;
// - `back`: pops the top screen.
extension TelegramRootController {
    func relayDebugInstallChatCommands() {
        #if DEBUG
        MattermostDebugChatCommands.handler = { [weak self] action, command, completion in
            guard let self, let context = self.chatListController?.context else {
                return false
            }
            return self.relayDebugRunChatCommand(context: context, action: action, command: command, completion: completion)
        }
        #endif
    }

    #if DEBUG
    private var relayTopChat: ChatControllerImpl? {
        return self.viewControllers.last as? ChatControllerImpl
    }

    private func relayDebugRunChatCommand(context: AccountContext, action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let accountId = context.account.id
        let after: (Double, @escaping () -> Void) -> Void = { delay, f in
            Queue.mainQueue().after(delay, f)
        }
        switch action {
        case "chat":
            guard let query = command["query"] as? String, let peerId = MattermostSync.debugChatPeerId(accountId: accountId, query: query) else {
                completion(false, "no chat", [:])
                return true
            }
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                guard let self, let peer else {
                    completion(false, "no peer", [:])
                    return
                }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: self, context: context, chatLocation: .peer(peer)))
                after(2.0) {
                    completion(true, nil, [:])
                }
            })
        case "post":
            guard let postId = command["post"] as? String else {
                completion(false, "missing post", [:])
                return true
            }
            let _ = (MattermostSync.postDestination(accountId: accountId, postId: postId)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] destination in
                guard let self, let destination else {
                    completion(false, "no destination", [:])
                    return
                }
                if let threadId = destination.threadId {
                    mattermostOpenThread(context: context, navigationController: self, peerId: destination.peerId, threadId: threadId, messageId: destination.messageId)
                    after(2.5) {
                        completion(true, nil, ["threadId": threadId, "messageId": destination.messageId.map { Int($0.id) } ?? 0])
                    }
                } else {
                    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: destination.peerId))
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                        guard let self, let peer else {
                            return
                        }
                        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: self, context: context, chatLocation: .peer(peer), subject: destination.messageId.map { .message(id: .id($0), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false) }))
                        after(2.5) {
                            completion(true, nil, ["messageId": destination.messageId.map { Int($0.id) } ?? 0])
                        }
                    })
                }
            })
        case "replies":
            guard let chat = self.relayTopChat else {
                completion(false, "no chat", [:])
                return true
            }
            var target: Message?
            if let postId = command["post"] as? String, let messageId = MattermostSync.debugMessageId(accountId: accountId, postId: postId) {
                target = chat.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId)?._asMessage()
            } else {
                let index = (command["index"] as? String).flatMap(Int.init) ?? 0
                var candidates: [Message] = []
                chat.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
                    if let item = itemNode.item, hasCommentButton(item: item) {
                        candidates.append(item.message)
                    }
                }
                candidates.sort(by: { $0.index > $1.index })
                if index < candidates.count {
                    target = candidates[index]
                }
            }
            guard let target else {
                completion(false, "no root with a replies button", [:])
                return true
            }
            chat.controllerInteraction?.openMessageReplies(target.id, true, false)
            after(2.5) {
                completion(true, nil, ["opened": Int(target.id.id)])
            }
        case "threads":
            let teamId = (command["team"] as? String) ?? MattermostSync.teams(accountId: accountId).first?.id ?? ""
            self.pushViewController(mattermostThreadsController(context: context, teamId: teamId))
            after(2.0) {
                completion(true, nil, [:])
            }
        case "follow", "unfollow":
            guard let chat = self.relayTopChat, case let .replyThread(thread) = chat.chatLocation else {
                completion(false, "no thread open", [:])
                return true
            }
            mattermostSetFollowingThread(context: context, peerId: thread.peerId, threadId: thread.threadId, following: action == "follow", present: { c in
                chat.present(c, in: .current)
            })
            after(2.0) {
                completion(true, nil, ["following": (MattermostSync.isFollowingThread(accountId: accountId, peerId: thread.peerId, threadId: thread.threadId).map { $0 ? "yes" : "no" } ?? "unknown")])
            }
        case "scroll":
            guard let chat = self.relayTopChat else {
                completion(false, "no chat", [:])
                return true
            }
            if (command["to"] as? String) == "top" {
                chat.chatDisplayNode.historyNode.scrollToStartOfHistory()
            } else {
                chat.chatDisplayNode.historyNode.scrollToEndOfHistory()
            }
            after(1.5) {
                completion(true, nil, [:])
            }
        case "visible":
            guard let chat = self.relayTopChat else {
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
                    "id": Int(message.id.id),
                    "namespace": Int(message.id.namespace),
                    "post": MattermostSync.debugPostId(accountId: accountId, messageId: message.id) ?? "",
                    "threadId": message.threadId.map { Int($0) } ?? 0,
                    "rootTag": message.tags.contains(.mattermostRootPost),
                    "repliesButton": hasCommentButton(item: item),
                    "text": String(message.text.prefix(60))
                ]
                if let attribute = message.attributes.first(where: { $0 is ReplyThreadMessageAttribute }) as? ReplyThreadMessageAttribute {
                    entry["replyCount"] = Int(attribute.count)
                    entry["latestUsers"] = attribute.latestUsers.count
                }
                messages.append(entry)
            }
            messages.sort(by: { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) })
            var chatInfo: [String: Any] = ["messages": messages, "collapsedThreads": MattermostSync.isCollapsedThreads(accountId: accountId)]
            if case let .replyThread(thread) = chat.chatLocation {
                chatInfo["threadId"] = thread.threadId
                chatInfo["following"] = (MattermostSync.isFollowingThread(accountId: accountId, peerId: thread.peerId, threadId: thread.threadId).map { $0 ? "yes" : "no" } ?? "unknown")
            }
            completion(true, nil, chatInfo)
        case "menu":
            guard let chat = self.relayTopChat, let postId = command["post"] as? String, let messageId = MattermostSync.debugMessageId(accountId: accountId, postId: postId) else {
                completion(false, "no chat or message", [:])
                return true
            }
            var found = false
            chat.chatDisplayNode.historyNode.forEachItemNode { node in
                if !found, let itemNode = node as? ChatMessageItemView, let item = itemNode.item, item.message.id == messageId {
                    found = true
                    itemNode.openMessageContextMenu()
                }
            }
            after(1.5) {
                completion(found, found ? nil : "message not visible", [:])
            }
        case "check-thread":
            guard let postId = command["post"] as? String else {
                completion(false, "missing post", [:])
                return true
            }
            let _ = (MattermostSync.debugCheckThread(accountId: accountId, rootPostId: postId)
            |> deliverOnMainQueue).startStandalone(next: { report in
                completion(report["error"] == nil, report["error"] as? String, report)
            })
        case "back":
            if self.viewControllers.count > 1 {
                let _ = self.popViewController(animated: false)
            }
            after(1.0) {
                completion(true, nil, [:])
            }
        default:
            return false
        }
        return true
    }
    #endif
}
