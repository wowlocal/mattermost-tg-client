import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import TelegramPresentationData
import UndoUI
import AppBundle
import ChatControllerInteraction
import MattermostSync
import MattermostUI

// MATTERMOST: collapsed reply threads (Phase 3B) in the chat screen. A Mattermost thread is a Postbox thread view
// of its root's local id (`ChatReplyThreadMessage(isForumPost: true)`, filled by MattermostSync's hole filler from
// `GET /posts/{root}/thread`), so nothing here asks Telegram's server for a discussion:
// - "N replies" buttons, "View Replies" and notification taps open the thread locally;
// - navigating to a reply that collapsed threads hide from its chat opens its thread at it;
// - the message menu offers View Thread (on replies) and Follow / Unfollow Thread.

/// The thread root of a message: its reply target for a reply, else the message itself.
private func mattermostThreadRoot(of message: Message) -> (root: EngineMessage.Id, isReply: Bool) {
    for attribute in message.attributes {
        if let reply = attribute as? ReplyMessageAttribute, reply.messageId.peerId == message.id.peerId, reply.messageId.namespace == Namespaces.Message.Cloud {
            return (reply.threadMessageId ?? reply.messageId, true)
        }
    }
    return (message.id, false)
}

extension ChatControllerImpl {
    /// `openMessageReplies` for Mattermost: the thread of `messageId` (a root, or a reply: its root's thread at
    /// it), opened locally.
    static func mattermostOpenMessageReplies(context: AccountContext, navigationController: NavigationController, messageId: EngineMessage.Id, atMessage atMessageId: EngineMessage.Id?) -> Signal<Never, NoError> {
        return context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> deliverOnMainQueue
        |> mapToSignal { message -> Signal<Never, NoError> in
            guard let message = message?._asMessage() else {
                return .complete()
            }
            let (root, isReply) = mattermostThreadRoot(of: message)
            mattermostOpenThread(context: context, navigationController: navigationController, peerId: root.peerId, threadId: Int64(root.id), messageId: atMessageId ?? (isReply ? message.id : nil))
            return .complete()
        }
    }

    /// `navigateToMessage` for a reply that collapsed reply threads hide from this chat: opens its thread at it.
    /// False when the message is not such a reply (normal navigation goes on).
    func mattermostNavigateToReplyInThread(messageId: EngineMessage.Id) -> Bool {
        guard MattermostBackend.isEnabled, case .peer = self.chatLocation else {
            return false
        }
        if case .scheduledMessages = self.presentationInterfaceState.subject {
            return false
        }
        guard let root = MattermostSync.collapsedThreadRoot(accountId: self.context.account.id, messageId: messageId), let navigationController = self.effectiveNavigationController else {
            return false
        }
        mattermostOpenThread(context: self.context, navigationController: navigationController, peerId: root.peerId, threadId: Int64(root.id), messageId: messageId)
        return true
    }
}

extension ChatControllerImpl {
    /// Reply (menu, swipe) in a chat whose history shows root posts only: the reply would vanish from it, so the
    /// message's thread opens with the composer instead, as Mattermost does. False otherwise.
    func mattermostReplyInThread(messageId: EngineMessage.Id) -> Bool {
        guard MattermostBackend.isEnabled, case let .peer(peerId) = self.chatLocation, MattermostBackend.mainHistoryTag(accountPeerId: self.context.account.peerId, peerId: peerId) != nil else {
            return false
        }
        guard messageId.namespace == Namespaces.Message.Cloud, let message = self.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId)?._asMessage(), let navigationController = self.effectiveNavigationController else {
            return false
        }
        let (root, isReply) = mattermostThreadRoot(of: message)
        mattermostOpenThread(context: self.context, navigationController: navigationController, peerId: root.peerId, threadId: Int64(root.id), messageId: isReply ? message.id : nil, activateInput: true)
        return true
    }
}

/// View Thread (on replies shown inline) and Follow / Unfollow Thread for a message's context menu.
func mattermostThreadContextMenuItems(context: AccountContext, chatLocation: ChatLocation, message: Message, controllerInteraction: ChatControllerInteraction, strings: PresentationStrings) -> [ContextMenuItem] {
    guard MattermostBackend.isEnabled, message.id.namespace == Namespaces.Message.Cloud else {
        return []
    }
    let (root, isReply) = mattermostThreadRoot(of: message)
    var hasThread = isReply
    if !hasThread, let attribute = message.attributes.first(where: { $0 is ReplyThreadMessageAttribute }) as? ReplyThreadMessageAttribute, attribute.count > 0 {
        hasThread = true
    }
    var items: [ContextMenuItem] = []
    // Telegram's own "View N Replies" covers roots in channels; replies (inline while collapsed threads are off)
    // open their thread at them.
    if isReply, case .peer = chatLocation {
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextViewThread, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Replies"), color: theme.actionSheet.primaryTextColor)
        }, action: { c, _ in
            c?.dismiss(completion: {
                controllerInteraction.openMessageReplies(message.id, true, true)
            })
        })))
    }
    let threadId = Int64(root.id)
    if hasThread || chatLocation.threadId == threadId, let following = MattermostSync.isFollowingThread(accountId: context.account.id, peerId: root.peerId, threadId: threadId) {
        items.append(.action(ContextMenuActionItem(text: following ? strings.Relay_Threads_Unfollow : strings.Relay_Threads_Follow, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: following ? "Chat/Context Menu/Muted" : "Chat/Context Menu/Unmute"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            mattermostSetFollowingThread(context: context, peerId: root.peerId, threadId: threadId, following: !following, present: { c in
                controllerInteraction.presentControllerInCurrent(c, nil)
            })
        })))
    }
    return items
}

func mattermostSetFollowingThread(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64, following: Bool, present: @escaping (ViewController) -> Void) {
    let _ = (MattermostSync.setFollowingThread(accountId: context.account.id, peerId: peerId, threadId: threadId, following: following)
    |> deliverOnMainQueue).startStandalone(next: { done in
        guard done else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let text = following ? presentationData.strings.Relay_Threads_Followed : presentationData.strings.Relay_Threads_Unfollowed
        present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    })
}
