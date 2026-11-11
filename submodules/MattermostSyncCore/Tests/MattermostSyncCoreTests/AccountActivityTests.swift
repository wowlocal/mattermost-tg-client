import XCTest
@testable import MattermostSyncCore

private actor ActivityRecorder {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor ActivityGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

final class AccountActivityTests: XCTestCase {
    private func waitFor(_ recorder: ActivityRecorder, count: Int) async throws {
        for _ in 0..<1000 {
            if await recorder.values.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Activity did not start")
    }

    func testSocketPolicyDoesNotDependOnPrimaryPresence() {
        XCTAssertTrue(AccountSocketLifecycle.requiresSocket(mobile: true, foreground: true, callSignalling: false, stopped: false))
        XCTAssertTrue(AccountSocketLifecycle.requiresSocket(mobile: true, foreground: false, callSignalling: true, stopped: false))
        XCTAssertFalse(AccountSocketLifecycle.requiresSocket(mobile: true, foreground: false, callSignalling: false, stopped: false))
        XCTAssertFalse(AccountSocketLifecycle.requiresSocket(mobile: true, foreground: true, callSignalling: true, stopped: true))
        XCTAssertTrue(AccountSocketLifecycle.requiresSocket(mobile: false, foreground: false, callSignalling: false, stopped: false))
    }

    func testLatestForegroundWinsWhileConnectIsRunning() async throws {
        let recorder = ActivityRecorder(), gate = ActivityGate()
        let lifecycle = AccountSocketLifecycle(connect: { await recorder.append("connect"); await gate.wait() }, disconnect: { await recorder.append("disconnect") }, reconnect: { await recorder.append("reconnect") }, verify: { await recorder.append("verify") })
        let first = Task { await lifecycle.update(.init(revision: 1, required: true)) }
        try await waitFor(recorder, count: 1)
        await lifecycle.update(.init(revision: 2, required: false))
        await lifecycle.update(.init(revision: 3, required: true, verify: 1))
        await gate.release()
        await first.value
        await lifecycle.update(.init(revision: 2, required: false))
        let values = await recorder.values
        XCTAssertEqual(values, ["connect", "verify"])
    }

    func testBackgroundDuringConnectClosesTheSocketAndIgnoresReconnect() async throws {
        let recorder = ActivityRecorder(), gate = ActivityGate()
        let lifecycle = AccountSocketLifecycle(connect: { await recorder.append("connect"); await gate.wait() }, disconnect: { await recorder.append("disconnect") }, reconnect: { await recorder.append("reconnect") }, verify: { await recorder.append("verify") })
        let first = Task { await lifecycle.update(.init(revision: 1, required: true)) }
        try await waitFor(recorder, count: 1)
        await lifecycle.update(.init(revision: 2, required: false, reconnect: 1, verify: 1))
        await gate.release()
        await first.value
        let values = await recorder.values
        XCTAssertEqual(values, ["connect", "disconnect"])
    }

    func testInitialActivationConnectsOnceThenChecksRetainedSocket() async {
        let recorder = ActivityRecorder()
        let lifecycle = AccountSocketLifecycle(connect: { await recorder.append("connect") }, disconnect: { await recorder.append("disconnect") }, reconnect: { await recorder.append("reconnect") }, verify: { await recorder.append("verify") })
        await lifecycle.update(.init(revision: 1, required: true, verify: 1))
        await lifecycle.update(.init(revision: 2, required: true, verify: 2))
        let values = await recorder.values
        XCTAssertEqual(values, ["connect", "verify"])
    }

    func testPresenceTransitionDuringAReportIsSentImmediatelyAfterIt() async throws {
        let recorder = ActivityRecorder(), gate = ActivityGate()
        let reporter = PresenceActivityReporter { active in
            await recorder.append(String(active))
            if active { await gate.wait() }
        }
        let first = Task { await reporter.update(.init(revision: 1, active: true, connected: true)) }
        try await waitFor(recorder, count: 1)
        await reporter.update(.init(revision: 2, active: false, connected: true))
        await gate.release()
        await first.value
        await reporter.update(.init(revision: 1, active: true, connected: true))
        let values = await recorder.values
        XCTAssertEqual(values, ["true", "false"])
    }

    func testFailedActivityBacksOffButANewTransitionDoesNotWait() async {
        let recorder = ActivityRecorder()
        let reporter = PresenceActivityReporter(now: { 0 }) { active in
            await recorder.append(String(active))
            if active { throw NSError(domain: "test", code: 1) }
        }
        await reporter.update(.init(revision: 1, active: true, connected: true))
        await reporter.update(.init(revision: 2, active: true, connected: true))
        await reporter.update(.init(revision: 3, active: true, connected: true))
        await reporter.update(.init(revision: 4, active: false, connected: true))
        await reporter.update(.init(revision: 5, active: true, connected: false))
        let values = await recorder.values
        XCTAssertEqual(values, ["true", "false"])
    }
}
