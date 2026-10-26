import XCTest
@testable import MattermostKit

final class ServerAddressTests: XCTestCase {
    private func normalized(_ input: String, insecure: Bool = false) throws -> String {
        return try ServerAddress.normalize(input, allowInsecureLocal: insecure).absoluteString
    }

    func testAddsHTTPSAndStripsTrailingSlashes() throws {
        XCTAssertEqual(try normalized("chat.example.com"), "https://chat.example.com")
        XCTAssertEqual(try normalized("  chat.example.com/  "), "https://chat.example.com")
        XCTAssertEqual(try normalized("https://chat.example.com///"), "https://chat.example.com")
        XCTAssertEqual(try normalized("HTTPS://Chat.Example.COM"), "https://chat.example.com")
    }

    func testKeepsPortAndSubpath() throws {
        XCTAssertEqual(try normalized("example.com:8443/mattermost/"), "https://example.com:8443/mattermost")
        XCTAssertEqual(try normalized("https://example.com/team/chat"), "https://example.com/team/chat")
    }

    func testDropsQueryFragmentAndUserInfo() throws {
        XCTAssertEqual(try normalized("https://user:pw@example.com/?a=b#frag"), "https://example.com")
    }

    func testRejectsEmptyAndInvalid() {
        XCTAssertThrowsError(try normalized("   ")) { XCTAssertEqual($0 as? ServerAddress.NormalizationError, .empty) }
        XCTAssertThrowsError(try normalized("not a url")) { XCTAssertEqual($0 as? ServerAddress.NormalizationError, .invalid) }
        XCTAssertThrowsError(try normalized("ftp://example.com")) { XCTAssertEqual($0 as? ServerAddress.NormalizationError, .invalid) }
        XCTAssertThrowsError(try normalized("https://")) { XCTAssertEqual($0 as? ServerAddress.NormalizationError, .invalid) }
    }

    func testHTTPOnlyForLocalHostsWhenAllowed() throws {
        XCTAssertEqual(try normalized("http://localhost:8065", insecure: true), "http://localhost:8065")
        XCTAssertEqual(try normalized("http://192.168.1.20:8065/", insecure: true), "http://192.168.1.20:8065")
        XCTAssertEqual(try normalized("http://mm.local", insecure: true), "http://mm.local")
        XCTAssertThrowsError(try normalized("http://localhost:8065", insecure: false)) {
            XCTAssertEqual($0 as? ServerAddress.NormalizationError, .insecureNotAllowed)
        }
        XCTAssertThrowsError(try normalized("http://chat.example.com", insecure: true)) {
            XCTAssertEqual($0 as? ServerAddress.NormalizationError, .insecureNotAllowed)
        }
        XCTAssertThrowsError(try normalized("http://8.8.8.8", insecure: true)) {
            XCTAssertEqual($0 as? ServerAddress.NormalizationError, .insecureNotAllowed)
        }
    }

    func testLocalHosts() {
        for host in ["localhost", "LOCALHOST", "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.10", "169.254.1.1", "nas.local", "::1", "[::1]", "fd12:3456::1"] {
            XCTAssertTrue(ServerAddress.isLocalHost(host), host)
        }
        for host in ["example.com", "172.32.0.1", "172.15.0.1", "8.8.8.8", "192.169.0.1", "localhost.example.com", "fcbank.com", "1.2.3"] {
            XCTAssertFalse(ServerAddress.isLocalHost(host), host)
        }
    }
}

final class ServerCompatibilityTests: XCTestCase {
    func testMinimumIsCurrentESR() {
        XCTAssertEqual(ServerCompatibility.minimumVersion, ServerVersion(major: 11, minor: 7))
    }

    func testSupportedVersions() {
        XCTAssertEqual(ServerCompatibility.check(version: "11.7.14"), .supported(ServerVersion(major: 11, minor: 7, patch: 14)))
        XCTAssertEqual(ServerCompatibility.check(version: "11.7.0"), .supported(ServerVersion(major: 11, minor: 7)))
        XCTAssertEqual(ServerCompatibility.check(version: "11.10.1"), .supported(ServerVersion(major: 11, minor: 10, patch: 1)))
        XCTAssertEqual(ServerCompatibility.check(version: "12.0.0-rc1"), .supported(ServerVersion(major: 12)))
    }

    func testTooOldVersions() {
        let minimum = ServerCompatibility.minimumVersion
        XCTAssertEqual(ServerCompatibility.check(version: "11.6.9"), .tooOld(ServerVersion(major: 11, minor: 6, patch: 9), minimum: minimum))
        XCTAssertEqual(ServerCompatibility.check(version: "10.11.3"), .tooOld(ServerVersion(major: 10, minor: 11, patch: 3), minimum: minimum))
        XCTAssertEqual(ServerCompatibility.check(version: "9.11.1"), .tooOld(ServerVersion(major: 9, minor: 11, patch: 1), minimum: minimum))
    }

    func testCustomMinimum() {
        let minimum = ServerVersion(major: 10, minor: 11)
        XCTAssertEqual(ServerCompatibility.check(version: "10.11.0", minimum: minimum), .supported(ServerVersion(major: 10, minor: 11)))
        XCTAssertEqual(ServerCompatibility.check(version: "10.5.2", minimum: minimum), .tooOld(ServerVersion(major: 10, minor: 5, patch: 2), minimum: minimum))
    }

    func testUnknownVersion() {
        XCTAssertEqual(ServerCompatibility.check(version: nil), .unknown)
        XCTAssertEqual(ServerCompatibility.check(version: ""), .unknown)
        XCTAssertEqual(ServerCompatibility.check(version: "dev"), .unknown)
    }
}

final class UnauthorizedHookTests: StubbedClientTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeHookedClient(token: String?, counter: Counter) -> MattermostClient {
        return MattermostClient(
            configuration: .init(serverURL: self.serverURL, onUnauthorized: { counter.increment() }),
            token: token,
            session: StubURLProtocol.makeSession()
        )
    }

    func testCalledFor401WithToken() async {
        StubURLProtocol.respond(with: .json(#"{"id":"api.context.session_expired.app_error","message":"Invalid or expired session, please login again.","status_code":401}"#, status: 401))
        let counter = Counter()
        let client = makeHookedClient(token: "expired", counter: counter)
        let error = await expectMattermostError { try await client.me() }
        XCTAssertTrue(error?.isSessionExpired == true)
        XCTAssertEqual(counter.current, 1)
    }

    func testNotCalledForLoginFailure() async {
        StubURLProtocol.respond(with: .json(Fixtures.appError, status: 401))
        let counter = Counter()
        let client = makeHookedClient(token: "previous", counter: counter)
        _ = await expectMattermostError { try await client.login(loginId: "alice", password: "wrong") }
        XCTAssertEqual(counter.current, 0)
    }

    func testNotCalledForOtherErrors() async {
        StubURLProtocol.respond(with: .json(Fixtures.appError, status: 403))
        let counter = Counter()
        let client = makeHookedClient(token: "t", counter: counter)
        _ = await expectMattermostError { try await client.me() }
        XCTAssertEqual(counter.current, 0)
    }
}

/// Phase 4B: `onServerReached` tells the sync that the server answers (its WebSocket can stop waiting out a backoff).
final class ServerReachedHookTests: StubbedClientTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeHookedClient(counter: Counter) -> MattermostClient {
        var configuration = MattermostClient.Configuration(serverURL: self.serverURL)
        configuration.onServerReached = { counter.increment() }
        return MattermostClient(configuration: configuration, token: "t", session: StubURLProtocol.makeSession())
    }

    func testCalledForAnswers() async {
        StubURLProtocol.respond(with: .json(Fixtures.appError, status: 403))
        let counter = Counter()
        let client = makeHookedClient(counter: counter)
        _ = await expectMattermostError { try await client.me() }
        XCTAssertEqual(counter.current, 1)
    }

    func testNotCalledWhenUnreachable() async {
        StubURLProtocol.respond(with: .failure(.cannotConnectToHost))
        let counter = Counter()
        let client = makeHookedClient(counter: counter)
        _ = await expectMattermostError { try await client.me() }
        XCTAssertEqual(counter.current, 0)
    }
}
