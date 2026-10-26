import XCTest
@testable import MattermostSyncCore

final class MessageIdAllocatorTests: XCTestCase {
    let channel = "channel-1"

    private func assertValid(_ store: InMemoryMessageIdStore, maxId: Int32 = Int32.max, file: StaticString = #filePath, line: UInt = #line) {
        let problems = store.validate(channelId: channel, maxId: maxId)
        XCTAssertEqual(problems, [], file: file, line: line)
    }

    private func ids(_ store: InMemoryMessageIdStore) -> [Int32] {
        return store.allEntries(channelId: channel).map { $0.localId }
    }

    // MARK: First post / initial page

    func testFirstPostGetsTwoToTheThirtieth() throws {
        var rng = SeededGenerator(seed: 1)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        let post = PostOrderKey(createAt: Times.year2026, postId: randomPostId(&rng))
        let result = try allocator.insertPost(post, channelId: channel, store: &store)
        XCTAssertEqual(result.allocations, [PostAllocation(postId: post.postId, localId: 1 << 30, status: .inserted)])
        // A single post with no context: holes on both sides.
        XCTAssertEqual(result.holes.map { $0.range }, [1 ... (1 << 30) - 1, (1 << 30) + 1 ... Int32.max])
        assertValid(store)
    }

    func testInitialPage() throws {
        var rng = SeededGenerator(seed: 2)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        let posts = makePosts(count: 60, start: Times.year2026, spacing: 1000, rng: &rng)
        let result = try allocator.ingestLatestPage(posts.shuffled(using: &rng), reachedStart: false, channelId: channel, store: &store)

        XCTAssertEqual(result.insertedCount, 60)
        XCTAssertNil(result.renumberPlan)
        XCTAssertEqual(result.allocations.map { $0.postId }, posts.map { $0.postId }, "allocations are reported in key order")
        let expected = (0 ..< 60).map { Int32(1 << 30) - Int32(59 - $0) * 16 }
        XCTAssertEqual(result.allocations.map { $0.localId }, expected)
        XCTAssertEqual(result.islandRange, expected.first! ... expected.last!)
        // Live at the top, unloaded history below.
        XCTAssertEqual(result.holes, [HistoryHole(range: 1 ... expected.first! - 1, lowerBoundary: nil, upperBoundary: posts.first!)])
        XCTAssertEqual(result.holes[0].cursor(direction: .older), .before(postId: posts.first!.postId))
        assertValid(store)

        // Replaying the same page is a no-op.
        let replay = try allocator.ingestLatestPage(posts, reachedStart: false, channelId: channel, store: &store)
        XCTAssertEqual(replay.insertedCount, 0)
        XCTAssertTrue(replay.allocations.allSatisfy { $0.status == .existing })
        XCTAssertEqual(ids(store), expected)
    }

    func testEmptyChannelHasOneHole() {
        let store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        XCTAssertEqual(allocator.holes(channelId: channel, store: store), [HistoryHole(range: 1 ... Int32.max, lowerBoundary: nil, upperBoundary: nil)])
        XCTAssertEqual(allocator.fillCursor(direction: .older, boundaryLocalId: Int32.max, channelId: channel, store: store), .latest)
        XCTAssertNil(allocator.fillCursor(direction: .newer, boundaryLocalId: 1, channelId: channel, store: store))
    }

    // MARK: Paging

    func testBackwardPagingOverTenThousandPosts() throws {
        var rng = SeededGenerator(seed: 3)
        // Irregular timestamps, including bursts in the same millisecond.
        var time = Times.year2025
        var posts: [PostOrderKey] = []
        for _ in 0 ..< 10_000 {
            if rng.next() % 10 != 0 {
                time += Int64(rng.next() % 120_000)
            }
            posts.append(PostOrderKey(createAt: time, postId: randomPostId(&rng)))
        }
        let server = FakeServer(posts: posts)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()

        let first = server.latest(limit: 60)
        _ = try allocator.ingestLatestPage(first.posts, reachedStart: first.reachedEnd, channelId: channel, store: &store)
        var pages = 1
        while let hole = allocator.holes(channelId: channel, store: store).first {
            guard case let .before(anchor)? = allocator.fillCursor(direction: .older, boundaryLocalId: hole.range.upperBound, channelId: channel, store: store) else {
                return XCTFail("expected a before cursor")
            }
            let page = server.before(anchor, limit: 60)
            let result = try allocator.ingestPage(page.posts, extending: anchor, direction: .older, reachedEnd: page.reachedEnd, channelId: channel, store: &store)
            XCTAssertNil(result.renumberPlan)
            XCTAssertEqual(result.insertedCount, page.posts.count)
            pages += 1
            XCTAssertLessThan(pages, 200)
        }

        let entries = store.allEntries(channelId: channel)
        XCTAssertEqual(entries.map { $0.key }, server.posts)
        XCTAssertEqual(entries.last?.localId, 1 << 30)
        for (lower, upper) in zip(entries, entries.dropFirst()) {
            XCTAssertEqual(upper.localId - lower.localId, 16)
        }
        XCTAssertEqual(allocator.islandSummaries(channelId: channel, store: store).count, 1)
        XCTAssertTrue(allocator.holes(channelId: channel, store: store).isEmpty)
        assertValid(store)
    }

    func testPermalinkJumpThenPagingUntilIslandsJoin() throws {
        var rng = SeededGenerator(seed: 4)
        let posts = makePosts(count: 3000, start: Times.year2025, spacing: 10 * 60 * 1000, rng: &rng)
        let server = FakeServer(posts: posts)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()

        let latest = server.latest(limit: 60)
        _ = try allocator.ingestLatestPage(latest.posts, reachedStart: false, channelId: channel, store: &store)
        let latestBottom = latest.posts[0]
        let latestBottomId = try XCTUnwrap(store.entries(channelId: channel, postIds: [latestBottom.postId])[latestBottom.postId]?.localId)

        // Jump to a post deep in history.
        let target = posts[1000]
        let older = server.before(target.postId, limit: 30)
        let newer = server.after(target.postId, limit: 30)
        let jump = try allocator.ingestAround(target: target, older: older.posts, newer: newer.posts, olderReachedStart: older.reachedEnd, newerReachedLatest: false, channelId: channel, store: &store)
        XCTAssertEqual(jump.insertedCount, 61)
        XCTAssertFalse(jump.didCloseHole)
        XCTAssertNil(jump.renumberPlan)
        let islandRange = try XCTUnwrap(jump.islandRange)
        XCTAssertEqual(jump.holes.count, 2, "holes below the new island and between the islands")
        XCTAssertEqual(jump.holes[0].range, 1 ... islandRange.lowerBound - 1)
        XCTAssertEqual(jump.holes[1].range, islandRange.upperBound + 1 ... latestBottomId - 1)
        XCTAssertEqual(jump.holes[1].lowerBoundary, newer.posts.last)
        XCTAssertEqual(jump.holes[1].upperBoundary, latestBottom)
        let ids = jump.allocations.map { $0.localId! }
        XCTAssertEqual(Set(zip(ids, ids.dropFirst()).map { $1 - $0 }), [16])

        // Proportional placement: the island sits in the gap roughly where its time sits
        // between the history floor and the latest island.
        let floor = allocator.configuration.historyFloorTime
        let timeFraction = Double(target.createAt - floor) / Double(latestBottom.createAt - floor)
        let idFraction = Double(islandRange.lowerBound) / Double(latestBottomId)
        XCTAssertEqual(idFraction, timeFraction, accuracy: 0.1)

        // Page newer from the island until it reaches the latest island.
        var closed = false
        var pages = 0
        while !closed {
            let holes = allocator.holes(channelId: channel, store: store)
            let middle = try XCTUnwrap(holes.first { $0.lowerBoundary != nil && $0.upperBoundary != nil })
            guard case let .after(anchor)? = allocator.fillCursor(direction: .newer, boundaryLocalId: middle.range.lowerBound, channelId: channel, store: store) else {
                return XCTFail("expected an after cursor")
            }
            XCTAssertEqual(middle.cursor(direction: .newer), .after(postId: anchor))
            let page = server.after(anchor, limit: 60)
            let result = try allocator.ingestPage(page.posts, extending: anchor, direction: .newer, reachedEnd: page.reachedEnd, channelId: channel, store: &store)
            XCTAssertNil(result.renumberPlan)
            closed = result.didCloseHole
            pages += 1
            XCTAssertLessThan(pages, 100)
        }
        XCTAssertEqual(allocator.islandSummaries(channelId: channel, store: store).count, 1)
        let holes = allocator.holes(channelId: channel, store: store)
        XCTAssertEqual(holes.count, 1, "only the hole below the merged island is left")
        XCTAssertNil(holes[0].lowerBoundary)
        // Everything from the jump target to the latest post is loaded and ordered.
        let entries = store.allEntries(channelId: channel)
        XCTAssertEqual(entries.map { $0.key }, Array(posts[(1000 - 30)...]))
        assertValid(store)
    }

    // MARK: Late inserts

    func testLateArrivingPostBetweenAdjacentPosts() throws {
        var rng = SeededGenerator(seed: 5)
        let posts = makePosts(count: 60, start: Times.year2026, spacing: 60_000, rng: &rng)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        _ = try allocator.ingestLatestPage(posts, reachedStart: true, channelId: channel, store: &store)
        let before = store.allEntries(channelId: channel)

        let late = PostOrderKey(createAt: posts[10].createAt + 30_000, postId: randomPostId(&rng))
        let result = try allocator.insertPost(late, channelId: channel, store: &store)
        let a = before[10].localId
        let b = before[11].localId
        XCTAssertEqual(result.localId(for: late.postId), a + (b - a) / 2)
        XCTAssertNil(result.renumberPlan)
        XCTAssertEqual(result.joinedIslandCount, 1)
        XCTAssertTrue(result.holes.isEmpty, "the island still covers the whole channel")
        assertValid(store)

        // Idempotent.
        let again = try allocator.insertPost(late, channelId: channel, store: &store)
        XCTAssertEqual(again.allocations, [PostAllocation(postId: late.postId, localId: a + (b - a) / 2, status: .existing)])
    }

    func testLivePostExtendsLatestIsland() throws {
        var rng = SeededGenerator(seed: 6)
        let posts = makePosts(count: 10, start: Times.year2026, spacing: 60_000, rng: &rng)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        _ = try allocator.ingestLatestPage(posts, reachedStart: false, channelId: channel, store: &store)
        let live = PostOrderKey(createAt: posts.last!.createAt + 5000, postId: randomPostId(&rng))
        let result = try allocator.insertPost(live, channelId: channel, store: &store)
        XCTAssertEqual(result.localId(for: live.postId), (1 << 30) + 16)
        XCTAssertEqual(allocator.islandSummaries(channelId: channel, store: store).count, 1)

        // After a disconnect the top is no longer known to be live: a new post becomes its own island.
        allocator.invalidateLatest(channelId: channel, store: &store)
        XCTAssertEqual(allocator.holes(channelId: channel, store: store).last?.upperBoundary, nil)
        XCTAssertEqual(allocator.holes(channelId: channel, store: store).last?.range.upperBound, Int32.max)
        let later = PostOrderKey(createAt: live.createAt + 3_600_000, postId: randomPostId(&rng))
        let isolated = try allocator.insertPost(later, channelId: channel, store: &store)
        XCTAssertEqual(isolated.joinedIslandCount, 0)
        XCTAssertEqual(allocator.islandSummaries(channelId: channel, store: store).count, 2)
        XCTAssertEqual(isolated.holes.count, 3, "below, between, above")
        assertValid(store)
    }

    // MARK: Same millisecond / second

    func testManyPostsInTheSameMillisecond() throws {
        var rng = SeededGenerator(seed: 7)
        let instant = Times.year2026 + 123
        let posts = (0 ..< 1000).map { _ in PostOrderKey(createAt: instant, postId: randomPostId(&rng)) }.sorted()
        let server = FakeServer(posts: posts)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()

        let latest = server.latest(limit: 100)
        _ = try allocator.ingestLatestPage(latest.posts, reachedStart: false, channelId: channel, store: &store)
        while let hole = allocator.holes(channelId: channel, store: store).first {
            guard case let .before(anchor)? = allocator.fillCursor(direction: .older, boundaryLocalId: hole.range.upperBound, channelId: channel, store: store) else {
                return XCTFail("expected a before cursor")
            }
            let page = server.before(anchor, limit: 100)
            _ = try allocator.ingestPage(page.posts.shuffled(using: &rng), extending: anchor, direction: .older, reachedEnd: page.reachedEnd, channelId: channel, store: &store)
        }
        XCTAssertEqual(store.allEntries(channelId: channel).map { $0.postId }, posts.map { $0.postId }, "ordered by post id within the millisecond")
        assertValid(store)
    }

    func testManyPostsInTheSameSecondArrivingLive() throws {
        var rng = SeededGenerator(seed: 8)
        let second = Times.year2026
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        let seed = makePosts(count: 5, start: second - 10_000, spacing: 1000, rng: &rng)
        _ = try allocator.ingestLatestPage(seed, reachedStart: true, channelId: channel, store: &store)

        // A bot posts 400 messages within one second; WebSocket events arrive out of order.
        var burst = (0 ..< 400).map { _ in PostOrderKey(createAt: second + Int64(rng.next() % 1000), postId: randomPostId(&rng)) }
        burst.shuffle(using: &rng)
        var shadow: [String: Int32] = [:]
        for entry in store.allEntries(channelId: channel) {
            shadow[entry.postId] = entry.localId
        }
        var renumbers = 0
        for post in burst {
            let result = try allocator.insertPost(post, channelId: channel, store: &store)
            if let plan = result.renumberPlan {
                renumbers += 1
                for move in plan.moves {
                    XCTAssertEqual(shadow[move.postId], move.from)
                    shadow[move.postId] = move.to
                }
            }
            shadow[post.postId] = result.localId(for: post.postId)
        }
        let entries = store.allEntries(channelId: channel)
        XCTAssertEqual(entries.map { $0.key }, (seed + burst).sorted())
        for entry in entries {
            XCTAssertEqual(shadow[entry.postId], entry.localId)
        }
        XCTAssertGreaterThan(renumbers, 0, "out-of-order arrivals exhaust midpoints")
        XCTAssertEqual(allocator.islandSummaries(channelId: channel, store: store).count, 1)
        assertValid(store)
    }

    // MARK: Imported history

    func testImportedPostsFrom2013MixedWith2026() throws {
        var rng = SeededGenerator(seed: 9)
        let imported = makePosts(count: 500, start: Times.year2013, spacing: Times.day / 3, rng: &rng)
        let recent = makePosts(count: 500, start: Times.year2026, spacing: 15 * 60 * 1000, rng: &rng)
        var server = FakeServer(posts: imported + recent)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()

        let latest = server.latest(limit: 60)
        _ = try allocator.ingestLatestPage(latest.posts, reachedStart: false, channelId: channel, store: &store)
        // Permalink to a 2013 post.
        let target = imported[200]
        let older = server.before(target.postId, limit: 30)
        let newer = server.after(target.postId, limit: 30)
        let jump = try allocator.ingestAround(target: target, older: older.posts, newer: newer.posts, olderReachedStart: false, newerReachedLatest: false, channelId: channel, store: &store)
        let jumpRange = try XCTUnwrap(jump.islandRange)
        XCTAssertLessThan(jumpRange.upperBound, 1 << 29, "a 2013 island sits far below a 2026 island")
        XCTAssertGreaterThan(jumpRange.lowerBound, 1 << 24, "but leaves room for the older 2013 history below it")

        // A post imported later (e.g. a second Slack import) with a 2013 timestamp that falls
        // into the unloaded gap becomes its own island.
        let lateImport = PostOrderKey(createAt: imported[400].createAt + 1, postId: randomPostId(&rng))
        server.add(lateImport)
        let single = try allocator.insertPost(lateImport, channelId: channel, store: &store)
        XCTAssertEqual(single.joinedIslandCount, 0)
        XCTAssertEqual(allocator.islandSummaries(channelId: channel, store: store).count, 3)

        // Load everything from both ends until no hole is left.
        var iterations = 0
        while let hole = allocator.holes(channelId: channel, store: store).first {
            iterations += 1
            XCTAssertLessThan(iterations, 100)
            guard case let .before(anchor)? = allocator.fillCursor(direction: .older, boundaryLocalId: hole.range.upperBound, channelId: channel, store: store) else {
                return XCTFail("expected a before cursor")
            }
            let page = server.before(anchor, limit: 60)
            let result = try allocator.ingestPage(page.posts, extending: anchor, direction: .older, reachedEnd: page.reachedEnd, channelId: channel, store: &store)
            XCTAssertNil(result.renumberPlan)
        }
        XCTAssertEqual(store.allEntries(channelId: channel).map { $0.key }, server.posts)
        assertValid(store)
    }

    // MARK: Gap exhaustion

    func testExhaustedGapInsideIslandProducesMinimalRenumberPlan() throws {
        var rng = SeededGenerator(seed: 10)
        let posts = makePosts(count: 200, start: Times.year2026, spacing: 60_000, rng: &rng)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        _ = try allocator.ingestLatestPage(posts, reachedStart: true, channelId: channel, store: &store)
        var shadow: [String: Int32] = [:]
        for entry in store.allEntries(channelId: channel) {
            shadow[entry.postId] = entry.localId
        }

        // Keep inserting right after posts[100]: 16 → 8 → 4 → 2 → 1, then the gap is exhausted.
        let anchor = posts[100]
        var plan: RenumberPlan?
        var inserted = 0
        for offset in stride(from: 1000, to: 0, by: -100) {
            let late = PostOrderKey(createAt: anchor.createAt + Int64(offset), postId: randomPostId(&rng))
            let result = try allocator.insertPost(late, channelId: channel, store: &store)
            inserted += 1
            if let renumber = result.renumberPlan {
                plan = renumber
                for move in renumber.moves {
                    XCTAssertEqual(shadow[move.postId], move.from, "the plan starts from the stored ids")
                    XCTAssertTrue(renumber.affectedRange.contains(move.from) && renumber.affectedRange.contains(move.to))
                    shadow[move.postId] = move.to
                }
            }
            shadow[late.postId] = result.localId(for: late.postId)
            if plan != nil {
                break
            }
        }
        let renumber = try XCTUnwrap(plan)
        XCTAssertEqual(inserted, 5)
        XCTAssertFalse(renumber.moves.isEmpty)
        XCTAssertLessThan(renumber.moves.count, 20, "only a small window around the insertion moves")
        for entry in store.allEntries(channelId: channel) {
            XCTAssertEqual(shadow[entry.postId], entry.localId)
        }
        assertValid(store)
    }

    func testExhaustedHoleRenumbersTheSmallerIsland() throws {
        var rng = SeededGenerator(seed: 11)
        let configuration = MessageIdAllocator.Configuration(firstId: 50_000, maxId: 100_000)
        let allocator = MessageIdAllocator(configuration: configuration)
        // An old cluster, a dense stretch of 800 posts, then 1500 recent posts.
        let old = makePosts(count: 20, start: Times.year2025, spacing: 60_000, rng: &rng)
        let dense = makePosts(count: 800, start: Times.year2026 - 800 * 1000, spacing: 1000, rng: &rng)
        let recent = makePosts(count: 1500, start: Times.year2026, spacing: 60_000, rng: &rng)
        let server = FakeServer(posts: old + dense + recent)
        var store = InMemoryMessageIdStore()

        let latest = server.latest(limit: 1500)
        _ = try allocator.ingestLatestPage(latest.posts, reachedStart: false, channelId: channel, store: &store)
        // Jump to the start of the dense stretch: a small island just below the large latest one,
        // with a large hole under it.
        let target = dense[0]
        let jump = try allocator.ingestAround(target: target, older: server.before(target.postId, limit: 5).posts, newer: server.after(target.postId, limit: 5).posts, olderReachedStart: false, newerReachedLatest: false, channelId: channel, store: &store)
        XCTAssertNil(jump.renumberPlan)

        // Page forward through the dense stretch: the hole between the islands runs out.
        var shadow: [String: Int32] = [:]
        for entry in store.allEntries(channelId: channel) {
            shadow[entry.postId] = entry.localId
        }
        let recentIds = Set(recent.map { $0.postId })
        var plans = 0
        var closed = false
        while !closed {
            let holes = allocator.holes(channelId: channel, store: store)
            let middle = try XCTUnwrap(holes.first { $0.lowerBoundary != nil && $0.upperBoundary != nil })
            guard case let .after(anchor)? = middle.cursor(direction: .newer) else {
                return XCTFail("expected an after cursor")
            }
            let smallIslandSize = store.allEntries(channelId: channel).filter { !recentIds.contains($0.postId) }.count
            let page = server.after(anchor, limit: 100)
            let result = try allocator.ingestPage(page.posts, extending: anchor, direction: .newer, reachedEnd: page.reachedEnd, channelId: channel, store: &store)
            if let plan = result.renumberPlan {
                plans += 1
                XCTAssertFalse(plan.moves.contains { recentIds.contains($0.postId) }, "the larger latest island is not moved")
                XCTAssertLessThanOrEqual(plan.moves.count, smallIslandSize)
                for move in plan.moves {
                    XCTAssertEqual(shadow[move.postId], move.from)
                    shadow[move.postId] = move.to
                }
            }
            for allocation in result.allocations where allocation.status == .inserted {
                shadow[allocation.postId] = allocation.localId
            }
            closed = result.didCloseHole
            assertValid(store, maxId: configuration.maxId)
        }
        XCTAssertGreaterThan(plans, 0)
        let entries = store.allEntries(channelId: channel)
        XCTAssertEqual(entries.map { $0.key }, Array(server.posts.dropFirst(old.count - 5)))
        for entry in entries {
            XCTAssertEqual(shadow[entry.postId], entry.localId)
        }
        // The renumbered island got its STEP spacing back.
        let denseIds = dense.prefix(100).compactMap { shadow[$0.postId] }
        XCTAssertEqual(Set(zip(denseIds, denseIds.dropFirst()).map { $1 - $0 }), [16])
    }

    // MARK: Cursors and tombstones

    func testHoleFillCursorTranslation() throws {
        var rng = SeededGenerator(seed: 12)
        let posts = makePosts(count: 500, start: Times.year2026, spacing: 60_000, rng: &rng)
        let server = FakeServer(posts: posts)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        _ = try allocator.ingestLatestPage(server.latest(limit: 50).posts, reachedStart: false, channelId: channel, store: &store)
        let target = posts[100]
        _ = try allocator.ingestAround(target: target, older: server.before(target.postId, limit: 10).posts, newer: server.after(target.postId, limit: 10).posts, olderReachedStart: false, newerReachedLatest: false, channelId: channel, store: &store)

        let holes = allocator.holes(channelId: channel, store: store)
        XCTAssertEqual(holes.count, 2)
        let middle = holes[1]
        XCTAssertEqual(allocator.fillCursor(direction: .older, boundaryLocalId: middle.range.upperBound, channelId: channel, store: store), .before(postId: posts[450].postId))
        XCTAssertEqual(allocator.fillCursor(direction: .newer, boundaryLocalId: middle.range.lowerBound, channelId: channel, store: store), .after(postId: posts[110].postId))
        // A boundary that is itself a mapped id.
        let boundaryId = middle.range.upperBound + 1
        XCTAssertEqual(allocator.fillCursor(direction: .older, boundaryLocalId: boundaryId, channelId: channel, store: store), .before(postId: posts[450].postId))
        XCTAssertEqual(allocator.aroundCursor(localId: boundaryId, channelId: channel, store: store), .around(postId: posts[450].postId))
        XCTAssertNil(allocator.aroundCursor(localId: middle.range.lowerBound, channelId: channel, store: store))
        // Nothing below the lowest island: can't page forward from the channel start.
        XCTAssertNil(allocator.fillCursor(direction: .newer, boundaryLocalId: 1, channelId: channel, store: store))
        XCTAssertEqual(holes[0].cursor(direction: .older), .before(postId: posts[90].postId))

        // A tombstoned boundary post is skipped in favour of a live one in the same island.
        allocator.markDeleted([posts[450].postId], channelId: channel, store: &store)
        XCTAssertEqual(allocator.fillCursor(direction: .older, boundaryLocalId: middle.range.upperBound, channelId: channel, store: store), .before(postId: posts[451].postId))
    }

    func testTombstonesPreventResurrection() throws {
        var rng = SeededGenerator(seed: 13)
        let posts = makePosts(count: 20, start: Times.year2026, spacing: 60_000, rng: &rng)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        _ = try allocator.ingestLatestPage(Array(posts.prefix(10)), reachedStart: true, channelId: channel, store: &store)
        let mappedId = store.entries(channelId: channel, postIds: [posts[3].postId])[posts[3].postId]?.localId

        let deleted = allocator.markDeleted([posts[3].postId, posts[15].postId], channelId: channel, store: &store)
        XCTAssertEqual(deleted.map { $0.postId }, [posts[3].postId])
        XCTAssertEqual(deleted.first?.localId, mappedId, "a deleted post keeps its id")

        // A replayed `posted` event for either post doesn't bring it back.
        let replayMapped = try allocator.insertPost(posts[3], channelId: channel, store: &store)
        XCTAssertEqual(replayMapped.allocations, [PostAllocation(postId: posts[3].postId, localId: mappedId, status: .deleted)])
        let replayUnmapped = try allocator.insertPost(posts[15], channelId: channel, store: &store)
        XCTAssertEqual(replayUnmapped.allocations, [PostAllocation(postId: posts[15].postId, localId: nil, status: .deleted)])
        let page = try allocator.ingestLatestPage(Array(posts.suffix(10)), reachedStart: false, channelId: channel, store: &store)
        XCTAssertEqual(page.allocations.first { $0.postId == posts[15].postId }?.status, .deleted)
        XCTAssertEqual(page.insertedCount, 9)
        XCTAssertNil(store.entries(channelId: channel, postIds: [posts[15].postId])[posts[15].postId])
        assertValid(store)
    }

    func testUnknownAnchorThrows() {
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        XCTAssertThrowsError(try allocator.ingestPage([], extending: "missing", direction: .older, reachedEnd: false, channelId: channel, store: &store)) { error in
            XCTAssertEqual(error as? MessageIdAllocationError, .unknownAnchor(postId: "missing"))
        }
    }

    func testCapacityExhaustedThrows() throws {
        var rng = SeededGenerator(seed: 14)
        let allocator = MessageIdAllocator(configuration: MessageIdAllocator.Configuration(firstId: 32, maxId: 64))
        var store = InMemoryMessageIdStore()
        let posts = makePosts(count: 70, start: Times.year2026, spacing: 1000, rng: &rng)
        XCTAssertThrowsError(try allocator.ingestLatestPage(posts, reachedStart: true, channelId: channel, store: &store)) { error in
            XCTAssertEqual(error as? MessageIdAllocationError, .capacityExhausted(channelId: channel))
        }
        XCTAssertTrue(store.allEntries(channelId: channel).isEmpty, "nothing is written on failure")
    }

    func testReadStateFromStore() throws {
        var rng = SeededGenerator(seed: 15)
        let posts = makePosts(count: 10, start: Times.year2026, spacing: 60_000, rng: &rng)
        var store = InMemoryMessageIdStore()
        let allocator = MessageIdAllocator()
        _ = try allocator.ingestLatestPage(posts, reachedStart: true, channelId: channel, store: &store)
        let counters = ChannelReadCounters(lastViewedAt: posts[6].createAt, totalMessageCount: 10, memberMessageCount: 7, mentionCount: 1)
        let state = ReadStateMapper.readState(channelId: channel, store: store, counters: counters)
        let entries = store.allEntries(channelId: channel)
        XCTAssertEqual(state.maxIncomingReadId, entries[6].localId)
        XCTAssertEqual(state.maxKnownId, entries[9].localId)
        XCTAssertEqual(state.unreadCount, 3)
        XCTAssertEqual(state.mentionCount, 1)
        let fromList = ReadStateMapper.readState(knownPosts: entries.map { .init(localId: $0.localId, createAt: $0.createAt) }, counters: counters)
        XCTAssertEqual(fromList, state)
    }
}
