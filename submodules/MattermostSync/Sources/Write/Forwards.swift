import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// 4H: why a forward can't go where it was asked to (Mattermost's rule, web app 11.7): posts of private channels,
/// DMs and GMs can only be forwarded within their own channel, since nobody else could open the preview.
public enum MattermostForwardRestriction: Equatable {
    /// "This message is from a private channel and can only be shared with ~<channel>".
    case privateChannel
    /// "This message is from a private conversation and can only be shared with <participants>".
    case privateConversation
}

/// 4H: Telegram's Forward as Mattermost's forward. A forwarded message that shows its sender's name goes as the web
/// app's forward: a post whose message is the forwarded post's permalink (`PermalinkForward`), no files copied; every
/// Mattermost client previews it, and Relay shows it as a forwarded message (`ForwardedPost`). "Hide Sender Name"
/// (Telegram's copy) and forwards Mattermost doesn't allow (a private post into another chat, through a path that
/// didn't ask: the share sheet) go as copies, as before.
public enum MattermostForwards {
    /// Whether messages of `sourcePeerId` may be forwarded (with their sender's name) to `targetPeerIds`; nil when
    /// they may. The forward picker asks before it forwards.
    public static func restriction(accountId: AccountRecordId, sourcePeerId: PeerId, targetPeerIds: [PeerId]) -> MattermostForwardRestriction? {
        guard let sync = MattermostSync.sync(accountId: accountId), let sourceChannelId = sync.channelId(forPeerId: sourcePeerId), let source = sync.channelState(sourceChannelId) else {
            return nil
        }
        if case .publicChannel = source.channel.type {
            return nil
        }
        guard targetPeerIds.contains(where: { $0 != sourcePeerId }) else {
            return nil
        }
        if case .privateChannel = source.channel.type {
            return .privateChannel
        }
        return .privateConversation
    }
}

extension MattermostAccountSync {
    /// The permalink a forwarded message is sent as, or nil to send a copy: Telegram's forward with the sender's
    /// name (`forwardInfo`) of a stored post, allowed by Mattermost's rule into `channelId`. A forward of a forward
    /// links the post it shows when that post is stored.
    func forwardPermalink(of message: Message, channelId: String, transaction: Transaction) -> String? {
        guard message.forwardInfo != nil, let attribute = message.attributes.first(where: { $0 is ForwardSourceInfoAttribute }) as? ForwardSourceInfoAttribute else {
            return nil
        }
        var sourceId = attribute.messageId
        if let source = transaction.getMessage(sourceId), let inner = source.forwardInfo?.sourceMessageId {
            sourceId = inner
        }
        guard let reference = self.postReference(for: sourceId), let sourceState = self.channelState(reference.channelId) else {
            return nil
        }
        guard PermalinkForward.canForward(sourceChannelType: sourceState.channel.type.rawValue, sourceChannelId: reference.channelId, targetChannelId: channelId) else {
            MMLog.log("forward: \(reference.postId) of a \(sourceState.channel.type.rawValue) channel goes to another chat as a copy")
            return nil
        }
        return self.permalink(channelId: reference.channelId, postId: reference.postId)
    }

    /// A message that goes as a permalink forward uploads nothing.
    func isPermalinkForward(_ messageId: MessageId) async -> Bool {
        guard let channelId = self.channelId(forPeerId: messageId.peerId) else {
            return false
        }
        return await self.postbox.mmTransaction { transaction -> Bool in
            guard let message = transaction.getMessage(messageId) else {
                return false
            }
            return self.forwardPermalink(of: message, channelId: channelId, transaction: transaction) != nil
        }
    }

    /// Posts from `POST /posts/ids` (which never has embeds) that are plain forwards, fetched on their own so they
    /// keep their forwarded content (`ForwardedPost.lacksPreview`); the others as they are.
    func withForwardPreviews(_ posts: [Post]) async -> [Post] {
        var result = posts
        for (index, post) in posts.enumerated() where ForwardedPost.lacksPreview(post) {
            if let full = try? await self.client.post(id: post.id) {
                result[index] = full
            }
        }
        return result
    }
}
