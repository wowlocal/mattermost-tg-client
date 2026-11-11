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
                if scheduler.reserveRequests(cost, now: now) { requests.append((now, cost)) }
                scheduler.completed(next, result: .unconfirmed, now: now)
            }
            XCTAssertLessThanOrEqual(requests.filter { $0.time > now - 60 }.reduce(0) { $0 + $1.count }, 12)
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

    func testOpenChatGetsSixSamplesAMinuteWithoutInputActivity() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let chat = candidate(0, priority: 2)
        var samples = 0
        for second in 0..<60 {
            if let next = scheduler.next([chat], now: Double(second)) {
                XCTAssertTrue(scheduler.reserveRequests(2, now: Double(second)))
                scheduler.completed(next, result: .unconfirmed, now: Double(second))
                samples += 1
            }
        }
        XCTAssertEqual(samples, 6)
    }
}
