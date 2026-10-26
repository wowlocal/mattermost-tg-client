import Foundation
import MattermostSyncCore

public enum MattermostCursorKey {
    /// Server time (ms) up to which posts are known everywhere; catch-up asks for `since=` this.
    public static let lastSyncAt = MattermostSyncCursorKey.lastSyncAt
    /// Set once the first bootstrap finished.
    public static let bootstrapped = "bootstrapped"
    static func folderId(teamId: String) -> String {
        return "folder.\(teamId)"
    }
}

/// The per-account MattermostSync store (`docs/design/mattermost-sync.md`, "Storage"): a
/// `SQLiteMattermostSyncStore` at `<account>/mattermost/sync.sqlite` behind a lock, with a non-throwing API
/// (failures are logged).
///
/// MattermostSync does its ID-map work inside Postbox transactions (`Postbox.mmTransaction`), which already
/// serializes it; the lock covers the few reads made from tasks (user and mapping lookups) and the debug
/// login, which writes before the account exists. `SQLiteMattermostSyncStore` itself has no locking.
public final class MattermostSyncStore: MessageIdStore {
    public let path: String
    private let base: SQLiteMattermostSyncStore
    private let lock = NSRecursiveLock()
    private var idMapDepth = 0

    public init(path: String) throws {
        self.path = path
        self.base = try SQLiteMattermostSyncStore(path: path)
    }

    /// `<account base path>/mattermost/sync.sqlite`.
    public static func path(accountBasePath: String) -> String {
        return accountBasePath + "/mattermost/sync.sqlite"
    }

    private func locked<T>(_ f: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return f()
    }

    private func attempt<T>(_ what: String, _ fallback: T, _ f: () throws -> T) -> T {
        return self.locked {
            do {
                return try f()
            } catch {
                MMLog.log("store: \(what) failed: \(error)")
                return fallback
            }
        }
    }

    /// For `MessageIdStore` calls, which record failures instead of throwing: outside a transaction the
    /// first failure would otherwise block every later call.
    private func recording<T>(_ f: () -> T) -> T {
        return self.locked {
            let result = f()
            if self.idMapDepth == 0, let error = self.base.messageIdError {
                MMLog.log("store: id map query failed: \(error)")
                self.base.clearMessageIdError()
            }
            return result
        }
    }

    /// Runs allocator work as one SQLite transaction (rolled back as a whole on failure). Returns the error.
    func idMapTransaction(_ body: () throws -> Void) -> Error? {
        return self.locked {
            self.idMapDepth += 1
            defer {
                self.idMapDepth -= 1
            }
            do {
                try self.base.transaction { _ in
                    try body()
                }
                return nil
            } catch {
                MMLog.log("store: id map transaction rolled back: \(error)")
                return error
            }
        }
    }

    // MARK: MessageIdStore

    public func entries(channelId: String, postIds: [String]) -> [String: MessageIdEntry] {
        return self.recording { self.base.entries(channelId: channelId, postIds: postIds) }
    }

    public func entries(channelId: String, keyRange: ClosedRange<PostOrderKey>) -> [MessageIdEntry] {
        return self.recording { self.base.entries(channelId: channelId, keyRange: keyRange) }
    }

    public func entries(channelId: String, olderThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        return self.recording { self.base.entries(channelId: channelId, olderThan: key, limit: limit) }
    }

    public func entries(channelId: String, newerThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        return self.recording { self.base.entries(channelId: channelId, newerThan: key, limit: limit) }
    }

    public func entries(channelId: String, fromLocalId localId: Int32, ascending: Bool, limit: Int) -> [MessageIdEntry] {
        return self.recording { self.base.entries(channelId: channelId, fromLocalId: localId, ascending: ascending, limit: limit) }
    }

    public func islands(channelId: String) -> [HistoryIsland] {
        return self.recording { self.base.islands(channelId: channelId) }
    }

    public func unmappedTombstones(channelId: String, among postIds: [String]) -> Set<String> {
        return self.recording { self.base.unmappedTombstones(channelId: channelId, among: postIds) }
    }

    public func apply(_ changes: MessageIdChangeSet) {
        self.recording { self.base.apply(changes) }
    }

    public func allEntries(channelId: String) -> [MessageIdEntry] {
        return self.recording { self.base.allEntries(channelId: channelId) }
    }

    public func validate(channelId: String) -> [String] {
        return self.recording { self.base.validate(channelId: channelId, maxId: Int32.max - 1) }
    }

    // MARK: Server

    public func serverInfo() -> MattermostServerInfo? {
        return self.attempt("serverInfo", nil) { try self.base.serverInfo() }
    }

    public func setServerInfo(_ info: MattermostServerInfo) {
        self.attempt("setServerInfo", ()) { try self.base.setServerInfo(info) }
    }

    // MARK: Peers

    public func peer(mattermostId: String) -> MattermostPeer? {
        return self.attempt("peer(mattermostId:)", nil) { try self.base.peer(mattermostId: mattermostId) }
    }

    public func peer(namespace: MattermostPeerNamespace, peerId: Int64) -> MattermostPeer? {
        return self.attempt("peer(namespace:peerId:)", nil) { try self.base.peer(namespace: namespace, peerId: peerId) }
    }

    public func allocatePeer(mattermostId: String, kind: MattermostPeerKind, teamId: String?) -> MattermostPeer? {
        return self.attempt("allocatePeer(\(mattermostId))", nil) { try self.base.allocatePeer(mattermostId: mattermostId, kind: kind, teamId: teamId) }
    }

    public func reserveOwnUserPeer(userId: String, peerId: Int64) -> MattermostPeer? {
        return self.attempt("reserveOwnUserPeerId", nil) { try self.base.reserveOwnUserPeerId(userId: userId, hash: peerId) }
    }

    // MARK: DM channels

    public func setDirectChannel(channelId: String, userId: String) {
        self.attempt("setDirectChannel", ()) { try self.base.setDirectChannel(channelId: channelId, userId: userId) }
    }

    public func directChannelUserId(channelId: String) -> String? {
        return self.attempt("directChannelUserId", nil) { try self.base.directChannelUserId(channelId: channelId) }
    }

    public func directChannelId(userId: String) -> String? {
        return self.attempt("directChannelId", nil) { try self.base.directChannelId(userId: userId) }
    }

    // MARK: Media

    /// Sequential `MediaId.id` per Mattermost file id (stable across messages that share a file).
    public func allocateMediaId(fileId: String) -> Int64 {
        return self.attempt("allocateMediaId", 0) { try self.base.allocateMediaId(fileId: fileId) }
    }

    // MARK: Cursors

    public func cursor(_ key: String) -> String? {
        return self.attempt("cursor(\(key))", nil) { try self.base.cursor(key) }
    }

    public func setCursor(_ key: String, _ value: String?) {
        self.attempt("setCursor(\(key))", ()) { try self.base.setCursor(key, value) }
    }

    // MARK: Pending posts (outgoing deduplication)

    @discardableResult
    public func registerPendingPost(_ post: MattermostPendingPost) -> MattermostPendingPost? {
        return self.attempt("registerPendingPost", nil) { try self.base.registerPendingPost(post) }
    }

    public func pendingPost(pendingPostId: String) -> MattermostPendingPost? {
        return self.attempt("pendingPost(pendingPostId:)", nil) { try self.base.pendingPost(pendingPostId: pendingPostId) }
    }

    /// The files a pending message already uploaded (4F), recorded with its pending row.
    @discardableResult
    public func setPendingUploads(_ post: MattermostPendingPost) -> MattermostPendingPost? {
        return self.attempt("setPendingUploads", nil) { try self.base.setPendingUploads(post) }
    }

    public func pendingPost(channelId: String, localMessageId: Int32) -> MattermostPendingPost? {
        return self.attempt("pendingPost(channelId:localMessageId:)", nil) { try self.base.pendingPost(channelId: channelId, localMessageId: localMessageId) }
    }

    public func removePendingPost(pendingPostId: String) {
        self.attempt("removePendingPost", ()) { try self.base.removePendingPost(pendingPostId: pendingPostId) }
    }

    // MARK: Threads

    public func setThreadRootIds(_ rootIdByPostId: [String: String], channelId: String) {
        if rootIdByPostId.isEmpty {
            return
        }
        self.attempt("setThreadRootIds", ()) { try self.base.setThreadRootIds(rootIdByPostId, channelId: channelId) }
    }

    public func threadReplies(rootPostIds: [String], channelId: String) -> [String: [MessageIdEntry]] {
        return self.attempt("threadReplies", [:]) { try self.base.threadReplies(rootPostIds: rootPostIds, channelId: channelId) }
    }

    public func threadRootId(postId: String, channelId: String) -> String? {
        return self.attempt("threadRootId", nil) { try self.base.threadRootId(postId: postId, channelId: channelId) }
    }
}
