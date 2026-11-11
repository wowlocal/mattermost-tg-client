import XCTest
@testable import MattermostSyncCore

final class DirectMessageReceiptPollSchedulerTests: XCTestCase {
    private func candidate(_ id: Int, revision: Int64 = 1, bot: Bool = false, priority: Int = 1, opened: Int = 0) -> DirectMessageReceiptPollCandidate {
        .init(channelId: String(format: "%03d", id), revision: revision, isBot: bot, priority: priority, opened: opened)
    }

    func testOwnRootBelowAnIncomingReplyRemainsTheCandidate() {
        let own = DirectMessageReceiptPost(postId: "own", localId: 10, isOwn: true, eligible: true)
        let incoming = DirectMessageReceiptPost(postId: "answer", localId: 20, isOwn: false, eligible: true)
        XCTAssertEqual(DirectMessageReceiptPost.newestUnconfirmedRoot(in: [incoming, own], after: 0), own)
        XCTAssertNil(DirectMessageReceiptPost.newestUnconfirmedRoot(in: [incoming, own], after: 10))
    }

    func testOwnThreadReplyAndDeletedNewestPostDoNotHideEarlierRoot() {
        let root = DirectMessageReceiptPost(postId: "root", localId: 10, isOwn: true, eligible: true)
        let reply = DirectMessageReceiptPost(postId: "reply", localId: 20, isOwn: true, eligible: false)
        let deleted = DirectMessageReceiptPost(postId: "deleted", localId: 30, isOwn: true, isDeleted: true, eligible: true)
        XCTAssertEqual(DirectMessageReceiptPost.newestUnconfirmedRoot(in: [deleted, reply, root], after: 0), root)
        XCTAssertNil(DirectMessageReceiptPost.newestUnconfirmedRoot(in: [deleted, reply], after: 0))
    }

    func testOlderUnknownRootIsMigratedBeforeItCanConfirm() {
        let old = DirectMessageReceiptPost(postId: "old", localId: 1, isOwn: true, eligible: false, needsMigration: true)
        XCTAssertEqual(DirectMessageReceiptPost.newestUnconfirmedRoot(in: [old], after: 0), old)
        XCTAssertFalse(old.eligible)
    }

    func testOneHundredDMsHaveAConstantRollingBudgetIncludingMigration() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let candidates = (0..<100).map { candidate($0) }
        var requests: [(time: Double, count: Int)] = []
        for second in 0..<600 {
            let now = Double(second)
            if let next = scheduler.next(candidates, now: now) {
                let cost = second % 2 == 0 ? 3 : 2
                if scheduler.reserveRequests(cost, for: next, now: now) { requests.append((now, cost)) }
                scheduler.completed(next, result: .unconfirmed, now: now)
            }
            XCTAssertLessThanOrEqual(requests.filter { $0.time > now - 60 }.reduce(0) { $0 + $1.count }, DirectMessageReceiptPollScheduler.requestsPerMinute)
        }
    }

    func testOpeningChatMakesThirtyMinuteBackoffDueImmediately() {
        var scheduler = DirectMessageReceiptPollScheduler()
        var chat = candidate(0)
        for i in 0..<8 {
            let now = Double(i * 3600)
            XCTAssertNotNil(scheduler.next([chat], now: now))
            scheduler.completed(chat, result: .unconfirmed, now: now)
        }
        XCTAssertNil(scheduler.next([chat], now: 25201))
        chat.priority = 2
        chat.opened = 1
        XCTAssertNotNil(scheduler.next([chat], now: 25201))
        scheduler.completed(chat, result: .unconfirmed, now: 25201)
        XCTAssertNil(scheduler.next([chat], now: 25210))
        XCTAssertNotNil(scheduler.next([chat], now: 25211))
        scheduler.completed(chat, result: .unconfirmed, now: 25211)
        chat.opened = 2
        XCTAssertNotNil(scheduler.next([chat], now: 25212))
    }

    func testNetworkErrorsAndAbortsDoNotGrowBotOrHumanBackoff() {
        for bot in [false, true] {
            var scheduler = DirectMessageReceiptPollScheduler()
            let chat = candidate(0, bot: bot)
            for now in stride(from: 0.0, through: 50.0, by: 10.0) {
                XCTAssertNotNil(scheduler.next([chat], now: now))
                scheduler.completed(chat, result: .retryable, now: now)
            }
            XCTAssertNotNil(scheduler.next([chat], now: 60))
            scheduler.completed(chat, result: .aborted, now: 60)
            XCTAssertNotNil(scheduler.next([chat], now: 60))
            scheduler.completed(chat, result: .unconfirmed, now: 60)
            XCTAssertNil(scheduler.next([chat], now: 89))
            XCTAssertNotNil(scheduler.next([chat], now: bot ? 3660 : 90))
        }
    }

    func testOnlyDueChannelsReachTheStorageCaller() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let channels = (0..<15).map { candidate($0) }
        for channel in channels {
            _ = scheduler.next([channel], now: 0)
            scheduler.completed(channel, result: .noPending, now: 0)
        }
        for second in 1..<60 { XCTAssertNil(scheduler.next(channels, now: Double(second))) }
        XCTAssertNotNil(scheduler.next([candidate(0, revision: 2)], now: 60))
    }

    func testFifteenUnconfirmedRowsInBackoffCauseNoStorageSelectionsForAMinute() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let channels = (0..<15).map { candidate($0) }
        for round in 0..<8 {
            for (index, channel) in channels.enumerated() {
                let now = Double(round * 4000 + index * 61)
                XCTAssertNotNil(scheduler.next([channel], now: now))
                XCTAssertTrue(scheduler.reserveRequests(2, now: now))
                scheduler.completed(channel, result: .unconfirmed, now: now)
            }
        }
        for now in 28855..<28915 { XCTAssertNil(scheduler.next(channels, now: Double(now))) }
    }

    func testOpenChatGetsSixSamplesAMinuteWithoutInputActivity() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let chat = candidate(0, priority: 2)
        var samples = 0
        for second in 0..<60 {
            if let next = scheduler.next([chat], now: Double(second)) {
                XCTAssertTrue(scheduler.reserveRequests(2, for: next, now: Double(second)))
                scheduler.completed(next, result: .unconfirmed, now: Double(second))
                samples += 1
            }
        }
        XCTAssertEqual(samples, 6)
    }
    func testOpenBotCannotStarveDueListRowsAndUsesAtMostHalfTheBudget() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let open = candidate(0, bot: true, priority: 2)
        let rows = (1...30).map { candidate($0) }
        var requests: [(at: Double, count: Int, open: Bool)] = []
        var sampledRows = Set<String>()
        for second in stride(from: 0, to: 600, by: 5) {
            let now = Double(second)
            guard let next = scheduler.next([open] + rows, now: now) else { continue }
            let cost = second % 3 == 0 ? 3 : 2
            if scheduler.reserveRequests(cost, for: next, now: now) {
                requests.append((now, cost, next.priority == 2))
                if next.priority < 2 { sampledRows.insert(next.channelId) }
                scheduler.completed(next, result: .unconfirmed, now: now)
            } else { scheduler.completed(next, result: .retryable, now: now) }
            let window = requests.filter { $0.at > now - 60 }
            XCTAssertLessThanOrEqual(window.reduce(0) { $0 + $1.count }, 24)
            XCTAssertLessThanOrEqual(window.filter { $0.open }.reduce(0) { $0 + $1.count }, 12)
        }
        XCTAssertEqual(sampledRows.count, 30)
    }

    func testOpenChatSlowsAfterOneMinuteAndAnOwnPostRestartsFastSampling() {
        var scheduler = DirectMessageReceiptPollScheduler()
        var chat = candidate(0, priority: 2)
        var times: [Int] = []
        for second in 0...210 {
            if let next = scheduler.next([chat], now: Double(second)) {
                times.append(second)
                scheduler.completed(next, result: .unconfirmed, now: Double(second))
            }
        }
        XCTAssertEqual(times, [0, 10, 20, 30, 40, 50, 60, 90, 150, 210])
        chat.written = 211
        XCTAssertNotNil(scheduler.next([chat], now: 211))
        scheduler.completed(chat, result: .unconfirmed, now: 211)
        XCTAssertNotNil(scheduler.next([chat], now: 221))
    }

    func testIncomingRevisionDoesNotExtendTheOpenFastWindow() {
        var scheduler = DirectMessageReceiptPollScheduler()
        var chat = candidate(0, priority: 2)
        for second in stride(from: 0, through: 50, by: 10) {
            XCTAssertNotNil(scheduler.next([chat], now: Double(second)))
            scheduler.completed(chat, result: .unconfirmed, now: Double(second))
        }
        chat.revision = 2
        XCTAssertNotNil(scheduler.next([chat], now: 60))
        scheduler.completed(chat, result: .unconfirmed, now: 60)
        XCTAssertNil(scheduler.next([chat], now: 70))
        XCTAssertNotNil(scheduler.next([chat], now: 90))
    }

    func testMinuteInOpenChatDoesNotInflateTheListDelay() {
        var scheduler = DirectMessageReceiptPollScheduler()
        var chat = candidate(0, priority: 2)
        for second in stride(from: 0, through: 60, by: 10) {
            XCTAssertNotNil(scheduler.next([chat], now: Double(second)))
            scheduler.completed(chat, result: .unconfirmed, now: Double(second))
        }
        chat.priority = 1
        XCTAssertNotNil(scheduler.next([chat], now: 61))
        scheduler.completed(chat, result: .unconfirmed, now: 61)
        XCTAssertNil(scheduler.next([chat], now: 90))
        XCTAssertNotNil(scheduler.next([chat], now: 91))
        scheduler.completed(chat, result: .unconfirmed, now: 91)
        XCTAssertNotNil(scheduler.next([chat], now: 151))
    }

    func testSlowSamplesCannotGiveEveryTickToTheOpenChat() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let open = candidate(0, priority: 2)
        let row = candidate(1)
        var rowTimes: [Int] = []
        for second in stride(from: 0, through: 50, by: 10) {
            let now = Double(second)
            let next = scheduler.next([open, row], now: now)!
            XCTAssertTrue(scheduler.reserveRequests(2, for: next, now: now))
            if next.channelId == row.channelId { rowTimes.append(second) }
            scheduler.completed(next, result: .unconfirmed, now: now)
        }
        XCTAssertEqual(rowTimes, [10, 40])
    }

}
