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

    func testRestartWithTheSameFirstChunkStillRecordsBodyProgress() {
        var activity = UploadActivity(now: 0, totalBytes: 1000)
        activity.record(bytesSent: 100, now: 10)
        activity.record(bytesSent: 100, now: 35, sentBodyBytes: 100)
        XCTAssertFalse(activity.isStalled(now: 64, timeout: 30))
        XCTAssertTrue(activity.isStalled(now: 65, timeout: 30))
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

    func testFailedWebSocketNeedsANewTransportBeforeItIsEvidence() {
        let clock = Locked<TimeInterval>(10)
        let health = UploadConnectionHealth(now: { clock.current })
        let old = UUID()
        health.transportConnected(connection: old)
        health.transportFailed(connection: old)
        XCTAssertNil(health.evidence(after: 0))
        health.transportConnected(connection: old)
        XCTAssertNil(health.evidence(after: 0))
        clock.set(20)
        health.transportConnected(connection: UUID())
        XCTAssertNotNil(health.evidence(after: 9))
        XCTAssertNil(health.evidence(after: 11))
        XCTAssertNil(health.evidence(after: 21))
    }

    func testAddingAnInterfaceIsNotEvidenceButReplacingUsedInterfaceIs() {
        let clock = Locked<TimeInterval>(10)
        let health = UploadConnectionHealth(now: { clock.current })
        health.pathChanged(from: [], to: ["wifi"])
        health.pathChanged(from: ["wifi"], to: ["wifi", "vpn"])
        XCTAssertNil(health.evidence(after: 0))
        health.pathChanged(from: ["wifi"], to: ["cellular"])
        XCTAssertNotNil(health.evidence(after: 0))
    }

    func testAnEarlyTransportTimeoutIsNotAWholeResponseWaitTimeout() {
        var activity = UploadActivity(now: 0, totalBytes: 1000)
        XCTAssertFalse(activity.exhaustedResponseAllowance(now: 300, allowance: 300))
        activity.record(bytesSent: 1000, now: 1)
        XCTAssertFalse(activity.exhaustedResponseAllowance(now: 30, allowance: 300))
        XCTAssertFalse(activity.exhaustedResponseAllowance(now: 299, allowance: 300))
        XCTAssertTrue(activity.exhaustedResponseAllowance(now: 301, allowance: 300))
    }

    func testLongMovingBodyGetsAFullAllowanceAfterItsLastByte() {
        var activity = UploadActivity(now: 0, totalBytes: 1000)
        for second in stride(from: 20, through: 360, by: 20) {
            activity.record(bytesSent: Int64(second), now: Double(second))
        }
        activity.record(bytesSent: 1000, now: 361)
        XCTAssertFalse(activity.exhaustedResponseAllowance(now: 400, allowance: 300))
        XCTAssertFalse(activity.exhaustedResponseAllowance(now: 660, allowance: 300))
        XCTAssertTrue(activity.exhaustedResponseAllowance(now: 661, allowance: 300))
    }

    func testRestartToZeroStillCountsAsABodyThatStarted() {
        var activity = UploadActivity(now: 0, totalBytes: 1000)
        XCTAssertFalse(activity.bodyStarted)
        activity.record(bytesSent: 100, now: 1)
        activity.record(bytesSent: 0, now: 2)
        XCTAssertTrue(activity.bodyStarted)
        XCTAssertTrue(activity.isStalled(now: 32, timeout: 30))
    }

    func testFailureBeforeUploadProgressCannotCancelItOnReconnect() {
        let clock = Locked<TimeInterval>(10)
        let health = UploadConnectionHealth(now: { clock.current })
        health.transportFailed(connection: UUID())
        clock.set(30)
        health.transportConnected(connection: UUID())
        XCTAssertNil(health.evidence(after: 20))
        clock.set(40)
        health.transportFailed(connection: UUID())
        clock.set(50)
        health.transportConnected(connection: UUID())
        XCTAssertNotNil(health.evidence(after: 20))
    }

    func testEvidenceCanRestartAGivenUploadOnlyOnce() {
        let state = UploadRetryState()
        XCTAssertTrue(state.claimEvidenceRestart())
        XCTAssertFalse(state.claimEvidenceRestart())
        XCTAssertFalse(state.claimEvidenceRestart())
    }

    func testOnlyBodyStallsConsumeTheRetryCapAndResponseWaitIsTerminal() {
        let state = UploadRetryState()
        for _ in 0..<20 {
            XCTAssertTrue(state.shouldRetry(.uploadStalled(.connectionUnavailable)))
            XCTAssertTrue(state.shouldRetry(.transport(URLError(.notConnectedToInternet))))
            XCTAssertTrue(state.shouldRetry(.server(AppError(message: "restart", statusCode: 503))))
            XCTAssertTrue(state.shouldRetry(.rateLimited(retryAfter: 30)))
        }
        XCTAssertTrue(state.shouldRetry(.uploadStalled(.bodyProgress)))
        XCTAssertTrue(state.shouldRetry(.uploadStalled(.bodyProgress)))
        XCTAssertFalse(state.shouldRetry(.uploadStalled(.bodyProgress)))
        XCTAssertFalse(state.shouldRetry(.uploadStalled(.responseWait)))
        XCTAssertFalse(MattermostError.uploadStalled(.responseWait).isTransient)
    }
}
