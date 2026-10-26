import Foundation
import MattermostKit
import MattermostSyncCore

// Sharing from other apps into Mattermost (Phase 3F, the share extension).
//
// The extension shows Telegram's chat picker over the account's Postbox; for the chosen chats it
// 1. finds the account's server and user in `<root>/account-<id>/mattermost/sync.sqlite` (the app writes it; the
//    extension only reads) — the session token comes from the shared Keychain group (MattermostPush);
// 2. turns each chosen Telegram peer into a Mattermost channel (`MattermostShareResolver`): channels and group
//    messages by the peers table, users by their DM channel (created with `POST /channels/direct` when there is
//    none yet), a thread by its root post;
// 3. plans the posts (`MattermostSharePlanner`): the comment and shared texts/links as one message, files at most
//    `maxFilesPerPost` per post, the message on the first one;
// 4. uploads and posts (`MattermostShareSender`): `POST /files`, then `POST /posts` with the file ids.

/// An account on this device that can share.
public struct MattermostShareAccount: Equatable, Sendable {
    public let accountId: Int64
    public let serverURL: String
    public let userId: String
    public let username: String?
    public let siteName: String?
    public let storePath: String

    public init(accountId: Int64, serverURL: String, userId: String, username: String?, siteName: String?, storePath: String) {
        self.accountId = accountId
        self.serverURL = serverURL
        self.userId = userId
        self.username = username
        self.siteName = siteName
        self.storePath = storePath
    }
}

public enum MattermostShareAccounts {
    /// `account-<id>` as Telegram names account directories (the id's bit pattern, unsigned).
    public static func directoryName(accountId: Int64) -> String {
        return "account-\(UInt64(bitPattern: accountId))"
    }

    /// The account's server and user, or nil when it isn't a Mattermost account (or its store is unreadable).
    public static func account(rootPath: String, accountId: Int64) -> MattermostShareAccount? {
        let storePath = rootPath + "/" + self.directoryName(accountId: accountId) + "/mattermost/sync.sqlite"
        guard FileManager.default.fileExists(atPath: storePath), let store = try? SQLiteMattermostSyncStore(path: storePath) else {
            return nil
        }
        defer {
            store.close()
        }
        guard let server = (try? store.serverInfo()) ?? nil else {
            return nil
        }
        let username = (try? store.cursor("own_username")) ?? nil
        return MattermostShareAccount(accountId: accountId, serverURL: server.url, userId: server.userId, username: username, siteName: server.siteName, storePath: storePath)
    }

    /// Every account directory with a Mattermost store, sorted by account id.
    public static func all(rootPath: String) -> [MattermostShareAccount] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else {
            return []
        }
        var result: [MattermostShareAccount] = []
        for name in names where name.hasPrefix("account-") {
            guard let unsigned = UInt64(name.dropFirst("account-".count)), let account = self.account(rootPath: rootPath, accountId: Int64(bitPattern: unsigned)) else {
                continue
            }
            result.append(account)
        }
        return result.sorted(by: { $0.accountId < $1.accountId })
    }
}

/// Where shared content goes.
public enum MattermostShareTarget: Equatable, Sendable {
    /// A channel, group message or existing DM.
    case channel(id: String)
    /// A DM that doesn't exist yet (created before posting).
    case directMessage(userId: String)
}

public enum MattermostShareResolver {
    /// The Mattermost chat of a Telegram peer: `namespace` is the peer's namespace (users or channels), `peerIdValue`
    /// the peer id's value.
    public static func target(namespace: MattermostPeerNamespace, peerIdValue: Int64, store: SQLiteMattermostSyncStore) -> MattermostShareTarget? {
        guard let peer = (try? store.peer(namespace: namespace, peerId: peerIdValue)) ?? nil else {
            return nil
        }
        switch peer.kind {
        case .channel, .groupMessage:
            return .channel(id: peer.mattermostId)
        case .user:
            if let channelId = (try? store.directChannelId(userId: peer.mattermostId)) ?? nil {
                return .channel(id: channelId)
            }
            return .directMessage(userId: peer.mattermostId)
        }
    }

    /// The root post of a thread (Telegram's thread id is the root's local message id), nil if it isn't known.
    public static func rootPostId(channelId: String, threadLocalId: Int64, store: SQLiteMattermostSyncStore) -> String? {
        guard let localId = Int32(exactly: threadLocalId), let entry = store.entries(channelId: channelId, fromLocalId: localId, ascending: true, limit: 1).first, entry.localId == localId, !entry.isDeleted else {
            return nil
        }
        return entry.key.serverPostId
    }
}

/// A file to share.
public struct MattermostShareFile: Equatable, Sendable {
    public var fileName: String
    public var mimeType: String
    public var content: FileUpload.Content

    public init(fileName: String, mimeType: String, content: FileUpload.Content) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.content = content
    }

    public var size: Int64 {
        switch self.content {
        case let .data(data):
            return Int64(data.count)
        case let .file(url):
            return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}

/// What the other app handed over.
public struct MattermostShareContent: Equatable, Sendable {
    /// Texts and links, in order.
    public var texts: [String]
    public var files: [MattermostShareFile]

    public init(texts: [String] = [], files: [MattermostShareFile] = []) {
        self.texts = texts
        self.files = files
    }
}

/// One post to make.
public struct MattermostSharePost: Equatable, Sendable {
    public var message: String
    public var files: [MattermostShareFile]

    public init(message: String, files: [MattermostShareFile]) {
        self.message = message
        self.files = files
    }
}

public enum MattermostSharePlanner {
    /// Mattermost's default `MaxFileCount` per post (older servers: 5; newer can be configured higher).
    public static let defaultMaxFilesPerPost = 10
    /// The server's `MaxPostSize` default (runes).
    public static let defaultMaxMessageLength = 16383

    /// The posts for `content`: the comment and texts as one message (empty parts dropped, a text equal to a link
    /// another part already has is kept once), cut at `maxMessageLength`; files `maxFilesPerPost` at a time, the
    /// message on the first post.
    public static func posts(comment: String, content: MattermostShareContent, maxFilesPerPost: Int = defaultMaxFilesPerPost, maxMessageLength: Int = defaultMaxMessageLength) -> [MattermostSharePost] {
        var parts: [String] = []
        for part in [comment] + content.texts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || parts.contains(trimmed) {
                continue
            }
            parts.append(trimmed)
        }
        let message = parts.joined(separator: "\n\n")
        var messages: [String] = []
        if !message.isEmpty {
            var remaining = Substring(message)
            let limit = max(1, maxMessageLength)
            while !remaining.isEmpty {
                messages.append(String(remaining.prefix(limit)))
                remaining = remaining.dropFirst(limit)
            }
        }
        let perPost = max(1, maxFilesPerPost)
        var fileGroups: [[MattermostShareFile]] = []
        var index = 0
        while index < content.files.count {
            fileGroups.append(Array(content.files[index ..< min(content.files.count, index + perPost)]))
            index += perPost
        }
        var posts: [MattermostSharePost] = []
        if let firstGroup = fileGroups.first {
            // The (last part of the) message goes with the first files; longer messages come first on their own.
            let leading = messages.dropLast()
            for text in leading {
                posts.append(MattermostSharePost(message: text, files: []))
            }
            posts.append(MattermostSharePost(message: messages.last ?? "", files: firstGroup))
            for group in fileGroups.dropFirst() {
                posts.append(MattermostSharePost(message: "", files: group))
            }
        } else {
            for text in messages {
                posts.append(MattermostSharePost(message: text, files: []))
            }
        }
        return posts
    }
}

/// Uploads and posts for one account.
public final class MattermostShareSender: @unchecked Sendable {
    private let client: MattermostClient
    private let userId: String

    public init(client: MattermostClient, userId: String) {
        self.client = client
        self.userId = userId
    }

    /// The channel of `target` (creates the DM if needed).
    public func channelId(for target: MattermostShareTarget) async throws -> String {
        switch target {
        case let .channel(id):
            return id
        case let .directMessage(otherUserId):
            return try await self.client.createDirectChannel(userId: self.userId, otherUserId: otherUserId).id
        }
    }

    /// Makes `posts` in the channel (in the thread of `rootId`), in order; `progress` gets 0…1 over all uploads.
    @discardableResult
    public func send(_ posts: [MattermostSharePost], channelId: String, rootId: String? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Post] {
        let totalBytes = max(1, posts.reduce(Int64(0)) { sum, post in sum + post.files.reduce(Int64(0)) { $0 + $1.size } })
        var sentBytes: Int64 = 0
        var result: [Post] = []
        for post in posts {
            var fileIds: [String] = []
            if !post.files.isEmpty {
                let uploads = post.files.map { FileUpload(fileName: $0.fileName, mimeType: $0.mimeType, content: $0.content) }
                let base = sentBytes
                let response = try await self.client.uploadFiles(uploads, channelId: channelId, progress: { value in
                    progress?(Double(base + value.bytesSent) / Double(totalBytes))
                })
                // The answer keeps the order of `client_ids`.
                for clientId in uploads.map(\.clientId) {
                    if let index = response.clientIds.firstIndex(of: clientId), index < response.fileInfos.count {
                        fileIds.append(response.fileInfos[index].id)
                    }
                }
                if fileIds.count != uploads.count {
                    fileIds = response.fileInfos.map(\.id)
                }
                sentBytes += post.files.reduce(Int64(0)) { $0 + $1.size }
            }
            let draft = PostDraft(channelId: channelId, message: post.message, rootId: rootId ?? "", fileIds: fileIds, pendingPostId: "\(self.userId):\(Int64(Date().timeIntervalSince1970 * 1000))\(result.count)")
            result.append(try await self.client.createPost(draft))
        }
        progress?(1.0)
        return result
    }
}
