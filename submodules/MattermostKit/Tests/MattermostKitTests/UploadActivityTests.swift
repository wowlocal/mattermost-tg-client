import XCTest
@testable import MattermostKit

final class UploadActivityTests: XCTestCase {
    func testBlackholeAndResponseWaitExpire() {
        var activity = UploadActivity(now: 100)
        XCTAssertFalse(activity.isStalled(now: 129, timeout: 30))
        XCTAssertTrue(activity.isStalled(now: 130, timeout: 30))
        activity.record(bytesSent: 4096, now: 129)
        XCTAssertFalse(activity.isStalled(now: 150, timeout: 30))
        XCTAssertTrue(activity.isStalled(now: 159, timeout: 30))
    }

    func testSlowTransferCanExceedFiveMinutesWhileAdvancing() {
        var activity = UploadActivity(now: 0)
        for second in stride(from: 20, through: 600, by: 20) {
            XCTAssertFalse(activity.isStalled(now: Double(second), timeout: 30))
            activity.record(bytesSent: Int64(second), now: Double(second))
        }
        activity.record(bytesSent: 600, now: 620)
        XCTAssertTrue(activity.isStalled(now: 630, timeout: 30), "repeated progress must not postpone the timeout")
    }
}
