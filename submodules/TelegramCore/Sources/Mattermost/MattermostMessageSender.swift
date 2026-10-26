import Foundation
import Postbox
import SwiftSignalKit

// MATTERMOST: the send and edit seam (docs/research/telegram-internals.md §5, "narrowest plug").
//
// While `MattermostBackend.isEnabled`, `PendingMessageManager` keeps all of its bookkeeping (message
// contexts, upload status and progress, delivered events, failing messages) and hands only the network
// part to this sender: uploading a message's media and creating the post. `PendingUpdateMessageManager`
// hands it text edits. MattermostSync implements it and installs it with `Account.mattermostSetMessageSender`.
// Messages that are unsent at launch wait until the sender is installed.

public enum MattermostSendError {
    /// The message can't be sent (rejected by the server); it is marked failed and can be resent.
    case generic
}

public protocol MattermostMessageSender: AnyObject {
    /// Uploads the media of an outgoing message (a `Local` message id). Emits upload progress in 0...1 and
    /// completes once every file is on the server. Only called for messages with media. Transient network
    /// errors are retried by the sender; an error fails the message.
    func uploadMedia(messageId: MessageId) -> Signal<Float, MattermostSendError>

    /// Creates the post of an outgoing message whose media is uploaded and rewrites the `Local` message into
    /// its `Cloud` message in Postbox (as `applyUpdateMessage` does for Telegram). Emits the `Cloud` id once
    /// and completes. Transient network errors are retried by the sender; an error fails the message.
    func sendMessage(messageId: MessageId) -> Signal<MessageId, MattermostSendError>

    /// Creates one post for a group of outgoing messages (an album or grouped files: one post with all their
    /// files) and rewrites the `Local` messages into the post's `Cloud` messages. Emits the `Cloud` ids once
    /// and completes; an error fails every message of the group.
    func sendMessageGroup(messageIds: [MessageId]) -> Signal<[MessageId], MattermostSendError>

    /// Edits the text of a sent message. Emits `.done` after the edited message is written to Postbox.
    func editMessage(messageId: MessageId, text: String, entities: TextEntitiesMessageAttribute?) -> Signal<RequestEditMessageResult, RequestEditMessageError>
}

public extension Account {
    /// Installs MattermostSync's sender for this account (sending and editing).
    func mattermostSetMessageSender(_ sender: MattermostMessageSender) {
        self.pendingMessageManager.mattermostSetSender(sender)
        self.pendingUpdateMessageManager.mattermostSetSender(sender)
    }
}
