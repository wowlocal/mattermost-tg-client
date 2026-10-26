import Foundation

/// The message id map's statements (internal so tests can check their query plans).
enum MessageIdSQL {
    static let entryColumns = "create_at_ms, post_id, local_id, tombstone"
    static let entryByPostId = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 AND post_id = ?2"
    static let entriesInKeyRange = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 AND (create_at_ms, post_id) >= (?2, ?3) AND (create_at_ms, post_id) <= (?4, ?5) ORDER BY create_at_ms, post_id"
    static let entriesOlderThanKey = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 AND (create_at_ms, post_id) < (?2, ?3) ORDER BY create_at_ms DESC, post_id DESC LIMIT ?4"
    static let newestEntries = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 ORDER BY create_at_ms DESC, post_id DESC LIMIT ?2"
    static let entriesNewerThanKey = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 AND (create_at_ms, post_id) > (?2, ?3) ORDER BY create_at_ms, post_id LIMIT ?4"
    static let oldestEntries = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 ORDER BY create_at_ms, post_id LIMIT ?2"
    static let entriesFromLocalIdUp = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 AND local_id >= ?2 ORDER BY local_id LIMIT ?3"
    static let entriesFromLocalIdDown = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 AND local_id <= ?2 ORDER BY local_id DESC LIMIT ?3"
    static let allEntries = "SELECT \(entryColumns) FROM posts WHERE channel_key = ?1 ORDER BY create_at_ms, post_id"
    static let islands = "SELECT lower_create_at_ms, lower_post_id, upper_create_at_ms, upper_post_id, reaches_start, reaches_latest FROM islands WHERE channel_key = ?1 ORDER BY ordinal"
    static let tombstone = "SELECT 1 FROM post_tombstones WHERE channel_key = ?1 AND post_id = ?2"

    static let setLocalId = "UPDATE posts SET local_id = ?3 WHERE channel_key = ?1 AND post_id = ?2"
    static let insertEntry = "INSERT INTO posts (channel_key, create_at_ms, post_id, local_id, tombstone) SELECT ?1, ?2, ?3, ?4, ?5 WHERE NOT EXISTS (SELECT 1 FROM posts WHERE channel_key = ?1 AND post_id = ?3)"
    static let markDeleted = "UPDATE posts SET tombstone = 1 WHERE channel_key = ?1 AND post_id = ?2"
    static let insertTombstone = "INSERT OR IGNORE INTO post_tombstones (channel_key, post_id) SELECT ?1, ?2 WHERE NOT EXISTS (SELECT 1 FROM posts WHERE channel_key = ?1 AND post_id = ?2)"
    static let deleteIslands = "DELETE FROM islands WHERE channel_key = ?1"
    static let insertIsland = "INSERT INTO islands (channel_key, ordinal, lower_create_at_ms, lower_post_id, upper_create_at_ms, upper_post_id, reaches_start, reaches_latest) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"

    static let setThreadRoot = "UPDATE posts SET thread_root_id = ?3 WHERE channel_key = ?1 AND post_id = ?2"
    /// Without ANALYZE statistics SQLite assumes `channel_key = ?` matches ~10 rows and would scan
    /// the channel instead, so the index is named.
    static let threadReplies = "SELECT \(entryColumns) FROM posts INDEXED BY posts_by_thread_root WHERE channel_key = ?1 AND thread_root_id = ?2 ORDER BY create_at_ms, post_id"
    static let threadRootOfPost = "SELECT thread_root_id FROM posts WHERE channel_key = ?1 AND post_id = ?2 AND thread_root_id IS NOT NULL"
}

/// The message id map on the `posts`, `post_tombstones` and `islands` tables. Semantics match
/// `InMemoryMessageIdStore` for every change set the allocator produces. Change sets that would
/// break an invariant the schema enforces (two posts with one local id, one post id twice in a
/// channel) fail and are rolled back as a whole, where the in-memory store would accept them.
extension SQLiteMattermostSyncStore: MessageIdStore {
    // MARK: Channel keys

    private func existingChannelKey(_ channelId: String) throws -> Int64? {
        if let key = channelKeys[channelId] {
            return key
        }
        var key: Int64?
        try connection.query("SELECT channel_key FROM post_channels WHERE channel_id = ?1", [.text(channelId)]) { row in
            key = row.int64(0)
        }
        if let key = key {
            channelKeys[channelId] = key
        }
        return key
    }

    /// Only called inside a write transaction (a rollback clears the cache).
    private func channelKey(creating channelId: String) throws -> Int64 {
        if let key = try existingChannelKey(channelId) {
            return key
        }
        try connection.execute("INSERT INTO post_channels (channel_id) VALUES (?1)", [.text(channelId)])
        let key = connection.lastInsertRowId
        channelKeys[channelId] = key
        return key
    }

    // MARK: Reading

    private func readEntry(_ row: SQLiteRow) -> MessageIdEntry {
        return MessageIdEntry(key: PostOrderKey(createAt: row.int64(0), postId: row.string(1)), localId: Int32(truncatingIfNeeded: row.int64(2)), isDeleted: row.bool(3))
    }

    private func readEntries(_ sql: String, _ bindings: [SQLiteValue]) throws -> [MessageIdEntry] {
        var entries: [MessageIdEntry] = []
        try connection.query(sql, bindings) { row in
            entries.append(readEntry(row))
        }
        return entries
    }

    /// Runs a `MessageIdStore` query, recording a failure in `messageIdError`.
    private func recording<T>(_ fallback: T, _ body: () throws -> T) -> T {
        do {
            return try body()
        } catch {
            recordMessageIdError(error)
            return fallback
        }
    }

    private func recordMessageIdError(_ error: Error) {
        if messageIdError == nil {
            messageIdError = (error as? MattermostSyncStoreError) ?? .sqlite(code: 1, message: "\(error)")
        }
    }

    // MARK: MessageIdStore

    public func entries(channelId: String, postIds: [String]) -> [String: MessageIdEntry] {
        return recording([:]) {
            guard !postIds.isEmpty, let channel = try existingChannelKey(channelId) else {
                return [:]
            }
            var result: [String: MessageIdEntry] = [:]
            for postId in postIds where result[postId] == nil {
                try connection.query(MessageIdSQL.entryByPostId, [.integer(channel), .text(postId)]) { row in
                    result[postId] = readEntry(row)
                }
            }
            return result
        }
    }

    public func entries(channelId: String, keyRange: ClosedRange<PostOrderKey>) -> [MessageIdEntry] {
        return recording([]) {
            guard let channel = try existingChannelKey(channelId) else {
                return []
            }
            let lower = keyRange.lowerBound
            let upper = keyRange.upperBound
            return try readEntries(MessageIdSQL.entriesInKeyRange, [.integer(channel), .integer(lower.createAt), .text(lower.postId), .integer(upper.createAt), .text(upper.postId)])
        }
    }

    public func entries(channelId: String, olderThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        return recording([]) {
            guard limit > 0, let channel = try existingChannelKey(channelId) else {
                return []
            }
            if let key = key {
                return try readEntries(MessageIdSQL.entriesOlderThanKey, [.integer(channel), .integer(key.createAt), .text(key.postId), .integer(Int64(limit))])
            }
            return try readEntries(MessageIdSQL.newestEntries, [.integer(channel), .integer(Int64(limit))])
        }
    }

    public func entries(channelId: String, newerThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        return recording([]) {
            guard limit > 0, let channel = try existingChannelKey(channelId) else {
                return []
            }
            if let key = key {
                return try readEntries(MessageIdSQL.entriesNewerThanKey, [.integer(channel), .integer(key.createAt), .text(key.postId), .integer(Int64(limit))])
            }
            return try readEntries(MessageIdSQL.oldestEntries, [.integer(channel), .integer(Int64(limit))])
        }
    }

    public func entries(channelId: String, fromLocalId localId: Int32, ascending: Bool, limit: Int) -> [MessageIdEntry] {
        return recording([]) {
            guard limit > 0, let channel = try existingChannelKey(channelId) else {
                return []
            }
            return try readEntries(ascending ? MessageIdSQL.entriesFromLocalIdUp : MessageIdSQL.entriesFromLocalIdDown, [.integer(channel), .integer(Int64(localId)), .integer(Int64(limit))])
        }
    }

    public func islands(channelId: String) -> [HistoryIsland] {
        return recording([]) {
            guard let channel = try existingChannelKey(channelId) else {
                return []
            }
            return try readIslands(channel: channel)
        }
    }

    private func readIslands(channel: Int64) throws -> [HistoryIsland] {
        var islands: [HistoryIsland] = []
        try connection.query(MessageIdSQL.islands, [.integer(channel)]) { row in
            islands.append(HistoryIsland(
                lower: PostOrderKey(createAt: row.int64(0), postId: row.string(1)),
                upper: PostOrderKey(createAt: row.int64(2), postId: row.string(3)),
                reachesStart: row.bool(4),
                reachesLatest: row.bool(5)
            ))
        }
        return islands
    }

    public func unmappedTombstones(channelId: String, among postIds: [String]) -> Set<String> {
        return recording([]) {
            guard !postIds.isEmpty, let channel = try existingChannelKey(channelId) else {
                return []
            }
            var result = Set<String>()
            for postId in postIds where !result.contains(postId) {
                try connection.query(MessageIdSQL.tombstone, [.integer(channel), .text(postId)]) { _ in
                    result.insert(postId)
                }
            }
            return result
        }
    }

    /// Applies the change set in one transaction (a savepoint inside `transaction(_:)`). On
    /// failure nothing is written and the error is recorded in `messageIdError`. Does nothing
    /// while `messageIdError` is set.
    public func apply(_ changes: MessageIdChangeSet) {
        if changes.isEmpty || messageIdError != nil {
            return
        }
        do {
            try writeTransaction {
                try applyChanges(changes)
            }
        } catch {
            recordMessageIdError(error)
        }
    }

    private func applyChanges(_ changes: MessageIdChangeSet) throws {
        let channel = try channelKey(creating: changes.channelId)
        // Moves may swap ids between posts, and `posts_by_local_id` is unique: park every moved
        // post on a distinct negative id first, then set the final ids.
        for (index, move) in changes.renumbered.enumerated() {
            try connection.execute(MessageIdSQL.setLocalId, [.integer(channel), .text(move.postId), .integer(-Int64(index) - 1)])
        }
        for move in changes.renumbered {
            try connection.execute(MessageIdSQL.setLocalId, [.integer(channel), .text(move.postId), .integer(Int64(move.to))])
        }
        for entry in changes.inserted {
            try connection.execute(MessageIdSQL.insertEntry, [.integer(channel), .integer(entry.createAt), .text(entry.postId), .integer(Int64(entry.localId)), .bool(entry.isDeleted)])
        }
        for postId in changes.deletedPostIds {
            try connection.execute(MessageIdSQL.markDeleted, [.integer(channel), .text(postId)])
        }
        for postId in changes.unmappedTombstones {
            try connection.execute(MessageIdSQL.insertTombstone, [.integer(channel), .text(postId)])
        }
        if let islands = changes.islands {
            try connection.execute(MessageIdSQL.deleteIslands, [.integer(channel)])
            for (ordinal, island) in islands.enumerated() {
                try connection.execute(MessageIdSQL.insertIsland, [
                    .integer(channel), .integer(Int64(ordinal)),
                    .integer(island.lower.createAt), .text(island.lower.postId),
                    .integer(island.upper.createAt), .text(island.upper.postId),
                    .bool(island.reachesStart), .bool(island.reachesLatest),
                ])
            }
        }
    }

    // MARK: Thread roots

    /// Records the thread root (`root_id`) of mapped posts (post id → root post id), so that the
    /// replies of a root moved by a `RenumberPlan` can be found with `threadReplies`. Unmapped
    /// post ids are ignored.
    public func setThreadRootIds(_ rootIdByPostId: [String: String], channelId: String) throws {
        guard !rootIdByPostId.isEmpty, let channel = try existingChannelKey(channelId) else {
            return
        }
        try writeTransaction {
            for (postId, rootId) in rootIdByPostId {
                try connection.execute(MessageIdSQL.setThreadRoot, [.integer(channel), .text(postId), .text(rootId)])
            }
        }
    }

    /// Mapped replies of the given thread roots, by root post id, each in key order.
    public func threadReplies(rootPostIds: [String], channelId: String) throws -> [String: [MessageIdEntry]] {
        guard let channel = try existingChannelKey(channelId) else {
            return [:]
        }
        var result: [String: [MessageIdEntry]] = [:]
        for rootId in rootPostIds where result[rootId] == nil {
            let replies = try readEntries(MessageIdSQL.threadReplies, [.integer(channel), .text(rootId)])
            if !replies.isEmpty {
                result[rootId] = replies
            }
        }
        return result
    }

    /// The thread root recorded for a mapped post (or part), or nil for a root post and unknown posts.
    public func threadRootId(postId: String, channelId: String) throws -> String? {
        guard let channel = try existingChannelKey(channelId) else {
            return nil
        }
        var rootId: String?
        try connection.query(MessageIdSQL.threadRootOfPost, [.integer(channel), .text(postId)]) { row in
            rootId = row.optionalString(0)
        }
        return rootId.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Maintenance and inspection

    /// Removes everything the id map knows about a channel (full resync).
    public func removeChannel(_ channelId: String) throws {
        try writeTransaction {
            try connection.execute("DELETE FROM post_channels WHERE channel_id = ?1", [.text(channelId)])
        }
        channelKeys.removeValue(forKey: channelId)
    }

    /// All entries of a channel in key order. Failures are recorded in `messageIdError`.
    public func allEntries(channelId: String) -> [MessageIdEntry] {
        return recording([]) {
            guard let channel = try existingChannelKey(channelId) else {
                return []
            }
            return try readEntries(MessageIdSQL.allEntries, [.integer(channel)])
        }
    }

    /// Checks the id map invariants (as `InMemoryMessageIdStore.validate` does) and returns every
    /// violation found, including a recorded `messageIdError` or a failed read.
    public func validate(channelId: String, maxId: Int32 = Int32.max) -> [String] {
        var problems: [String] = []
        if let error = messageIdError {
            problems.append("recorded error: \(error)")
        }
        do {
            if let channel = try existingChannelKey(channelId) {
                let entries = try readEntries(MessageIdSQL.allEntries, [.integer(channel)])
                problems += InMemoryMessageIdStore.invariantProblems(entries: entries, islands: try readIslands(channel: channel), maxId: maxId)
            }
        } catch {
            problems.append("read failed: \(error)")
        }
        return problems
    }
}
