import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatInterfaceState
import MattermostUI
import MattermostSync

// MATTERMOST: debug only (Phase 3D). Drives the composer of the visible chat through the debug remote
// (`tools/relay-remote.py`), since the simulator takes no scripted touches or typing here:
// - `compose` (`text`): sets the composer's text, cursor at the end, as typing it would (the suggestion
//   queries run on the change);
// - `suggestions`: the visible suggestion panel's entries (`state.chat.suggestions`) and the composer text;
// - `pick` (`index`): selects an entry of the visible panel through the panel's own selection closure, as a
//   tap on it does (the `mattermostDebug…Pick` wrappers around the mention, command and emoji panels' closures);
// - `send-composer`: the send button with what the composer holds (`sendCurrentMessage`; 3B's `send` types a
//   `text` first);
// - `input`: the composer text;
// - `open-thread` (`post`): the thread view of a loaded root post of the visible chat (as a tap on its replies).
// Release builds compile none of the driver; the panel wrappers just return their closure.

func mattermostDebugMentionPick(_ peers: [EnginePeer], _ select: @escaping (EnginePeer) -> Void) -> (EnginePeer) -> Void {
    #if DEBUG
    RelayDebugComposer.shared.register(kind: "mentions", items: peers.map { "\($0.compactDisplayTitle) \($0.addressName.map { "@" + $0 } ?? "")" }, select: { index in
        guard index >= 0 && index < peers.count else {
            return false
        }
        select(peers[index])
        return true
    })
    #endif
    return select
}

func mattermostDebugCommandPick(_ commands: [ChatInputTextCommand], _ select: @escaping (ChatInputTextCommand, Bool) -> Void) -> (ChatInputTextCommand, Bool) -> Void {
    #if DEBUG
    RelayDebugComposer.shared.register(kind: "commands", items: commands.map { command in
        if case let .command(value) = command {
            return "/\(value.command.text)  \(value.command.description)"
        }
        return "shortcut"
    }, select: { index in
        guard index >= 0 && index < commands.count else {
            return false
        }
        // A tap on the row (not on its insert arrow).
        select(commands[index], true)
        return true
    })
    #endif
    return select
}

func mattermostDebugEmojiPick(_ items: [(String, TelegramMediaFile?)], _ select: @escaping (String, TelegramMediaFile?) -> Void) -> (String, TelegramMediaFile?) -> Void {
    #if DEBUG
    RelayDebugComposer.shared.register(kind: "emojis", items: items.map { symbol, file in
        if let file {
            for attribute in file.attributes {
                if case let .CustomEmoji(_, _, alt, _) = attribute {
                    return alt
                }
            }
        }
        return symbol
    }, select: { index in
        guard index >= 0 && index < items.count else {
            return false
        }
        select(items[index].0, items[index].1)
        return true
    })
    #endif
    return select
}

#if DEBUG
final class RelayDebugComposer {
    static let shared = RelayDebugComposer()

    private weak var rootController: TelegramRootController?
    private var kind = ""
    private var items: [String] = []
    private var select: ((Int) -> Bool)?

    func register(kind: String, items: [String], select: @escaping (Int) -> Bool) {
        self.kind = kind
        self.items = items
        self.select = select
    }

    static func install(rootController: TelegramRootController) {
        self.shared.rootController = rootController
        MattermostDebugHooks.chatCommand = { action, command, completion in
            return self.shared.run(action: action, command: command, completion: completion)
        }
    }

    private var chat: ChatControllerImpl? {
        guard let navigationController = self.rootController else {
            return nil
        }
        for controller in navigationController.viewControllers.reversed() {
            if let chat = controller as? ChatControllerImpl {
                return chat
            }
        }
        return nil
    }

    private func info(_ chat: ChatControllerImpl) -> [String: Any] {
        let state = chat.presentationInterfaceState
        var queries: [String] = []
        for (kind, result) in state.inputQueryResults {
            switch result {
            case let .mentions(peers):
                queries.append("\(kind): \(peers.count) mentions")
            case let .commands(commands):
                queries.append("\(kind): \(commands.commands.count) commands")
            case let .emojis(emojis, _):
                queries.append("\(kind): \(emojis.count) emojis")
            case let .hashtags(hashtags, _):
                queries.append("\(kind): \(hashtags.count) hashtags")
            default:
                queries.append("\(kind)")
            }
        }
        return [
            "input": state.interfaceState.effectiveInputState.inputText.string,
            "panel": self.kind,
            "suggestions": self.items,
            "queries": queries,
            "threadId": chat.chatLocation.threadId.map { "\($0)" } ?? ""
        ]
    }

    private func run(action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        switch action {
        case "compose", "suggestions", "pick", "send-composer", "input", "open-thread":
            break
        default:
            return false
        }
        guard let chat = self.chat else {
            completion(false, "no chat", [:])
            return true
        }
        switch action {
        case "compose":
            let text = command["text"] as? String ?? ""
            self.kind = ""
            self.items = []
            self.select = nil
            chat.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                return state.updatedInterfaceState { interfaceState in
                    return interfaceState.withUpdatedEffectiveInputState(ChatTextInputState(inputText: NSAttributedString(string: text)))
                }
            })
            if command["focus"] as? String != "0" {
                chat.chatDisplayNode.ensureInputViewFocused()
            }
            // The suggestion queries wait ~0.1 s before their request.
            Queue.mainQueue().after(1.5) {
                completion(true, nil, self.info(chat))
            }
        case "suggestions", "input":
            completion(true, nil, self.info(chat))
        case "pick":
            let index = (command["index"] as? String).flatMap(Int.init) ?? (command["index"] as? Int) ?? 0
            let picked = index < self.items.count ? self.items[index] : nil
            let ok = self.select?(index) ?? false
            Queue.mainQueue().after(0.8) {
                var info = self.info(chat)
                info["picked"] = picked ?? ""
                completion(ok, ok ? nil : "no suggestion \(index)", info)
            }
        case "open-thread":
            guard let postId = command["post"] as? String, let peerId = chat.chatLocation.peerId, let rootId = MattermostDebug.messageId(accountId: chat.context.account.id, peerId: peerId, postId: postId), let navigationController = self.rootController else {
                completion(false, "no such post in this chat", self.info(chat))
                return true
            }
            let context = chat.context
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).start(next: { peer in
                guard peer != nil else {
                    completion(false, "no peer", [:])
                    return
                }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .replyThread(ChatReplyThreadMessage(
                    peerId: peerId, threadId: Int64(rootId.id), channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false
                ))))
                Queue.mainQueue().after(2.0) {
                    if let thread = self.chat {
                        completion(true, nil, self.info(thread))
                    } else {
                        completion(false, "thread not open", [:])
                    }
                }
            })
        case "send-composer":
            chat.chatDisplayNode.sendCurrentMessage()
            Queue.mainQueue().after(1.0) {
                completion(true, nil, self.info(chat))
            }
        default:
            break
        }
        return true
    }
}
#endif
