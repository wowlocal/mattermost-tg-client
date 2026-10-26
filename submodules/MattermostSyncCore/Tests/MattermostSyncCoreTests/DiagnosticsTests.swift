import Foundation
import XCTest
@testable import MattermostSyncCore

/// Exported diagnostics (Phase 4G): log redaction and the bounded MetricKit report store.
final class DiagnosticsTests: XCTestCase {
    private let redactor = DiagnosticsRedactor(salt: Data([1, 2, 3, 4]))

    // MARK: Redaction

    func testCredentialsAreRedacted() {
        let text = """
        Authorization: Bearer 7xk3m9q2p5w8r1t4y6u0i3o5ab
        GET /api/v4/users/me?token=abcdef0123456789&x=1
        {"token": "sk-secret-value", "password":"hunter22", "csrf": 'zzzzzzzz'}
        cookie: MMAUTHTOKEN=qwertyuiopasdfghjklzxcvbnm1; MMCSRF=12345678
        push: APNs sandbox token 0a1b2c3d4e5f60718293a4b5c6d7e8f9
        """
        let redacted = self.redactor.redact(text)
        for secret in ["7xk3m9q2p5w8r1t4y6u0i3o5ab", "abcdef0123456789", "sk-secret-value", "hunter22", "zzzzzzzz", "qwertyuiopasdfghjklzxcvbnm1", "12345678", "0a1b2c3d4e5f60718293a4b5c6d7e8f9"] {
            XCTAssertFalse(redacted.contains(secret), "\(secret) left in:\n\(redacted)")
        }
        XCTAssertTrue(redacted.hasPrefix("Authorization: <redacted>"), redacted)
        XCTAssertTrue(redacted.contains("&x=1"), "the rest of the line stays")
    }

    func testIdsBecomeStablePseudonyms() {
        let line = "send: post kq3mxj8ub7fy5mdbg3yd1wqzhr in channel 9fx3ux5bwbrc8xjr4dqqxb7uyc; reply to kq3mxj8ub7fy5mdbg3yd1wqzhr"
        let redacted = self.redactor.redact(line)
        XCTAssertFalse(redacted.contains("kq3mxj8ub7fy5mdbg3yd1wqzhr"))
        XCTAssertFalse(redacted.contains("9fx3ux5bwbrc8xjr4dqqxb7uyc"))
        let pseudonym = "<id:\(self.redactor.pseudonym("kq3mxj8ub7fy5mdbg3yd1wqzhr"))>"
        XCTAssertEqual(redacted.components(separatedBy: pseudonym).count - 1, 2, "the same id maps to the same pseudonym")
        XCTAssertNotEqual(self.redactor.pseudonym("kq3mxj8ub7fy5mdbg3yd1wqzhr"), self.redactor.pseudonym("9fx3ux5bwbrc8xjr4dqqxb7uyc"))
        XCTAssertNotEqual(DiagnosticsRedactor(salt: Data([9])).pseudonym("kq3mxj8ub7fy5mdbg3yd1wqzhr"), self.redactor.pseudonym("kq3mxj8ub7fy5mdbg3yd1wqzhr"), "another export, another pseudonym")
    }

    func testIdsInsideLongerTokensAreLeftAlone() {
        // 27 characters, and an id glued to other letters: not a Mattermost id.
        let line = "kq3mxj8ub7fy5mdbg3yd1wqzhrx mm-file-Kq3mxj8ub7fy5mdbg3yd1wqzhr"
        XCTAssertEqual(self.redactor.redact(line), line)
    }

    func testEmailsAndDeviceTokens() {
        let line = "login id alice@example.com; token for device 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let redacted = self.redactor.redact(line)
        XCTAssertFalse(redacted.contains("alice@example.com"))
        XCTAssertTrue(redacted.contains("<email>"))
        XCTAssertFalse(redacted.contains("0123456789abcdef0123456789abcdef"))
    }

    func testOrdinaryLinesAreUnchanged() {
        let line = "[Mattermost] 2026-10-26 12:00:01.123 catch-up since 1730000000000: 12 channels, 3 with new posts in 46 ms"
        XCTAssertEqual(self.redactor.redact(line), line)
        XCTAssertEqual(self.redactor.redact("account 7133911708254456849: no session token in the Keychain"), "account 7133911708254456849: no session token in the Keychain")
    }

    func testLargeLogIsRedactedLineByLineInLinearTime() {
        // ~4 MB of log lines, each with ids, as the app's file log looks after a busy day.
        let line = "[Mattermost] 2026-10-26 12:00:01.123 send: post kq3mxj8ub7fy5mdbg3yd1wqzhr in 9fx3ux5bwbrc8xjr4dqqxb7uyc for alice@example.com, token abcdefgh12345678"
        let text = Array(repeating: line, count: 30_000).joined(separator: "\n")
        let started = Date()
        let redacted = self.redactor.redact(text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30.0)
        XCTAssertEqual(redacted.split(separator: "\n", omittingEmptySubsequences: false).count, 30_000)
        XCTAssertFalse(redacted.contains("kq3mxj8ub7fy5mdbg3yd1wqzhr"))
        XCTAssertFalse(redacted.contains("alice@example.com"))
        XCTAssertFalse(redacted.contains("abcdefgh12345678"))
    }

    // MARK: Report store

    private func makeStore(_ limits: DiagnosticReportStore.Limits) throws -> DiagnosticReportStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-reports-\(UUID().uuidString)")
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return DiagnosticReportStore(directory: directory, limits: limits)
    }

    func testStoresAndListsOldestFirst() throws {
        let store = try self.makeStore(.init())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.store(Data("{\"b\":1}".utf8), kind: .diagnostics, date: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(store.store(Data("{\"a\":1}".utf8), kind: .metrics, date: now.addingTimeInterval(-3600), now: now))
        let reports = store.reports()
        XCTAssertEqual(reports.map(\.kind), [.metrics, .diagnostics])
        XCTAssertEqual(reports.map { Int($0.date.timeIntervalSince1970) }, [1_800_000_000 - 3600, 1_800_000_000 - 60])
        XCTAssertEqual(try Data(contentsOf: reports[0].url), Data("{\"a\":1}".utf8))
        store.removeAll()
        XCTAssertTrue(store.reports().isEmpty)
    }

    func testOldReportsExpire() throws {
        let store = try self.makeStore(.init(maximumAge: 7 * 86400))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.store(Data("{}".utf8), kind: .metrics, date: now.addingTimeInterval(-8 * 86400), now: now.addingTimeInterval(-8 * 86400))
        store.store(Data("{}".utf8), kind: .metrics, date: now.addingTimeInterval(-86400), now: now)
        XCTAssertEqual(store.reports().count, 1)
    }

    func testCountAndSizeBounds() throws {
        let store = try self.makeStore(.init(maximumCount: 3, maximumTotalBytes: 250, maximumReportBytes: 200))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0 ..< 5 {
            store.store(Data(repeating: 0x20, count: 50), kind: .diagnostics, date: now.addingTimeInterval(Double(index)), now: now)
        }
        XCTAssertEqual(store.reports().map { Int($0.date.timeIntervalSince(now)) }, [2, 3, 4], "the newest three")
        XCTAssertFalse(store.store(Data(repeating: 0x20, count: 201), kind: .diagnostics, date: now, now: now), "a single report over the limit is dropped")
        store.store(Data(repeating: 0x20, count: 180), kind: .metrics, date: now.addingTimeInterval(10), now: now)
        let reports = store.reports()
        XCTAssertLessThanOrEqual(reports.reduce(0) { $0 + $1.size }, 250)
        XCTAssertEqual(reports.last?.kind, .metrics)
    }

    func testIgnoresForeignFiles() throws {
        let store = try self.makeStore(.init())
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.directory.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: store.directory.appendingPathComponent("garbage-name.json"))
        XCTAssertTrue(store.reports().isEmpty)
    }
}
