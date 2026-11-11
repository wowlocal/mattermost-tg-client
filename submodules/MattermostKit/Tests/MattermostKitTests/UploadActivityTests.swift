import XCTest
@testable import MattermostKit

final class UploadActivityTests: XCTestCase {
    func testUnsentBodyStallsButACompleteBodyKeepsTheResponseAllowance() {
        var activity = UploadActivity(now: 100, totalBytes: 4096)
        XCTAssertFalse(activity.isStalled(now: 129, timeout: 30))
        XCTAssertTrue(activity.isStalled(now: 130, timeout: 30))
        activity.record(bytesSent: 1000, now: 129)
        XCTAssertFalse(activity.isStalled(now: 150, timeout: 30))
        XCTAssertTrue(activity.isStalled(now: 159, timeout: 30))
        activity.record(bytesSent: 4096, now: 160)
        XCTAssertTrue(activity.bodySent)
        XCTAssertFalse(activity.isStalled(now: 460, timeout: 30))
    }

    func testRestartedBodyCountsAsActivityBelowThePreviousHighWaterMark() {
        var activity = UploadActivity(now: 0, totalBytes: 1000)
        activity.record(bytesSent: 900, now: 20)
        activity.record(bytesSent: 100, now: 45)
        XCTAssertFalse(activity.isStalled(now: 74, timeout: 30))
        activity.record(bytesSent: 200, now: 70)
        XCTAssertFalse(activity.isStalled(now: 99, timeout: 30))
        XCTAssertTrue(activity.isStalled(now: 100, timeout: 30))
    }

    func testSlowTransferCanExceedFiveMinutesWhileAdvancing() {
        var activity = UploadActivity(now: 0)
        for second in stride(from: 20, through: 600, by: 20) {
            XCTAssertFalse(activity.isStalled(now: Double(second), timeout: 30))
            activity.record(bytesSent: Int64(second), now: Double(second))
        }
        activity.record(bytesSent: 600, now: 620)
        XCTAssertTrue(activity.isStalled(now: 630, timeout: 30))
    }

    func testOnlyIndependentEvidenceAfterLastProgressInvalidatesAResponseWait() {
        let clock = Locked<TimeInterval>(10)
        let health = UploadConnectionHealth(now: { clock.current })
        health.pathChanged()
        XCTAssertNil(health.evidence(after: 10))
        XCTAssertNil(health.evidence(after: 11))
        clock.set(20)
        health.transportFailed()
        XCTAssertEqual(health.evidence(after: 11)?.reason, "websocket transport failed")
        XCTAssertNil(health.evidence(after: 21))
    }
}
