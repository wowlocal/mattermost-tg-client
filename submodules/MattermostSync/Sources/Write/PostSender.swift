import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// TelegramCore's send seam (`MattermostMessageSender`, design: "Replacing managed operations" → send/edit).
///
/// `PendingMessageManager` keeps Telegram's bookkeeping and calls this for the network part:
/// - `uploadMedia`: `POST /files` for every photo/file of the message (with progress);
/// - `sendMessage`: `POST /posts` with `pending_post_id` = the message's `globallyUniqueId`, then the Local →
///   Cloud rewrite (`applyOwnPost`). Posts are created one at a time per channel, in the order they were
///   handed over, so messages queued while offline go out in order. Transient errors (offline, server down,
///   5xx, 429) are retried until the server is back; other errors fail the message.
/// - `sendMessageGroup`: a group of messages (an album, or files sent grouped) as one post with all their
///   files and captions; the post's messages (`PostLayout`) replace the group.
///
/// Deduplication against the WebSocket `posted` echo: the `pending` table maps `pending_post_id` to the local
/// message; while our request is in flight, its echo is ignored and the response does the rewrite. An echo
/// without a request in flight (the app was restarted) does the rewrite itself.
///
/// Uploaded file ids are kept in memory and with the message's `pending` row (4F): a restart between the upload
/// and `POST /posts` uses them instead of uploading again.
final class PostSender: MattermostMessageSender {
    struct UploadedFile {
        /// Index into the message's `media`.
        var mediaIndex: Int
        var fileId: String
        /// A voice recording's AAC file (5A), moved to the sent message's resource after the post (in memory only:
        /// after a restart the sent message downloads it).
        var transcodedPath: String? = nil
    }

    private weak var sync: MattermostAccountSync?
    private let accountId: AccountRecordId
    private let uploads = MMLocked<[MessageId: [UploadedFile]]>([:])
    private let inFlight = MMLocked<Set<String>>([])
    private let channelTails = MMLocked<[String: Task<Void, Never>]>([:])

    init(sync: MattermostAccountSync) {
        self.sync = sync
        self.accountId = sync.account.id
    }

    /// The sync to write with: this sender's own while it runs. After the session expired (the sync stopped),
    /// the account's next running sync, which a re-login starts; until then this waits, so messages sent
    /// while the session is expired stay pending (clock) and go out after the re-login, in order. Nil once
    /// the account is gone (logged out).
    private func activeSync() async -> MattermostAccountSync? {
        if let sync = self.sync, !sync.isStopped {
            return sync
        }
        return await MattermostSync.waitForRunningSync(accountId: self.accountId)
    }

    func isInFlight(pendingPostId: String) -> Bool {
        return self.inFlight.with { $0.contains(pendingPostId) }
    }

    func uploadedFiles(messageId: MessageId) -> [UploadedFile] {
        return self.uploads.with { $0[messageId] ?? [] }
    }

    // MARK: MattermostMessageSender

    func uploadMedia(messageId: MessageId) -> Signal<Float, MattermostSendError> {
        return Signal { subscriber in
            let task = Task {
                while true {
                    guard let sync = await self.activeSync(), let sender = sync.sender else {
                        subscriber.putError(.generic)
                        return
                    }
                    do {
                        // The running sync's sender keeps the uploaded file ids for its `send`.
                        try await sender.upload(messageId: messageId, sync: sync, progress: { value in
                            subscriber.putNext(value)
                        })
                        subscriber.putCompletion()
                        return
                    } catch {
                        if Task.isCancelled {
                            return
                        }
                        if await MattermostSync.isSessionRejected(error, sync: sync) {
                            MMLog.log("send: upload of \(messageId) waits for a new login (session expired)")
                            continue
                        }
                        MMLog.log("send: upload of \(messageId) failed: \(error)")
                        sync.notice(.uploadFailed(detail: describeError(error)))
                        subscriber.putError(.generic)
                        return
                    }
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    func sendMessage(messageId: MessageId) -> Signal<MessageId, MattermostSendError> {
        return self.sendMessageGroup(messageIds: [messageId])
        |> mapToSignal { ids -> Signal<MessageId, MattermostSendError> in
            if let id = ids.first {
                return .single(id)
            }
            return .complete()
        }
    }

    func sendMessageGroup(messageIds: [MessageId]) -> Signal<[MessageId], MattermostSendError> {
        return Signal { subscriber in
            let task = Task {
                while !messageIds.isEmpty {
                    guard let sync = await self.activeSync(), let sender = sync.sender else {
                        break
                    }
                    do {
                        // The running sync's sender: its in-flight set deduplicates the WebSocket echo.
                        try await sender.send(messageIds: messageIds, sync: sync, onRewritten: { cloudIds in
                            // Called inside the rewriting transaction, like Telegram's `pendingMessageEvent`: the
                            // delivered event reaches PendingMessageManager before the unsent-ids update does.
                            subscriber.putNext(cloudIds)
                            subscriber.putCompletion()
                        })
                        subscriber.putCompletion()
                        return
                    } catch {
                        if Task.isCancelled {
                            return
                        }
                        if await MattermostSync.isSessionRejected(error, sync: sync) {
                            MMLog.log("send: \(messageIds) wait for a new login (session expired)")
                            continue
                        }
                        MMLog.log("send: \(messageIds) failed: \(error)")
                        break
                    }
                }
                subscriber.putError(.generic)
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    func editMessage(messageId: MessageId, text: String, entities: TextEntitiesMessageAttribute?) -> Signal<RequestEditMessageResult, RequestEditMessageError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = await self.activeSync() else {
                    subscriber.putError(.generic)
                    return
                }
                if let error = await sync.editPost(messageId: messageId, text: text, entities: entities?.entities ?? []) {
                    subscriber.putError(error)
                } else {
                    subscriber.putNext(.done(true))
                    subscriber.putCompletion()
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    // MARK: Upload

    private func upload(messageId: MessageId, sync: MattermostAccountSync, progress: @escaping (Float) -> Void) async throws {
        await sync.waitUntilBootstrapped()
        let message = await sync.postbox.mmTransaction { transaction in
            return transaction.getMessage(messageId)
        }
        guard let message = message else {
            return
        }
        guard let channelId = await sync.ensureChannel(forPeerId: messageId.peerId) else {
            throw SendFailure.unknownChat
        }
        // Uploaded by an earlier run of the app (4F): the file ids are in the message's pending row.
        if self.uploadedFiles(messageId: messageId).isEmpty, let stored = sync.store.pendingPost(channelId: channelId, localMessageId: messageId.id), !stored.uploadedFiles.isEmpty {
            let files = stored.uploadedFiles.map { UploadedFile(mediaIndex: $0.mediaIndex, fileId: $0.fileId) }
            self.uploads.with { $0[messageId] = files }
            progress(1.0)
            MMLog.log("send: \(messageId) reuses \(files.count) file(s) uploaded before a restart: \(files.map { $0.fileId })")
            return
        }
        var items: [(mediaIndex: Int, upload: FileUpload)] = []
        var transcodedPaths: [Int: String] = [:]
        let voiceRecording = PostSender.voiceRecording(of: message)
        for (index, media) in message.media.enumerated() {
            guard var source = UploadSource(media: media, messageId: messageId, index: index) else {
                continue
            }
            var path = try await sync.completeResourcePath(source.resource)
            if let recording = voiceRecording, recording.file.fileId == (media as? TelegramMediaFile)?.fileId {
                // A voice message (5A, V1): Telegram's Ogg/Opus recording goes as AAC (`.m4a`) with a readable
                // name; when transcoding fails it goes as recorded (an `.ogg`, still marked as a voice message).
                let date = Date(timeIntervalSince1970: Double(message.timestamp))
                if recording.needsTranscoding {
                    if let transcoded = await PostSender.transcodeVoiceRecording(sourcePath: path, name: "\(self.accountId.int64)-\(message.globallyUniqueId ?? Int64(messageId.id))-\(index)") {
                        path = transcoded
                        transcodedPaths[index] = transcoded
                        source.fileName = VoiceMessageFile.fileName(prefix: MattermostVoiceMessages.fileNamePrefix(), date: date)
                        source.mimeType = VoiceMessageFile.mimeType
                    } else {
                        source.fileName = (VoiceMessageFile.fileName(prefix: MattermostVoiceMessages.fileNamePrefix(), date: date) as NSString).deletingPathExtension + ".ogg"
                        source.mimeType = "audio/ogg"
                    }
                }
            }
            items.append((index, FileUpload(clientId: "\(messageId.id)-\(index)", fileName: source.fileName, mimeType: source.mimeType, content: .file(URL(fileURLWithPath: path)))))
        }
        if items.isEmpty {
            return
        }
        progress(0.0)
        let started = CFAbsoluteTimeGetCurrent()
        let response = try await sync.retryingTransient("upload \(messageId)", isStillWanted: { await sync.messageExists(messageId) }) {
            try await sync.client.uploadFiles(items.map { $0.upload }, channelId: channelId, progress: { value in
                progress(Float(value.fractionCompleted))
            })
        }
        var files: [UploadedFile] = []
        for (clientId, info) in zip(response.clientIds, response.fileInfos) {
            if let item = items.first(where: { $0.upload.clientId == clientId }) {
                files.append(UploadedFile(mediaIndex: item.mediaIndex, fileId: info.id))
            }
        }
        if files.count != items.count {
            // Older servers may not echo client ids; the order is the request order.
            files = zip(items, response.fileInfos).map { UploadedFile(mediaIndex: $0.0.mediaIndex, fileId: $0.1.id) }
        }
        for index in files.indices {
            files[index].transcodedPath = transcodedPaths[files[index].mediaIndex]
        }
        self.uploads.with { $0[messageId] = files }
        // Kept with the message's pending row, in case the app ends before the post is created (4F).
        let globallyUniqueId = message.globallyUniqueId ?? Int64(messageId.id)
        await sync.postbox.mmTransaction { _ in
            sync.store.setPendingUploads(MattermostPendingPost(pendingPostId: String(globallyUniqueId), channelId: channelId, globallyUniqueId: globallyUniqueId, localMessageId: messageId.id, uploadedFiles: files.map { MattermostPendingUpload(mediaIndex: $0.mediaIndex, fileId: $0.fileId) }))
        }
        MMLog.log("send: uploaded \(files.count) file(s) for \(messageId) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms: \(files.map { $0.fileId })")
        #if DEBUG
        // Debug hook (4F checks): time to end the app between the upload and the post.
        if let delay = ProcessInfo.processInfo.environment["RELAY_DEBUG_SEND_DELAY"].flatMap(Double.init), delay > 0 {
            MMLog.log("send: debug delay of \(delay) s before posting \(messageId)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        #endif
    }

    // MARK: Post

    /// Creates the post of one message, or of a group of messages (one post with all their files), and
    /// rewrites the messages. The first message stands for the group (its `globallyUniqueId` is the
    /// `pending_post_id`).
    private func send(messageIds unsortedIds: [MessageId], sync: MattermostAccountSync, onRewritten: @escaping ([MessageId]) -> Void) async throws {
        await sync.waitUntilBootstrapped()
        let messageIds = unsortedIds.sorted()
        let messageId = messageIds[0]
        var files: [MessageId: [UploadedFile]] = [:]
        for id in messageIds {
            var uploaded = self.uploadedFiles(messageId: id)
            if uploaded.isEmpty, await sync.messageHasMedia(id) {
                // Not uploaded by this run: the ids stored with the pending row (4F), else upload again.
                try await self.upload(messageId: id, sync: sync, progress: { _ in })
                uploaded = self.uploadedFiles(messageId: id)
            }
            files[id] = uploaded
        }
        guard await sync.messageExists(messageId) else {
            MMLog.log("send: \(messageId) is gone; nothing to send")
            return
        }
        // Files in message order, each message's files in media order (Mattermost keeps `file_ids` order).
        let fileIds = messageIds.flatMap { id in (files[id] ?? []).sorted(by: { $0.mediaIndex < $1.mediaIndex }).map { $0.fileId } }
        guard await sync.ensureChannel(forPeerId: messageId.peerId) != nil, let draft = await sync.outgoingDraft(messageId: messageId, fileIds: fileIds, groupMessageIds: messageIds) else {
            sync.notice(.sendChatMissing)
            throw SendFailure.unknownChat
        }
        let pendingPostId = draft.post.pendingPostId
        let queuedAt = CFAbsoluteTimeGetCurrent()
        let outcome = MMLocked<Result<Post, Error>>(.failure(SendFailure.notSent))
        await self.serially(channelId: draft.post.channelId) {
            self.inFlight.with { _ = $0.insert(pendingPostId) }
            do {
                let post = try await sync.retryingTransient("post \(messageId)", isStillWanted: { await sync.messageExists(messageId) }) {
                    try await sync.client.createPost(draft.post)
                }
                outcome.with { $0 = .success(post) }
            } catch {
                outcome.with { $0 = .failure(error) }
            }
        }
        switch outcome.current {
        case let .success(post):
            MMLog.log("send: \(messageIds) → post \(post.id) with \(fileIds.count) file(s) (pending \(pendingPostId)) in \(Int((CFAbsoluteTimeGetCurrent() - queuedAt) * 1000)) ms")
            await sync.applyOwnPost(post, pendingPostId: pendingPostId, uploadedFiles: files, onRewritten: onRewritten)
            self.inFlight.with { _ = $0.remove(pendingPostId) }
            // The group's other messages recorded their uploads in rows of their own (4F).
            if messageIds.count > 1 {
                await sync.postbox.mmTransaction { _ in
                    for id in messageIds.dropFirst() {
                        if let row = sync.store.pendingPost(channelId: draft.post.channelId, localMessageId: id.id), row.pendingPostId != pendingPostId {
                            sync.store.removePendingPost(pendingPostId: row.pendingPostId)
                        }
                    }
                }
            }
            self.uploads.with { uploads in
                for id in messageIds {
                    uploads.removeValue(forKey: id)
                }
            }
        case let .failure(error):
            self.inFlight.with { _ = $0.remove(pendingPostId) }
            await sync.postbox.mmTransaction { _ in
                sync.store.removePendingPost(pendingPostId: pendingPostId)
            }
            if sync.isStopped || error.isMattermostUnauthorized {
                // The session ended: the caller waits for a new login and sends again (no failure toast).
                throw error
            }
            if await sync.messageExists(messageId) {
                sync.notice(.sendFailed(detail: describeError(error)))
                throw error
            }
        }
    }

    /// Runs `work` after every earlier post of the same channel (FIFO per channel).
    private func serially(channelId: String, _ work: @escaping () async -> Void) async {
        let task: Task<Void, Never> = self.channelTails.with { tails in
            let previous = tails[channelId]
            let task = Task {
                await previous?.value
                await work()
            }
            tails[channelId] = task
            return task
        }
        await task.value
    }
}

extension Error {
    var isMattermostUnauthorized: Bool {
        if let error = self as? MattermostError, case .unauthorized = error {
            return true
        }
        return false
    }
}

enum SendFailure: Error {
    case unknownChat
    case notSent
    case missingData
}

/// What to upload for one media item of an outgoing message.
struct UploadSource {
    var resource: MediaResource
    var fileName: String
    var mimeType: String

    init?(media: Media, messageId: MessageId, index: Int) {
        if let image = media as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations) {
            self.resource = representation.resource
            self.fileName = "image-\(messageId.id)-\(index).jpg"
            self.mimeType = "image/jpeg"
        } else if let file = media as? TelegramMediaFile {
            self.resource = file.resource
            self.mimeType = file.mimeType.isEmpty ? "application/octet-stream" : file.mimeType
            if let name = file.fileName, !name.isEmpty {
                self.fileName = name
            } else {
                let ext = file.mimeType.hasPrefix("video/") ? "mp4" : file.mimeType.hasPrefix("audio/") ? "m4a" : file.mimeType.hasPrefix("image/") ? "jpg" : "bin"
                self.fileName = "file-\(messageId.id)-\(index).\(ext)"
            }
        } else {
            return nil
        }
    }
}

/// A short, user-facing description of an error.
func describeError(_ error: Error) -> String {
    if let error = error as? MattermostError {
        if let message = error.appError?.message, !message.isEmpty {
            return message
        }
        return error.errorDescription ?? "\(error)"
    }
    return "\(error)"
}
