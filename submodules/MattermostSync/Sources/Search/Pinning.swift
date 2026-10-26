import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Pin and unpin from the message menu (Phase 3C): `POST /posts/{id}/pin` / `unpin`. The `.pinned` tag of the
/// post's primary message is set as soon as the server accepts it (the pinned bar and "Pinned Messages" list read
/// the tag); the server's `post_edited` echo (`is_pinned`) rewrites the message the same way, and pins made on
/// other clients arrive that way too (`applyEdited` also stores a pinned post that isn't loaded yet).
extension MattermostAccountSync {
    func setPinned(messageId: MessageId, pinned: Bool) async -> Bool {
        guard let reference = self.postReference(for: messageId) else {
            MMLog.log("pin: message \(messageId) has no post")
            return false
        }
        do {
            if pinned {
                try await self.client.pinPost(id: reference.postId)
            } else {
                try await self.client.unpinPost(id: reference.postId)
            }
        } catch {
            MMLog.log("pin: \(pinned ? "pin" : "unpin") \(reference.postId) failed: \(error)")
            if !(await MattermostSync.isSessionRejected(error, sync: self)) {
                self.notice(pinned ? MattermostNotice.pinFailed : MattermostNotice.unpinFailed)
            }
            return false
        }
        await self.applyPinnedLocally(channelId: reference.channelId, postId: reference.postId, pinned: pinned)
        MMLog.log("pin: \(pinned ? "pinned" : "unpinned") \(reference.postId) in \(reference.channelId)")
        return true
    }

    /// Unpins the chat's pinned posts (or the thread's, `threadId` = local id of its root).
    func unpinAll(peerId: PeerId, threadId: Int64?) async -> Bool {
        guard let channelId = self.channelId(forPeerId: peerId) else {
            return false
        }
        var rootPostId: String?
        if let threadId = threadId, let localId = Int32(exactly: threadId) {
            rootPostId = self.store.entries(channelId: channelId, fromLocalId: localId, ascending: true, limit: 1).first.flatMap { $0.localId == localId ? $0.serverPostId : nil }
        }
        do {
            var posts = try await self.client.pinnedPosts(channelId: channelId).orderedPosts
            if let rootPostId = rootPostId {
                posts = posts.filter { $0.id == rootPostId || $0.rootId == rootPostId }
            }
            for post in posts {
                try await self.client.unpinPost(id: post.id)
                await self.applyPinnedLocally(channelId: channelId, postId: post.id, pinned: false)
            }
            MMLog.log("pin: unpinned all \(posts.count) post(s) of \(channelId)")
            return true
        } catch {
            MMLog.log("pin: unpinning all of \(channelId) failed: \(error)")
            self.notice(.unpinAllFailed)
            return false
        }
    }

    /// Sets or clears the `.pinned` tag of a post's primary message.
    func applyPinnedLocally(channelId: String, postId: String, pinned: Bool) async {
        guard let peerId = self.channelState(channelId)?.peerId else {
            return
        }
        await self.postbox.mmTransaction { transaction in
            guard let entry = self.store.entries(channelId: channelId, postIds: [postId])[postId], !entry.isDeleted else {
                return
            }
            let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)
            transaction.updateMessage(id, update: { current in
                var tags = current.tags
                if pinned {
                    tags.insert(.pinned)
                } else {
                    tags.remove(.pinned)
                }
                if tags == current.tags {
                    return .skip
                }
                return .update(StoreMessage(
                    id: current.id,
                    customStableId: nil,
                    globallyUniqueId: current.globallyUniqueId,
                    groupingKey: current.groupingKey,
                    threadId: current.threadId,
                    timestamp: current.timestamp,
                    flags: StoreMessageFlags(current.flags),
                    tags: tags,
                    globalTags: current.globalTags,
                    localTags: current.localTags,
                    forwardInfo: current.forwardInfo.flatMap(StoreMessageForwardInfo.init),
                    authorId: current.author?.id,
                    text: current.text,
                    attributes: current.attributes,
                    media: current.media
                ))
            })
        }
    }
}
