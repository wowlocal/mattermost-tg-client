import Foundation

/// The persistent per-account `MattermostSyncStore`: one SQLite file holding the post ↔ message id
/// map (`MessageIdStore`), the peer, DM channel, pending post, file and cursor tables, and the
/// server row. See `docs/design/mattermost-sync.md` ("Storage") and the package README.
///
/// **Threading.** No internal locking or queue. Use an instance from one serial queue at a time
/// (it may move between queues, but calls must never overlap). Other processes (the extensions)
/// may open the same file: it is in WAL mode with a 5 s busy timeout.
///
/// **Transactions.** Every write method is atomic on its own. Wrap a unit of work (allocator
/// call, peer and media id allocation, cursor update) in `transaction(_:)` to make it one
/// `BEGIN IMMEDIATE … COMMIT`; writes inside it nest as savepoints.
///
/// **Errors.** Typed methods throw. `MessageIdStore` methods can't, so they record the first
/// failure in `messageIdError`, return empty results, and refuse to write while it is set (a
/// change set computed from failed reads is never committed). `transaction(_:)` clears it on
/// entry and throws it on exit after rolling back, so run allocator operations inside it.
public final class SQLiteMattermostSyncStore {
    public let path: String
    let connection: SQLiteConnection
    /// Channel id → `post_channels.channel_key`. Cleared on every rollback.
    var channelKeys: [String: Int64] = [:]
    private var transactionDepth = 0

    /// The first error hit by a `MessageIdStore` method since it was last cleared.
    public internal(set) var messageIdError: MattermostSyncStoreError?

    /// The schema version this build creates and understands.
    public static var schemaVersion: Int {
        return MattermostSyncStoreSchema.latestVersion
    }

    /// Opens the store at `path`, creating the file (and its directory) and migrating the schema
    /// as needed. Throws `unsupportedSchemaVersion` for a file written by a newer build.
    public convenience init(path: String) throws {
        try self.init(path: path, migrations: MattermostSyncStoreSchema.migrations)
    }

    init(path: String, migrations: [String]) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        connection = try SQLiteConnection(path: path, busyTimeoutMilliseconds: 5000)
        try connection.executeScript("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        """)
        try migrate(migrations)
    }

    /// Closes the database. Later calls fail with `MattermostSyncStoreError.closed`.
    public func close() {
        connection.close()
        channelKeys.removeAll()
    }

    private func migrate(_ migrations: [String]) throws {
        try writeTransaction {
            try connection.executeScript(MattermostSyncStoreSchema.versionTable)
            var current = 0
            try connection.query("SELECT version FROM schema_version WHERE id = 1") { row in
                current = Int(row.int64(0))
            }
            if current > migrations.count {
                throw MattermostSyncStoreError.unsupportedSchemaVersion(found: current, supported: migrations.count)
            }
            if current == migrations.count {
                return
            }
            for migration in migrations[current...] {
                try connection.executeScript(migration)
            }
            try connection.execute("INSERT OR REPLACE INTO schema_version (id, version) VALUES (1, ?1)", [.integer(Int64(migrations.count))])
        }
    }

    /// The file's schema version.
    public func storedSchemaVersion() throws -> Int {
        var version = 0
        try connection.query("SELECT version FROM schema_version WHERE id = 1") { row in
            version = Int(row.int64(0))
        }
        return version
    }

    // MARK: - Transactions

    /// Runs `body` as one transaction (a savepoint when nested). Commits when `body` returns,
    /// rolls back when it throws or when a `MessageIdStore` method failed inside it (that error is
    /// then thrown). Typical use:
    ///
    ///     let result = try store.transaction { store in
    ///         try allocator.ingestPage(posts, extending: anchor, direction: .older, reachedEnd: end, channelId: channelId, store: &store)
    ///     }
    public func transaction<T>(_ body: (inout SQLiteMattermostSyncStore) throws -> T) throws -> T {
        if transactionDepth == 0 {
            messageIdError = nil
        } else if let error = messageIdError {
            throw error
        }
        do {
            return try writeTransaction {
                var store = self
                let result = try body(&store)
                if let error = messageIdError {
                    throw error
                }
                return result
            }
        } catch {
            // Rolled back: the failure has been turned into a thrown error.
            messageIdError = nil
            throw error
        }
    }

    /// `BEGIN IMMEDIATE … COMMIT` at the outermost level, a savepoint inside another transaction.
    func writeTransaction<T>(_ body: () throws -> T) throws -> T {
        let isOutermost = transactionDepth == 0
        let savepoint = "level\(transactionDepth)"
        try connection.execute(isOutermost ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        do {
            let result = try body()
            try connection.execute(isOutermost ? "COMMIT" : "RELEASE \(savepoint)")
            transactionDepth -= 1
            return result
        } catch {
            if isOutermost {
                try? connection.execute("ROLLBACK")
            } else {
                try? connection.execute("ROLLBACK TO \(savepoint)")
                try? connection.execute("RELEASE \(savepoint)")
            }
            transactionDepth -= 1
            // A rolled-back transaction may have created channel rows.
            channelKeys.removeAll()
            throw error
        }
    }

    /// Clears `messageIdError` after the caller has handled it outside `transaction(_:)`.
    public func clearMessageIdError() {
        messageIdError = nil
    }

    // MARK: - Server

    public func serverInfo() throws -> MattermostServerInfo? {
        var info: MattermostServerInfo?
        try connection.query("SELECT url, user_id, site_name, version, capabilities FROM server WHERE id = 1") { row in
            info = MattermostServerInfo(url: row.string(0), userId: row.string(1), siteName: row.optionalString(2), version: row.optionalString(3), capabilitiesJSON: row.optionalString(4))
        }
        return info
    }

    public func setServerInfo(_ info: MattermostServerInfo) throws {
        try connection.execute(
            "INSERT OR REPLACE INTO server (id, url, user_id, site_name, version, capabilities) VALUES (1, ?1, ?2, ?3, ?4, ?5)",
            [.text(info.url), .text(info.userId), .optionalText(info.siteName), .optionalText(info.version), .optionalText(info.capabilitiesJSON)]
        )
    }

    // MARK: - Peers

    private static let peerColumns = "mm_id, kind, peer_id, team_id"

    private func readPeer(_ row: SQLiteRow) -> MattermostPeer {
        return MattermostPeer(mattermostId: row.string(0), kind: MattermostPeerKind(rawValue: row.string(1)) ?? .user, peerId: row.int64(2), teamId: row.optionalString(3))
    }

    public func peer(mattermostId: String) throws -> MattermostPeer? {
        var peer: MattermostPeer?
        try connection.query("SELECT \(Self.peerColumns) FROM peers WHERE mm_id = ?1", [.text(mattermostId)]) { row in
            peer = readPeer(row)
        }
        return peer
    }

    public func peer(namespace: MattermostPeerNamespace, peerId: Int64) throws -> MattermostPeer? {
        var peer: MattermostPeer?
        try connection.query("SELECT \(Self.peerColumns) FROM peers WHERE namespace = ?1 AND peer_id = ?2", [.integer(Int64(namespace.rawValue)), .integer(peerId)]) { row in
            peer = readPeer(row)
        }
        return peer
    }

    /// The peer that shows a channel's messages: the channel or GM peer, or for a DM channel the
    /// other user's peer (registered with `setDirectChannel`). Nil when unknown.
    public func peer(channelId: String) throws -> MattermostPeer? {
        if let peer = try peer(mattermostId: channelId), peer.kind != .user {
            return peer
        }
        var peer: MattermostPeer?
        try connection.query(
            "SELECT p.mm_id, p.kind, p.peer_id, p.team_id FROM dm_channels d JOIN peers p ON p.mm_id = d.user_mm_id WHERE d.channel_id = ?1",
            [.text(channelId)]
        ) { row in
            peer = readPeer(row)
        }
        return peer
    }

    /// Returns the peer of a Mattermost user, channel or GM, allocating the next sequential id of
    /// its namespace (starting at 1, skipping ids already taken, e.g. the own user's reserved id)
    /// the first time. A known id keeps its peer id; its kind (GM converted to a channel) and a
    /// non-nil `teamId` are updated. Throws `peerNamespaceMismatch` if the id is known in the other
    /// namespace.
    @discardableResult
    public func allocatePeer(mattermostId: String, kind: MattermostPeerKind, teamId: String? = nil) throws -> MattermostPeer {
        func merged(_ existing: MattermostPeer) throws -> MattermostPeer {
            guard existing.namespace == kind.namespace else {
                throw MattermostSyncStoreError.peerNamespaceMismatch(mattermostId: mattermostId, existing: existing.kind, requested: kind)
            }
            return MattermostPeer(mattermostId: mattermostId, kind: kind, peerId: existing.peerId, teamId: teamId ?? existing.teamId)
        }
        // Known and unchanged (the common case): no write transaction.
        if let existing = try peer(mattermostId: mattermostId), try merged(existing) == existing {
            return existing
        }
        return try writeTransaction {
            if let existing = try peer(mattermostId: mattermostId) {
                let updated = try merged(existing)
                if updated != existing {
                    try connection.execute("UPDATE peers SET kind = ?2, team_id = ?3 WHERE mm_id = ?1", [.text(mattermostId), .text(kind.rawValue), .optionalText(updated.teamId)])
                }
                return updated
            }
            let namespace = kind.namespace
            let peerId = try allocateSequential("peer.\(namespace.rawValue)") { candidate in
                try peer(namespace: namespace, peerId: candidate) == nil
            }
            let peer = MattermostPeer(mattermostId: mattermostId, kind: kind, peerId: peerId, teamId: teamId)
            try insertPeer(peer)
            return peer
        }
    }

    /// Maps the own user to `hash`, the stable peer id derived from `(server URL, user id)` that
    /// keeps two accounts from ever sharing a `PeerId`. Sequential allocation skips it. Idempotent
    /// for the same hash; throws `ownUserAlreadyAllocated` if the user already has another id and
    /// `peerIdTaken` if another user has this one. Call it before the own user is allocated
    /// any other way (at login, before bootstrap).
    @discardableResult
    public func reserveOwnUserPeerId(userId: String, hash: Int64) throws -> MattermostPeer {
        guard hash > 0 else {
            throw MattermostSyncStoreError.invalidPeerId(hash)
        }
        return try writeTransaction {
            if let existing = try peer(mattermostId: userId) {
                guard existing.kind == .user else {
                    throw MattermostSyncStoreError.peerNamespaceMismatch(mattermostId: userId, existing: existing.kind, requested: .user)
                }
                guard existing.peerId == hash else {
                    throw MattermostSyncStoreError.ownUserAlreadyAllocated(mattermostId: userId, peerId: existing.peerId)
                }
                return existing
            }
            if let other = try peer(namespace: .user, peerId: hash) {
                throw MattermostSyncStoreError.peerIdTaken(namespace: .user, peerId: hash, mattermostId: other.mattermostId)
            }
            let peer = MattermostPeer(mattermostId: userId, kind: .user, peerId: hash)
            try insertPeer(peer)
            return peer
        }
    }

    private func insertPeer(_ peer: MattermostPeer) throws {
        try connection.execute(
            "INSERT INTO peers (mm_id, kind, namespace, peer_id, team_id) VALUES (?1, ?2, ?3, ?4, ?5)",
            [.text(peer.mattermostId), .text(peer.kind.rawValue), .integer(Int64(peer.namespace.rawValue)), .integer(peer.peerId), .optionalText(peer.teamId)]
        )
    }

    /// Takes the next value of a sequence (starting at 1) for which `isFree` holds.
    private func allocateSequential(_ sequence: String, isFree: (Int64) throws -> Bool) throws -> Int64 {
        var candidate: Int64 = 1
        try connection.query("SELECT next_value FROM sequences WHERE name = ?1", [.text(sequence)]) { row in
            candidate = max(1, row.int64(0))
        }
        while try !isFree(candidate) {
            candidate += 1
        }
        try connection.execute("INSERT OR REPLACE INTO sequences (name, next_value) VALUES (?1, ?2)", [.text(sequence), .integer(candidate + 1)])
        return candidate
    }

    // MARK: - DM channels

    /// Records that `channelId` is the DM with `userId` (the own user for the self-DM).
    public func setDirectChannel(channelId: String, userId: String) throws {
        try connection.execute("INSERT OR REPLACE INTO dm_channels (channel_id, user_mm_id) VALUES (?1, ?2)", [.text(channelId), .text(userId)])
    }

    /// The other user of a DM channel.
    public func directChannelUserId(channelId: String) throws -> String? {
        var userId: String?
        try connection.query("SELECT user_mm_id FROM dm_channels WHERE channel_id = ?1", [.text(channelId)]) { row in
            userId = row.string(0)
        }
        return userId
    }

    /// The DM channel with a user (where to post when a user peer is written to).
    public func directChannelId(userId: String) throws -> String? {
        var channelId: String?
        try connection.query("SELECT channel_id FROM dm_channels WHERE user_mm_id = ?1 LIMIT 1", [.text(userId)]) { row in
            channelId = row.string(0)
        }
        return channelId
    }

    // MARK: - Pending posts

    private static let pendingColumns = "pending_post_id, channel_id, globally_unique_id, local_message_id"

    private func pendingPosts(where condition: String, _ bindings: [SQLiteValue]) throws -> [MattermostPendingPost] {
        var posts: [MattermostPendingPost] = []
        try connection.query("SELECT \(Self.pendingColumns) FROM pending \(condition)", bindings) { row in
            posts.append(MattermostPendingPost(pendingPostId: row.string(0), channelId: row.string(1), globallyUniqueId: row.int64(2), localMessageId: Int32(truncatingIfNeeded: row.int64(3))))
        }
        return posts
    }

    /// Records an outgoing post. Idempotent: a known `pendingPostId` returns the stored record
    /// unchanged. A `globallyUniqueId` used by another pending post is an error.
    @discardableResult
    public func registerPendingPost(_ post: MattermostPendingPost) throws -> MattermostPendingPost {
        return try writeTransaction {
            if let existing = try pendingPost(pendingPostId: post.pendingPostId) {
                return existing
            }
            try connection.execute(
                "INSERT INTO pending (pending_post_id, channel_id, globally_unique_id, local_message_id) VALUES (?1, ?2, ?3, ?4)",
                [.text(post.pendingPostId), .text(post.channelId), .integer(post.globallyUniqueId), .integer(Int64(post.localMessageId))]
            )
            return post
        }
    }

    public func pendingPost(pendingPostId: String) throws -> MattermostPendingPost? {
        return try pendingPosts(where: "WHERE pending_post_id = ?1", [.text(pendingPostId)]).first
    }

    public func pendingPost(globallyUniqueId: Int64) throws -> MattermostPendingPost? {
        return try pendingPosts(where: "WHERE globally_unique_id = ?1", [.integer(globallyUniqueId)]).first
    }

    /// The most recently registered pending post for a local message.
    public func pendingPost(channelId: String, localMessageId: Int32) throws -> MattermostPendingPost? {
        return try pendingPosts(where: "WHERE channel_id = ?1 AND local_message_id = ?2 ORDER BY rowid DESC LIMIT 1", [.text(channelId), .integer(Int64(localMessageId))]).first
    }

    /// All pending posts, oldest first.
    public func allPendingPosts() throws -> [MattermostPendingPost] {
        return try pendingPosts(where: "ORDER BY rowid", [])
    }

    public func removePendingPost(pendingPostId: String) throws {
        try connection.execute("DELETE FROM pending WHERE pending_post_id = ?1", [.text(pendingPostId)])
    }

    // MARK: - Files

    /// The media id of a Mattermost file, allocating the next sequential id (starting at 1) the
    /// first time. The same file in several posts shares one media id.
    public func allocateMediaId(fileId: String) throws -> Int64 {
        if let existing = try mediaId(fileId: fileId) {
            return existing
        }
        return try writeTransaction {
            if let existing = try mediaId(fileId: fileId) {
                return existing
            }
            let mediaId = try allocateSequential("media") { candidate in
                try self.fileId(mediaId: candidate) == nil
            }
            try connection.execute("INSERT INTO files (file_id, media_id) VALUES (?1, ?2)", [.text(fileId), .integer(mediaId)])
            return mediaId
        }
    }

    public func mediaId(fileId: String) throws -> Int64? {
        var mediaId: Int64?
        try connection.query("SELECT media_id FROM files WHERE file_id = ?1", [.text(fileId)]) { row in
            mediaId = row.int64(0)
        }
        return mediaId
    }

    public func fileId(mediaId: Int64) throws -> String? {
        var fileId: String?
        try connection.query("SELECT file_id FROM files WHERE media_id = ?1", [.integer(mediaId)]) { row in
            fileId = row.string(0)
        }
        return fileId
    }

    // MARK: - Cursors

    /// See `MattermostSyncCursorKey` for the well-known keys.
    public func cursor(_ key: String) throws -> String? {
        var value: String?
        try connection.query("SELECT value FROM cursors WHERE key = ?1", [.text(key)]) { row in
            value = row.string(0)
        }
        return value
    }

    /// Sets a cursor; nil removes it.
    public func setCursor(_ key: String, _ value: String?) throws {
        if let value = value {
            try connection.execute("INSERT OR REPLACE INTO cursors (key, value) VALUES (?1, ?2)", [.text(key), .text(value)])
        } else {
            try connection.execute("DELETE FROM cursors WHERE key = ?1", [.text(key)])
        }
    }
}
