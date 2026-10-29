import Foundation
import UIKit
import AVFoundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import MattermostPush
import MattermostShare

// Phase 3F: the share extension's Mattermost side. Telegram's share extension shows its chat picker over the
// account's Postbox (`standaloneStateManager`, null network); for the chosen chats `share` turns the other app's
// items into Mattermost posts (MattermostShare: account, chats, planning, upload) instead of Telegram's standalone
// uploads. Debug builds of the app run the same code (`MattermostShareExtension.share` from the debug remote).

public enum MattermostShareError: Error, Equatable {
    /// No Mattermost account (or no readable session token) for the chosen account.
    case noAccount
    /// A chosen chat isn't known to the account's store.
    case unknownChat
    /// The server refused (its message), or the network failed.
    case failed(String)
    /// A file is larger than the server's `MaxFileSize`.
    case fileTooBig(Int64)
    /// None of the shared items could be read, and there is no comment.
    case nothingToShare
}

public enum MattermostShareStatus: Equatable {
    case preparing
    case progress(Float)
    case done
}

public enum MattermostShareExtension {
    static func log(_ text: String) {
        let role = Bundle.main.bundlePath.hasSuffix(".appex") ? "share" : "share (app)"
        NSLog("[Relay] %@: %@", role, text)
    }

    /// Phase 4G: the extension takes the certificate pins and the server restriction from the app's copy of its
    /// managed configuration (only the app can read the configuration itself), once per process.
    private static let managedConfigurationLoaded = MMLocked<Bool>(false)

    static func loadManagedConfiguration(rootPath: String) {
        guard Bundle.main.bundlePath.hasSuffix(".appex"), self.managedConfigurationLoaded.with({ loaded -> Bool in
            let first = !loaded
            loaded = true
            return first
        }) else {
            return
        }
        MattermostManagedSettings.loadInExtension(sharedDirectory: URL(fileURLWithPath: rootPath))
    }

    /// The client of an account on this device: server from its store, token from the shared Keychain group.
    static func client(rootPath: String, accountId: AccountRecordId) -> (MattermostClient, MattermostShareAccount)? {
        self.loadManagedConfiguration(rootPath: rootPath)
        guard let account = MattermostShareAccounts.account(rootPath: rootPath, accountId: accountId.int64), let url = URL(string: account.serverURL) else {
            return nil
        }
        guard MattermostManagedSettings.current.allowsServer(url) else {
            self.log("account \(accountId.int64): its server is not allowed by managed configuration")
            return nil
        }
        guard let token = MattermostSessionKeychain.token(accountId: accountId.int64, log: { self.log($0) }) else {
            self.log("no session token for account \(accountId.int64)")
            return nil
        }
        var configuration = MattermostClient.Configuration(serverURL: url, userAgent: "Relay/0.1 (iOS; Share)")
        configuration.timeoutInterval = 30
        return (MattermostClient(configuration: configuration, token: token), account)
    }

    /// Lets the extension's media box load Mattermost avatars and files (the chat picker's pictures) with the
    /// account's session.
    public static func prepareAccount(postbox: Postbox, accountId: AccountRecordId, rootPath: String) {
        if let (client, _) = self.client(rootPath: rootPath, accountId: accountId) {
            MattermostResourceClients.shared.register(postbox: postbox, client: client)
        }
    }

    /// The other app's items as Mattermost content: texts and links, images, files, videos and audio as files.
    /// `items` are the dictionaries of `TGItemProviderSignals` (`text`, `url`, `scaledImageData`, `image`, `data` +
    /// `fileName` + `mimeType`, `video`, `audio`). An item of another kind is logged and left out.
    public static func content(items: [[String: Any]]) -> MattermostShareContent {
        var content = MattermostShareContent()
        var imageIndex = 0
        let addImage: (Data, String, String) -> Void = { data, mimeType, fileExtension in
            imageIndex += 1
            content.files.append(MattermostShareFile(fileName: (imageIndex == 1 ? "image" : "image-\(imageIndex)") + fileExtension, mimeType: mimeType, content: .data(data)))
        }
        for item in items {
            if let text = item["text"] as? String {
                content.texts.append(text)
            } else if let url = item["url"] as? URL {
                content.texts.append(url.absoluteString)
            } else if let data = item["scaledImageData"] as? Data {
                // A photo shared as a file (the Photos app): `TGItemProviderSignals` hands it over as a JPEG it
                // scaled down to 1280 px.
                addImage(data, "image/jpeg", ".jpg")
            } else if let image = item["image"] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                addImage(data, "image/jpeg", ".jpg")
            } else if let data = item["image"] as? Data {
                // An app that hands over the image's bytes: JPEG and PNG as they are, anything else (HEIC) as JPEG.
                if data.starts(with: [0xFF, 0xD8, 0xFF]) {
                    addImage(data, "image/jpeg", ".jpg")
                } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                    addImage(data, "image/png", ".png")
                } else if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
                    addImage(jpeg, "image/jpeg", ".jpg")
                } else {
                    self.log("left out an image the system can't decode (\(data.count) bytes)")
                }
            } else if let data = item["data"] as? Data {
                let mimeType = (item["mimeType"] as? String) ?? "application/octet-stream"
                var fileName = (item["fileName"] as? String) ?? ""
                if fileName.isEmpty {
                    fileName = "file" + self.fileExtension(mimeType: mimeType)
                }
                content.files.append(MattermostShareFile(fileName: fileName, mimeType: mimeType, content: .data(data)))
            } else if let asset = item["video"] as? AVURLAsset {
                let url = asset.url
                content.files.append(MattermostShareFile(fileName: url.lastPathComponent.isEmpty ? "video.mp4" : url.lastPathComponent, mimeType: url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4", content: .file(url)))
            } else if let url = item["audio"] as? URL {
                content.files.append(MattermostShareFile(fileName: url.lastPathComponent, mimeType: (item["mimeType"] as? String) ?? "audio/mpeg", content: .file(url)))
            } else {
                self.log("left out an item with \(item.keys.sorted())")
            }
        }
        return content
    }

    /// For logs and the debug remote: the texts and the files' names, types and sizes.
    public static func summary(_ content: MattermostShareContent) -> [String: Any] {
        return ["texts": content.texts, "files": content.files.map { "\($0.fileName) (\($0.mimeType), \($0.size) bytes)" }]
    }

    private static func fileExtension(mimeType: String) -> String {
        switch mimeType {
        case "application/pdf":
            return ".pdf"
        case "text/plain":
            return ".txt"
        case "image/jpeg":
            return ".jpg"
        case "image/png":
            return ".png"
        default:
            return ""
        }
    }

    /// Shares `content` into each chosen chat of the account (a thread when `threadIds` names one): uploads, then
    /// posts. `comment` is the text typed in the share sheet.
    public static func share(accountId: AccountRecordId, rootPath: String, peerIds: [PeerId], threadIds: [PeerId: Int64], comment: String, content: MattermostShareContent) -> Signal<MattermostShareStatus, MattermostShareError> {
        return Signal { subscriber in
            let task = Task {
                do {
                    try await self.run(accountId: accountId, rootPath: rootPath, peerIds: peerIds, threadIds: threadIds, comment: comment, content: content, progress: { value in
                        subscriber.putNext(.progress(value))
                    })
                    subscriber.putNext(.done)
                    subscriber.putCompletion()
                } catch let error as MattermostShareError {
                    self.log("failed: \(error)")
                    subscriber.putError(error)
                } catch {
                    self.log("failed: \(error)")
                    subscriber.putError(.failed(describeError(error)))
                }
            }
            subscriber.putNext(.preparing)
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    private static func run(accountId: AccountRecordId, rootPath: String, peerIds: [PeerId], threadIds: [PeerId: Int64], comment: String, content: MattermostShareContent, progress: @escaping (Float) -> Void) async throws {
        guard let (client, account) = self.client(rootPath: rootPath, accountId: accountId) else {
            throw MattermostShareError.noAccount
        }
        let store = try SQLiteMattermostSyncStore(path: account.storePath)
        defer {
            store.close()
        }
        // The server's limits (`MaxFileSize`, `MaxPostSize` comes from the default).
        if let config = try? await client.clientConfig(), let maxFileSize = config.int64("MaxFileSize"), maxFileSize > 0 {
            if let tooBig = content.files.first(where: { $0.size > maxFileSize }) {
                self.log("\(tooBig.fileName) has \(tooBig.size) bytes, the server allows \(maxFileSize)")
                throw MattermostShareError.fileTooBig(tooBig.size)
            }
        }
        let posts = MattermostSharePlanner.posts(comment: comment, content: content)
        if posts.isEmpty {
            // Nothing the other app shared could be read. Finishing here showed the share sheet's success with
            // nothing posted (photos from the Photos app, before `scaledImageData` was read).
            throw MattermostShareError.nothingToShare
        }
        let sender = MattermostShareSender(client: client, userId: account.userId)
        for (index, peerId) in peerIds.enumerated() {
            let namespace: MattermostPeerNamespace = peerId.namespace == Namespaces.Peer.CloudChannel ? .channel : .user
            guard let target = MattermostShareResolver.target(namespace: namespace, peerIdValue: peerId.id._internalGetInt64Value(), store: store) else {
                throw MattermostShareError.unknownChat
            }
            let channelId = try await sender.channelId(for: target)
            var rootId: String?
            if let threadId = threadIds[peerId] {
                rootId = MattermostShareResolver.rootPostId(channelId: channelId, threadLocalId: threadId, store: store)
            }
            let base = Float(index) / Float(peerIds.count)
            let created = try await sender.send(posts, channelId: channelId, rootId: rootId, progress: { value in
                progress(base + Float(value) / Float(peerIds.count))
            })
            self.log("shared \(created.count) post(s) to \(channelId)\(rootId.map { " in thread \($0)" } ?? ""): \(created.map(\.id)) (\(content.texts.count) texts, \(content.files.count) files)")
        }
    }
}
