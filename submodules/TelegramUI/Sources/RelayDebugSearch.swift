import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatListUI
import ContactsPeerItem
import PeerInfoScreen
import MattermostSync
import MattermostUI

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

// MATTERMOST: debug only (Phase 3C). Search, saved posts, mentions and pinning commands of the debug remote
// (`tools/relay-remote.py`), for checks without UI automation; each goes through the code path a tap uses:
// - `search` (`query`; `filter`: chats, media, links, files, music): the chat list's search field (`activateSearch`),
//   then the visible results (`search-results` again later);
// - `search-tap` (`index`, `kind`: message or peer): a tap on the n-th visible result row (`ListViewItem.selected`);
// - `search-cancel`: leaves the search; `join-confirm`: Join on the join alert of a not-joined channel;
// - `engine-search` (`query`; `chat` to search in one chat as `chat` names it; `from` username; `pages`): the engine
//   call the search UI makes, every page, with the post ids (for comparing with REST);
// - `people` (`query`): the engine's people/channel search;
// - `peerinfo-search` (`chat`, `pane`: files, links, music; `query`): the profile's media pane search;
// - `chat-search` (`query`, `from` username): Search in the visible chat; `chat-search-step` (`dir`: earlier, later);
// - `post-list` (`kind`: saved, mentions): the screen, pushed; `post-list-items`, `post-list-tap` (`index`);
// - `save`, `unsave` (`post`): the message menu's Save Post / Remove from Saved; `saved-state` (`post`);
// - `pin`, `unpin` (`post`): the message menu's Pin / Unpin in the visible chat; `pinned`: its pinned bar;
//   `pinned-list`: the bar's list button (all pinned messages).
extension TelegramRootController {
    func relayDebugInstallSearchCommands() {
        #if DEBUG
        let previous = MattermostDebugChatCommands.handler
        MattermostDebugChatCommands.handler = { [weak self] action, command, completion in
            if let self, let context = self.chatListController?.context, self.relayDebugRunSearchCommand(context: context, action: action, command: command, completion: completion) {
                return true
            }
            return previous?(action, command, completion) ?? false
        }
        #endif
    }

    #if DEBUG
    private var relaySearchTopChat: ChatControllerImpl? {
        return self.viewControllers.last as? ChatControllerImpl
    }

    private func relaySearchContainer() -> ASDisplayNode? {
        var result: ASDisplayNode?
        func visit(_ node: ASDisplayNode) {
            if result != nil {
                return
            }
            if node is ChatListSearchContainerNode {
                result = node
                return
            }
            for subnode in node.subnodes ?? [] {
                visit(subnode)
            }
        }
        if let chatList = self.chatListController, chatList.isNodeLoaded {
            visit(chatList.displayNode)
        }
        return result
    }

    private func relayVisibleRows(in root: ASDisplayNode) -> [(item: ListViewItem, listView: ListViewImpl, frame: CGRect, info: [String: Any])] {
        var rows: [(item: ListViewItem, listView: ListViewImpl, frame: CGRect, info: [String: Any])] = []
        let accountId = self.chatListController?.context.account.id
        func listView(of node: ASDisplayNode) -> ListViewImpl? {
            var current = node.supernode
            while let node = current {
                if let listView = node as? ListViewImpl {
                    return listView
                }
                current = node.supernode
            }
            return nil
        }
        func isShown(_ node: ASDisplayNode) -> Bool {
            var current: ASDisplayNode? = node
            while let node = current {
                if node.isHidden || node.alpha < 0.01 {
                    return false
                }
                current = node.supernode
            }
            return true
        }
        func visit(_ node: ASDisplayNode) {
            if let itemNode = node as? ChatListItemNode, let item = itemNode.item, let list = listView(of: itemNode), isShown(itemNode) {
                var info: [String: Any] = ["kind": "chat"]
                if case let .peer(peerData) = item.content {
                    info["chat"] = peerData.peer.chatMainPeer?.debugDisplayTitle ?? ""
                    if let message = peerData.messages.first {
                        info["kind"] = "message"
                        info["messageId"] = Int(message.id.id)
                        info["post"] = accountId.flatMap { MattermostSync.debugPostId(accountId: $0, messageId: message.id) } ?? ""
                        info["text"] = String(message.text.prefix(80))
                        info["date"] = Int(message.timestamp)
                    }
                }
                rows.append((item, list, itemNode.view.convert(itemNode.bounds, to: nil), info))
            } else if let itemNode = node as? ContactsPeerItemNode, let item = itemNode.item, let list = listView(of: itemNode), isShown(itemNode) {
                var info: [String: Any] = ["kind": "peer"]
                if case let .peer(peer, _) = item.peer, let peer {
                    info["peer"] = peer.debugDisplayTitle
                    info["peerId"] = "\(peer.id.toInt64())"
                    if case let .channel(channel) = peer {
                        info["joined"] = channel.participationStatus == .member
                    }
                }
                rows.append((item, list, itemNode.view.convert(itemNode.bounds, to: nil), info))
            }
            for subnode in node.subnodes ?? [] {
                visit(subnode)
            }
        }
        visit(root)
        rows.sort(by: { $0.frame.minY < $1.frame.minY })
        return rows
    }

    private func relayDebugRunSearchCommand(context: AccountContext, action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let accountId = context.account.id
        let after: (Double, @escaping () -> Void) -> Void = { delay, f in
            Queue.mainQueue().after(delay, f)
        }
        let searchRows: () -> [[String: Any]] = { [weak self] in
            guard let self, let container = self.relaySearchContainer() else {
                return []
            }
            return self.relayVisibleRows(in: container).map(\.info)
        }
        switch action {
        case "search":
            guard let chatList = self.chatListController else {
                completion(false, "no chat list", [:])
                return true
            }
            let query = command["query"] as? String ?? ""
            let filter: ChatListSearchFilter
            switch command["filter"] as? String ?? "chats" {
            case "media":
                filter = .media
            case "links":
                filter = .links
            case "files":
                filter = .files
            case "music":
                filter = .music
            case "voice":
                // Phase 5A: the Voice tab.
                filter = .voice
            default:
                filter = .chats
            }
            let _ = chatList
            self.openChatsController(activateSearch: true, filter: filter, query: query)
            let delay = (command["wait"] as? String).flatMap(Double.init) ?? 4.0
            after(delay) {
                completion(true, nil, ["results": searchRows()])
            }
        case "search-results":
            completion(true, nil, ["results": searchRows()])
        case "search-tap":
            guard let container = self.relaySearchContainer() else {
                completion(false, "search not active", [:])
                return true
            }
            let kind = command["kind"] as? String ?? "message"
            let index = (command["index"] as? String).flatMap(Int.init) ?? 0
            let rows = self.relayVisibleRows(in: container).filter { ($0.info["kind"] as? String) == kind }
            guard index < rows.count else {
                completion(false, "no such row (\(rows.count) \(kind) rows)", [:])
                return true
            }
            let row = rows[index]
            row.item.selected(listView: row.listView)
            after(3.0) { [weak self] in
                var extra: [String: Any] = ["tapped": row.info]
                if let chat = self?.relaySearchTopChat {
                    extra["chatLocation"] = chat.chatLocation.threadId.map { "thread \($0)" } ?? "peer \(chat.chatLocation.peerId?.toInt64() ?? 0)"
                }
                completion(true, nil, extra)
            }
        case "join-confirm":
            // "Join" on the join alert of a public channel found by search.
            guard let (alert, join) = mattermostDebugJoinAlert else {
                completion(false, "no join alert", [:])
                return true
            }
            mattermostDebugJoinAlert = nil
            alert.dismiss()
            join()
            after(3.0) { [weak self] in
                var extra: [String: Any] = [:]
                if let chat = self?.relaySearchTopChat {
                    extra["chatLocation"] = "peer \(chat.chatLocation.peerId?.toInt64() ?? 0)"
                }
                completion(true, nil, extra)
            }
        case "search-cancel":
            self.chatListController?.deactivateSearch(animated: false)
            after(1.0) {
                completion(true, nil, [:])
            }
        case "engine-search":
            let query = command["query"] as? String ?? ""
            var location: SearchMessagesLocation = .general(scope: .everywhere, groupId: nil, tags: nil, minDate: nil, maxDate: nil, folderId: nil, communityId: nil)
            if let chat = command["chat"] as? String {
                guard let peerId = MattermostSync.debugChatPeerId(accountId: accountId, query: chat) else {
                    completion(false, "no chat", [:])
                    return true
                }
                var fromId: EnginePeer.Id?
                if let from = command["from"] as? String {
                    fromId = MattermostSync.debugUserPeerId(accountId: accountId, username: from)
                }
                location = .peer(peerId: peerId, fromId: fromId, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil)
            }
            let maxPages = (command["pages"] as? String).flatMap(Int.init) ?? 5
            let started = CFAbsoluteTimeGetCurrent()
            func run(state: SearchMessagesState?, page: Int) {
                let _ = (context.engine.messages.searchMessages(location: location, query: query, state: state, limit: 100)
                |> take(1)
                |> deliverOnMainQueue).startStandalone(next: { result, updatedState in
                    if !result.completed && page + 1 < maxPages {
                        run(state: updatedState, page: page + 1)
                        return
                    }
                    let posts: [[String: Any]] = result.messages.map { message in
                        return [
                            "post": MattermostSync.debugPostId(accountId: accountId, messageId: message.id) ?? "",
                            "messageId": Int(message.id.id),
                            "peerId": "\(message.id.peerId.toInt64())",
                            "text": String(message.text.prefix(60))
                        ]
                    }
                    completion(true, nil, ["count": result.messages.count, "completed": result.completed, "pages": page + 1, "ms": Int((CFAbsoluteTimeGetCurrent() - started) * 1000), "posts": posts])
                })
            }
            run(state: nil, page: 0)
        case "peerinfo-search":
            // The profile's Files (Links, Music) pane: its search button, then `query` typed; the result's `posts` are
            // what the pane's search asks the engine for (the same call).
            guard let chat = command["chat"] as? String, let peerId = MattermostSync.debugChatPeerId(accountId: accountId, query: chat) else {
                completion(false, "no chat", [:])
                return true
            }
            let pane = command["pane"] as? String ?? "files"
            let query = command["query"] as? String ?? ""
            let tags: MessageTags = pane == "links" ? .webPage : (pane == "music" ? .music : (pane == "voice" ? .voiceOrInstantVideo : .file))
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                guard let self, let peer, let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else {
                    completion(false, "no profile", [:])
                    return
                }
                self.pushViewController(controller)
                after(2.0) {
                    (controller as? PeerInfoScreenImpl)?.relayDebugSearchPane(pane, query: query)
                    after(4.0) {
                        let _ = (context.engine.messages.searchMessages(location: .peer(peerId: peerId, fromId: nil, tags: tags, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: query, state: nil)
                        |> take(1)
                        |> deliverOnMainQueue).startStandalone(next: { result, _ in
                            let posts = result.messages.map { message -> [String: Any] in
                                var name = ""
                                for media in message.media {
                                    if let file = media as? TelegramMediaFile {
                                        name = file.fileName ?? ""
                                    }
                                }
                                return ["post": MattermostSync.debugPostId(accountId: accountId, messageId: message.id) ?? "", "file": name]
                            }
                            completion(true, nil, ["count": posts.count, "posts": posts])
                        })
                    }
                }
            })
        case "people":
            let query = command["query"] as? String ?? ""
            let _ = (context.engine.contacts.searchRemotePeers(query: query)
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { mine, other in
                let describe: (FoundPeer) -> [String: Any] = { found in
                    var entry: [String: Any] = ["title": found.peer.debugDisplayTitle, "peerId": "\(found.peer.id.toInt64())"]
                    if case let .channel(channel) = found.peer {
                        entry["joined"] = channel.participationStatus == .member
                    }
                    if let username = found.peer.addressName {
                        entry["username"] = username
                    }
                    return entry
                }
                completion(true, nil, ["mine": mine.map(describe), "other": other.map(describe)])
            })
        case "chat-search":
            guard let chat = self.relaySearchTopChat else {
                completion(false, "no chat", [:])
                return true
            }
            let query = command["query"] as? String ?? ""
            if let from = command["from"] as? String, let peerId = MattermostSync.debugUserPeerId(accountId: accountId, username: from) {
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                |> deliverOnMainQueue).startStandalone(next: { peer in
                    if let peer {
                        chat.activateSearch(domain: .member(peer._asPeer()), query: query)
                    }
                })
            } else {
                chat.activateSearch(domain: .everything, query: query)
            }
            after(4.0) { [weak self] in
                completion(true, nil, self?.relayChatSearchState(context: context) ?? [:])
            }
        case "chat-search-step":
            guard let chat = self.relaySearchTopChat else {
                completion(false, "no chat", [:])
                return true
            }
            chat.interfaceInteraction?.navigateMessageSearch((command["dir"] as? String) == "later" ? .later : .earlier)
            after(2.5) { [weak self] in
                completion(true, nil, self?.relayChatSearchState(context: context) ?? [:])
            }
        case "post-list":
            let kind: MattermostPostListKind = (command["kind"] as? String) == "mentions" ? .mentions : .saved
            self.pushViewController(MattermostPostListController(context: context, kind: kind))
            after((command["wait"] as? String).flatMap(Double.init) ?? 4.0) { [weak self] in
                completion(true, nil, self?.relayPostListState(accountId: accountId) ?? [:])
            }
        case "post-list-items":
            completion(true, nil, self.relayPostListState(accountId: accountId))
        case "post-list-tap":
            guard let list = self.viewControllers.last as? MattermostPostListController else {
                completion(false, "no post list", [:])
                return true
            }
            let index = (command["index"] as? String).flatMap(Int.init) ?? 0
            guard list.debugOpen(index: index) else {
                completion(false, "no such row", [:])
                return true
            }
            after(3.0) { [weak self] in
                var extra: [String: Any] = [:]
                if let chat = self?.relaySearchTopChat {
                    extra["chatLocation"] = chat.chatLocation.threadId.map { "thread \($0)" } ?? "peer \(chat.chatLocation.peerId?.toInt64() ?? 0)"
                }
                completion(true, nil, extra)
            }
        case "save", "unsave":
            guard let postId = command["post"] as? String, let messageId = MattermostSync.debugMessageId(accountId: accountId, postId: postId) else {
                completion(false, "post not stored", [:])
                return true
            }
            mattermostSetPostSaved(context: context, messageId: messageId, saved: action == "save", present: { [weak self] c in
                (self?.viewControllers.last as? ViewController)?.present(c, in: .current)
            })
            after(2.0) {
                completion(true, nil, ["saved": MattermostSync.isPostSaved(accountId: accountId, messageId: messageId).map { $0 ? "yes" : "no" } ?? "unknown"])
            }
        case "saved-state":
            guard let postId = command["post"] as? String, let messageId = MattermostSync.debugMessageId(accountId: accountId, postId: postId) else {
                completion(false, "post not stored", [:])
                return true
            }
            completion(true, nil, ["saved": MattermostSync.isPostSaved(accountId: accountId, messageId: messageId).map { $0 ? "yes" : "no" } ?? "unknown"])
        case "pin", "unpin":
            guard let chat = self.relaySearchTopChat, let postId = command["post"] as? String, let messageId = MattermostSync.debugMessageId(accountId: accountId, postId: postId) else {
                completion(false, "no chat or message", [:])
                return true
            }
            if action == "pin" {
                chat.interfaceInteraction?.pinMessage(messageId, nil)
            } else {
                chat.interfaceInteraction?.unpinMessage(messageId, false, nil)
            }
            after(2.5) { [weak self] in
                completion(true, nil, self?.relayPinnedState(accountId: accountId) ?? [:])
            }
        case "pinned":
            completion(true, nil, self.relayPinnedState(accountId: accountId))
        case "pinned-list":
            guard let chat = self.relaySearchTopChat, let pinned = chat.presentationInterfaceState.pinnedMessage else {
                completion(false, "no pinned message", [:])
                return true
            }
            chat.interfaceInteraction?.openPinnedList(pinned.message.id)
            after(3.0) { [weak self] in
                guard let self, let list = self.relaySearchTopChat else {
                    completion(false, "no list", [:])
                    return
                }
                var posts: [String] = []
                list.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
                    if let item = itemNode.item, let post = MattermostSync.debugPostId(accountId: accountId, messageId: item.message.id), !posts.contains(post) {
                        posts.append(post)
                    }
                }
                completion(true, nil, ["visiblePinnedPosts": posts])
            }
        default:
            return false
        }
        return true
    }

    private func relayChatSearchState(context: AccountContext) -> [String: Any] {
        guard let chat = self.relaySearchTopChat, let search = chat.presentationInterfaceState.search else {
            return ["search": "inactive"]
        }
        let accountId = context.account.id
        var result: [String: Any] = ["query": search.query]
        if let resultsState = search.resultsState {
            result["totalCount"] = Int(resultsState.totalCount)
            result["completed"] = resultsState.completed
            result["posts"] = resultsState.messageIndices.map { MattermostSync.debugPostId(accountId: accountId, messageId: $0.id) ?? "?" }
            result["current"] = resultsState.currentId.flatMap { MattermostSync.debugPostId(accountId: accountId, messageId: $0) } ?? ""
        }
        return result
    }

    private func relayPostListState(accountId: AccountRecordId) -> [String: Any] {
        guard let list = self.viewControllers.last as? MattermostPostListController else {
            return ["list": "not open"]
        }
        let messages = list.debugMessages
        return [
            "kind": list.kind == .saved ? "saved" : "mentions",
            "loading": list.debugIsLoading,
            "count": messages.count,
            "posts": messages.map { message -> [String: Any] in
                return [
                    "post": MattermostSync.debugPostId(accountId: accountId, messageId: message.id) ?? "",
                    "chat": message.peers[message.id.peerId].map { EnginePeer($0).debugDisplayTitle } ?? "",
                    "text": String(message.text.prefix(60))
                ]
            }
        ]
    }

    private func relayPinnedState(accountId: AccountRecordId) -> [String: Any] {
        guard let chat = self.relaySearchTopChat else {
            return ["chat": "none"]
        }
        guard let pinned = chat.presentationInterfaceState.pinnedMessage else {
            return ["pinned": "none"]
        }
        return [
            "top": MattermostSync.debugPostId(accountId: accountId, messageId: pinned.topMessageId) ?? "",
            "shown": MattermostSync.debugPostId(accountId: accountId, messageId: pinned.message.id) ?? "",
            "totalCount": pinned.totalCount
        ]
    }
    #endif
}
#endif
