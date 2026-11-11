import XCTest
@testable import MattermostSyncCore

final class DirectMessageReceiptPollSchedulerTests: XCTestCase {
    private func candidate(_ id: Int, own: Bool = true, bot: Bool = false, deactivated: Bool = false, visible: Bool = true, migration: Bool = false) -> DirectMessageReceiptPollCandidate {
        .init(channelId: String(format: "%03d", id), postId: "post", isOwn: own, isBot: bot, isDeactivated: deactivated, visible: visible, recentlyWritten: false, needsMigration: migration)
    }

    func testOneHundredUnconfirmedDMsHaveAConstantRollingRequestBudget() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let candidates = (0..<100).map { candidate($0) }
        var requests: [(time: Double, count: Int)] = []
        for second in 0..<600 {
            let now = Double(second)
            if let next = scheduler.next(candidates, now: now) {
                requests.append((now, 2))
                scheduler.completed(next, confirmed: false, now: now)
            }
            XCTAssertLessThanOrEqual(requests.filter { $0.time > now - 60 }.reduce(0) { $0 + $1.count }, 12)
        }
        XCTAssertEqual(requests.count, 60)
        XCTAssertEqual(requests.reduce(0) { $0 + $1.count }, 120)
    }

    func testUpgradePagesConsumeTheSameBudgetAndOnlyInterestedDMsQualify() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let candidates = (0..<100).map { candidate($0, visible: false, migration: true) }
        XCTAssertNil(scheduler.next(candidates, now: 0))
        var visible = candidates
        for i in visible.indices { visible[i].visible = true }
        var count = 0
        for second in 0..<60 {
            if let next = scheduler.next(visible, now: Double(second)) {
                count += 3
                scheduler.completed(next, confirmed: false, now: Double(second))
            }
        }
        XCTAssertEqual(count, 12)
    }

    func testIncomingAndDeactivatedLatestPostsAreNeverPolled() {
        var scheduler = DirectMessageReceiptPollScheduler()
        XCTAssertNil(scheduler.next([candidate(0, own: false), candidate(1, deactivated: true)], now: 0))
    }

    func testBotThatDoesNotViewBacksOffForAnHour() {
        var scheduler = DirectMessageReceiptPollScheduler()
        let bot = candidate(0, bot: true)
        XCTAssertNotNil(scheduler.next([bot], now: 0))
        scheduler.completed(bot, confirmed: false, now: 0)
        XCTAssertNil(scheduler.next([bot], now: 3599))
        XCTAssertNotNil(scheduler.next([bot], now: 3600))
    }

    func testVisibleChatGetsPriorityAndNewOwnPostResetsItsBackoff() {
        var scheduler = DirectMessageReceiptPollScheduler()
        var chat = candidate(99)
        chat.priority = 2
        let other = candidate(0)
        XCTAssertEqual(scheduler.next([other, chat], now: 0)?.channelId, chat.channelId)
        scheduler.completed(chat, confirmed: false, now: 0)
        XCTAssertNil(scheduler.next([chat], now: 29))
        chat.postId = "new post"
        XCTAssertNotNil(scheduler.next([chat], now: 29))
        scheduler.completed(chat, confirmed: true, now: 29)
        XCTAssertNil(scheduler.next([chat], now: 3600))
    }
}
