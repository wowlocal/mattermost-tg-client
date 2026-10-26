import XCTest
@testable import MattermostSyncCore

/// Random interleavings of every allocator operation against a simulated server. After each step:
/// ids are unique, positive and within range, strictly increasing in `(createAt, postId)` order;
/// every renumber plan describes exactly the id changes that happened; every island really is
/// contiguous on the server; holes contain no mapped ids; the start/latest flags are true.
/// `SQLiteMessageIdPropertyTests` runs them again against the SQLite store.
class MessageIdPropertyTests: XCTestCase {
    func makeStore() throws -> any InspectableMessageIdStore {
        return InMemoryMessageIdStore()
    }

    private struct Simulation {
        let channel = "c"
        let allocator: MessageIdAllocator
        var rng: SeededGenerator
        var server: FakeServer
        var store: any InspectableMessageIdStore
        /// The ids we expect the store to hold, maintained only from operation results.
        var shadow: [String: Int32] = [:]
        var connected = true
        /// Posts created while disconnected; delivered by catch-up (`since=`) on reconnect.
        var undelivered: [PostOrderKey] = []
        var clock: Int64
        var stats: [String: Int] = [:]

        init(seed: UInt64, configuration: MessageIdAllocator.Configuration, initialPosts: Int, store: any InspectableMessageIdStore) {
            self.store = store
            allocator = MessageIdAllocator(configuration: configuration)
            rng = SeededGenerator(seed: seed)
            var posts: [PostOrderKey] = []
            // Imported 2013 history, then a gap, then regular traffic with bursts.
            var time = Times.year2013
            for index in 0 ..< initialPosts {
                if index == initialPosts / 4 {
                    time = Times.year2025
                }
                switch rng.next() % 10 {
                case 0:
                    break // same millisecond
                case 1:
                    time += Int64(rng.next() % 1000) // same second
                default:
                    time += Int64(rng.next() % (6 * 3_600_000))
                }
                posts.append(PostOrderKey(createAt: time, postId: randomPostId(&rng)))
            }
            server = FakeServer(posts: posts)
            clock = time + 60_000
        }

        mutating func random(_ upperBound: Int) -> Int {
            return Int(rng.next() % UInt64(upperBound))
        }

        /// Set `SIM_TRACE=<directory>` to write the operation log of a failing seed there.
        final class Log {
            let enabled = ProcessInfo.processInfo.environment["SIM_TRACE"] != nil
            var lines: [String] = []
        }
        let log = Log()

        mutating func count(_ name: String) {
            stats[name, default: 0] += 1
            trace(name)
        }

        func trace(_ message: @autoclosure () -> String) {
            if log.enabled {
                log.lines.append(message())
            }
        }

        // MARK: Operations

        /// One random operation, as one store transaction when the store has them.
        mutating func step() throws {
            if let runner = store.operationRunner {
                try runner { try self.randomOperation() }
            } else {
                try randomOperation()
            }
        }

        mutating func randomOperation() throws {
            trace("islands=\(store.islands(channelId: channel))")
            let roll = random(100)
            switch roll {
            case 0 ..< 10:
                try openLatest()
            case 10 ..< 42:
                try fillRandomHole()
            case 42 ..< 52:
                try permalinkJump()
            case 52 ..< 64:
                try livePost()
            case 64 ..< 72:
                try latePost()
            case 72 ..< 78:
                try burst()
            case 78 ..< 85:
                deleteRandomPost()
            case 85 ..< 90:
                try toggleConnection()
            default:
                try replayKnownPage()
            }
        }

        mutating func perPage() -> Int {
            return [1, 5, 30, 60, 200][random(5)]
        }

        mutating func openLatest() throws {
            count("openLatest")
            let page = server.latest(limit: perPage())
            let result = try allocator.ingestLatestPage(page.posts, reachedStart: page.reachedEnd, channelId: channel, store: &store)
            try absorb(result)
            if !connected {
                allocator.invalidateLatest(channelId: channel, store: &store)
            }
        }

        mutating func fillRandomHole() throws {
            let holes = allocator.holes(channelId: channel, store: store)
            guard !holes.isEmpty else {
                count("fillHole.none")
                return
            }
            let hole = holes[random(holes.count)]
            let direction: HistoryDirection = random(2) == 0 ? .older : .newer
            let boundary = direction == .older ? hole.range.upperBound : hole.range.lowerBound
            let cursor = allocator.fillCursor(direction: direction, boundaryLocalId: boundary, channelId: channel, store: store)
            let limit = perPage()
            switch cursor {
            case .latest?:
                count("fillHole.latest")
                let page = server.latest(limit: limit)
                trace("page=\(page.posts.first.map { "\($0)" } ?? "-")…\(page.posts.last.map { "\($0)" } ?? "-") n=\(page.posts.count) end=\(page.reachedEnd)")
                try absorb(try allocator.ingestLatestPage(page.posts, reachedStart: page.reachedEnd, channelId: channel, store: &store))
                if !connected {
                    allocator.invalidateLatest(channelId: channel, store: &store)
                }
            case let .before(anchor)?:
                count("fillHole.before")
                let page = server.before(anchor, limit: limit)
                trace("anchor=\(server.key(of: anchor)!) page=\(page.posts.first.map { "\($0)" } ?? "-")…\(page.posts.last.map { "\($0)" } ?? "-") n=\(page.posts.count) end=\(page.reachedEnd)")
                try absorb(try allocator.ingestPage(page.posts, extending: anchor, direction: .older, reachedEnd: page.reachedEnd, channelId: channel, store: &store))
            case let .after(anchor)?:
                count("fillHole.after")
                let page = server.after(anchor, limit: limit)
                trace("anchor=\(server.key(of: anchor)!) page=\(page.posts.first.map { "\($0)" } ?? "-")…\(page.posts.last.map { "\($0)" } ?? "-") n=\(page.posts.count) end=\(page.reachedEnd)")
                // Only a connected client may treat the newest page as live.
                try absorb(try allocator.ingestPage(page.posts, extending: anchor, direction: .newer, reachedEnd: page.reachedEnd && connected, channelId: channel, store: &store))
            case .around?, nil:
                count("fillHole.nil")
            }
        }

        mutating func permalinkJump() throws {
            let live = server.livePosts
            guard !live.isEmpty else {
                return
            }
            count("permalink")
            let target = live[random(live.count)]
            let limit = perPage()
            let older = server.before(target.postId, limit: limit)
            let newer = server.after(target.postId, limit: limit)
            trace("target=\(target) older=\(older.posts.first.map { "\($0)" } ?? "-") n=\(older.posts.count) end=\(older.reachedEnd) newer=\(newer.posts.last.map { "\($0)" } ?? "-") n=\(newer.posts.count) end=\(newer.reachedEnd)")
            let result = try allocator.ingestAround(target: target, older: older.posts, newer: newer.posts, olderReachedStart: older.reachedEnd, newerReachedLatest: newer.reachedEnd && connected, channelId: channel, store: &store)
            try absorb(result)
        }

        mutating func livePost() throws {
            count("live")
            clock += Int64(random(5) == 0 ? 0 : random(120_000))
            let post = PostOrderKey(createAt: clock, postId: randomPostId(&rng))
            server.add(post)
            if connected {
                try absorb(try allocator.insertPost(post, channelId: channel, store: &store))
            } else {
                undelivered.append(post)
            }
        }

        /// A backdated post (import, delayed bot) delivered by an event; anywhere in time.
        mutating func latePost() throws {
            count("late")
            let live = server.livePosts
            let time: Int64
            if !live.isEmpty && random(3) != 0 {
                // Next to an existing post, often in the very same millisecond.
                let neighbour = live[random(live.count)]
                time = neighbour.createAt + Int64(random(3) == 0 ? 0 : random(2000))
            } else {
                time = Times.year2013 + Int64(rng.next() % UInt64(clock - Times.year2013))
            }
            let post = PostOrderKey(createAt: time, postId: randomPostId(&rng))
            server.add(post)
            try absorb(try allocator.insertPost(post, channelId: channel, store: &store))
        }

        /// A bot posting many messages in one millisecond, delivered out of order.
        mutating func burst() throws {
            count("burst")
            clock += 1
            var posts = (0 ..< (1 + random(40))).map { _ in PostOrderKey(createAt: clock, postId: randomPostId(&rng)) }
            for post in posts {
                server.add(post)
            }
            guard connected else {
                undelivered += posts
                return
            }
            posts.shuffle(using: &rng)
            for post in posts {
                try absorb(try allocator.insertPost(post, channelId: channel, store: &store))
            }
        }

        mutating func deleteRandomPost() {
            let live = server.livePosts
            guard !live.isEmpty else {
                return
            }
            count("delete")
            let post = live[random(live.count)]
            trace("deleted=\(post)")
            server.delete(post.postId)
            // Deletions are always delivered (event or catch-up).
            let deleted = allocator.markDeleted([post.postId], channelId: channel, store: &store)
            for entry in deleted {
                XCTAssertEqual(shadow[entry.postId], entry.localId)
            }
        }

        mutating func toggleConnection() throws {
            if connected {
                count("disconnect")
                connected = false
                allocator.invalidateLatest(channelId: channel, store: &store)
            } else {
                try reconnect()
            }
        }

        /// Catch-up: posts created while offline are applied one by one, oldest first.
        mutating func reconnect() throws {
            count("reconnect")
            connected = true
            let missed = undelivered.sorted()
            undelivered = []
            for post in missed {
                try absorb(try allocator.insertPost(post, channelId: channel, store: &store))
            }
        }

        /// Catch-up and WebSocket resume replay data that is already known.
        mutating func replayKnownPage() throws {
            let entries = store.allEntries(channelId: channel)
            guard !entries.isEmpty else {
                return
            }
            count("replay")
            let anchor = entries[random(entries.count)]
            let page = server.before(anchor.postId, limit: perPage())
            trace("anchor=\(anchor) page=\(page.posts.first.map { "\($0)" } ?? "-")…\(page.posts.last.map { "\($0)" } ?? "-") n=\(page.posts.count) end=\(page.reachedEnd)")
            try absorb(try allocator.ingestPage(page.posts, extending: anchor.postId, direction: .older, reachedEnd: page.reachedEnd, channelId: channel, store: &store))
        }

        // MARK: Checking

        mutating func absorb(_ result: IngestResult) throws {
            if let plan = result.renumberPlan {
                count("renumber")
                stats["renumberedPosts", default: 0] += plan.moves.count
                var seen = Set<String>()
                for move in plan.moves {
                    XCTAssertTrue(seen.insert(move.postId).inserted, "post moved twice in one plan")
                    XCTAssertEqual(shadow[move.postId], move.from, "plan must start from the stored id")
                    XCTAssertNotEqual(move.from, move.to)
                    XCTAssertTrue(plan.affectedRange.contains(move.from) && plan.affectedRange.contains(move.to))
                }
                for move in plan.moves {
                    shadow[move.postId] = move.to
                }
            }
            for allocation in result.allocations {
                switch allocation.status {
                case .inserted:
                    XCTAssertNil(shadow[allocation.postId], "inserted twice")
                    shadow[allocation.postId] = allocation.localId
                case .existing:
                    XCTAssertEqual(shadow[allocation.postId], allocation.localId)
                case .deleted:
                    if let id = allocation.localId {
                        XCTAssertEqual(shadow[allocation.postId], id)
                    }
                }
            }
        }

        func check(step: Int) -> [String] {
            var problems: [String] = store.validate(channelId: channel, maxId: allocator.configuration.maxId)
            let entries = store.allEntries(channelId: channel)
            if entries.count != shadow.count {
                problems.append("store has \(entries.count) entries, shadow \(shadow.count)")
            }
            for entry in entries where shadow[entry.postId] != entry.localId {
                problems.append("\(entry) but shadow says \(String(describing: shadow[entry.postId]))")
            }
            let islands = store.islands(channelId: channel)
            let pending = Set(undelivered.map { $0.postId })
            for island in islands {
                for post in server.livePosts(in: island.lower, island.upper) where shadow[post.postId] == nil && !pending.contains(post.postId) {
                    problems.append("island \(island) misses server post \(post)")
                }
            }
            if let first = islands.first, first.reachesStart, server.hasLivePost(olderThan: first.lower) {
                problems.append("lowest island claims the channel start but older posts exist")
            }
            if let last = islands.last, last.reachesLatest, server.hasLivePost(newerThan: last.upper) {
                problems.append("highest island claims to be live but newer posts exist")
            }
            let holes = allocator.holes(channelId: channel, store: store)
            for hole in holes {
                if !store.entries(channelId: channel, fromLocalId: hole.range.lowerBound, ascending: true, limit: 1).filter({ hole.range.contains($0.localId) }).isEmpty {
                    problems.append("hole \(hole) contains a mapped id")
                }
            }
            return problems.map { "step \(step): \($0)" }
        }
    }

    private func run(seed: UInt64, steps: Int, configuration: MessageIdAllocator.Configuration, initialPosts: Int) throws -> [String: Int] {
        var simulation = Simulation(seed: seed, configuration: configuration, initialPosts: initialPosts, store: try makeStore())
        for step in 0 ..< steps {
            try simulation.step()
            // Plan consistency is checked on every operation (`absorb`); the full O(n) invariant
            // scan runs every few steps to keep the test fast.
            if step % 3 != 2 && step != steps - 1 {
                continue
            }
            let problems = simulation.check(step: step)
            if !problems.isEmpty {
                XCTFail("seed \(seed): \(problems.prefix(5).joined(separator: "\n"))")
                if let directory = ProcessInfo.processInfo.environment["SIM_TRACE"] {
                    try? simulation.log.lines.joined(separator: "\n").write(toFile: "\(directory)/trace-\(seed).txt", atomically: true, encoding: .utf8)
                }
                return simulation.stats
            }
        }
        // Finally reconnect, load everything and compare with the server.
        if !simulation.connected {
            try simulation.reconnect()
        }
        var guardCounter = 0
        while let hole = simulation.allocator.holes(channelId: simulation.channel, store: simulation.store).first {
            guardCounter += 1
            if guardCounter > 10_000 {
                XCTFail("seed \(seed): holes never close")
                break
            }
            let cursor = simulation.allocator.fillCursor(direction: .older, boundaryLocalId: hole.range.upperBound, channelId: simulation.channel, store: simulation.store)
            switch cursor {
            case let .before(anchor)?:
                let page = simulation.server.before(anchor, limit: 200)
                try simulation.absorb(try simulation.allocator.ingestPage(page.posts, extending: anchor, direction: .older, reachedEnd: page.reachedEnd, channelId: simulation.channel, store: &simulation.store))
            default:
                let page = simulation.server.latest(limit: 200)
                try simulation.absorb(try simulation.allocator.ingestLatestPage(page.posts, reachedStart: page.reachedEnd, channelId: simulation.channel, store: &simulation.store))
            }
        }
        let problems = simulation.check(step: steps)
        XCTAssertEqual(problems, [], "seed \(seed)")
        let mapped = Set(simulation.store.allEntries(channelId: simulation.channel).filter { !$0.isDeleted }.map { $0.postId })
        for post in simulation.server.livePosts {
            XCTAssertTrue(mapped.contains(post.postId), "seed \(seed): \(post) never loaded")
        }
        // A persistent store reads back exactly what it held.
        let channel = simulation.channel
        let deletedIds = Array(simulation.server.deleted)
        let entries = simulation.store.allEntries(channelId: channel)
        let islands = simulation.store.islands(channelId: channel)
        let tombstones = simulation.store.unmappedTombstones(channelId: channel, among: deletedIds)
        let reopened = try simulation.store.reopened()
        XCTAssertEqual(reopened.allEntries(channelId: channel), entries, "seed \(seed)")
        XCTAssertEqual(reopened.islands(channelId: channel), islands, "seed \(seed)")
        XCTAssertEqual(reopened.unmappedTombstones(channelId: channel, among: deletedIds), tombstones, "seed \(seed)")
        XCTAssertEqual(reopened.validate(channelId: channel, maxId: configuration.maxId), [], "seed \(seed)")
        if ProcessInfo.processInfo.environment["SIM_STATS"] != nil {
            print("STATS seed \(seed): \(simulation.stats.sorted { $0.key < $1.key }) entries=\(simulation.store.allEntries(channelId: simulation.channel).count)")
        }
        return simulation.stats
    }

    func testRandomInterleavingsWithDefaultConfiguration() throws {
        var totals: [String: Int] = [:]
        for seed: UInt64 in 1 ... 4 {
            let stats = try run(seed: seed, steps: 400, configuration: .default, initialPosts: 1000)
            totals.merge(stats, uniquingKeysWith: +)
        }
        XCTAssertGreaterThan(totals["permalink", default: 0], 0)
        XCTAssertGreaterThan(totals["burst", default: 0], 0)
        XCTAssertGreaterThan(totals["renumber", default: 0], 0, "same-millisecond bursts exhaust midpoints")
    }

    /// A small id space so holes run out constantly and every renumber path is exercised.
    func testRandomInterleavingsInATightIdSpace() throws {
        let configuration = MessageIdAllocator.Configuration(firstId: 1 << 13, maxId: 1 << 14)
        var totals: [String: Int] = [:]
        for seed: UInt64 in 100 ... 105 {
            let stats = try run(seed: seed, steps: 300, configuration: configuration, initialPosts: 800)
            totals.merge(stats, uniquingKeysWith: +)
        }
        XCTAssertGreaterThan(totals["renumber", default: 0], 20)
    }

    /// Nearly full: forces whole-channel relayouts.
    func testRandomInterleavingsInANearlyFullIdSpace() throws {
        let configuration = MessageIdAllocator.Configuration(step: 16, firstId: 1500, maxId: 3000)
        for seed: UInt64 in 200 ... 202 {
            _ = try run(seed: seed, steps: 250, configuration: configuration, initialPosts: 600)
        }
    }
}
