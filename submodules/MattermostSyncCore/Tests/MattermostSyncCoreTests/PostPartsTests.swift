import XCTest
@testable import MattermostSyncCore

/// Posts shown as several messages (`PostParts`). `SQLitePostPartsTests` runs them again against the
/// SQLite store.
class PostPartsTests: XCTestCase {
    let channel = "channel-parts"

    func makeStore() throws -> any InspectableMessageIdStore {
        return InMemoryMessageIdStore()
    }

    private func assertValid(_ store: any InspectableMessageIdStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.validate(channelId: channel, maxId: Int32.max), [], file: file, line: line)
    }

    private func entryIds(_ store: any InspectableMessageIdStore) -> [String] {
        return store.allEntries(channelId: channel).map { $0.postId }
    }

    // MARK: Ids and ordering

    func testPartIdsRoundTrip() {
        XCTAssertEqual(PostParts.partId(postId: "abc", index: 0), "abc")
        XCTAssertEqual(PostParts.partId(postId: "abc", index: 1), "abc#01")
        XCTAssertEqual(PostParts.partId(postId: "abc", index: 12), "abc#12")
        XCTAssertEqual(PostParts.postId(ofPartId: "abc#12"), "abc")
        XCTAssertEqual(PostParts.postId(ofPartId: "abc"), "abc")
        XCTAssertEqual(PostParts.index(ofPartId: "abc#12"), 12)
        XCTAssertEqual(PostParts.index(ofPartId: "abc"), 0)
        XCTAssertTrue(PostParts.isPartId("abc#01"))
        XCTAssertFalse(PostParts.isPartId("abc"))
        let key = PostOrderKey(createAt: 5, postId: "abc")
        XCTAssertEqual(key.parts(count: 3).map { $0.postId }, ["abc", "abc#01", "abc#02"])
        XCTAssertEqual(key.parts(count: 0).map { $0.postId }, ["abc"])
        XCTAssertEqual(key.part(2).serverPostId, "abc")
        XCTAssertEqual(key.part(2).partIndex, 2)
    }

    /// Parts sort right after their post and before every other post, even ids that extend the post id
    /// (which real 26-character ids never do) or share its millisecond.
    func testPartsSortRightAfterTheirPost() {
        let post = PostOrderKey(createAt: 1000, postId: "abc")
        let others = ["ab", "abb", "abc0", "abca", "abd", "b", "a"].map { PostOrderKey(createAt: 1000, postId: $0) }
        let parts = post.parts(count: 12)
        let sorted = (others + parts).shuffled().sorted()
        let first = sorted.firstIndex(of: post)!
        XCTAssertEqual(Array(sorted[first ..< first + parts.count]), parts, "parts are contiguous and in index order")
        for other in others {
            XCTAssertFalse(post.partsRange.contains(other), "\(other) is not a part of \(post)")
        }
        for part in parts {
            XCTAssertTrue(post.partsRange.contains(part))
            XCTAssertEqual(part.partsRange, post.partsRange)
        }
        XCTAssertTrue(PostOrderKey(createAt: 999, postId: "zzz") < post)
        XCTAssertTrue(parts.last! < PostOrderKey(createAt: 1001, postId: "a"))
    }

    // MARK: Allocation

    func testPageWithPartsGetsConsecutiveIdsAndServerCursors() throws {
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let base = Times.year2026
        let posts = (0 ..< 5).map { PostOrderKey(createAt: base + Int64($0) * 1000, postId: "post\($0)") }
        // The oldest and the newest post have three parts each.
        let keys = posts[0].parts(count: 3) + posts[1 ... 3] + posts[4].parts(count: 3)
        let result = try allocator.ingestAround(target: posts[2], older: Array(keys[0 ..< 4]), newer: Array(keys[5...]), olderReachedStart: false, newerReachedLatest: false, channelId: channel, store: &store)
        XCTAssertEqual(result.insertedCount, 9)
        XCTAssertEqual(entryIds(store), keys.map { $0.postId })
        assertValid(store)

        // Holes on both sides; their cursors name the posts, never their parts.
        XCTAssertEqual(result.holes.count, 2)
        XCTAssertEqual(result.holes[0].upperBoundary, posts[0])
        XCTAssertEqual(result.holes[0].cursor(direction: .older), .before(postId: "post0"))
        XCTAssertEqual(result.holes[1].lowerBoundary, posts[4].part(2))
        XCTAssertEqual(result.holes[1].cursor(direction: .newer), .after(postId: "post4"))

        let entries = store.allEntries(channelId: channel)
        let lastPart = entries.last!
        XCTAssertEqual(allocator.fillCursor(direction: .newer, boundaryLocalId: lastPart.localId, channelId: channel, store: store), .after(postId: "post4"))
        XCTAssertEqual(allocator.fillCursor(direction: .older, boundaryLocalId: entries[1].localId, channelId: channel, store: store), .before(postId: "post0"))
        XCTAssertEqual(allocator.aroundCursor(localId: entries[2].localId, channelId: channel, store: store), .around(postId: "post0"))
        XCTAssertEqual(allocator.partEntries(postId: "post4", channelId: channel, store: store).map { $0.postId }, ["post4", "post4#01", "post4#02"])
        XCTAssertEqual(allocator.partEntries(postId: "post2", channelId: channel, store: store).map { $0.postId }, ["post2"])
        XCTAssertEqual(allocator.partEntries(postId: "unknown", channelId: channel, store: store), [])

        // Paging on from the post (its parts are above it) maps the next page below.
        let older = (0 ..< 3).map { PostOrderKey(createAt: base - Int64(3 - $0) * 1000, postId: "old\($0)") }
        let page = try allocator.ingestPage(older, extending: "post0", direction: .older, reachedEnd: true, channelId: channel, store: &store)
        XCTAssertEqual(page.insertedCount, 3)
        XCTAssertEqual(page.holes.count, 1)
        assertValid(store)
    }

    func testLivePostWithPartsAndAnEditThatAddsParts() throws {
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let base = Times.year2026
        let posts = (0 ..< 3).map { PostOrderKey(createAt: base + Int64($0) * 1000, postId: "p\($0)") }
        _ = try allocator.ingestLatestPage(posts, reachedStart: true, channelId: channel, store: &store)

        // A live post with four files: four consecutive entries on top of the live island.
        let live = PostOrderKey(createAt: base + 10_000, postId: "live")
        let inserted = try allocator.insertPost(live, partCount: 4, channelId: channel, store: &store)
        XCTAssertEqual(inserted.allocations.map { $0.postId }, ["live", "live#01", "live#02", "live#03"])
        XCTAssertTrue(inserted.allocations.allSatisfy { $0.status == .inserted })
        XCTAssertEqual(inserted.holes, [], "the live island grows; no hole opens")
        assertValid(store)

        // Replays (the WebSocket echo of our own post, catch-up) change nothing.
        let ids = store.allEntries(channelId: channel).map { $0.localId }
        let replay = try allocator.insertPost(live, partCount: 4, channelId: channel, store: &store)
        XCTAssertTrue(replay.allocations.allSatisfy { $0.status == .existing })
        XCTAssertEqual(replay.allocations.map { $0.localId }, Array(ids.suffix(4)))
        XCTAssertEqual(store.allEntries(channelId: channel).map { $0.localId }, ids)

        // An edit adds two files to the middle post: its new parts go between it and the next post.
        let edited = try allocator.insertPost(posts[1], partCount: 3, channelId: channel, store: &store)
        XCTAssertEqual(edited.allocations.map { $0.postId }, ["p1", "p1#01", "p1#02"])
        XCTAssertEqual(edited.allocations.map { $0.status }, [.existing, .inserted, .inserted])
        XCTAssertEqual(entryIds(store), ["p0", "p1", "p1#01", "p1#02", "p2", "live", "live#01", "live#02", "live#03"])
        XCTAssertEqual(edited.holes, [])
        assertValid(store)
    }

    func testDeletingAPostDeletesItsParts() throws {
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let base = Times.year2026
        let a = PostOrderKey(createAt: base, postId: "a")
        let b = PostOrderKey(createAt: base + 1000, postId: "b")
        _ = try allocator.ingestLatestPage(a.parts(count: 3) + [b], reachedStart: true, channelId: channel, store: &store)

        let deleted = allocator.markDeleted(["a"], channelId: channel, store: &store)
        XCTAssertEqual(deleted.map { $0.postId }, ["a", "a#01", "a#02"])
        XCTAssertTrue(store.allEntries(channelId: channel).filter { $0.serverPostId == "a" }.allSatisfy { $0.isDeleted })
        XCTAssertFalse(store.entries(channelId: channel, postIds: ["b"])["b"]!.isDeleted)
        XCTAssertEqual(allocator.markDeleted(["a"], channelId: channel, store: &store), [], "idempotent")

        // A stale page that still lists the post (and more parts) maps nothing.
        let stale = try allocator.ingestLatestPage(a.parts(count: 4) + [b], reachedStart: true, channelId: channel, store: &store)
        XCTAssertEqual(stale.insertedCount, 0)
        XCTAssertTrue(stale.allocations.filter { $0.postId.hasPrefix("a") }.allSatisfy { $0.status == .deleted })
        XCTAssertEqual(entryIds(store), ["a", "a#01", "a#02", "b"])
        assertValid(store)
    }

    func testPartsOfAPostDeletedBeforeItWasMappedAreNeverMapped() throws {
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let post = PostOrderKey(createAt: Times.year2026, postId: "gone")
        XCTAssertEqual(allocator.markDeleted(["gone"], channelId: channel, store: &store), [])
        let single = try allocator.insertPost(post, partCount: 3, channelId: channel, store: &store)
        XCTAssertEqual(single.allocations, post.parts(count: 3).map { PostAllocation(postId: $0.postId, localId: nil, status: .deleted) })
        let page = try allocator.ingestLatestPage(post.parts(count: 3), reachedStart: true, channelId: channel, store: &store)
        XCTAssertEqual(page.insertedCount, 0)
        XCTAssertEqual(store.allEntries(channelId: channel), [])
    }

    func testRemovingPartsKeepsThePost() throws {
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let post = PostOrderKey(createAt: Times.year2026, postId: "p")
        _ = try allocator.ingestLatestPage(post.parts(count: 4), reachedStart: true, channelId: channel, store: &store)
        let removed = allocator.removeParts(postId: "p", keeping: 2, channelId: channel, store: &store)
        XCTAssertEqual(removed.map { $0.postId }, ["p#02", "p#03"])
        XCTAssertEqual(store.allEntries(channelId: channel).map { $0.isDeleted }, [false, false, true, true])
        // `keeping: 0` never removes the post itself.
        let rest = allocator.removeParts(postId: "p", keeping: 0, channelId: channel, store: &store)
        XCTAssertEqual(rest.map { $0.postId }, ["p#01"])
        XCTAssertFalse(store.entries(channelId: channel, postIds: ["p"])["p"]!.isDeleted)
        // A removed part stays removed (Mattermost keeps no history of removed files).
        let regrown = try allocator.insertPost(post, partCount: 3, channelId: channel, store: &store)
        XCTAssertEqual(regrown.allocations.map { $0.status }, [.existing, .deleted, .deleted])
        assertValid(store)
    }

    private func insertAll(_ posts: [PostOrderKey], allocator: MessageIdAllocator, store: inout any InspectableMessageIdStore) throws -> Int {
        var count = 0
        for post in posts {
            count += try allocator.insertPost(post, channelId: channel, store: &store).insertedCount
        }
        return count
    }

    /// A late post landing between a post and the next one never splits the post from its parts.
    func testLateInsertsInTheSameMillisecondStayOutsideTheParts() throws {
        var store = try makeStore()
        let allocator = MessageIdAllocator()
        let time = Times.year2026
        let post = PostOrderKey(createAt: time, postId: "m")
        let next = PostOrderKey(createAt: time + 1, postId: "n")
        let initial = try allocator.ingestLatestPage(post.parts(count: 3) + [next], reachedStart: true, channelId: channel, store: &store)
        XCTAssertEqual(initial.insertedCount, 4)
        let insertedCount = try insertAll(["a", "l", "m0", "ma", "z"].map { PostOrderKey(createAt: time, postId: $0) }, allocator: allocator, store: &store)
        XCTAssertEqual(insertedCount, 5)
        XCTAssertEqual(entryIds(store), ["a", "l", "m", "m#01", "m#02", "m0", "ma", "z", "n"])
        assertValid(store)
    }
}

final class SQLitePostPartsTests: PostPartsTests {
    private var directory: TemporaryDirectory?
    private var count = 0

    override func makeStore() throws -> any InspectableMessageIdStore {
        if directory == nil {
            directory = try TemporaryDirectory()
        }
        count += 1
        return try SQLiteMattermostSyncStore(path: directory!.path("parts-\(count).sqlite"))
    }

    override func tearDownWithError() throws {
        directory = nil
        try super.tearDownWithError()
    }
}
