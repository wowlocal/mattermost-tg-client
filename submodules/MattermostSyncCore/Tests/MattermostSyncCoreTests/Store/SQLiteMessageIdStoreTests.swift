import XCTest
@testable import MattermostSyncCore

/// `SQLiteMattermostSyncStore` as a `MessageIdStore`: equivalence with the in-memory reference,
/// atomicity of `apply`, and the SQL-specific parts (renumber parking, channel keys, indexes).
final class SQLiteMessageIdStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let channel = "channel-1"

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore(_ name: String = "sync.sqlite") throws -> SQLiteMattermostSyncStore {
        return try SQLiteMattermostSyncStore(path: directory.path(name))
    }

    // MARK: Equivalence with InMemoryMessageIdStore

    private enum Outcome<T: Equatable>: Equatable {
        case value(T)
        case failure(String)
    }

    /// Runs `operation` on every store and checks that all outcomes are equal.
    @discardableResult
    private func lockstep<T: Equatable>(_ stores: inout [any MessageIdStore], _ label: @autoclosure () -> String, _ operation: (inout any MessageIdStore) throws -> T, file: StaticString = #filePath, line: UInt = #line) -> T? {
        var outcomes: [Outcome<T>] = []
        for index in stores.indices {
            do {
                outcomes.append(.value(try operation(&stores[index])))
            } catch {
                outcomes.append(.failure("\(error)"))
            }
        }
        for outcome in outcomes.dropFirst() where outcome != outcomes[0] {
            XCTFail("\(label()): \(outcome) != \(outcomes[0])", file: file, line: line)
        }
        if case let .value(value) = outcomes[0] {
            return value
        }
        return nil
    }

    /// Drives the allocator on the in-memory and the SQLite store in lockstep across two channels
    /// and probes every query with random arguments. The allocator is deterministic, so equal
    /// store semantics give equal results at every step.
    func testAllocatorAndQueriesMatchTheInMemoryStore() throws {
        let allocator = MessageIdAllocator(configuration: MessageIdAllocator.Configuration(firstId: 1 << 12, maxId: 1 << 13))
        for seed: UInt64 in 1 ... 3 {
            var rng = SeededGenerator(seed: seed)
            let sqlite = try makeStore("lockstep-\(seed).sqlite")
            var stores: [any MessageIdStore] = [InMemoryMessageIdStore(), sqlite]
            let channels = ["a", "b"]
            var servers: [String: FakeServer] = [:]
            for channelId in channels {
                var posts: [PostOrderKey] = []
                var time = Times.year2025
                for _ in 0 ..< 400 {
                    time += rng.next() % 4 == 0 ? 0 : Int64(rng.next() % 3_600_000)
                    posts.append(PostOrderKey(createAt: time, postId: randomPostId(&rng)))
                }
                servers[channelId] = FakeServer(posts: posts)
            }
            func pick<T>(_ values: [T]) -> T {
                return values[Int(rng.next() % UInt64(values.count))]
            }

            for step in 0 ..< 250 {
                let channelId = pick(channels)
                var server = servers[channelId]!
                let limit = pick([1, 7, 30, 100])
                switch rng.next() % 8 {
                case 0:
                    let page = server.latest(limit: limit)
                    lockstep(&stores, "step \(step) latest") { try allocator.ingestLatestPage(page.posts, reachedStart: page.reachedEnd, channelId: channelId, store: &$0) }
                case 1, 2:
                    guard let holes = lockstep(&stores, "step \(step) holes", { allocator.holes(channelId: channelId, store: $0) }), !holes.isEmpty else {
                        break
                    }
                    let hole = pick(holes)
                    let direction: HistoryDirection = rng.next() % 2 == 0 ? .older : .newer
                    let boundary = direction == .older ? hole.range.upperBound : hole.range.lowerBound
                    let cursor = lockstep(&stores, "step \(step) cursor") { allocator.fillCursor(direction: direction, boundaryLocalId: boundary, channelId: channelId, store: $0) }
                    switch cursor {
                    case .latest??:
                        let page = server.latest(limit: limit)
                        lockstep(&stores, "step \(step) fill latest") { try allocator.ingestLatestPage(page.posts, reachedStart: page.reachedEnd, channelId: channelId, store: &$0) }
                    case let .before(anchor)??:
                        let page = server.before(anchor, limit: limit)
                        lockstep(&stores, "step \(step) fill before") { try allocator.ingestPage(page.posts, extending: anchor, direction: .older, reachedEnd: page.reachedEnd, channelId: channelId, store: &$0) }
                    case let .after(anchor)??:
                        let page = server.after(anchor, limit: limit)
                        lockstep(&stores, "step \(step) fill after") { try allocator.ingestPage(page.posts, extending: anchor, direction: .newer, reachedEnd: page.reachedEnd, channelId: channelId, store: &$0) }
                    default:
                        break
                    }
                case 3:
                    let live = server.livePosts
                    let target = pick(live)
                    let older = server.before(target.postId, limit: limit)
                    let newer = server.after(target.postId, limit: limit)
                    lockstep(&stores, "step \(step) around") { try allocator.ingestAround(target: target, older: older.posts, newer: newer.posts, olderReachedStart: older.reachedEnd, newerReachedLatest: newer.reachedEnd, channelId: channelId, store: &$0) }
                case 4, 5:
                    // Late and same-millisecond posts anywhere in time.
                    let neighbour = pick(server.posts)
                    let post = PostOrderKey(createAt: neighbour.createAt + (rng.next() % 2 == 0 ? 0 : Int64(rng.next() % 5000)), postId: randomPostId(&rng))
                    server.add(post)
                    lockstep(&stores, "step \(step) insert") { try allocator.insertPost(post, channelId: channelId, store: &$0) }
                case 6:
                    let victim = pick(server.livePosts)
                    server.delete(victim.postId)
                    lockstep(&stores, "step \(step) delete") { allocator.markDeleted([victim.postId, victim.postId], channelId: channelId, store: &$0) }
                default:
                    lockstep(&stores, "step \(step) invalidate") { store -> Bool in
                        allocator.invalidateLatest(channelId: channelId, store: &store)
                        return true
                    }
                }
                servers[channelId] = server
                probeQueries(&stores, channelId: pick(channels + ["unknown"]), server: server, rng: &rng, step: step)
            }
            XCTAssertNil(sqlite.messageIdError)
            for channelId in channels {
                let memory = stores[0] as! InMemoryMessageIdStore
                XCTAssertEqual(sqlite.allEntries(channelId: channelId), memory.allEntries(channelId: channelId))
                XCTAssertEqual(sqlite.validate(channelId: channelId, maxId: allocator.configuration.maxId), [])
            }
        }
    }

    private func probeQueries(_ stores: inout [any MessageIdStore], channelId: String, server: FakeServer, rng: inout SeededGenerator, step: Int) {
        func randomKey() -> PostOrderKey {
            switch rng.next() % 4 {
            case 0:
                return server.posts[Int(rng.next() % UInt64(server.posts.count))]
            case 1:
                let post = server.posts[Int(rng.next() % UInt64(server.posts.count))]
                return rng.next() % 2 == 0 ? PostOrderKey.lowerBound(createAt: post.createAt) : PostOrderKey.upperBound(createAt: post.createAt)
            case 2:
                return PostOrderKey(createAt: Times.year2025 + Int64(rng.next() % (400 * 3_600_000)), postId: randomPostId(&rng))
            default:
                return PostOrderKey(createAt: Times.year2013, postId: "")
            }
        }
        let limit = [0, 1, 2, 16, Int.max][Int(rng.next() % 5)]
        let ids = (0 ..< 5).map { _ in rng.next() % 3 == 0 ? randomPostId(&rng) : server.posts[Int(rng.next() % UInt64(server.posts.count))].postId }
        let a = randomKey()
        let b = randomKey()
        let key: PostOrderKey? = rng.next() % 4 == 0 ? nil : a
        let localId = rng.next() % 2 == 0 ? Int32(rng.next() % (1 << 13)) : (stores[0].entries(channelId: channelId, postIds: ids)[ids[0]]?.localId ?? 1)
        lockstep(&stores, "step \(step) by post id") { $0.entries(channelId: channelId, postIds: ids + ids) }
        lockstep(&stores, "step \(step) key range") { $0.entries(channelId: channelId, keyRange: min(a, b) ... max(a, b)) }
        lockstep(&stores, "step \(step) older") { $0.entries(channelId: channelId, olderThan: key, limit: limit) }
        lockstep(&stores, "step \(step) newer") { $0.entries(channelId: channelId, newerThan: key, limit: limit) }
        lockstep(&stores, "step \(step) local up") { $0.entries(channelId: channelId, fromLocalId: localId, ascending: true, limit: limit) }
        lockstep(&stores, "step \(step) local down") { $0.entries(channelId: channelId, fromLocalId: localId, ascending: false, limit: limit) }
        lockstep(&stores, "step \(step) islands") { $0.islands(channelId: channelId) }
        lockstep(&stores, "step \(step) tombstones") { $0.unmappedTombstones(channelId: channelId, among: ids + Array(server.deleted)) }
    }

    // MARK: Atomicity

    private struct Snapshot: Equatable {
        var entries: [MessageIdEntry]
        var islands: [HistoryIsland]
        var tombstones: Set<String>
    }

    private func snapshot(_ store: SQLiteMattermostSyncStore, among tombstoneCandidates: [String]) -> Snapshot {
        return Snapshot(entries: store.allEntries(channelId: channel), islands: store.islands(channelId: channel), tombstones: store.unmappedTombstones(channelId: channel, among: tombstoneCandidates))
    }

    /// A channel with ten posts in one island, one tombstoned post and one unmapped tombstone.
    private func seededStore() throws -> (SQLiteMattermostSyncStore, [PostOrderKey]) {
        var rng = SeededGenerator(seed: 21)
        var store = try makeStore()
        let posts = makePosts(count: 10, start: Times.year2026, spacing: 60_000, rng: &rng)
        let allocator = MessageIdAllocator()
        _ = try allocator.ingestLatestPage(posts, reachedStart: false, channelId: channel, store: &store)
        allocator.markDeleted([posts[2].postId, "never-mapped"], channelId: channel, store: &store)
        XCTAssertNil(store.messageIdError)
        return (store, posts)
    }

    private func assertConstraintFailure(_ error: MattermostSyncStoreError?, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .sqlite(code, _)? = error else {
            return XCTFail("expected an SQLite error, got \(String(describing: error))", file: file, line: line)
        }
        XCTAssertEqual(code & 0xFF, 19, "SQLITE_CONSTRAINT", file: file, line: line)
    }

    func testFailedApplyLeavesTheDatabaseUnchanged() throws {
        let (store, posts) = try seededStore()
        let candidates = ["never-mapped", "gone", "new"]
        let before = snapshot(store, among: candidates)
        let entries = before.entries

        // Every part of a change set, with a local id collision in the second insert: the valid
        // renumber and the first insert have already been written when it fails.
        let failing = MessageIdChangeSet(
            channelId: channel,
            renumbered: [RenumberMove(postId: posts[0].postId, from: entries[0].localId, to: entries[0].localId - 5)],
            inserted: [
                MessageIdEntry(key: PostOrderKey(createAt: posts[0].createAt - 1000, postId: "new"), localId: 100),
                MessageIdEntry(key: PostOrderKey(createAt: posts[9].createAt + 1000, postId: "collides"), localId: entries[5].localId),
            ],
            deletedPostIds: [posts[4].postId],
            unmappedTombstones: ["gone"],
            islands: [HistoryIsland(lower: posts[0], upper: posts[9], reachesStart: true, reachesLatest: false)]
        )
        store.apply(failing)
        assertConstraintFailure(store.messageIdError)
        XCTAssertEqual(snapshot(store, among: candidates), before)

        // While the error is recorded, nothing is written.
        let valid = MessageIdChangeSet(channelId: channel, deletedPostIds: [posts[4].postId])
        store.apply(valid)
        XCTAssertEqual(snapshot(store, among: candidates), before)
        store.clearMessageIdError()
        store.apply(valid)
        XCTAssertNil(store.messageIdError)
        XCTAssertEqual(store.allEntries(channelId: channel)[4].isDeleted, true)

        // Two moves to one id fail while setting the final ids, after the parking pass.
        let afterValid = snapshot(store, among: candidates)
        store.apply(MessageIdChangeSet(channelId: channel, renumbered: [
            RenumberMove(postId: posts[0].postId, from: entries[0].localId, to: 7),
            RenumberMove(postId: posts[1].postId, from: entries[1].localId, to: 7),
        ]))
        assertConstraintFailure(store.messageIdError)
        XCTAssertEqual(snapshot(store, among: candidates), afterValid)

        store.close()
        let reopened = try makeStore()
        XCTAssertEqual(snapshot(reopened, among: candidates), afterValid)
        XCTAssertEqual(reopened.validate(channelId: channel), [])
    }

    func testTransactionRollsBackEveryWriteWhenAnApplyFails() throws {
        let (store, posts) = try seededStore()
        let before = snapshot(store, among: ["never-mapped"])
        let allocator = MessageIdAllocator()
        let late = PostOrderKey(createAt: posts[5].createAt + 1, postId: "late")
        XCTAssertThrowsError(try store.transaction { store -> Void in
            try store.setCursor("k", "v")
            _ = try store.allocatePeer(mattermostId: "user", kind: .user)
            let result = try allocator.insertPost(late, channelId: channel, store: &store)
            XCTAssertEqual(result.insertedCount, 1)
            store.apply(MessageIdChangeSet(channelId: channel, inserted: [MessageIdEntry(key: PostOrderKey(createAt: 1, postId: "x"), localId: before.entries[0].localId)]))
        }) { error in
            assertConstraintFailure(error as? MattermostSyncStoreError)
        }
        XCTAssertNil(store.messageIdError, "the error was thrown, not left recorded")
        XCTAssertEqual(snapshot(store, among: ["never-mapped"]), before)
        XCTAssertNil(try store.cursor("k"))
        XCTAssertNil(try store.peer(mattermostId: "user"))

        // A thrown error rolls back as well; a later transaction works normally.
        struct Abort: Error {}
        XCTAssertThrowsError(try store.transaction { store in
            _ = try allocator.insertPost(late, channelId: channel, store: &store)
            throw Abort()
        })
        XCTAssertEqual(snapshot(store, among: ["never-mapped"]), before)
        let inserted = try store.transaction { store in
            try allocator.insertPost(late, channelId: channel, store: &store)
        }
        XCTAssertEqual(inserted.insertedCount, 1)
        XCTAssertEqual(store.allEntries(channelId: channel).count, 11)
    }

    func testNestedTransactionFailureOnlyRollsBackItsOwnWrites() throws {
        let store = try makeStore()
        struct Abort: Error {}
        try store.transaction { store in
            try store.setCursor("outer", "1")
            XCTAssertThrowsError(try store.transaction { store in
                try store.setCursor("inner", "1")
                throw Abort()
            })
            // Typed writes nest as savepoints too: a failing one leaves the outer work intact.
            try store.reserveOwnUserPeerId(userId: "me", hash: 1 << 40)
            XCTAssertThrowsError(try store.reserveOwnUserPeerId(userId: "other", hash: 1 << 40))
            try store.setCursor("outer2", "2")
        }
        XCTAssertEqual(try store.cursor("outer"), "1")
        XCTAssertNil(try store.cursor("inner"))
        XCTAssertEqual(try store.cursor("outer2"), "2")
        XCTAssertEqual(try store.peer(mattermostId: "me")?.peerId, 1 << 40)
        XCTAssertNil(try store.peer(mattermostId: "other"))
    }

    // MARK: SQL specifics

    /// Moves where each target is the next post's current id (a shift) need the parking pass,
    /// because `posts_by_local_id` is unique.
    func testRenumberShiftAndSwapThroughOccupiedIds() throws {
        var rng = SeededGenerator(seed: 22)
        let store = try makeStore()
        let posts = makePosts(count: 4, start: Times.year2026, spacing: 1000, rng: &rng)
        store.apply(MessageIdChangeSet(channelId: channel, inserted: posts.enumerated().map { MessageIdEntry(key: $1, localId: Int32(10 * ($0 + 1))) }, islands: [HistoryIsland(lower: posts[0], upper: posts[3])]))
        store.apply(MessageIdChangeSet(channelId: channel, renumbered: [
            RenumberMove(postId: posts[0].postId, from: 10, to: 20),
            RenumberMove(postId: posts[1].postId, from: 20, to: 30),
            RenumberMove(postId: posts[2].postId, from: 30, to: 40),
            RenumberMove(postId: posts[3].postId, from: 40, to: 50),
        ]))
        XCTAssertNil(store.messageIdError)
        XCTAssertEqual(store.allEntries(channelId: channel).map { $0.localId }, [20, 30, 40, 50])
        XCTAssertEqual(store.validate(channelId: channel), [])

        // A swap breaks the order invariant, but applies like the in-memory store does.
        store.apply(MessageIdChangeSet(channelId: channel, renumbered: [
            RenumberMove(postId: posts[0].postId, from: 20, to: 30),
            RenumberMove(postId: posts[1].postId, from: 30, to: 20),
        ]))
        XCTAssertNil(store.messageIdError)
        XCTAssertEqual(store.allEntries(channelId: channel).map { $0.localId }, [30, 20, 40, 50])
    }

    func testChannelsAreIndependentAndRemovable() throws {
        var rng = SeededGenerator(seed: 23)
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let posts = makePosts(count: 20, start: Times.year2026, spacing: 1000, rng: &rng)
        // The same post ids in two channels are two independent maps (as in the in-memory store).
        _ = try allocator.ingestLatestPage(posts, reachedStart: true, channelId: "a", store: &store)
        _ = try allocator.ingestLatestPage(Array(posts.prefix(5)), reachedStart: false, channelId: "b", store: &store)
        allocator.markDeleted([posts[0].postId, "unmapped"], channelId: "b", store: &store)
        XCTAssertEqual(store.allEntries(channelId: "a").count, 20)
        XCTAssertEqual(store.allEntries(channelId: "b").count, 5)
        XCTAssertFalse(store.entries(channelId: "a", postIds: [posts[0].postId])[posts[0].postId]!.isDeleted)
        XCTAssertTrue(store.entries(channelId: "b", postIds: [posts[0].postId])[posts[0].postId]!.isDeleted)
        XCTAssertEqual(store.unmappedTombstones(channelId: "a", among: ["unmapped"]), [])
        XCTAssertEqual(store.unmappedTombstones(channelId: "b", among: ["unmapped"]), ["unmapped"])

        try store.removeChannel("b")
        XCTAssertEqual(store.allEntries(channelId: "b"), [])
        XCTAssertEqual(store.islands(channelId: "b"), [])
        XCTAssertEqual(store.unmappedTombstones(channelId: "b", among: ["unmapped"]), [])
        XCTAssertEqual(store.allEntries(channelId: "a").count, 20)
        // A removed channel starts over.
        let again = try allocator.ingestLatestPage(Array(posts.prefix(5)), reachedStart: false, channelId: "b", store: &store)
        XCTAssertEqual(again.insertedCount, 5)
        XCTAssertEqual(store.validate(channelId: "b"), [])
        XCTAssertNil(store.messageIdError)
    }

    func testThreadRepliesFollowRenumbering() throws {
        var rng = SeededGenerator(seed: 24)
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let posts = makePosts(count: 50, start: Times.year2026, spacing: 60_000, rng: &rng)
        _ = try allocator.ingestLatestPage(posts, reachedStart: true, channelId: channel, store: &store)
        let root = posts[10].postId
        try store.setThreadRootIds([posts[11].postId: root, posts[30].postId: root, posts[31].postId: posts[30].postId, "unmapped": root], channelId: channel)
        XCTAssertEqual(try store.threadReplies(rootPostIds: [root, posts[30].postId, "none"], channelId: channel).mapValues { $0.map { $0.postId } }, [
            root: [posts[11].postId, posts[30].postId],
            posts[30].postId: [posts[31].postId],
        ])

        // A renumber plan moves a reply: the thread link stays with the post.
        let reply = store.entries(channelId: channel, postIds: [posts[11].postId])[posts[11].postId]!
        store.apply(MessageIdChangeSet(channelId: channel, renumbered: [RenumberMove(postId: reply.postId, from: reply.localId, to: reply.localId + 3)]))
        XCTAssertNil(store.messageIdError)
        let replies = try XCTUnwrap(try store.threadReplies(rootPostIds: [root], channelId: channel)[root])
        XCTAssertEqual(replies.map { $0.localId }, [reply.localId + 3, store.entries(channelId: channel, postIds: [posts[30].postId])[posts[30].postId]!.localId])
        XCTAssertEqual(try store.threadReplies(rootPostIds: [root], channelId: "unknown"), [:])

        // The root of a single post (collapsed reply threads: a reply opens in its thread).
        XCTAssertEqual(try store.threadRootId(postId: posts[31].postId, channelId: channel), posts[30].postId)
        XCTAssertEqual(try store.threadRootId(postId: posts[11].postId, channelId: channel), root)
        XCTAssertNil(try store.threadRootId(postId: root, channelId: channel))
        XCTAssertNil(try store.threadRootId(postId: "unmapped", channelId: channel))
        XCTAssertNil(try store.threadRootId(postId: posts[11].postId, channelId: "unknown"))
    }

    func testQueryFailuresAreRecordedAndBlockWrites() throws {
        let (store, posts) = try seededStore()
        store.close()
        XCTAssertEqual(store.entries(channelId: channel, postIds: [posts[0].postId]), [:])
        XCTAssertEqual(store.messageIdError, .closed)
        XCTAssertEqual(store.validate(channelId: channel).first, "recorded error: sync store is closed")
        XCTAssertThrowsError(try store.transaction { _ in }) { error in
            XCTAssertEqual(error as? MattermostSyncStoreError, .closed)
        }
        XCTAssertThrowsError(try store.cursor("x"))
    }

    /// Every query is a search on the intended index: no full scans, no sorting.
    func testQueriesUseIndexes() throws {
        let store = try makeStore()
        let keyRange = "PRIMARY KEY (channel_key=? AND (create_at_ms,post_id)"
        let expectations: [(String, String)] = [
            (MessageIdSQL.entryByPostId, "posts_by_post_id (channel_key=? AND post_id=?)"),
            (MessageIdSQL.entriesInKeyRange, keyRange),
            (MessageIdSQL.entriesOlderThanKey, keyRange),
            (MessageIdSQL.entriesNewerThanKey, keyRange),
            (MessageIdSQL.newestEntries, "PRIMARY KEY (channel_key=?)"),
            (MessageIdSQL.oldestEntries, "PRIMARY KEY (channel_key=?)"),
            (MessageIdSQL.allEntries, "PRIMARY KEY (channel_key=?)"),
            (MessageIdSQL.entriesFromLocalIdUp, "posts_by_local_id (channel_key=? AND local_id>?)"),
            (MessageIdSQL.entriesFromLocalIdDown, "posts_by_local_id (channel_key=? AND local_id<?)"),
            (MessageIdSQL.islands, "PRIMARY KEY (channel_key=?)"),
            (MessageIdSQL.tombstone, "PRIMARY KEY (channel_key=? AND post_id=?)"),
            (MessageIdSQL.threadReplies, "posts_by_thread_root (channel_key=? AND thread_root_id=?)"),
        ]
        for (sql, expected) in expectations {
            var plan: [String] = []
            try store.connection.query("EXPLAIN QUERY PLAN \(sql)") { row in
                plan.append(row.string(3))
            }
            XCTAssertEqual(plan.count, 1, "\(plan) for \(sql)")
            XCTAssertTrue(plan.allSatisfy { $0.hasPrefix("SEARCH ") && $0.contains(expected) }, "\(plan) for \(sql)")
        }
    }
}
