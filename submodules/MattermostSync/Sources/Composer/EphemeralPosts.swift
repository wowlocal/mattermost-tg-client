import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Ephemeral posts (`ephemeral_message`: a slash command's or an integration's answer that only this user
/// sees) as local messages in their chat, as Mattermost's clients show them until a reload.
///
/// The message is a `Local` message without the unsent flag (nothing sends it; `PostSender` only takes unsent
/// ones), incoming and not counted as unread, in the post's thread when it has one. It is never on the server:
/// it has no reactions, no reply count and no buttons (actions need a stored post), and it is gone after a
/// relaunch (4F, `removeEphemeralMessages`), as Mattermost drops ephemeral posts when it reloads. Its author is the posting bot, a webhook-style override, or "System" for the server's own
/// answers (`system_ephemeral` from the user's own id), a bot user of its own without a chat.
extension MattermostAccountSync {
    static let systemAuthorKey = "system:ephemeral"
    static let ephemeralFooter = "(Only visible to you)"

    func writeEphemeralMessage(_ post: Post) async {
        guard let channelState = self.channelState(post.channelId) else {
            MMLog.log("live: ephemeral message in unknown channel \(post.channelId)")
            return
        }
        await self.ensureUsers([post.userId])
        let entries = post.rootId.isEmpty ? [:] : self.store.entries(channelId: post.channelId, postIds: [post.rootId])
        guard let context = self.conversionContext(channelId: post.channelId, entries: entries) else {
            return
        }
        // Render as a regular post (a `system_` type would become a service message).
        var visible = post
        visible.type = ""
        visible.fileIds = []
        visible.metadata = nil
        let converted = PostConverter.storeMessages(post: visible, localIds: [0: 0], context: context)
        guard let message = converted.messages.first else {
            return
        }
        let isSystem = post.type == "system_ephemeral" || post.userId == self.ownUserId || post.userId.isEmpty
        let peerId = channelState.peerId
        let written: Bool = await self.postbox.mmTransaction { transaction in
            var authorId = message.authorId
            if let override = self.writeOverridePeers([post], transaction: transaction)[post.id] {
                authorId = override
            } else if isSystem {
                authorId = self.systemAuthorPeer(transaction: transaction)
            }
            // Text plus the "only visible to you" line (italic); buttons are dropped.
            var text = message.text
            var attributes: [MessageAttribute] = message.attributes.filter { !($0 is ReplyMarkupMessageAttribute) && !($0 is ReactionsMessageAttribute) && !($0 is ReplyThreadMessageAttribute) }
            var entities = (attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
            attributes.removeAll(where: { $0 is TextEntitiesMessageAttribute })
            let footerStart = (text as NSString).length + (text.isEmpty ? 0 : 2)
            text += (text.isEmpty ? "" : "\n\n") + MattermostAccountSync.ephemeralFooter
            entities.append(MessageTextEntity(range: footerStart ..< (text as NSString).length, type: .Italic))
            attributes.append(TextEntitiesMessageAttribute(entities: entities))
            let storeMessage = StoreMessage(
                peerId: peerId,
                namespace: Namespaces.Message.Local,
                customStableId: nil,
                globallyUniqueId: Int64.random(in: 1 ..< Int64.max),
                groupingKey: nil,
                threadId: message.threadId,
                timestamp: max(message.timestamp, Int32(Date().timeIntervalSince1970) - 1),
                flags: [.Incoming, .NotCountedAsUnread],
                // A root-level answer shows in the channel's root-post history (collapsed reply threads, 3B).
                tags: message.tags.intersection(.mattermostRootPost),
                globalTags: [],
                localTags: [],
                forwardInfo: nil,
                authorId: authorId,
                text: text,
                attributes: attributes,
                media: message.media.filter { $0 is TelegramMediaImage }
            )
            let _ = transaction.addMessages([storeMessage], location: .Random)
            return true
        }
        if written {
            MMLog.log("live: ephemeral message in \(post.channelId)\(post.rootId.isEmpty ? "" : " (thread \(post.rootId))") shown as a local message")
        }
    }

    /// Removes the ephemeral messages of an earlier run (4F): Mattermost's clients keep them only until they reload.
    /// They are the only incoming `Local` messages (pending sends are outgoing), so no bookkeeping is needed.
    func removeEphemeralMessages() async {
        let removed: Int = await self.postbox.mmTransaction { transaction in
            var ids: [MessageId] = []
            for peerId in transaction.chatListGetAllPeerIds() {
                transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Local, { message in
                    if message.flags.contains(.Incoming) && message.flags.contains(.NotCountedAsUnread) && !message.flags.contains(.Unsent) {
                        ids.append(message.id)
                    }
                    return true
                })
            }
            if !ids.isEmpty {
                transaction.deleteMessages(ids, forEachMedia: nil)
            }
            return ids.count
        }
        if removed > 0 {
            MMLog.log("ephemeral: removed \(removed) message(s) of an earlier run")
        }
    }

    /// The "System" author of the server's own ephemeral answers: a bot user without a username (no chat,
    /// like webhook overrides, see `MattermostPostAuthors.isOverride`).
    func systemAuthorPeer(transaction: Transaction) -> PeerId? {
        guard let peer = self.store.allocatePeer(mattermostId: MattermostAccountSync.systemAuthorKey, kind: .user, teamId: nil) else {
            return nil
        }
        let peerId = MattermostPeerIds.userPeerId(peer.peerId)
        if transaction.getPeer(peerId) == nil {
            let user = TelegramUser(
                id: peerId,
                accessHash: .personal(0),
                firstName: "System",
                lastName: nil,
                username: nil,
                phone: nil,
                photo: [],
                botInfo: BotUserInfo(flags: [], inlinePlaceholder: nil),
                restrictionInfo: nil,
                flags: [],
                emojiStatus: nil,
                usernames: [],
                storiesHidden: nil,
                nameColor: nil,
                backgroundEmojiId: nil,
                profileColor: nil,
                profileBackgroundEmojiId: nil,
                subscriberCount: nil,
                verificationIconFileId: nil
            )
            updatePeersCustom(transaction: transaction, peers: [user], update: { _, updated in
                return updated
            })
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in
                return (current as? CachedUserData ?? CachedUserData())
                    .withUpdatedAbout("Messages from the Mattermost server that only you can see.")
                    .withUpdatedBusinessIntro(nil)
                    .withUpdatedPeerStatusSettings(PeerStatusSettings())
            })
        }
        return peerId
    }
}
