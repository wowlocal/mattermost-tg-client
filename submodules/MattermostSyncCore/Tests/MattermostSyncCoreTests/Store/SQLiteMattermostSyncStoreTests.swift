import XCTest
@testable import MattermostSyncCore

/// `SQLiteMattermostSyncStore`: schema and migrations, persistence, and the peer, DM channel,
/// pending post, file, cursor and server tables.
final class SQLiteMattermostSyncStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    /// Nested like the real `<rootPath>/account-<id>/mattermost/sync.sqlite`.
    private var path: String {
        return directory.path("account-1/mattermost/sync.sqlite")
    }

    private func open() throws -> SQLiteMattermostSyncStore {
        return try SQLiteMattermostSyncStore(path: path)
    }

    private func pragma(_ name: String, _ store: SQLiteMattermostSyncStore) throws -> [String] {
        var values: [String] = []
        try store.connection.query("PRAGMA \(name)") { row in
            values.append(row.string(0))
        }
        return values
    }

    // MARK: Schema

    func testCreatesDirectoriesAndSchema() throws {
        let store = try open()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try store.storedSchemaVersion(), SQLiteMattermostSyncStore.schemaVersion)
        XCTAssertEqual(try pragma("journal_mode", store), ["wal"])
        XCTAssertEqual(try pragma("foreign_keys", store), ["1"])
        XCTAssertEqual(try pragma("integrity_check", store), ["ok"])
    }

    func testMigratesAnEmptyFile() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
        let store = try open()
        XCTAssertEqual(try store.storedSchemaVersion(), SQLiteMattermostSyncStore.schemaVersion)
        try store.setCursor("k", "v")
        XCTAssertEqual(try store.cursor("k"), "v")
    }

    func testMigrationsRunForwardOnlyInOneTransaction() throws {
        let current = MattermostSyncStoreSchema.migrations
        var store = try SQLiteMattermostSyncStore(path: path, migrations: current)
        try store.setCursor(MattermostSyncCursorKey.lastSyncAt, "100")
        try store.allocatePeer(mattermostId: "u1", kind: .user)
        store.close()

        // A failing migration leaves the file at its version: its first statement is undone too.
        XCTAssertThrowsError(try SQLiteMattermostSyncStore(path: path, migrations: current + ["CREATE TABLE extra (x INTEGER); INSERT INTO missing VALUES (1);"]))
        store = try SQLiteMattermostSyncStore(path: path, migrations: current)
        XCTAssertEqual(try store.storedSchemaVersion(), current.count)
        XCTAssertEqual(try store.cursor(MattermostSyncCursorKey.lastSyncAt), "100")
        store.close()

        // The next version runs once, on top of the existing data.
        let next = current + ["CREATE TABLE extra (x INTEGER); INSERT INTO extra VALUES (42);"]
        store = try SQLiteMattermostSyncStore(path: path, migrations: next)
        XCTAssertEqual(try store.storedSchemaVersion(), current.count + 1)
        store.close()
        store = try SQLiteMattermostSyncStore(path: path, migrations: next)
        var rows: [Int64] = []
        try store.connection.query("SELECT x FROM extra") { row in
            rows.append(row.int64(0))
        }
        XCTAssertEqual(rows, [42], "not re-run on the next open")
        XCTAssertEqual(try store.peer(mattermostId: "u1")?.peerId, 1)
        store.close()

        // This build refuses a file written by a newer one.
        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? MattermostSyncStoreError, .unsupportedSchemaVersion(found: current.count + 1, supported: current.count))
        }
    }

    // MARK: Persistence

    func testReopenPreservesEverything() throws {
        var store = try open()
        let server = MattermostServerInfo(url: "https://chat.example.com", userId: "me", siteName: "Example", version: "10.5.0", capabilitiesJSON: #"{"collapsedThreads":"default_on"}"#)
        try store.setServerInfo(server)
        let own = try store.reserveOwnUserPeerId(userId: "me", hash: 0x7FFF_0000_1234)
        let alice = try store.allocatePeer(mattermostId: "alice", kind: .user)
        let town = try store.allocatePeer(mattermostId: "town-square", kind: .channel, teamId: "team-1")
        let gm = try store.allocatePeer(mattermostId: "gm-1", kind: .groupMessage)
        try store.setDirectChannel(channelId: "dm-alice", userId: "alice")
        try store.setDirectChannel(channelId: "dm-self", userId: "me")
        let pending = MattermostPendingPost(pendingPostId: "me:1700000000000", channelId: "town-square", globallyUniqueId: -42, localMessageId: 7)
        try store.registerPendingPost(pending)
        let media = try store.allocateMediaId(fileId: "file-1")
        try store.setCursor(MattermostSyncCursorKey.webSocketSequence, "17")

        var rng = SeededGenerator(seed: 31)
        let posts = makePosts(count: 30, start: Times.year2026, spacing: 60_000, rng: &rng)
        let allocator = MessageIdAllocator()
        _ = try store.transaction { store in
            try allocator.ingestLatestPage(posts, reachedStart: false, channelId: "town-square", store: &store)
        }
        allocator.markDeleted([posts[3].postId, "unmapped"], channelId: "town-square", store: &store)
        try store.setThreadRootIds([posts[5].postId: posts[4].postId], channelId: "town-square")
        let entries = store.allEntries(channelId: "town-square")
        let islands = store.islands(channelId: "town-square")
        XCTAssertNil(store.messageIdError)
        store.close()

        store = try open()
        XCTAssertEqual(try store.serverInfo(), server)
        XCTAssertEqual(try store.peer(mattermostId: "me"), own)
        XCTAssertEqual(try store.peer(namespace: .user, peerId: alice.peerId), alice)
        XCTAssertEqual(try store.peer(mattermostId: "town-square"), town)
        XCTAssertEqual(try store.peer(namespace: .channel, peerId: gm.peerId), gm)
        XCTAssertEqual(try store.peer(channelId: "dm-alice"), alice)
        XCTAssertEqual(try store.peer(channelId: "dm-self"), own)
        XCTAssertEqual(try store.peer(channelId: "gm-1"), gm)
        XCTAssertEqual(try store.pendingPost(globallyUniqueId: -42), pending)
        XCTAssertEqual(try store.mediaId(fileId: "file-1"), media)
        XCTAssertEqual(try store.cursor(MattermostSyncCursorKey.webSocketSequence), "17")
        XCTAssertEqual(store.allEntries(channelId: "town-square"), entries)
        XCTAssertEqual(store.islands(channelId: "town-square"), islands)
        XCTAssertEqual(store.unmappedTombstones(channelId: "town-square", among: ["unmapped", posts[3].postId]), ["unmapped"])
        XCTAssertEqual(try store.threadReplies(rootPostIds: [posts[4].postId], channelId: "town-square")[posts[4].postId]?.map { $0.postId }, [posts[5].postId])
        XCTAssertEqual(store.validate(channelId: "town-square"), [])
        // Sequences continue where they stopped.
        XCTAssertEqual(try store.allocatePeer(mattermostId: "bob", kind: .user).peerId, alice.peerId + 1)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "off-topic", kind: .channel).peerId, gm.peerId + 1)
        XCTAssertEqual(try store.allocateMediaId(fileId: "file-2"), media + 1)
    }

    /// Another process (an extension) reads committed data while the app holds the store open.
    func testSecondConnectionReadsCommittedData() throws {
        let writer = try open()
        try writer.setCursor("k", "1")
        let reader = try open()
        XCTAssertEqual(try reader.cursor("k"), "1")
        try writer.transaction { store in
            try store.setCursor("k", "2")
            XCTAssertEqual(try reader.cursor("k"), "1", "uncommitted writes are invisible")
        }
        XCTAssertEqual(try reader.cursor("k"), "2")
    }

    // MARK: Peers

    /// Sequential allocation skips the user ids Telegram's code special-cases (service notifications
    /// 777000, Replies, verification codes, …); channels only skip 0.
    func testPeerAllocationSkipsTelegramSpecialUserIds() throws {
        let store = try open()
        XCTAssertTrue(ReservedPeerIds.isReserved(777000, in: .user))
        XCTAssertTrue(ReservedPeerIds.isReserved(1271266957, in: .user))
        XCTAssertFalse(ReservedPeerIds.isReserved(777000, in: .channel))
        XCTAssertFalse(ReservedPeerIds.isReserved(1, in: .user))

        func setNext(_ value: Int64, _ namespace: MattermostPeerNamespace) throws {
            try store.connection.execute("INSERT OR REPLACE INTO sequences (name, next_value) VALUES (?1, ?2)", [.text("peer.\(namespace.rawValue)"), .integer(value)])
        }
        for reserved in ReservedPeerIds.users.sorted() where reserved > 0 {
            try setNext(reserved - 1, .user)
            let before = try store.allocatePeer(mattermostId: "before-\(reserved)", kind: .user)
            let after = try store.allocatePeer(mattermostId: "after-\(reserved)", kind: .user)
            XCTAssertEqual(before.peerId, reserved - 1)
            XCTAssertEqual(after.peerId, reserved + 1, "user id \(reserved) must be skipped")
        }
        // Starting exactly at a reserved id.
        try setNext(777000, .user)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "at-777000", kind: .user).peerId, 777002, "777000 is reserved, 777001 taken above")
        // Channels and GMs may use the same numbers.
        try setNext(777000, .channel)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "c-777000", kind: .channel, teamId: "t").peerId, 777000)
        // A sequence starting below 1 never hands out 0.
        try setNext(0, .user)
        XCTAssertNotEqual(try store.allocatePeer(mattermostId: "zero", kind: .user).peerId, 0)
        // Every allocated user id is outside the reserved set.
        var ids = Set<Int64>()
        try store.connection.query("SELECT peer_id FROM peers WHERE kind = 'user'") { row in
            ids.insert(row.int64(0))
        }
        XCTAssertTrue(ids.isDisjoint(with: ReservedPeerIds.users))
    }

    func testPeerIdsAreSequentialPerNamespaceAndStable() throws {
        let store = try open()
        XCTAssertEqual(try store.allocatePeer(mattermostId: "u1", kind: .user).peerId, 1)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "u2", kind: .user).peerId, 2)
        // Channels and GMs share the CloudChannel namespace; users have their own.
        XCTAssertEqual(try store.allocatePeer(mattermostId: "c1", kind: .channel, teamId: "t1").peerId, 1)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "g1", kind: .groupMessage).peerId, 2)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "u3", kind: .user).peerId, 3)

        // Known ids keep their peer id; a nil team keeps the stored one.
        XCTAssertEqual(try store.allocatePeer(mattermostId: "u2", kind: .user), MattermostPeer(mattermostId: "u2", kind: .user, peerId: 2))
        XCTAssertEqual(try store.allocatePeer(mattermostId: "c1", kind: .channel), MattermostPeer(mattermostId: "c1", kind: .channel, peerId: 1, teamId: "t1"))
        // A GM converted to a private channel, a channel moved to another team: same peer.
        XCTAssertEqual(try store.allocatePeer(mattermostId: "g1", kind: .channel, teamId: "t2"), MattermostPeer(mattermostId: "g1", kind: .channel, peerId: 2, teamId: "t2"))
        XCTAssertEqual(try store.peer(mattermostId: "g1"), MattermostPeer(mattermostId: "g1", kind: .channel, peerId: 2, teamId: "t2"))
        XCTAssertEqual(try store.allocatePeer(mattermostId: "c2", kind: .channel).peerId, 3)

        // An id never moves to the other namespace.
        XCTAssertThrowsError(try store.allocatePeer(mattermostId: "u1", kind: .groupMessage)) { error in
            XCTAssertEqual(error as? MattermostSyncStoreError, .peerNamespaceMismatch(mattermostId: "u1", existing: .user, requested: .groupMessage))
        }
        XCTAssertEqual(try store.peer(namespace: .user, peerId: 3)?.mattermostId, "u3")
        XCTAssertEqual(try store.peer(namespace: .channel, peerId: 3)?.mattermostId, "c2")
        XCTAssertNil(try store.peer(namespace: .channel, peerId: 4))
        XCTAssertNil(try store.peer(mattermostId: "nobody"))
    }

    func testOwnUserReservationNeverCollidesWithSequentialIds() throws {
        let store = try open()
        // A low reserved id: sequential allocation steps over it.
        let own = try store.reserveOwnUserPeerId(userId: "me", hash: 3)
        XCTAssertEqual(own, MattermostPeer(mattermostId: "me", kind: .user, peerId: 3))
        let ids = try (1 ... 5).map { try store.allocatePeer(mattermostId: "u\($0)", kind: .user).peerId }
        XCTAssertEqual(ids, [1, 2, 4, 5, 6])
        // Idempotent, and allocating the own user as a user later returns the reserved id.
        XCTAssertEqual(try store.reserveOwnUserPeerId(userId: "me", hash: 3), own)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "me", kind: .user), own)
        XCTAssertEqual(try store.allocatePeer(mattermostId: "c1", kind: .channel).peerId, 1, "other namespace unaffected")

        XCTAssertThrowsError(try store.reserveOwnUserPeerId(userId: "me", hash: 1 << 40)) { error in
            XCTAssertEqual(error as? MattermostSyncStoreError, .ownUserAlreadyAllocated(mattermostId: "me", peerId: 3))
        }
        XCTAssertThrowsError(try store.reserveOwnUserPeerId(userId: "other", hash: 2)) { error in
            XCTAssertEqual(error as? MattermostSyncStoreError, .peerIdTaken(namespace: .user, peerId: 2, mattermostId: "u2"))
        }
        XCTAssertThrowsError(try store.reserveOwnUserPeerId(userId: "c1", hash: 1 << 40)) { error in
            XCTAssertEqual(error as? MattermostSyncStoreError, .peerNamespaceMismatch(mattermostId: "c1", existing: .channel, requested: .user))
        }
        XCTAssertThrowsError(try store.reserveOwnUserPeerId(userId: "x", hash: 0)) { error in
            XCTAssertEqual(error as? MattermostSyncStoreError, .invalidPeerId(0))
        }
        XCTAssertNil(try store.peer(mattermostId: "other"))
        XCTAssertNil(try store.peer(mattermostId: "x"))

        // The usual case: a hash far above the sequential range.
        let fresh = try SQLiteMattermostSyncStore(path: directory.path("fresh.sqlite"))
        let hash: Int64 = 0x7FFF_ABCD_0001
        XCTAssertEqual(try fresh.reserveOwnUserPeerId(userId: "me", hash: hash).peerId, hash)
        XCTAssertEqual(try fresh.allocatePeer(mattermostId: "u1", kind: .user).peerId, 1)
        XCTAssertEqual(try fresh.allocatePeer(mattermostId: "u2", kind: .user).peerId, 2)
    }

    func testDirectChannelsResolveToTheOtherUser() throws {
        let store = try open()
        let alice = try store.allocatePeer(mattermostId: "alice", kind: .user)
        try store.setDirectChannel(channelId: "dm-1", userId: "alice")
        XCTAssertEqual(try store.directChannelUserId(channelId: "dm-1"), "alice")
        XCTAssertEqual(try store.directChannelId(userId: "alice"), "dm-1")
        XCTAssertEqual(try store.peer(channelId: "dm-1"), alice)
        XCTAssertNil(try store.peer(channelId: "dm-unknown"))
        XCTAssertNil(try store.directChannelId(userId: "nobody"))
        // A DM registered before its user resolves once the user is known.
        try store.setDirectChannel(channelId: "dm-2", userId: "bob")
        XCTAssertNil(try store.peer(channelId: "dm-2"))
        let bob = try store.allocatePeer(mattermostId: "bob", kind: .user)
        XCTAssertEqual(try store.peer(channelId: "dm-2"), bob)
        // A user id is not a channel.
        XCTAssertNil(try store.peer(channelId: "alice"))
    }

    // MARK: Pending posts, files, cursors, server

    func testPendingPosts() throws {
        let store = try open()
        let first = MattermostPendingPost(pendingPostId: "me:1", channelId: "c", globallyUniqueId: 1001, localMessageId: 1)
        let second = MattermostPendingPost(pendingPostId: "me:2", channelId: "c", globallyUniqueId: -5, localMessageId: 2)
        XCTAssertEqual(try store.registerPendingPost(first), first)
        XCTAssertEqual(try store.registerPendingPost(second), second)
        // A known pending post id keeps its mapping.
        XCTAssertEqual(try store.registerPendingPost(MattermostPendingPost(pendingPostId: "me:1", channelId: "c", globallyUniqueId: 9999, localMessageId: 9)), first)
        XCTAssertEqual(try store.pendingPost(pendingPostId: "me:2"), second)
        XCTAssertEqual(try store.pendingPost(globallyUniqueId: 1001), first)
        XCTAssertEqual(try store.pendingPost(channelId: "c", localMessageId: 2), second)
        XCTAssertNil(try store.pendingPost(channelId: "other", localMessageId: 2))
        XCTAssertNil(try store.pendingPost(globallyUniqueId: 9999))
        XCTAssertEqual(try store.allPendingPosts(), [first, second])
        // A globally unique id belongs to one pending post.
        XCTAssertThrowsError(try store.registerPendingPost(MattermostPendingPost(pendingPostId: "me:3", channelId: "c", globallyUniqueId: 1001, localMessageId: 3)))
        XCTAssertNil(try store.pendingPost(pendingPostId: "me:3"))
        try store.removePendingPost(pendingPostId: "me:1")
        XCTAssertNil(try store.pendingPost(globallyUniqueId: 1001))
        XCTAssertEqual(try store.allPendingPosts(), [second])
    }

    func testPendingUploadsSurviveReopening() throws {
        let path = directory.path("uploads.sqlite")
        var store = try SQLiteMattermostSyncStore(path: path)
        let uploads = [MattermostPendingUpload(mediaIndex: 0, fileId: "file-a"), MattermostPendingUpload(mediaIndex: 1, fileId: "file-b")]
        // The upload comes first: it registers the message.
        let recorded = try store.setPendingUploads(MattermostPendingPost(pendingPostId: "4242", channelId: "c", globallyUniqueId: 4242, localMessageId: 12, uploadedFiles: uploads))
        XCTAssertEqual(recorded.uploadedFiles, uploads)
        // The post's own registration keeps them.
        XCTAssertEqual(try store.registerPendingPost(MattermostPendingPost(pendingPostId: "4242", channelId: "c", globallyUniqueId: 4242, localMessageId: 12)).uploadedFiles, uploads)
        store.close()
        store = try SQLiteMattermostSyncStore(path: path)
        XCTAssertEqual(try store.pendingPost(channelId: "c", localMessageId: 12)?.uploadedFiles, uploads)
        // A new upload replaces them; none clears them.
        try store.setPendingUploads(MattermostPendingPost(pendingPostId: "4242", channelId: "c", globallyUniqueId: 4242, localMessageId: 12, uploadedFiles: [uploads[1]]))
        XCTAssertEqual(try store.pendingPost(pendingPostId: "4242")?.uploadedFiles, [uploads[1]])
        try store.setPendingUploads(MattermostPendingPost(pendingPostId: "4242", channelId: "c", globallyUniqueId: 4242, localMessageId: 12))
        XCTAssertEqual(try store.pendingPost(pendingPostId: "4242")?.uploadedFiles, [])
        try store.removePendingPost(pendingPostId: "4242")
        XCTAssertNil(try store.pendingPost(channelId: "c", localMessageId: 12))
        store.close()
    }

    func testPendingPostsOfVersionOneGetTheUploadsColumn() throws {
        let path = directory.path("v1.sqlite")
        var store = try SQLiteMattermostSyncStore(path: path, migrations: Array(MattermostSyncStoreSchema.migrations.prefix(1)))
        try store.connection.execute("INSERT INTO pending (pending_post_id, channel_id, globally_unique_id, local_message_id) VALUES ('1', 'c', 1, 1)")
        store.close()
        store = try SQLiteMattermostSyncStore(path: path)
        XCTAssertEqual(try store.storedSchemaVersion(), SQLiteMattermostSyncStore.schemaVersion)
        XCTAssertEqual(try store.pendingPost(pendingPostId: "1"), MattermostPendingPost(pendingPostId: "1", channelId: "c", globallyUniqueId: 1, localMessageId: 1))
        store.close()
    }

    func testMediaIdsAreSequentialAndStable() throws {
        let store = try open()
        XCTAssertEqual(try store.allocateMediaId(fileId: "f1"), 1)
        XCTAssertEqual(try store.allocateMediaId(fileId: "f2"), 2)
        XCTAssertEqual(try store.allocateMediaId(fileId: "f1"), 1)
        XCTAssertEqual(try store.allocateMediaId(fileId: "f3"), 3)
        XCTAssertEqual(try store.mediaId(fileId: "f2"), 2)
        XCTAssertNil(try store.mediaId(fileId: "f4"))
        XCTAssertEqual(try store.fileId(mediaId: 3), "f3")
        XCTAssertNil(try store.fileId(mediaId: 4))
    }

    func testCursors() throws {
        let store = try open()
        XCTAssertNil(try store.cursor(MattermostSyncCursorKey.lastSyncAt))
        try store.setCursor(MattermostSyncCursorKey.lastSyncAt, "1700000000000")
        try store.setCursor(MattermostSyncCursorKey.webSocketConnectionId, "ünïcødé 🚀")
        try store.setCursor("empty", "")
        try store.setCursor(MattermostSyncCursorKey.lastSyncAt, "1700000000001")
        XCTAssertEqual(try store.cursor(MattermostSyncCursorKey.lastSyncAt), "1700000000001")
        XCTAssertEqual(try store.cursor(MattermostSyncCursorKey.webSocketConnectionId), "ünïcødé 🚀")
        XCTAssertEqual(try store.cursor("empty"), "")
        try store.setCursor(MattermostSyncCursorKey.webSocketConnectionId, nil)
        XCTAssertNil(try store.cursor(MattermostSyncCursorKey.webSocketConnectionId))
    }

    func testServerRow() throws {
        let store = try open()
        XCTAssertNil(try store.serverInfo())
        let info = MattermostServerInfo(url: "https://a.example", userId: "me")
        try store.setServerInfo(info)
        XCTAssertEqual(try store.serverInfo(), info)
        let updated = MattermostServerInfo(url: "https://a.example", userId: "me", siteName: "A", version: "10.0.1", capabilitiesJSON: "{}")
        try store.setServerInfo(updated)
        XCTAssertEqual(try store.serverInfo(), updated)
        var rows: Int64 = 0
        try store.connection.query("SELECT COUNT(*) FROM server") { row in
            rows = row.int64(0)
        }
        XCTAssertEqual(rows, 1)
    }
}
