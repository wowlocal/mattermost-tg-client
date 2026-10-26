import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// One unit of posts to write (design: "Writing a page of posts", shared by bootstrap, hole fill, catch-up
/// and live events).
struct PageWrite {
    enum Kind {
        /// `GET /channels/{id}/posts` without a cursor. `reachedStart`: the page holds the first post.
        case latest(reachedStart: Bool)
        /// `before=anchor`.
        case older(anchor: String, reachedStart: Bool)
        /// `after=anchor`.
        case newer(anchor: String, reachedLatest: Bool)
        /// Permalink: the target plus the posts around it.
        case around(target: String, olderReachedStart: Bool, newerReachedLatest: Bool)
        /// Posts not known to be contiguous (live events, catch-up, threads): each placed on its own.
        case singles
    }

    var channelId: String
    var kind: Kind
    /// The contiguous run (any order).
    var run: [Post]
    /// Posts outside the run, e.g. thread roots of replies in the page; placed one by one.
    var extra: [Post] = []
    /// The Postbox hole range the request asked for; holes inside it are synced with the ID map.
    var requestedRange: ClosedRange<Int32>?
    /// Reset the read state from the server counters afterwards (bootstrap, catch-up).
    var resetReadState: Bool = false
}

struct PageWriteResult {
    var islandRange: ClosedRange<Int32>?
    var insertedCount = 0
    var renumberedCount = 0
    var writtenCount = 0
    var failed = false
}

extension MattermostAccountSync {
    var maxLocalId: Int32 {
        return Int32.max - 1
    }

    /// Allocates ids, writes the messages and syncs the holes, all inside the caller's Postbox transaction.
    @discardableResult
    func write(_ page: PageWrite, transaction: Transaction) -> PageWriteResult {
        var result = PageWriteResult()
        guard let channelState = self.channelState(page.channelId) else {
            MMLog.log("write: unknown channel \(page.channelId)")
            result.failed = true
            return result
        }
        let channelId = page.channelId
        var store = self.storeRef()
        var touched: [ClosedRange<Int32>] = []
        if let requestedRange = page.requestedRange {
            touched.append(requestedRange)
        }

        // 1. ID map, as one SQLite transaction. Every post brings its parts (one message per file).
        let runKeys = postKeys(page.run)
        var ingests: [IngestResult] = []
        var mainIngest: IngestResult?
        if case let .around(target, _, _) = page.kind, !page.run.contains(where: { $0.id == target }) {
            MMLog.log("write: permalink target \(target) missing from its page")
            result.failed = true
            return result
        }
        let error = self.store.idMapTransaction {
            switch page.kind {
            case let .latest(reachedStart):
                mainIngest = try self.allocator.ingestLatestPage(runKeys, reachedStart: reachedStart, channelId: channelId, store: &store)
            case let .older(anchor, reachedStart):
                mainIngest = try self.allocator.ingestPage(runKeys, extending: anchor, direction: .older, reachedEnd: reachedStart, channelId: channelId, store: &store)
            case let .newer(anchor, reachedLatest):
                mainIngest = try self.allocator.ingestPage(runKeys, extending: anchor, direction: .newer, reachedEnd: reachedLatest, channelId: channelId, store: &store)
            case let .around(target, olderReachedStart, newerReachedLatest):
                let targetPost = page.run.first(where: { $0.id == target })!
                let targetKey = PostOrderKey(createAt: targetPost.createAt, postId: targetPost.id)
                let older = runKeys.filter { $0 < targetKey }
                let newer = runKeys.filter { targetKey < $0 }
                mainIngest = try self.allocator.ingestAround(target: targetKey, older: older, newer: newer, olderReachedStart: olderReachedStart, newerReachedLatest: newerReachedLatest, channelId: channelId, store: &store)
            case .singles:
                for post in page.run.filter({ $0.deleteAt == 0 }).sorted(by: { PostOrderKey(createAt: $0.createAt, postId: $0.id) < PostOrderKey(createAt: $1.createAt, postId: $1.id) }) {
                    ingests.append(try self.allocator.insertPost(PostOrderKey(createAt: post.createAt, postId: post.id), partCount: PostLayout.partCount(post), channelId: channelId, store: &store))
                }
            }
            if let mainIngest = mainIngest {
                ingests.insert(mainIngest, at: 0)
            }
            for post in page.extra where post.deleteAt == 0 {
                ingests.append(try self.allocator.insertPost(PostOrderKey(createAt: post.createAt, postId: post.id), partCount: PostLayout.partCount(post), channelId: channelId, store: &store))
            }
        }
        if let error = error {
            MMLog.log("write: allocation failed in \(channelId): \(error)")
            result.failed = true
            return result
        }

        // 2. Postbox: renumber plans in the order they were made, then the messages and holes.
        for ingest in ingests {
            if let plan = ingest.renumberPlan, !plan.moves.isEmpty {
                self.applyRenumber(plan, channelId: channelId, channelState: channelState, transaction: transaction)
                touched.append(plan.affectedRange)
                result.renumberedCount += plan.moves.count
            }
            if let islandRange = ingest.islandRange {
                touched.append(islandRange)
            }
            result.insertedCount += ingest.insertedCount
        }
        if let mainIngest = mainIngest {
            result.islandRange = mainIngest.islandRange
            switch page.kind {
            case let .latest(reachedStart):
                if let islandRange = mainIngest.islandRange {
                    touched.append(islandRange.lowerBound ... self.maxLocalId)
                    if reachedStart {
                        touched.append(1 ... islandRange.upperBound)
                    }
                } else {
                    // An empty channel: nothing to load anywhere.
                    touched.append(1 ... self.maxLocalId)
                    self.state.with { _ = $0.emptyChannels.insert(channelId) }
                }
            case let .older(_, reachedStart):
                if reachedStart, let islandRange = mainIngest.islandRange {
                    touched.append(1 ... islandRange.upperBound)
                }
            case let .newer(_, reachedLatest):
                if reachedLatest, let islandRange = mainIngest.islandRange {
                    touched.append(islandRange.lowerBound ... self.maxLocalId)
                }
            case let .around(_, olderReachedStart, newerReachedLatest):
                if let islandRange = mainIngest.islandRange {
                    if olderReachedStart {
                        touched.append(1 ... islandRange.upperBound)
                    }
                    if newerReachedLatest {
                        touched.append(islandRange.lowerBound ... self.maxLocalId)
                    }
                }
            case .singles:
                break
            }
        }

        result.writtenCount = self.writeMessages(channelId: channelId, posts: page.run + page.extra, transaction: transaction)
        self.syncHoles(channelId: channelId, channelState: channelState, ranges: touched, transaction: transaction)
        if page.resetReadState {
            self.applyServerReadState(channelId: channelId, transaction: transaction)
        }
        return result
    }

    /// Converts and stores every live, mapped post (insert or update in place), one message per part
    /// (`PostLayout`). Returns the message count.
    @discardableResult
    func writeMessages(channelId: String, posts: [Post], transaction: Transaction) -> Int {
        if posts.isEmpty {
            return 0
        }
        var seen = Set<String>()
        let unique = posts.filter { seen.insert($0.id).inserted }
        self.reconcileParts(channelId: channelId, posts: unique, transaction: transaction)

        let layouts = unique.map { PostLayout(post: $0) }
        var lookupIds: [String] = []
        for (post, layout) in zip(unique, layouts) {
            lookupIds.append(contentsOf: PostOrderKey(createAt: post.createAt, postId: post.id).parts(count: layout.count).map { $0.postId })
            if !post.rootId.isEmpty {
                lookupIds.append(post.rootId)
            }
        }
        let entries = self.store.entries(channelId: channelId, postIds: lookupIds)
        guard var context = self.conversionContext(channelId: channelId, entries: entries) else {
            return 0
        }
        let overrides = self.writeOverridePeers(unique, transaction: transaction)
        context.authorOverride = { post in
            return overrides[post.id]
        }
        let chatPeerId = context.chatPeerId
        context.existingReplyThread = { localId in
            return transaction.getMessage(MessageId(peerId: chatPeerId, namespace: Namespaces.Message.Cloud, id: localId))?.attributes.first(where: { $0 is ReplyThreadMessageAttribute }) as? ReplyThreadMessageAttribute
        }
        var messages: [StoreMessage] = []
        var customEmojiFiles: [Int64: TelegramMediaFile] = [:]
        var threadRoots: [String: String] = [:]
        var reactionNames: [String] = []
        for (post, layout) in zip(unique, layouts) {
            guard post.deleteAt == 0, let entry = entries[post.id], !entry.isDeleted else {
                continue
            }
            var localIds: [Int: Int32] = [:]
            for (index, key) in PostOrderKey(createAt: post.createAt, postId: post.id).parts(count: layout.count).enumerated() {
                if let part = entries[key.postId], !part.isDeleted {
                    localIds[index] = part.localId
                    if !post.rootId.isEmpty {
                        threadRoots[key.postId] = post.rootId
                    }
                }
            }
            let converted = PostConverter.storeMessages(post: post, localIds: localIds, context: context)
            messages.append(contentsOf: converted.messages)
            reactionNames.append(contentsOf: (post.metadata?.reactions ?? []).map { $0.emojiName })
            for file in converted.customEmojiFiles {
                customEmojiFiles[file.fileId.id] = file
            }
        }
        self.store.setThreadRootIds(threadRoots, channelId: channelId)
        if !reactionNames.isEmpty {
            self.noteReactionEmoji(names: reactionNames, transaction: transaction)
        }
        for file in customEmojiFiles.values {
            transaction.storeMediaIfNotPresent(media: file)
        }
        let _ = transaction.addMessages(messages, location: .Random)
        return messages.count
    }

    /// Makes the id map hold exactly each post's current parts: posts mapped with fewer parts (an edit added
    /// files, or the post was mapped before it had parts) get the missing ones; parts beyond the current
    /// count (an edit removed files) are tombstoned and their messages deleted.
    private func reconcileParts(channelId: String, posts: [Post], transaction: Transaction) {
        var expectedIds: [String] = []
        var counts: [String: Int] = [:]
        for post in posts where post.deleteAt == 0 {
            let count = PostLayout.partCount(post)
            counts[post.id] = count
            // The parts it should have, and the one after them (present when it had more).
            expectedIds.append(contentsOf: PostOrderKey(createAt: post.createAt, postId: post.id).parts(count: count + 1).map { $0.postId })
        }
        if expectedIds.isEmpty {
            return
        }
        let entries = self.store.entries(channelId: channelId, postIds: expectedIds)
        var grow: [Post] = []
        var shrink: [(postId: String, keeping: Int)] = []
        for post in posts {
            guard let count = counts[post.id], let entry = entries[post.id], !entry.isDeleted else {
                continue
            }
            let key = PostOrderKey(createAt: post.createAt, postId: post.id)
            if (1 ..< max(1, count)).contains(where: { entries[key.part($0).postId] == nil }) {
                grow.append(post)
            }
            if count < PostParts.maximumCount, let extra = entries[key.part(count).postId], !extra.isDeleted {
                shrink.append((post.id, count))
            }
        }
        if grow.isEmpty && shrink.isEmpty {
            return
        }
        guard let channelState = self.channelState(channelId) else {
            return
        }
        var store = self.storeRef()
        var ingests: [IngestResult] = []
        var removed: [MessageIdEntry] = []
        let error = self.store.idMapTransaction {
            for post in grow {
                ingests.append(try self.allocator.insertPost(PostOrderKey(createAt: post.createAt, postId: post.id), partCount: counts[post.id] ?? 1, channelId: channelId, store: &store))
            }
            for item in shrink {
                removed.append(contentsOf: self.allocator.removeParts(postId: item.postId, keeping: item.keeping, channelId: channelId, store: &store))
            }
        }
        if let error = error {
            MMLog.log("write: parts of \(grow.count + shrink.count) post(s) in \(channelId) failed: \(error)")
            return
        }
        var touched: [ClosedRange<Int32>] = []
        for ingest in ingests {
            if let plan = ingest.renumberPlan, !plan.moves.isEmpty {
                self.applyRenumber(plan, channelId: channelId, channelState: channelState, transaction: transaction)
                touched.append(plan.affectedRange)
            }
            if let islandRange = ingest.islandRange {
                touched.append(islandRange)
            }
        }
        if !removed.isEmpty {
            transaction.deleteMessages(removed.map { MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: $0.localId) }, forEachMedia: nil)
        }
        self.syncHoles(channelId: channelId, channelState: channelState, ranges: touched, transaction: transaction)
        MMLog.log("write: parts of \(channelId): \(grow.count) post(s) grew, \(shrink.count) shrank (\(removed.count) removed)")
    }

    /// Makes Postbox's holes inside `ranges` equal to the ID map's holes (the fill contract: a request
    /// always removes at least the part of its range that is now loaded, so it never repeats unchanged).
    func syncHoles(channelId: String, channelState: ChannelState, ranges: [ClosedRange<Int32>], transaction: Transaction) {
        let clipped = ranges.compactMap { range -> ClosedRange<Int32>? in
            let lower = max(1, range.lowerBound)
            let upper = min(self.maxLocalId, range.upperBound)
            return lower <= upper ? lower ... upper : nil
        }
        if clipped.isEmpty {
            return
        }
        let storeRef = self.storeRef()
        // With nothing mapped there is nothing left to load (an empty channel): never re-add the full hole.
        let holes = storeRef.islands(channelId: channelId).isEmpty ? [] : self.allocator.holes(channelId: channelId, store: storeRef).map { $0.range }
        var threadIds: [Int64?] = [nil]
        if channelState.kind == .saved {
            threadIds.append(self.ownPeerId.toInt64())
        }
        let completeTagSpaces = self.state.with { $0.completeTagSpaces[channelId] ?? [] }
        let reservedIds = self.state.with { $0.reservedJumpIds[channelId] ?? [] }
        for range in mergeRanges(clipped) {
            for threadId in threadIds {
                transaction.removeHole(peerId: channelState.peerId, threadId: threadId, namespace: Namespaces.Message.Cloud, space: .everywhere, range: range)
                for hole in holes {
                    let lower = max(hole.lowerBound, range.lowerBound)
                    let upper = min(hole.upperBound, range.upperBound)
                    if lower <= upper {
                        transaction.addHole(peerId: channelState.peerId, threadId: threadId, namespace: Namespaces.Message.Cloud, space: .everywhere, range: lower ... upper)
                    }
                }
            }
            for id in reservedIds where range.contains(id) {
                let messageId = MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: id)
                if transaction.messageExists(id: messageId) {
                    self.state.with { _ = $0.reservedJumpIds[channelId]?.remove(id) }
                } else {
                    transaction.addHole(peerId: channelState.peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: id ... id)
                }
            }
            // Re-added `.everywhere` holes also reach every tag space; some are complete (see `fillHole`).
            for bit in 0 ..< 32 {
                let tag = MessageTags(rawValue: UInt32(1) << UInt32(bit))
                if completeTagSpaces.contains(tag) {
                    transaction.removeHole(peerId: channelState.peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .tag(tag), range: range)
                }
            }
        }
    }

    /// Applies an allocator renumber plan to Postbox: moved messages are deleted and re-inserted at their new
    /// ids, then every stored local id that points at a moved post is remapped: thread ids and reply
    /// references of replies, and the read state (whose counters a delete/re-insert would otherwise change).
    func applyRenumber(_ plan: RenumberPlan, channelId: String, channelState: ChannelState, transaction: Transaction) {
        let peerId = channelState.peerId
        var newIdByOldId: [Int32: Int32] = [:]
        for move in plan.moves {
            newIdByOldId[move.from] = move.to
        }
        func remap(_ id: Int32) -> Int32 {
            return newIdByOldId[id] ?? id
        }
        func remapThreadId(_ threadId: Int64?) -> Int64? {
            guard let threadId = threadId, channelState.kind != .saved, threadId != 1, let id = Int32(exactly: threadId) else {
                return threadId
            }
            return Int64(remap(id))
        }
        func remapAttributes(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
            return attributes.map { attribute -> MessageAttribute in
                guard let reply = attribute as? ReplyMessageAttribute, reply.messageId.peerId == peerId, reply.messageId.namespace == Namespaces.Message.Cloud else {
                    return attribute
                }
                let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: remap(reply.messageId.id))
                let threadMessageId = reply.threadMessageId.map { MessageId(peerId: $0.peerId, namespace: $0.namespace, id: remap($0.id)) }
                return ReplyMessageAttribute(messageId: messageId, threadMessageId: threadMessageId, quote: reply.quote, isQuote: reply.isQuote, innerSubject: reply.innerSubject)
            }
        }

        // Read everything before changing anything: ids can be swapped between moved posts.
        let readStates = transaction.getPeerReadStates(peerId)
        var moved: [(message: Message, newId: Int32)] = []
        for move in plan.moves {
            if let message = transaction.getMessage(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: move.from)) {
                moved.append((message, move.to))
            }
        }
        // Replies of moved roots that stay where they are. The store already has the new ids, which equal the
        // old ones for posts that did not move.
        let movedPostIds = Set(plan.moves.map { $0.postId })
        var dependentIds: [MessageId] = []
        for (_, replies) in self.store.threadReplies(rootPostIds: plan.moves.map { $0.postId }, channelId: channelId) {
            for entry in replies where !entry.isDeleted && !movedPostIds.contains(entry.postId) {
                dependentIds.append(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
            }
        }

        transaction.deleteMessages(moved.map { $0.message.id }, forEachMedia: nil)
        let reinserted = moved.map { item -> StoreMessage in
            return StoreMessage.mmCopy(of: item.message, id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: item.newId), threadId: remapThreadId(item.message.threadId), attributes: remapAttributes(item.message.attributes))
        }
        let _ = transaction.addMessages(reinserted, location: .Random)
        for id in dependentIds {
            transaction.updateMessage(id, update: { current in
                return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: remapThreadId(current.threadId), attributes: remapAttributes(current.attributes)))
            })
        }

        if let readStates = readStates {
            var remapped: [MessageId.Namespace: PeerReadState] = [:]
            for (namespace, readState) in readStates {
                if namespace == Namespaces.Message.Cloud, case let .idBased(maxIncomingReadId, maxOutgoingReadId, maxKnownId, count, markedUnread) = readState {
                    remapped[namespace] = .idBased(maxIncomingReadId: remap(maxIncomingReadId), maxOutgoingReadId: remap(maxOutgoingReadId), maxKnownId: remap(maxKnownId), count: count, markedUnread: markedUnread)
                } else {
                    remapped[namespace] = readState
                }
            }
            transaction.resetIncomingReadStates([peerId: remapped])
        }
        self.applyMentionCount(self.channelState(channelId)?.mentionCount ?? channelState.mentionCount, peerId: peerId, transaction: transaction)
        MMLog.log("renumbered \(plan.moves.count) posts in \(channelId) (\(moved.count) stored, \(dependentIds.count) replies remapped), range \(plan.affectedRange)")
    }
}

func mergeRanges(_ ranges: [ClosedRange<Int32>]) -> [ClosedRange<Int32>] {
    let sorted = ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
    var result: [ClosedRange<Int32>] = []
    for range in sorted {
        if let last = result.last, Int64(range.lowerBound) <= Int64(last.upperBound) + 1 {
            result[result.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
        } else {
            result.append(range)
        }
    }
    return result
}
