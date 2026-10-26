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
///
/// Deduplication against the WebSocket `posted` echo: the `pending` table maps `pending_post_id` to the local
/// message; while our request is in flight, its echo is ignored and the response does the rewrite. An echo
/// without a request in flight (the app was restarted) does the rewrite itself.
final class PostSender: MattermostMessageSender {
    struct UploadedFile {
        /// Index into the message's `media`.
        var mediaIndex: Int
        var fileId: String
    }

    private weak var sync: MattermostAccountSync?
    private let uploads = MMLocked<[MessageId: [UploadedFile]]>([:])
    private let inFlight = MMLocked<Set<String>>([])
    private let channelTails = MMLocked<[String: Task<Void, Never>]>([:])

    init(sync: MattermostAccountSync) {
        self.sync = sync
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
                guard let sync = self.sync else {
                    subscriber.putError(.generic)
                    return
                }
                do {
                    try await self.upload(messageId: messageId, sync: sync, progress: { value in
                        subscriber.putNext(value)
                    })
                    subscriber.putCompletion()
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    MMLog.log("send: upload of \(messageId) failed: \(error)")
                    sync.notice("Couldn't upload the attachment: \(describeError(error))")
                    subscriber.putError(.generic)
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    func sendMessage(messageId: MessageId) -> Signal<MessageId, MattermostSendError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = self.sync else {
                    subscriber.putError(.generic)
                    return
                }
                do {
                    try await self.send(messageId: messageId, sync: sync, onRewritten: { cloudId in
                        // Called inside the rewriting transaction, like Telegram's `pendingMessageEvent`: the
                        // delivered event reaches PendingMessageManager before the unsent-ids update does.
                        subscriber.putNext(cloudId)
                        subscriber.putCompletion()
                    })
                    subscriber.putCompletion()
                } catch {
                    MMLog.log("send: \(messageId) failed: \(error)")
                    subscriber.putError(.generic)
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    func editMessage(messageId: MessageId, text: String, entities: TextEntitiesMessageAttribute?) -> Signal<RequestEditMessageResult, RequestEditMessageError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = self.sync else {
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
        var items: [(mediaIndex: Int, upload: FileUpload)] = []
        for (index, media) in message.media.enumerated() {
            guard let source = UploadSource(media: media, messageId: messageId, index: index) else {
                continue
            }
            let path = try await sync.completeResourcePath(source.resource)
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
        self.uploads.with { $0[messageId] = files }
        MMLog.log("send: uploaded \(files.count) file(s) for \(messageId) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms: \(files.map { $0.fileId })")
    }

    // MARK: Post

    private func send(messageId: MessageId, sync: MattermostAccountSync, onRewritten: @escaping (MessageId) -> Void) async throws {
        await sync.waitUntilBootstrapped()
        var files = self.uploadedFiles(messageId: messageId)
        if files.isEmpty, await sync.messageHasMedia(messageId) {
            // Uploaded by an earlier run of the app: upload again (file ids are kept only in memory).
            try await self.upload(messageId: messageId, sync: sync, progress: { _ in })
            files = self.uploadedFiles(messageId: messageId)
        }
        guard await sync.messageExists(messageId) else {
            MMLog.log("send: \(messageId) is gone; nothing to send")
            return
        }
        guard await sync.ensureChannel(forPeerId: messageId.peerId) != nil, let draft = await sync.outgoingDraft(messageId: messageId, fileIds: files.map { $0.fileId }) else {
            sync.notice("Couldn't send the message: this chat is not on the server.")
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
            MMLog.log("send: \(messageId) → post \(post.id) (pending \(pendingPostId)) in \(Int((CFAbsoluteTimeGetCurrent() - queuedAt) * 1000)) ms")
            await sync.applyOwnPost(post, pendingPostId: pendingPostId, uploadedFiles: files, onRewritten: onRewritten)
            self.inFlight.with { _ = $0.remove(pendingPostId) }
            self.uploads.with { _ = $0.removeValue(forKey: messageId) }
        case let .failure(error):
            self.inFlight.with { _ = $0.remove(pendingPostId) }
            await sync.postbox.mmTransaction { _ in
                sync.store.removePendingPost(pendingPostId: pendingPostId)
            }
            if await sync.messageExists(messageId) {
                sync.notice("Couldn't send the message: \(describeError(error))")
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
