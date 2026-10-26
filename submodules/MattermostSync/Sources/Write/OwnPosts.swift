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

    /// The post of a Cloud message, from the ID map.
    func postReference(for messageId: MessageId) -> (channelId: String, postId: String)? {
        guard messageId.namespace == Namespaces.Message.Cloud, let channelId = self.channelId(forPeerId: messageId.peerId) else {
            return nil
        }
        guard let entry = self.store.entries(channelId: channelId, fromLocalId: messageId.id, ascending: true, limit: 1).first, entry.localId == messageId.id, !entry.isDeleted else {
            return nil
        }
        return (channelId, entry.postId)
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
                if Task.isCancelled || !isWanted {
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

    // MARK: Building the post

    /// The `POST /posts` body of an outgoing message, and its `pending` row (registered here, before the
    /// request, so the WebSocket echo is always recognized). Nil when the message is gone.
    func outgoingDraft(messageId: MessageId, fileIds: [String]) async -> OutgoingDraft? {
        return await self.postbox.mmTransaction { transaction -> OutgoingDraft? in
            guard let message = transaction.getMessage(messageId), let channelId = self.channelId(forPeerId: messageId.peerId), let channelState = self.channelState(channelId) else {
                return nil
            }
            let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
            let markdown = OutgoingText.markdown(text: message.text, entities: entities, username: { peerId in
                return (transaction.getPeer(peerId) as? TelegramUser)?.username
            })
            var rootId = ""
            if let reply = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute, reply.messageId.peerId == messageId.peerId {
                rootId = self.threadRootPostId(replyTarget: reply.messageId, transaction: transaction) ?? ""
            } else if channelState.kind == .channel, let threadId = message.threadId, threadId != 1, let rootLocalId = Int32(exactly: threadId) {
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
    /// allocates its local id, rewrites the Local message into the Cloud one in place (same stable id, server
    /// text and timestamp, Mattermost media with the uploaded data moved over), and drops the `pending` row.
    /// `onRewritten` is called inside the transaction with the Cloud id. When the Local message is gone, the
    /// post is written like any live post.
    func applyOwnPost(_ post: Post, pendingPostId: String, uploadedFiles: [PostSender.UploadedFile], onRewritten: ((MessageId) -> Void)?) async {
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

            // 1. ID map (as `write` does for singles), then renumbering.
            var store = self.storeRef()
            var ingests: [IngestResult] = []
            let error = self.store.idMapTransaction {
                for root in extra where root.deleteAt == 0 {
                    ingests.append(try self.allocator.insertPost(PostOrderKey(createAt: root.createAt, postId: root.id), channelId: post.channelId, store: &store))
                }
                ingests.append(try self.allocator.insertPost(PostOrderKey(createAt: post.createAt, postId: post.id), channelId: post.channelId, store: &store))
            }
            guard error == nil, let ingest = ingests.last, let localId = ingest.localId(for: post.id) ?? self.store.entries(channelId: post.channelId, postIds: [post.id])[post.id]?.localId else {
                MMLog.log("send: could not allocate an id for own post \(post.id)")
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

            // 2. The rewrite.
            let entries = self.store.entries(channelId: post.channelId, postIds: [post.id, post.rootId].filter { !$0.isEmpty })
            guard let context = self.conversionContext(channelId: post.channelId, entries: entries) else {
                return
            }
            let converted = PostConverter.storeMessage(post: post, localId: localId, context: context)
            let cloudId = MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: localId)
            if !post.rootId.isEmpty {
                self.store.setThreadRootIds([post.id: post.rootId], channelId: post.channelId)
            }
            if transaction.messageExists(id: cloudId) {
                // Written already (e.g. by a catch-up): keep that one.
                transaction.deleteMessages([localMessageId], forEachMedia: nil)
                self.writeMessages(channelId: post.channelId, posts: [post], transaction: transaction)
            } else {
                moveUploadedMedia(from: localMessage, to: converted.media, uploadedFiles: uploadedFiles, mediaBox: mediaBox)
                transaction.updateMessage(localMessageId, update: { current in
                    return .update(StoreMessage(
                        id: cloudId,
                        customStableId: nil,
                        globallyUniqueId: current.globallyUniqueId,
                        groupingKey: nil,
                        threadId: converted.threadId,
                        timestamp: converted.timestamp,
                        flags: [],
                        tags: converted.tags,
                        globalTags: [],
                        localTags: current.localTags,
                        forwardInfo: nil,
                        authorId: converted.authorId,
                        text: converted.text,
                        attributes: converted.attributes,
                        media: converted.media
                    ))
                })
                self.bumpThreadRoot(of: post, transaction: transaction)
            }
            self.syncHoles(channelId: post.channelId, channelState: channelState, ranges: touched, transaction: transaction)
            MMLog.log("send: \(localMessageId) rewritten to \(cloudId) (post \(post.id))")
            onRewritten?(cloudId)
        }
    }

    /// Posting marks the channel read in Mattermost.
    func markOwnPostRead(_ post: Post, transaction: Transaction) {
        self.state.with { state in
            guard var channelState = state.channels[post.channelId] else {
                return
            }
            channelState.channel.lastPostAt = max(channelState.channel.lastPostAt, post.createAt)
            channelState.channel.totalMsgCount = max(channelState.channel.totalMsgCount, channelState.member.msgCount + 1)
            channelState.member.msgCount = channelState.channel.totalMsgCount
            channelState.member.lastViewedAt = max(channelState.member.lastViewedAt, post.createAt)
            channelState.mentionCount = 0
            state.channels[post.channelId] = channelState
        }
        self.applyServerReadState(channelId: post.channelId, transaction: transaction)
    }

    /// A new reply: one more on the root's reply counter, with the author first among the latest repliers.
    func bumpThreadRoot(of post: Post, transaction: Transaction) {
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
            attributes.append(ReplyThreadMessageAttribute(count: count + 1, latestUsers: Array(latestUsers.prefix(3)), commentsPeerId: nil, maxMessageId: nil, maxReadMessageId: nil))
            return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: attributes))
        })
    }

    // MARK: Edit

    /// `PUT /posts/{id}/patch` with the composer's text as markdown; the returned post replaces the message.
    /// Nil on success.
    func editPost(messageId: MessageId, text: String, entities: [MessageTextEntity]) async -> RequestEditMessageError? {
        guard let reference = self.postReference(for: messageId) else {
            self.notice("This message can't be edited yet.")
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
            self.notice("Couldn't edit the message: \(describeError(error))")
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
