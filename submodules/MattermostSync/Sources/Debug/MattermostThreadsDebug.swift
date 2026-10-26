import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Debug-only helpers for the collapsed-reply-threads checks (Phase 3B), used by TelegramUI's debug remote
/// commands (`RelayDebugScreens`). Release builds return nothing.
public extension MattermostSync {
    /// The chat matching a query (`firehose`, `engineering/town-square`, `dm:bob`, `saved`).
    static func debugChatPeerId(accountId: AccountRecordId, query: String) -> PeerId? {
        #if DEBUG
        guard let sync = self.sync(accountId: accountId), let channelId = sync.debugFindChannel(query) else {
            return nil
        }
        return sync.channelState(channelId)?.peerId
        #else
        return nil
        #endif
    }

    /// Writes `Documents/relay-debug/chatlist.json` now (as `RELAY_DEBUG_DUMP_CHATLIST=1` does at launch).
    static func debugDumpChatList(accountId: AccountRecordId) -> Signal<Bool, NoError> {
        #if DEBUG
        return self.signal {
            guard let sync = self.sync(accountId: accountId) else {
                return false
            }
            await sync.debugDumpChatList()
            return true
        }
        #else
        return .single(false)
        #endif
    }

    /// The (primary) message of a post, when mapped.
    static func debugMessageId(accountId: AccountRecordId, postId: String) -> MessageId? {
        #if DEBUG
        guard let sync = self.sync(accountId: accountId) else {
            return nil
        }
        for channelState in sync.state.with({ Array($0.channels.values) }) {
            if let entry = sync.store.entries(channelId: channelState.channel.id, postIds: [postId])[postId], !entry.isDeleted {
                return MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// The post of a message (its server post for a part of a multi-file post).
    static func debugPostId(accountId: AccountRecordId, messageId: MessageId) -> String? {
        #if DEBUG
        guard let sync = self.sync(accountId: accountId), let channelId = sync.channelId(forPeerId: messageId.peerId) else {
            return nil
        }
        guard let entry = sync.store.entries(channelId: channelId, fromLocalId: messageId.id, ascending: true, limit: 1).first, entry.localId == messageId.id else {
            return nil
        }
        return entry.serverPostId
        #else
        return nil
        #endif
    }

    /// Loads a thread as its thread view does (a Postbox view of the thread, whose hole the hole filler fills),
    /// then compares the stored thread with the server's (`GET /posts/{root}/thread`, every page): missing,
    /// extra and duplicate posts, id order against `create_at` order. Also writes
    /// `Documents/relay-debug/thread-<root>.json`.
    static func debugCheckThread(accountId: AccountRecordId, rootPostId: String) -> Signal<[String: Any], NoError> {
        #if DEBUG
        return self.signal {
            guard let sync = await self.waitForRunningSync(accountId: accountId) else {
                return ["error": "no sync"]
            }
            return await sync.debugCheckThread(rootPostId: rootPostId)
        }
        #else
        return .single([:])
        #endif
    }
}

#if DEBUG
extension MattermostAccountSync {
    func debugCheckThread(rootPostId: String) async -> [String: Any] {
        guard let root = try? await self.client.post(id: rootPostId), let channelState = self.channelState(root.channelId) else {
            return ["error": "root \(rootPostId) not found"]
        }
        guard let rootLocalId = await self.notificationLocalId(postId: rootPostId, channelId: root.channelId) else {
            return ["error": "root \(rootPostId) not mapped"]
        }
        let peerId = channelState.peerId
        let threadId = Int64(rootLocalId)
        let started = CFAbsoluteTimeGetCurrent()
        let view = self.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: threadId), anchor: .upperBound, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: Set(), count: 100, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: nil, appendMessagesFromTheSameGroup: false, namespaces: .not(Namespaces.Message.allNonRegular), orderStatistics: []).start()
        var holes = IndexSet(integersIn: 1 ..< 2)
        while CFAbsoluteTimeGetCurrent() - started < 30.0 {
            holes = await self.postbox.mmTransaction { transaction in
                return transaction.getThreadIndexHoles(peerId: peerId, threadId: threadId, namespace: Namespaces.Message.Cloud)
            }
            if holes.isEmpty {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        view.dispose()
        let fillMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)

        // The server's thread, every page.
        var serverPosts: [Post] = []
        var seen = Set<String>()
        var fromPost: Post?
        for _ in 0 ..< 100 {
            guard let list = try? await self.client.postThread(postId: rootPostId, options: PostThreadOptions(perPage: 200, fromPost: fromPost?.id, fromCreateAt: fromPost?.createAt, direction: .down)) else {
                return ["error": "server thread not loaded"]
            }
            let page = list.orderedPosts.filter { seen.insert($0.id).inserted }
            serverPosts.append(contentsOf: page)
            let replies = page.filter { $0.id != rootPostId }
            guard list.hasNext == true, let newest = replies.max(by: { ($0.createAt, $0.id) < ($1.createAt, $1.id) }) else {
                break
            }
            fromPost = newest
        }
        let serverReplies = serverPosts.filter { $0.id != rootPostId && $0.deleteAt == 0 }.sorted(by: { ($0.createAt, $0.id) < ($1.createAt, $1.id) })

        let local: (posts: [String], messageCount: Int, outOfOrder: Int, rootStored: Bool) = await self.postbox.mmTransaction { transaction in
            var messages: [Message] = []
            transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, { message in
                if message.threadId == threadId {
                    messages.append(message)
                }
                return true
            })
            messages.sort(by: { $0.id.id < $1.id.id })
            var outOfOrder = 0
            for i in 1 ..< max(1, messages.count) where messages[i].timestamp < messages[i - 1].timestamp {
                outOfOrder += 1
            }
            var posts: [String] = []
            for message in messages {
                if let entry = self.store.entries(channelId: root.channelId, fromLocalId: message.id.id, ascending: true, limit: 1).first, entry.localId == message.id.id {
                    posts.append(entry.serverPostId)
                } else {
                    posts.append("?\(message.id.id)")
                }
            }
            let rootStored = transaction.messageExists(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: rootLocalId))
            return (posts, messages.count, outOfOrder, rootStored)
        }
        // A multi-file reply is several messages of one post.
        var uniqueLocal: [String] = []
        var lastPost: String?
        var duplicates = 0
        for post in local.posts {
            if post == lastPost {
                continue
            }
            if uniqueLocal.contains(post) {
                duplicates += 1
            }
            uniqueLocal.append(post)
            lastPost = post
        }
        let serverIds = serverReplies.map { $0.id }
        let missing = serverIds.filter { !uniqueLocal.contains($0) }
        let extra = uniqueLocal.filter { !serverIds.contains($0) }
        let report: [String: Any] = [
            "rootPostId": rootPostId,
            "channelId": root.channelId,
            "peerId": "\(peerId.toInt64())",
            "threadId": threadId,
            "rootStored": local.rootStored,
            "fillMs": fillMs,
            "threadHolesLeft": holes.rangeView.map { "\($0.lowerBound)...\($0.upperBound - 1)" },
            "serverReplies": serverIds.count,
            "localReplyPosts": uniqueLocal.count,
            "localMessages": local.messageCount,
            "missing": missing,
            "extra": extra,
            "duplicates": duplicates,
            "outOfTimestampOrder": local.outOfOrder,
            "sameOrderAsServer": uniqueLocal == serverIds
        ]
        MMLog.log("debug: thread \(rootPostId): \(report)")
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("relay-debug")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("thread-\(rootPostId).json"))
        } catch {
            MMLog.log("debug: thread report not written: \(error)")
        }
        return report
    }
}
#endif
