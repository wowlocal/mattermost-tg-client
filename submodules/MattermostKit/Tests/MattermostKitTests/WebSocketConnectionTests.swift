import XCTest
@testable import MattermostKit

final class WebSocketConnectionTests: XCTestCase {
    private var transport: FakeWebSocketTransport!
    private var clock: ManualClock!
    private var sockets: [MattermostWebSocket] = []

    override func setUp() {
        super.setUp()
        transport = FakeWebSocketTransport()
        clock = ManualClock()
    }

    override func tearDown() async throws {
        for socket in sockets {
            await socket.disconnect()
        }
        sockets = []
        try await super.tearDown()
    }

    /// With `random` fixed at 0.5 and the default policy (1 s, ×2, jitter 0.5),
    /// retry n waits `0.75 * 2^(n-1)` seconds.
    private func makeSocket(
        serverURL: String = "https://chat.example.com",
        token: String? = "tok3n",
        configuration: MattermostWebSocket.Configuration = .init(pingInterval: nil, handshakeTimeout: nil),
        tokenVerifier: (@Sendable () async -> Bool)? = nil
    ) -> MattermostWebSocket {
        let socket = MattermostWebSocket(
            serverURL: URL(string: serverURL)!,
            token: token,
            configuration: configuration,
            transport: transport,
            clock: clock,
            random: { 0.5 },
            tokenVerifier: tokenVerifier
        )
        sockets.append(socket)
        return socket
    }

    private func connection(_ index: Int, file: StaticString = #filePath, line: UInt = #line) async throws -> FakeWebSocketConnection {
        await waitUntil(file: file, line: line) { self.transport.connections.count > index }
        return try XCTUnwrap(transport.connections.dropFirst(index).first, file: file, line: line)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }

    private func assertState(_ socket: MattermostWebSocket, _ expected: WebSocketConnectionState, file: StaticString = #filePath, line: UInt = #line) async {
        let state = await socket.state
        XCTAssertEqual(state, expected, file: file, line: line)
    }

    private func assertState(_ socket: MattermostWebSocket, connected expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let connected = await socket.isConnected
        XCTAssertEqual(connected, expected, file: file, line: line)
    }

    private func waitForState(_ socket: MattermostWebSocket, _ expected: WebSocketConnectionState, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(file: file, line: line) { await socket.state == expected }
    }

    private func waitForSleepers(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(file: file, line: line) { self.clock.pendingSleepers.count == count }
    }

    // MARK: Connecting

    func testWebSocketURL() {
        XCTAssertEqual(MattermostWebSocket.webSocketURL(serverURL: URL(string: "https://chat.example.com")!)?.absoluteString, "wss://chat.example.com/api/v4/websocket")
        XCTAssertEqual(MattermostWebSocket.webSocketURL(serverURL: URL(string: "http://localhost:8065/")!)?.absoluteString, "ws://localhost:8065/api/v4/websocket")
        XCTAssertEqual(MattermostWebSocket.webSocketURL(serverURL: URL(string: "https://example.com/mm/")!)?.absoluteString, "wss://example.com/mm/api/v4/websocket")
        XCTAssertNil(MattermostWebSocket.webSocketURL(serverURL: URL(string: "ftp://example.com")!))
    }

    func testConnectSendsBearerToken() async throws {
        let socket = makeSocket(serverURL: "https://example.com/mm", configuration: .init(pingInterval: nil, handshakeTimeout: nil, userAgent: "Tests/1"))
        await socket.connect()
        let connection = try await connection(0)
        XCTAssertEqual(connection.request.url?.absoluteString, "wss://example.com/mm/api/v4/websocket")
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok3n")
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "User-Agent"), "Tests/1")
        await assertState(socket, .connecting(attempt: 1))
        // Every connection starts with the handshake probe.
        await waitUntil { connection.sentTexts.count == 1 }
        XCTAssertEqual(connection.sentActions, [["action": "ping", "seq": 1, "data": [:]]])
    }

    func testAuthenticationChallenge() async throws {
        let socket = makeSocket(configuration: .init(authentication: .challenge, pingInterval: nil, handshakeTimeout: nil))
        await socket.connect()
        let connection = try await connection(0)
        XCTAssertNil(connection.request.value(forHTTPHeaderField: "Authorization"))
        await waitUntil { connection.sentTexts.count == 2 }
        XCTAssertEqual(connection.sentActions, [
            ["action": "authentication_challenge", "seq": 1, "data": ["token": "tok3n"]],
            ["action": "ping", "seq": 2, "data": [:]],
        ])
    }

    func testHelloConnectsAndEventsAreStreamed() async throws {
        let socket = makeSocket()
        let events = StreamRecorder(socket.events())
        let states = StreamRecorder(socket.connectionStates())
        await socket.connect()
        let connection = try await connection(0)
        connection.push(Fixtures.hello(connectionId: "abc"))
        connection.push(Fixtures.posted)
        connection.push("garbage that is ignored")
        connection.push(Fixtures.typing(seq: 2))

        await waitUntil { events.values.count == 3 }
        XCTAssertEqual(events.values.map(\.type), [.hello, .posted, .typing])
        XCTAssertEqual(events.values[1].posted?.post.message, "hello @alice")

        let expected = WebSocketConnectionState.connected(WebSocketConnectionInfo(connectionId: "abc", serverVersion: "9.11.1.10234567.f4b4f3a6b0b84d7e.true", resumed: false))
        await assertState(socket, expected)
        await assertState(socket, connected: true)
        await waitUntil { states.values.last == expected }
        XCTAssertEqual(states.values, [.disconnected, .connecting(attempt: 1), expected])
    }

    func testMultipleSubscribers() async throws {
        let socket = makeSocket()
        let first = StreamRecorder(socket.events())
        let second = StreamRecorder(socket.events())
        await socket.connect()
        try await connection(0).push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { first.values.count == 1 && second.values.count == 1 }
    }

    // MARK: Reconnect, backoff, resume

    func testReconnectWithBackoffAndResume() async throws {
        let socket = makeSocket()
        let events = StreamRecorder(socket.events())
        await socket.connect()

        let first = try await connection(0)
        XCTAssertNil(first.request.url?.query)
        first.push(Fixtures.hello(connectionId: "abc", seq: 0))
        first.push(Fixtures.typing(seq: 1))
        await waitUntil { events.values.count == 2 }

        // Drop the connection: first retry after 0.75 s.
        first.fail()
        await waitForSleepers(1)
        XCTAssertEqual(clock.requestedSleeps, [0.75])
        await assertState(socket, .waitingToReconnect(attempt: 2, delay: 0.75))
        XCTAssertTrue(first.isClosed)

        // Two failed attempts double the delay each time.
        transport.enqueue(.fail(URLError(.cannotConnectToHost)), .fail(URLError(.timedOut)))
        clock.advance(by: 0.75)
        await waitUntil { self.clock.requestedSleeps.count == 2 }
        XCTAssertEqual(clock.requestedSleeps, [0.75, 1.5])
        await assertState(socket, .waitingToReconnect(attempt: 3, delay: 1.5))
        clock.advance(by: 1.5)
        await waitUntil { self.clock.requestedSleeps.count == 3 }
        XCTAssertEqual(clock.requestedSleeps, [0.75, 1.5, 3.0])
        clock.advance(by: 3.0)

        // Every reconnect asks the server to resume after the last seen event,
        // and probes with a ping to detect a resume without hello.
        let second = try await connection(1)
        await waitUntil { second.sentTexts.count == 1 }
        XCTAssertEqual(second.sentActions.first?["action"], "ping")
        XCTAssertEqual(transport.requests.count, 4)
        for request in transport.requests.dropFirst() {
            XCTAssertEqual(query(request), ["connection_id": "abc", "sequence_number": "2"])
        }

        // Same connection ID in hello: resumed, no catch-up needed.
        second.push(Fixtures.hello(connectionId: "abc", seq: 2))
        second.push(Fixtures.typing(seq: 3))
        await waitUntil { events.values.count == 4 }
        await assertState(socket, .connected(WebSocketConnectionInfo(connectionId: "abc", serverVersion: "9.11.1.10234567.f4b4f3a6b0b84d7e.true", resumed: true)))

        // A successful connection resets the backoff.
        second.fail()
        await waitForSleepers(1)
        XCTAssertEqual(clock.requestedSleeps.last, 0.75)
        clock.advance(by: 0.75)
        let third = try await connection(2)
        XCTAssertEqual(query(third.request), ["connection_id": "abc", "sequence_number": "4"])

        // A different connection ID means the server could not resume.
        third.push(Fixtures.hello(connectionId: "xyz", seq: 0))
        await waitUntil {
            if case .connected(let info) = await socket.state { return info.connectionId == "xyz" }
            return false
        }
        guard case .connected(let info) = await socket.state else { return XCTFail("Not connected") }
        XCTAssertFalse(info.resumed)

        third.push(Fixtures.typing(seq: 1))
        await waitUntil { events.values.count == 6 }
    }

    func testResumeWithoutHelloIsDetectedByProbeReply() async throws {
        let socket = makeSocket()
        let events = StreamRecorder(socket.events())
        await socket.connect()
        let first = try await connection(0)
        first.push(Fixtures.hello(connectionId: "abc"))
        first.push(Fixtures.typing(seq: 1))
        await waitUntil { events.values.count == 2 }
        first.fail()
        await waitForSleepers(1)
        clock.advance(by: 0.75)

        let second = try await connection(1)
        XCTAssertEqual(query(second.request), ["connection_id": "abc", "sequence_number": "2"])
        await waitUntil { second.sentTexts.count == 1 }
        let probe = try XCTUnwrap(second.sentActions.first)
        XCTAssertEqual(probe["action"], "ping")
        let probeSeq = try XCTUnwrap(probe["seq"]?.int64Value)

        // Replayed events arrive before the probe reply; duplicates are dropped.
        second.push(Fixtures.typing(seq: 1))
        second.push(Fixtures.typing(seq: 2))
        second.push(#"{"status":"OK","seq_reply":\#(probeSeq),"data":{"text":"pong"}}"#)
        await waitForState(socket, .connected(WebSocketConnectionInfo(
            connectionId: "abc",
            serverVersion: "9.11.1.10234567.f4b4f3a6b0b84d7e.true",
            resumed: true
        )))
        XCTAssertEqual(events.values.compactMap(\.seq), [0, 1, 2])

        // The connection is usable, and later events continue the sequence.
        try await socket.userTyping(channelId: "c1")
        second.push(Fixtures.typing(seq: 3))
        await waitUntil { events.values.count == 4 }
    }

    func testResumeRejectedWhenHelloHasNewConnectionId() async throws {
        let socket = makeSocket()
        await socket.connect()
        let first = try await connection(0)
        first.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }
        first.fail()
        await waitForSleepers(1)
        clock.advance(by: 0.75)

        let second = try await connection(1)
        await waitUntil { second.sentTexts.count == 1 }
        let probeSeq = try XCTUnwrap(second.sentActions.first?["seq"]?.int64Value)
        // The server could not resume: hello with a new ID comes first.
        second.push(Fixtures.hello(connectionId: "xyz", seq: 0))
        second.push(#"{"status":"OK","seq_reply":\#(probeSeq)}"#)
        let expected = WebSocketConnectionState.connected(WebSocketConnectionInfo(
            connectionId: "xyz",
            serverVersion: "9.11.1.10234567.f4b4f3a6b0b84d7e.true",
            resumed: false
        ))
        await waitForState(socket, expected)
        second.push(Fixtures.typing(seq: 1))
        try await Task.sleep(nanoseconds: 20_000_000)
        await assertState(socket, expected)
    }

    func testHandshakeTimeoutDropsSilentConnection() async throws {
        let socket = makeSocket(configuration: .init(pingInterval: nil, handshakeTimeout: 15))
        await socket.connect()
        let first = try await connection(0)
        await waitForSleepers(1)
        XCTAssertEqual(clock.pendingSleepers, [15])
        clock.advance(by: 15)
        await waitUntil { first.isClosed }
        await waitForState(socket, .waitingToReconnect(attempt: 2, delay: 0.75))

        // A connection that says hello in time cancels the timer.
        clock.advance(by: 0.75)
        let second = try await connection(1)
        await waitForSleepers(1)
        second.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }
        await waitForSleepers(0)
        XCTAssertFalse(second.isClosed)
    }

    func testNotAuthenticatedProbeReplyStops() async throws {
        let socket = makeSocket(token: "bad")
        await socket.connect()
        let connection = try await connection(0)
        await waitUntil { connection.sentTexts.count == 1 }
        connection.push(#"{"status":"FAIL","seq_reply":1,"error":{"id":"api.web_socket_router.not_authenticated.app_error","status_code":401}}"#)
        await waitForState(socket, .unauthorized)
        XCTAssertTrue(connection.isClosed)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testTokenVerifierStopsSilentConnection() async throws {
        let calls = Locked(0)
        let socket = makeSocket(
            token: "revoked",
            configuration: .init(pingInterval: nil, handshakeTimeout: 15),
            tokenVerifier: {
                calls.withLock { $0 += 1 }
                return false
            }
        )
        await socket.connect()
        let connection = try await connection(0)
        // The server accepted the upgrade but never says hello.
        await waitForSleepers(1)
        clock.advance(by: 15)
        await waitForState(socket, .unauthorized)
        XCTAssertTrue(connection.isClosed)
        XCTAssertEqual(calls.current, 1)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(clock.pendingSleepers.isEmpty)
    }

    func testTokenVerifierAcceptingKeepsRetrying() async throws {
        let calls = Locked(0)
        transport.enqueue(.fail(URLError(.cannotConnectToHost)))
        let socket = makeSocket(
            configuration: .init(pingInterval: nil, handshakeTimeout: 15),
            tokenVerifier: {
                calls.withLock { $0 += 1 }
                return true
            }
        )
        await socket.connect()
        // A connect failure is a network problem: the verifier is not asked.
        await waitForState(socket, .waitingToReconnect(attempt: 2, delay: 0.75))
        XCTAssertEqual(calls.current, 0)
        clock.advance(by: 0.75)

        let connection = try await connection(0)
        await waitForSleepers(1)
        clock.advance(by: 15)
        await waitUntil { connection.isClosed }
        await waitForState(socket, .waitingToReconnect(attempt: 3, delay: 1.5))
        XCTAssertEqual(calls.current, 1)
    }

    func testSequenceGapForcesResumeReconnect() async throws {
        let socket = makeSocket()
        let events = StreamRecorder(socket.events())
        await socket.connect()
        let first = try await connection(0)
        first.push(Fixtures.hello(connectionId: "abc"))
        first.push(Fixtures.typing(seq: 1))
        first.push(Fixtures.typing(seq: 3))

        await waitUntil { first.isClosed }
        await waitForSleepers(1)
        // The out-of-order event is not delivered; the server replays it.
        XCTAssertEqual(events.values.compactMap(\.seq), [0, 1])
        clock.advance(by: 0.75)
        let second = try await connection(1)
        XCTAssertEqual(query(second.request), ["connection_id": "abc", "sequence_number": "2"])
    }

    func testReplayedDuplicatesAreDropped() async throws {
        let socket = makeSocket()
        let events = StreamRecorder(socket.events())
        await socket.connect()
        let connection = try await connection(0)
        connection.push(Fixtures.hello(connectionId: "abc"))
        connection.push(Fixtures.typing(seq: 1))
        connection.push(Fixtures.typing(seq: 1))
        connection.push(Fixtures.typing(seq: 2))
        await waitUntil { events.values.count == 3 }
        XCTAssertEqual(events.values.compactMap(\.seq), [0, 1, 2])
        XCTAssertFalse(connection.isClosed)
    }

    func testUnauthorizedHandshakeStopsReconnecting() async throws {
        transport.enqueue(.fail(WebSocketTransportError.handshakeFailed(statusCode: 401)))
        let socket = makeSocket(token: "expired")
        await socket.connect()
        await waitForState(socket, .unauthorized)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(clock.pendingSleepers.isEmpty)

        await socket.setToken("fresh")
        await socket.connect()
        let connection = try await connection(0)
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testOtherHandshakeFailuresRetry() async throws {
        transport.enqueue(.fail(WebSocketTransportError.handshakeFailed(statusCode: 502)))
        let socket = makeSocket()
        await socket.connect()
        await waitForState(socket, .waitingToReconnect(attempt: 2, delay: 0.75))
    }

    func testDisconnectStopsAndKeepsResumeState() async throws {
        let socket = makeSocket()
        await socket.connect()
        let first = try await connection(0)
        first.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }

        await socket.disconnect()
        await assertState(socket, .disconnected)
        XCTAssertTrue(first.isClosed)
        XCTAssertTrue(clock.pendingSleepers.isEmpty)
        do {
            try await socket.userTyping(channelId: "c1")
            XCTFail("Expected notConnected")
        } catch {
            XCTAssertEqual(error as? MattermostWebSocketError, .notConnected)
        }

        await socket.connect()
        let second = try await connection(1)
        XCTAssertEqual(query(second.request), ["connection_id": "abc", "sequence_number": "1"])

        await socket.resetResumeState()
        await socket.reconnectNow()
        let third = try await connection(2)
        XCTAssertNil(third.request.url?.query)
    }

    func testReconnectNowSkipsBackoff() async throws {
        let socket = makeSocket()
        await socket.connect()
        let first = try await connection(0)
        first.push(Fixtures.hello(connectionId: "abc"))
        first.fail()
        await waitForSleepers(1)

        await socket.reconnectNow()
        let second = try await connection(1)
        XCTAssertEqual(query(second.request), ["connection_id": "abc", "sequence_number": "1"])
        await waitForSleepers(0)
        await assertState(socket, .connecting(attempt: 1))
    }

    // MARK: Actions

    func testUserTyping() async throws {
        let socket = makeSocket()
        await socket.connect()
        let connection = try await connection(0)
        do {
            try await socket.userTyping(channelId: "c1")
            XCTFail("Expected notConnected before hello")
        } catch {
            XCTAssertEqual(error as? MattermostWebSocketError, .notConnected)
        }

        connection.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }
        try await socket.userTyping(channelId: "c1", parentId: "root1")
        try await socket.userTyping(channelId: "c2")
        XCTAssertEqual(Array(connection.sentActions.dropFirst()), [
            ["action": "user_typing", "seq": 2, "data": ["channel_id": "c1", "parent_id": "root1"]],
            ["action": "user_typing", "seq": 3, "data": ["channel_id": "c2", "parent_id": ""]],
        ])
    }

    func testSendActionAwaitsReply() async throws {
        let socket = makeSocket()
        await socket.connect()
        let connection = try await connection(0)
        connection.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }

        let ok = Task { try await socket.sendAction("get_statuses") }
        await waitUntil { connection.sentTexts.count == 2 }
        XCTAssertEqual(connection.sentActions[1], ["action": "get_statuses", "seq": 2, "data": [:]])
        connection.push(#"{"status":"OK","seq_reply":2,"data":{"u1":"online"}}"#)
        let response = try await ok.value
        XCTAssertEqual(response.data["u1"], "online")

        let failing = Task { try await socket.sendAction("bogus") }
        await waitUntil { connection.sentTexts.count == 3 }
        connection.push(#"{"status":"FAIL","seq_reply":3,"error":{"id":"api.web_socket_router.bad_action.app_error","message":"Invalid action."}}"#)
        do {
            _ = try await failing.value
            XCTFail("Expected actionFailed")
        } catch let MattermostWebSocketError.actionFailed(response) {
            XCTAssertEqual(response.error?.id, "api.web_socket_router.bad_action.app_error")
        }
    }

    func testActionTimesOut() async throws {
        let socket = makeSocket(configuration: .init(pingInterval: nil, actionTimeout: 10, handshakeTimeout: nil))
        await socket.connect()
        let connection = try await connection(0)
        connection.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }

        let task = Task { try await socket.sendAction("get_statuses") }
        await waitForSleepers(1)
        clock.advance(by: 10)
        do {
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? MattermostWebSocketError, .timeout)
        }
    }

    func testPendingActionFailsWhenConnectionDrops() async throws {
        let socket = makeSocket()
        await socket.connect()
        let connection = try await connection(0)
        connection.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }

        let task = Task { try await socket.sendAction("get_statuses") }
        await waitUntil { connection.sentTexts.count == 2 }
        connection.fail()
        do {
            _ = try await task.value
            XCTFail("Expected connectionClosed")
        } catch {
            XCTAssertEqual(error as? MattermostWebSocketError, .connectionClosed)
        }
    }

    func testPingKeepsConnectionAliveAndTimeoutReconnects() async throws {
        let socket = makeSocket(configuration: .init(pingInterval: 30, actionTimeout: 5, handshakeTimeout: nil))
        await socket.connect()
        let first = try await connection(0)
        first.push(Fixtures.hello(connectionId: "abc"))
        await waitUntil { await socket.isConnected }

        // First ping is answered.
        await waitForSleepers(1)
        XCTAssertEqual(clock.pendingSleepers, [30])
        clock.advance(by: 30)
        await waitUntil { first.sentTexts.count == 2 }
        XCTAssertEqual(first.sentActions[1]["action"], "ping")
        let seq = try XCTUnwrap(first.sentActions[1]["seq"]?.int64Value)
        first.push(#"{"status":"OK","seq_reply":\#(seq),"data":{"text":"pong","server_time":1700000000000}}"#)
        await waitUntil { self.clock.pendingSleepers == [30] }
        XCTAssertFalse(first.isClosed)

        // Second ping gets no reply: the connection is treated as dead.
        clock.advance(by: 30)
        await waitUntil { first.sentTexts.count == 3 }
        await waitUntil { self.clock.pendingSleepers == [5] }
        clock.advance(by: 5)
        await waitUntil { first.isClosed }
        await waitForState(socket, .waitingToReconnect(attempt: 2, delay: 0.75))
        clock.advance(by: 0.75)
        let second = try await connection(1)
        XCTAssertEqual(query(second.request)["connection_id"], "abc")
    }

    func testFailedPingReplyStillCountsAsAlive() async throws {
        let socket = makeSocket(configuration: .init(pingInterval: 30, actionTimeout: 5, handshakeTimeout: nil))
        await socket.connect()
        let connection = try await connection(0)
        connection.push(Fixtures.hello(connectionId: "abc"))
        await waitForSleepers(1)
        clock.advance(by: 30)
        await waitUntil { connection.sentTexts.count == 2 }
        connection.push(#"{"status":"FAIL","seq_reply":2,"error":{"id":"unknown"}}"#)
        await waitUntil { self.clock.pendingSleepers == [30] }
        XCTAssertFalse(connection.isClosed)
        await assertState(socket, connected: true)
    }

    // MARK: Backoff policy

    func testBackoffPolicy() {
        let policy = BackoffPolicy(initialDelay: 1, multiplier: 2, maximumDelay: 60, jitter: 0.5)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0), 0.5)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 1), 1.0)
        XCTAssertEqual(policy.delay(forAttempt: 3, random: 0.5), 3.0)
        XCTAssertEqual(policy.delay(forAttempt: 20, random: 1), 60)
        XCTAssertEqual(policy.delay(forAttempt: 2000, random: 0), 30)
        XCTAssertEqual(policy.delay(forAttempt: 0, random: 1), 1)

        let noJitter = BackoffPolicy(initialDelay: 2, multiplier: 3, maximumDelay: 100, jitter: 0)
        XCTAssertEqual(noJitter.delay(forAttempt: 3, random: 0.9), 18)
    }
}
