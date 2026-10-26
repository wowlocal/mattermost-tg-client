import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// A post ready for `POST /posts`.
struct OutgoingDraft {
    var post: PostDraft
    var globallyUniqueId: Int64
}

extension MattermostAccountSync {
    // MARK: Lookups

    func messageExists(_ id: MessageId) async -> Bool {
        return await self.postbox.mmTransaction { transaction in
            return transaction.messageExists(id: id)
        }
    }

    func messageHasMedia(_ id: MessageId) async -> Bool {
        return await self.postbox.mmTransaction { transaction in
            return transaction.getMessage(id)?.media.contains(where: { $0 is TelegramMediaImage || $0 is TelegramMediaFile }) ?? false
        }
    }

    /// The post of a Cloud message, from the ID map. Every message of a multi-file post (`PostParts`) gives
    /// the post.
    func postReference(for messageId: MessageId) -> (channelId: String, postId: String)? {
        guard messageId.namespace == Namespaces.Message.Cloud, let channelId = self.channelId(forPeerId: messageId.peerId) else {
            return nil
        }
        guard let entry = self.store.entries(channelId: channelId, fromLocalId: messageId.id, ascending: true, limit: 1).first, entry.localId == messageId.id, !entry.isDeleted else {
            return nil
        }
        return (channelId, entry.serverPostId)
    }

    /// The primary message of the post a Cloud message belongs to (the message itself for most posts): it
    /// carries the post's reactions and reply count.
    func primaryMessageId(for messageId: MessageId) -> MessageId? {
        guard let reference = self.postReference(for: messageId), let entry = self.store.entries(channelId: reference.channelId, postIds: [reference.postId])[reference.postId], !entry.isDeleted else {
            return nil
        }
        return MessageId(peerId: messageId.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)
    }

    /// The thread root post of a reply target: our replies always point at their root, so a target that is
    /// itself a reply gives its root.
    func threadRootPostId(replyTarget: MessageId, transaction: Transaction) -> String? {
        var rootId = replyTarget
        if let target = transaction.getMessage(replyTarget), let reply = target.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute, reply.messageId.peerId == replyTarget.peerId, reply.messageId.namespace == Namespaces.Message.Cloud {
            rootId = reply.messageId
        }
        return self.postReference(for: rootId)?.postId
    }

    /// The path of a resource's complete data, fetching it first if needed (photo library, local files,
    /// another post's file for a forward).
    func completeResourcePath(_ resource: MediaResource, timeoutSeconds: Double = 120.0) async throws -> String {
        let mediaBox = self.postbox.mediaBox
        let fetchSignal = fetchedMediaResource(mediaBox: mediaBox, userLocation: .other, userContentType: .other, reference: .standalone(resource: resource))
        let fallback = MediaResourceData(path: "", offset: 0, size: 0, complete: false)
        let dataSignal: Signal<MediaResourceData, NoError> = mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false))
        |> filter { data in
            return data.complete
        }
        |> take(1)
        |> timeout(timeoutSeconds, queue: Queue.concurrentDefaultQueue(), alternate: .single(fallback))
        let path: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resumed = Atomic<Bool>(value: false)
            let fetch = MetaDisposable()
            fetch.set(fetchSignal.start())
            let _ = dataSignal.start(next: { data in
                if !resumed.swap(true) {
                    fetch.dispose()
                    continuation.resume(returning: data.complete ? data.path : nil)
                }
            })
        }
        guard let path = path, !path.isEmpty else {
            throw SendFailure.missingData
        }
        return path
    }

    // MARK: Retries

    /// Runs `body`, retrying transient errors (offline, server down, 5xx, 429) with a backoff of up to 5 s,
    /// sooner once the WebSocket reconnects, for as long as `isStillWanted` holds.
    @discardableResult
    func retryingTransient<T>(_ what: String, isStillWanted: () async -> Bool, _ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let error as MattermostError where error.isTransient {
                attempt += 1
                let isWanted = await isStillWanted()
                if Task.isCancelled || !isWanted || self.isStopped {
                    throw error
                }
                let delay = min(5.0, 0.5 * pow(2.0, Double(min(attempt, 4))))
                if attempt == 1 || attempt % 10 == 0 {
                    MMLog.log("\(what): \(describeError(error)); retrying (attempt \(attempt))")
                }
                await self.waitForReconnect(maxDelay: delay)
            }
        }
    }

    /// Sleeps up to `maxDelay` seconds, returning early when the WebSocket (re)connects.
    func waitForReconnect(maxDelay: Double) async {
        let generation = self.connectionGeneration.current
        let deadline = CFAbsoluteTimeGetCurrent() + maxDelay
        while CFAbsoluteTimeGetCurrent() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if self.connectionGeneration.current != generation {
                return
            }
        }
    }

    /// The channel of a chat, creating the DM channel for a user without one yet (a new chat started from
    /// the compose screen).
    func ensureChannel(forPeerId peerId: PeerId) async -> String? {
        if let channelId = self.channelId(forPeerId: peerId) {
            return channelId
        }
        guard peerId.namespace == Namespaces.Peer.CloudUser, let user = self.store.peer(namespace: .user, peerId: peerId.id._internalGetInt64Value()) else {
            return nil
        }
        do {
            let channel = try await self.retryingTransient("direct channel with \(user.mattermostId)", isStillWanted: { true }) {
                try await self.client.createDirectChannel(userId: self.ownUserId, otherUserId: user.mattermostId)
            }
            await self.refreshChannel(channel.id)
            MMLog.log("send: created DM channel \(channel.id) with \(user.mattermostId)")
        } catch {
            MMLog.log("send: could not create the DM channel with \(user.mattermostId): \(error)")
        }
        return self.channelId(forPeerId: peerId)
    }

    // MARK: Building the post

    /// The `POST /posts` body of an outgoing message (or of a group of messages sent as one post: an album),
    /// and its `pending` row (registered here, before the request, so the WebSocket echo is always
    /// recognized). The first message of a group stands for it. Nil when the messages are gone.
    func outgoingDraft(messageId: MessageId, fileIds: [String], groupMessageIds: [MessageId] = []) async -> OutgoingDraft? {
        return await self.postbox.mmTransaction { transaction -> OutgoingDraft? in
            guard let message = transaction.getMessage(messageId), let channelId = self.channelId(forPeerId: messageId.peerId), let channelState = self.channelState(channelId) else {
                return nil
            }
            // A group's captions (usually one) become the post's text.
            let texts = ([message] + groupMessageIds.filter { $0 != messageId }.compactMap { transaction.getMessage($0) }).compactMap { item -> String? in
                let entities = (item.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
                let markdown = OutgoingText.markdown(text: item.text, entities: entities, username: { peerId in
                    return (transaction.getPeer(peerId) as? TelegramUser)?.username
                })
                return markdown.isEmpty ? nil : markdown
            }
            let markdown = texts.joined(separator: "\n\n")
            var rootId = ""
            if let reply = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute, reply.messageId.peerId == messageId.peerId {
                rootId = self.threadRootPostId(replyTarget: reply.messageId, transaction: transaction) ?? ""
            } else if channelState.kind != .saved, let threadId = message.threadId, threadId != 1, let rootLocalId = Int32(exactly: threadId) {
                rootId = self.postReference(for: MessageId(peerId: messageId.peerId, namespace: Namespaces.Message.Cloud, id: rootLocalId))?.postId ?? ""
            }
            let globallyUniqueId = message.globallyUniqueId ?? Int64(messageId.id)
            let pendingPostId = String(globallyUniqueId)
            self.store.registerPendingPost(MattermostPendingPost(pendingPostId: pendingPostId, channelId: channelId, globallyUniqueId: globallyUniqueId, localMessageId: messageId.id))
            return OutgoingDraft(post: PostDraft(channelId: channelId, message: markdown, rootId: rootId, fileIds: fileIds, pendingPostId: pendingPostId), globallyUniqueId: globallyUniqueId)
        }
    }

    // MARK: The sent post

    /// Writes our own created post (from the `POST /posts` response, or its WebSocket echo after a restart):
    /// allocates its local ids, rewrites the Local messages into the Cloud ones in place (same stable ids,
    /// server text and timestamp, Mattermost media with the uploaded data moved over), and drops the
    /// `pending` row. A post sent from a group of messages (an album) rewrites the whole group: each Local
    /// message becomes the Cloud message (part) with its file. `onRewritten` is called inside the
    /// transaction with the Cloud ids, in the order of the Local messages. When the Local messages are gone,
    /// the post is written like any live post.
    func applyOwnPost(_ post: Post, pendingPostId: String, uploadedFiles: [MessageId: [PostSender.UploadedFile]], onRewritten: (([MessageId]) -> Void)?) async {
        var extra: [Post] = []
        if !post.rootId.isEmpty, self.store.entries(channelId: post.channelId, postIds: [post.rootId])[post.rootId] == nil, let root = try? await self.client.post(id: post.rootId) {
            extra.append(root)
        }
        await self.ensureUsers(referencedUserIds([post] + extra))
        let mediaBox = self.postbox.mediaBox
        await self.postbox.mmTransaction { transaction in
            guard let channelState = self.channelState(post.channelId) else {
                return
            }
            self.markOwnPostRead(post, transaction: transaction)
            let pending = self.store.pendingPost(pendingPostId: pendingPostId)
            self.store.removePendingPost(pendingPostId: pendingPostId)
            let localMessageId = pending.map { MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Local, id: $0.localMessageId) }
            guard let localMessageId = localMessageId, let localMessage = transaction.getMessage(localMessageId) else {
                let result = self.write(PageWrite(channelId: post.channelId, kind: .singles, run: [post], extra: extra), transaction: transaction)
                if result.insertedCount > 0 {
                    self.bumpThreadRoot(of: post, transaction: transaction)
                }
                return
            }
            // The Local messages of the post: the message, or its whole group (an album sent as one post).
            var localMessages = [localMessage]
            if localMessage.groupingKey != nil, let group = transaction.getMessageGroup(localMessageId) {
                let locals = group.filter { $0.id.namespace == Namespaces.Message.Local }.sorted(by: { $0.id < $1.id })
                if locals.contains(where: { $0.id == localMessageId }) {
                    localMessages = locals
                }
            }

            // 1. ID map (as `write` does for singles, with the post's parts), then renumbering.
            let layout = PostLayout(post: post)
            let postKey = PostOrderKey(createAt: post.createAt, postId: post.id)
            var store = self.storeRef()
            var ingests: [IngestResult] = []
            let error = self.store.idMapTransaction {
                for root in extra where root.deleteAt == 0 {
                    ingests.append(try self.allocator.insertPost(PostOrderKey(createAt: root.createAt, postId: root.id), partCount: PostLayout.partCount(root), channelId: post.channelId, store: &store))
                }
                ingests.append(try self.allocator.insertPost(postKey, partCount: layout.count, channelId: post.channelId, store: &store))
            }
            guard error == nil else {
                MMLog.log("send: could not allocate ids for own post \(post.id)")
                return
            }
            var touched: [ClosedRange<Int32>] = []
            for item in ingests {
                if let plan = item.renumberPlan, !plan.moves.isEmpty {
                    self.applyRenumber(plan, channelId: post.channelId, channelState: channelState, transaction: transaction)
                    touched.append(plan.affectedRange)
                }
                if let islandRange = item.islandRange {
                    touched.append(islandRange)
                }
            }
            if !extra.isEmpty {
                self.writeMessages(channelId: post.channelId, posts: extra, transaction: transaction)
            }

            // 2. The Cloud messages.
            let partKeys = postKey.parts(count: layout.count)
            let entries = self.store.entries(channelId: post.channelId, postIds: partKeys.map { $0.postId } + [post.rootId].filter { !$0.isEmpty })
            guard var context = self.conversionContext(channelId: post.channelId, entries: entries), let primary = entries[post.id], !primary.isDeleted else {
                MMLog.log("send: own post \(post.id) is not mapped")
                return
            }
            let overrides = self.writeOverridePeers([post], transaction: transaction)
            context.authorOverride = { item in
                return overrides[item.id]
            }
            var localIds: [Int: Int32] = [:]
            var threadRoots: [String: String] = [:]
            for (index, key) in partKeys.enumerated() {
                if let entry = entries[key.postId], !entry.isDeleted {
                    localIds[index] = entry.localId
                    if !post.rootId.isEmpty {
                        threadRoots[key.postId] = post.rootId
                    }
                }
            }
            self.store.setThreadRootIds(threadRoots, channelId: post.channelId)
            let converted = PostConverter.storeMessages(post: post, localIds: localIds, context: context)
            for file in converted.customEmojiFiles {
                transaction.storeMediaIfNotPresent(media: file)
            }

            // 3. Pair each Local message with its Cloud message: by uploaded file, else in order.
            func cloudId(_ message: StoreMessage) -> MessageId? {
                if case let .Id(id) = message.id {
                    return id
                }
                return nil
            }
            func fileIds(_ message: StoreMessage) -> [String] {
                return message.media.flatMap { media -> [String] in
                    if let image = media as? TelegramMediaImage {
                        return image.representations.compactMap { ($0.resource as? MattermostFileResource)?.fileId }
                    } else if let file = media as? TelegramMediaFile, let resource = file.resource as? MattermostFileResource {
                        return [resource.fileId]
                    }
                    return []
                }
            }
            var remaining = converted.messages
            var pairs: [(local: Message, cloud: StoreMessage)] = []
            var unpaired: [Message] = []
            for local in localMessages {
                if let fileId = uploadedFiles[local.id]?.first?.fileId, let index = remaining.firstIndex(where: { fileIds($0).contains(fileId) }) {
                    pairs.append((local, remaining.remove(at: index)))
                } else {
                    unpaired.append(local)
                }
            }
            for local in unpaired {
                if remaining.isEmpty {
                    transaction.deleteMessages([local.id], forEachMedia: nil)
                } else {
                    pairs.append((local, remaining.removeFirst()))
                }
            }
            pairs.sort(by: { $0.local.id < $1.local.id })

            var rewritten: [MessageId] = []
            for (local, cloud) in pairs {
                guard let id = cloudId(cloud) else {
                    continue
                }
                if transaction.messageExists(id: id) {
                    // Written already (e.g. by a catch-up): keep that one, updated.
                    transaction.deleteMessages([local.id], forEachMedia: nil)
                    let _ = transaction.addMessages([cloud], location: .Random)
                } else {
                    moveUploadedMedia(from: local, to: cloud.media, uploadedFiles: uploadedFiles[local.id] ?? [], mediaBox: mediaBox)
                    transaction.updateMessage(local.id, update: { current in
                        return .update(StoreMessage(
                            id: id,
                            customStableId: nil,
                            globallyUniqueId: current.globallyUniqueId,
                            groupingKey: cloud.groupingKey,
                            threadId: cloud.threadId,
                            timestamp: cloud.timestamp,
                            flags: [],
                            tags: cloud.tags,
                            globalTags: [],
                            localTags: current.localTags,
                            forwardInfo: nil,
                            authorId: cloud.authorId,
                            text: cloud.text,
                            attributes: cloud.attributes,
                            media: cloud.media
                        ))
                    })
                }
                rewritten.append(id)
            }
            if !remaining.isEmpty {
                // More parts than Local messages (should not happen): store them as received.
                let _ = transaction.addMessages(remaining, location: .Random)
            }
            self.bumpThreadRoot(of: post, transaction: transaction)
            self.syncHoles(channelId: post.channelId, channelState: channelState, ranges: touched, transaction: transaction)
            MMLog.log("send: \(localMessages.map { $0.id }) rewritten to \(rewritten) (post \(post.id), \(layout.count) part(s))")
            onRewritten?(rewritten)
        }
    }

    /// Posting marks the channel read in Mattermost (with collapsed reply threads only a root post does: a reply
    /// reads its thread).
    func markOwnPostRead(_ post: Post, transaction: Transaction) {
        let isRoot = post.rootId.isEmpty
        let marksRead = isRoot || !self.isCollapsedThreads
        self.state.with { state in
            guard var channelState = state.channels[post.channelId] else {
                return
            }
            channelState.channel.lastPostAt = max(channelState.channel.lastPostAt, post.createAt)
            channelState.channel.totalMsgCount = max(channelState.channel.totalMsgCount, channelState.member.msgCount + 1)
            if isRoot {
                channelState.channel.lastRootPostAt = max(channelState.channel.lastRootPostAt, post.createAt)
                channelState.channel.totalMsgCountRoot = max(channelState.channel.totalMsgCountRoot, channelState.member.msgCountRoot + 1)
            }
            if marksRead {
                channelState.member.msgCount = channelState.channel.totalMsgCount
                channelState.member.msgCountRoot = channelState.channel.totalMsgCountRoot
                channelState.member.lastViewedAt = max(channelState.member.lastViewedAt, post.createAt)
                channelState.mentionCount = 0
            }
            state.channels[post.channelId] = channelState
        }
        if marksRead {
            self.applyServerReadState(channelId: post.channelId, transaction: transaction)
        }
    }

    /// A new reply: one more on the root's reply counter, with the author first among the latest repliers.
    func bumpThreadRoot(of post: Post, transaction: Transaction) {
        let marker: PeerId? = self.isCollapsedThreads ? self.channelState(post.channelId)?.peerId : nil
        guard !post.rootId.isEmpty, let channelState = self.channelState(post.channelId), let rootEntry = self.store.entries(channelId: post.channelId, postIds: [post.rootId])[post.rootId], !rootEntry.isDeleted else {
            return
        }
        let authorPeerId = self.userPeerId(post.userId)
        transaction.updateMessage(MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: rootEntry.localId), update: { current in
            var attributes = current.attributes
            var count: Int32 = 0
            var latestUsers: [PeerId] = []
            if let index = attributes.firstIndex(where: { $0 is ReplyThreadMessageAttribute }) {
                let existing = attributes[index] as! ReplyThreadMessageAttribute
                count = existing.count
                latestUsers = existing.latestUsers
                attributes.remove(at: index)
            }
            if let authorPeerId = authorPeerId {
                latestUsers.removeAll(where: { $0 == authorPeerId })
                latestUsers.insert(authorPeerId, at: 0)
            }
            // A reply carries its thread's reply count: use it when present, so a `thread_updated` that came first
            // isn't counted twice.
            let updatedCount = post.replyCount > 0 ? Int32(clamping: post.replyCount) : count + 1
            attributes.append(ReplyThreadMessageAttribute(count: updatedCount, latestUsers: Array(latestUsers.prefix(3)), commentsPeerId: marker, maxMessageId: nil, maxReadMessageId: nil))
            return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: attributes))
        })
    }

    // MARK: Edit

    /// `PUT /posts/{id}/patch` with the composer's text as markdown; the returned post replaces the message.
    /// Nil on success.
    func editPost(messageId: MessageId, text: String, entities: [MessageTextEntity]) async -> RequestEditMessageError? {
        guard let reference = self.postReference(for: messageId) else {
            self.notice(.editTooEarly)
            return .generic
        }
        let markdown = await self.postbox.mmTransaction { transaction in
            return OutgoingText.markdown(text: text, entities: entities, username: { peerId in
                return (transaction.getPeer(peerId) as? TelegramUser)?.username
            })
        }
        do {
            var post = try await self.client.patchPost(id: reference.postId, patch: PostPatch(message: markdown))
            if post.hasReactions && (post.metadata?.reactions.isEmpty ?? true), let full = try? await self.client.post(id: post.id) {
                post = full
            }
            await self.ensureUsers(referencedUserIds([post]))
            await self.postbox.mmTransaction { transaction in
                self.writeMessages(channelId: reference.channelId, posts: [post], transaction: transaction)
            }
            MMLog.log("edit: \(messageId) → post \(post.id) edited")
            return nil
        } catch {
            MMLog.log("edit: \(messageId) (post \(reference.postId)) failed: \(error)")
            self.notice(.editFailed(detail: describeError(error)))
            if let error = error as? MattermostError, case .forbidden = error {
                return .restricted
            }
            return .generic
        }
    }
}

/// Moves the uploaded data of a sent message to the resources of its Mattermost media, so the sent photo or
/// file shows without downloading it again (as Telegram's `applyMediaResourceChanges`).
private func moveUploadedMedia(from localMessage: Message, to media: [Media], uploadedFiles: [PostSender.UploadedFile], mediaBox: MediaBox) {
    func targetResources(fileId: String) -> (file: MediaResource?, preview: MediaResource?, thumbnail: MediaResource?) {
        for item in media {
            if let image = item as? TelegramMediaImage {
                let resources = image.representations.compactMap { $0.resource as? MattermostFileResource }.filter { $0.fileId == fileId }
                if !resources.isEmpty {
                    return (resources.first(where: { $0.variant == .file }), resources.first(where: { $0.variant == .preview }), resources.first(where: { $0.variant == .thumbnail }))
                }
            } else if let file = item as? TelegramMediaFile, let resource = file.resource as? MattermostFileResource, resource.fileId == fileId {
                return (resource, nil, nil)
            }
        }
        return (nil, nil, nil)
    }
    for uploaded in uploadedFiles where uploaded.mediaIndex < localMessage.media.count {
        let local = localMessage.media[uploaded.mediaIndex]
        let targets = targetResources(fileId: uploaded.fileId)
        var full: MediaResource?
        var small: MediaResource?
        if let image = local as? TelegramMediaImage {
            full = largestImageRepresentation(image.representations)?.resource
            if image.representations.count > 1 {
                small = smallestImageRepresentation(image.representations)?.resource
            }
        } else if let file = local as? TelegramMediaFile {
            full = file.resource
        }
        guard let source = full else {
            continue
        }
        if let preview = targets.preview {
            mediaBox.copyResourceData(from: source.id, to: preview.id)
        }
        if let thumbnail = targets.thumbnail, let small = small {
            mediaBox.copyResourceData(from: small.id, to: thumbnail.id)
        }
        if let target = targets.file {
            if source is LocalFileMediaResource || source is LocalFileReferenceMediaResource {
                mediaBox.moveResourceData(from: source.id, to: target.id)
            } else {
                mediaBox.copyResourceData(from: source.id, to: target.id)
            }
        }
    }
}
