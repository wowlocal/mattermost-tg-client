import Foundation

public struct WebSocketConnectionInfo: Sendable, Equatable {
    public var connectionId: String
    /// From the `hello` event, e.g. `"11.7.14.39757492507.abcdef.false"`. On a
    /// resumed connection, the value from the last `hello`.
    public var serverVersion: String?
    /// True when the server resumed the previous connection, so it replays the
    /// events missed in between. When false after a reconnect, the sync layer
    /// must run catch-up.
    ///
    /// Mattermost (verified on 11.7) sends no `hello` on a resumed connection;
    /// it only sends `hello` for a new connection, with a new connection ID. The
    /// client therefore sends a `ping` action right after connecting (the
    /// handshake probe): a reply without a preceding `hello` means "resumed". A
    /// `hello` with the previous connection ID is also treated as resumed.
    public var resumed: Bool

    public init(connectionId: String, serverVersion: String? = nil, resumed: Bool) {
        self.connectionId = connectionId
        self.serverVersion = serverVersion
        self.resumed = resumed
    }
}

public enum WebSocketConnectionState: Sendable, Equatable {
    /// Not connected and not trying (initial state, or after `disconnect()`).
    case disconnected
    /// Opening a connection. `attempt` is 1 for the first try after a
    /// successful connection or `connect()`, and counts up while retrying.
    case connecting(attempt: Int)
    /// The server sent `hello`, or accepted the resumed connection.
    case connected(WebSocketConnectionInfo)
    /// Waiting `delay` seconds before connection attempt number `attempt`.
    case waitingToReconnect(attempt: Int, delay: TimeInterval)
    /// The server rejected the token. Reconnecting stops until `connect()` is
    /// called again, normally after a new login.
    ///
    /// Mattermost (verified on 11.7) accepts the upgrade even with an invalid
    /// token, then stays silent: no `hello`, no replies. So besides an HTTP 401
    /// on upgrade (e.g. from a proxy), this state is only reached when the
    /// `tokenVerifier` confirms the token is invalid after a connection failed
    /// to complete its handshake. `MattermostClient.makeWebSocket()` sets one up.
    case unauthorized
}

public enum MattermostWebSocketError: Error, Sendable, Equatable {
    /// Not connected (or the connection handshake has not finished yet).
    case notConnected
    /// The connection closed before the server replied.
    case connectionClosed
    /// The server did not reply in time.
    case timeout
    /// The server replied with a non-OK status.
    case actionFailed(WebSocketResponse)
}

/// Mattermost WebSocket client: connects, authenticates, parses events,
/// reconnects with exponential backoff and jitter, and resumes the previous
/// connection when the server still has it.
///
/// Call `disconnect()` when done; while running, the reconnect loop keeps the
/// instance alive.
public actor MattermostWebSocket {
    public struct Configuration: Sendable {
        public enum Authentication: Sendable, Equatable {
            /// `Authorization: Bearer` on the upgrade request.
            case header
            /// An `authentication_challenge` action after connecting. Note: the
            /// server only resumes connections authenticated on upgrade.
            case challenge
            /// Both.
            case headerAndChallenge
        }

        public var authentication: Authentication
        public var backoff: BackoffPolicy
        /// Interval for `ping` actions that detect dead connections; nil disables.
        public var pingInterval: TimeInterval?
        /// How long to wait for an action reply (including pings).
        public var actionTimeout: TimeInterval
        /// How long a new connection may take to complete its handshake
        /// (`hello`, or the reply to the handshake probe) before it is dropped
        /// and retried; nil waits forever.
        public var handshakeTimeout: TimeInterval?
        /// Send `connection_id` and `sequence_number` when reconnecting.
        public var resumesConnections: Bool
        public var userAgent: String?

        public init(
            authentication: Authentication = .header,
            backoff: BackoffPolicy = BackoffPolicy(),
            pingInterval: TimeInterval? = 30,
            actionTimeout: TimeInterval = 10,
            handshakeTimeout: TimeInterval? = 15,
            resumesConnections: Bool = true,
            userAgent: String? = nil
        ) {
            self.authentication = authentication
            self.backoff = backoff
            self.pingInterval = pingInterval
            self.actionTimeout = actionTimeout
            self.handshakeTimeout = handshakeTimeout
            self.resumesConnections = resumesConnections
            self.userAgent = userAgent
        }
    }

    public nonisolated let serverURL: URL
    public nonisolated let configuration: Configuration
    private let transport: any WebSocketTransport
    private let clock: any WebSocketClock
    private let random: @Sendable () -> Double
    private let tokenVerifier: (@Sendable () async -> Bool)?
    private var token: String?

    private nonisolated let eventBroadcaster = StreamBroadcaster<WebSocketEvent>(replaysLatest: false)
    private nonisolated let stateBroadcaster = StreamBroadcaster<WebSocketConnectionState>(replaysLatest: true, initial: .disconnected)

    public private(set) var state: WebSocketConnectionState = .disconnected
    private var runTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var connection: (any WebSocketConnection)?
    /// Set once the current connection got `hello` or the probe reply.
    private var handshakeComplete = false
    /// Whether the current connection asked the server to resume.
    private var isResumeAttempt = false
    /// Sequence number of the `ping` sent right after connecting, used to
    /// detect resumed and unauthenticated connections.
    private var handshakeProbeSequence: Int64?
    private var consecutiveFailures = 0

    /// Resume state: the server's connection ID, the next event sequence
    /// number we expect, and the server version from the last `hello`.
    private var connectionId: String?
    private var nextSequence: Int64 = 0
    private var serverVersion: String?

    private var nextActionSequence: Int64 = 1
    private var pendingReplies: [Int64: OneShot<WebSocketResponse>] = [:]

    /// - Parameters:
    ///   - serverURL: The server's site URL (`https://…`); the WebSocket URL is
    ///     derived from it.
    ///   - transport: Inject a fake in tests.
    ///   - clock: Used for backoff, pings and timeouts. Inject in tests.
    ///   - random: Jitter source returning values in `0..<1`. Inject in tests.
    ///   - tokenVerifier: Called when a connection opened but never completed
    ///     its handshake, which is how Mattermost treats an invalid token.
    ///     Return false only if the token is definitely rejected (e.g. a REST
    ///     call answered 401); the socket then stops in `.unauthorized`.
    public init(
        serverURL: URL,
        token: String?,
        configuration: Configuration = Configuration(),
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        clock: any WebSocketClock = SystemWebSocketClock(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        tokenVerifier: (@Sendable () async -> Bool)? = nil
    ) {
        self.serverURL = serverURL
        self.token = token
        self.configuration = configuration
        self.transport = transport
        self.clock = clock
        self.random = random
        self.tokenVerifier = tokenVerifier
    }

    deinit {
        eventBroadcaster.finish()
        stateBroadcaster.finish()
    }

    // MARK: - Streams

    /// A new stream of server events. Any number of subscribers is supported;
    /// each receives events from the time it subscribes.
    public nonisolated func events() -> AsyncStream<WebSocketEvent> {
        eventBroadcaster.makeStream()
    }

    /// A new stream of connection states, starting with the current state.
    public nonisolated func connectionStates() -> AsyncStream<WebSocketConnectionState> {
        stateBroadcaster.makeStream()
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Control

    /// The token for the next connection attempt.
    public func setToken(_ token: String?) {
        self.token = token
    }

    /// Starts connecting; afterwards reconnects automatically until
    /// `disconnect()`. No-op while already running.
    public func connect() {
        guard runTask == nil else { return }
        consecutiveFailures = 0
        startRunLoop()
    }

    /// Closes the connection and stops reconnecting. Resume state is kept, so a
    /// later `connect()` asks the server to resume.
    public func disconnect() {
        runTask?.cancel()
        runTask = nil
        tearDownConnection()
        setState(.disconnected)
    }

    /// Drops the current connection or pending backoff and connects again now,
    /// e.g. when the app returns to the foreground or the network changes.
    public func reconnectNow() {
        runTask?.cancel()
        runTask = nil
        tearDownConnection()
        consecutiveFailures = 0
        startRunLoop()
    }

    /// Forgets the connection ID and sequence number, so the next connection
    /// starts fresh (reported as not resumed).
    public func resetResumeState() {
        connectionId = nil
        nextSequence = 0
        serverVersion = nil
    }

    // MARK: - Actions

    /// Sends an action and waits for its `seq_reply`.
    /// - Throws: `MattermostWebSocketError`.
    @discardableResult
    public func sendAction(_ action: String, data: [String: JSONValue] = [:]) async throws -> WebSocketResponse {
        try await sendAction(action, data: data, timeout: configuration.actionTimeout)
    }

    /// Sends a `user_typing` action without waiting for the reply. Callers
    /// should throttle (the official clients send at most one every few seconds).
    public func userTyping(channelId: String, parentId: String? = nil) async throws {
        guard let connection, handshakeComplete else {
            throw MattermostWebSocketError.notConnected
        }
        let data: [String: JSONValue] = [
            "channel_id": .string(channelId),
            "parent_id": .string(parentId ?? ""),
        ]
        let text = Self.encodeAction("user_typing", sequence: takeActionSequence(), data: data)
        do {
            try await connection.send(text)
        } catch {
            throw MattermostWebSocketError.connectionClosed
        }
    }

    /// Sends a `ping` action; the reply's data includes `server_time`.
    @discardableResult
    public func ping() async throws -> WebSocketResponse {
        try await sendAction("ping")
    }

    /// Sends a `ping` action that fails after `timeout`, e.g. a quick check that the connection survived while
    /// the app was suspended.
    @discardableResult
    public func ping(timeout: TimeInterval) async throws -> WebSocketResponse {
        try await sendAction("ping", data: [:], timeout: timeout)
    }

    // MARK: - URL

    /// `ws(s)://<host>/<subpath>/api/v4/websocket` for a server site URL.
    public static func webSocketURL(serverURL: URL) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws": components.scheme = "ws"
        default: return nil
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.percentEncodedPath = basePath + "/api/v4/websocket"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func makeRequest() throws -> URLRequest {
        guard let url = Self.webSocketURL(serverURL: serverURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        if configuration.resumesConnections, let connectionId {
            components.queryItems = [
                URLQueryItem(name: "connection_id", value: connectionId),
                URLQueryItem(name: "sequence_number", value: String(nextSequence)),
            ]
        }
        guard let requestURL = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: requestURL)
        if configuration.authentication != .challenge, let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let userAgent = configuration.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    // MARK: - Connection loop

    private struct SequenceGap: Error {}
    private struct NotAuthenticated: Error {}

    private func startRunLoop() {
        runTask = Task {
            await self.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            setState(.connecting(attempt: consecutiveFailures + 1))
            var unauthorized = false
            var openedWithoutHandshake = false
            do {
                let request = try makeRequest()
                let newConnection = try await transport.connect(request: request)
                if Task.isCancelled {
                    newConnection.close()
                    return
                }
                connection = newConnection
                handshakeComplete = false
                isResumeAttempt = configuration.resumesConnections && connectionId != nil
                handshakeProbeSequence = nil
                startHandshakeTimer(newConnection)
                if configuration.authentication != .header {
                    try await sendAuthenticationChallenge(on: newConnection)
                }
                try await sendHandshakeProbe(on: newConnection)
                do {
                    try await receiveLoop(newConnection)
                } catch {
                    openedWithoutHandshake = !handshakeComplete
                    throw error
                }
            } catch let error as WebSocketTransportError {
                if case .handshakeFailed(statusCode: 401) = error {
                    unauthorized = true
                }
            } catch is NotAuthenticated {
                unauthorized = true
            } catch {
                // Dropped or failed; retry below.
            }

            // A cancelled loop has been superseded by disconnect()/reconnectNow(),
            // which own the connection and state from here on.
            if Task.isCancelled { return }
            tearDownConnection()
            if !unauthorized, openedWithoutHandshake, let tokenVerifier {
                let accepted = await tokenVerifier()
                if Task.isCancelled { return }
                unauthorized = !accepted
            }
            if unauthorized {
                setState(.unauthorized)
                runTask = nil
                return
            }

            consecutiveFailures += 1
            let delay = configuration.backoff.delay(forAttempt: consecutiveFailures, random: random())
            setState(.waitingToReconnect(attempt: consecutiveFailures + 1, delay: delay))
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func receiveLoop(_ connection: any WebSocketConnection) async throws {
        while true {
            let frame = try await connection.receive()
            try Task.checkCancellation()
            guard connection === self.connection else { throw CancellationError() }
            let message: WebSocketMessage?
            switch frame {
            case .text(let text): message = WebSocketMessage(text: text)
            case .binary(let data): message = WebSocketMessage(data: data)
            }
            switch message {
            case .response(let response):
                if let probe = handshakeProbeSequence, response.seqReply == probe {
                    handshakeProbeSequence = nil
                    if !handshakeComplete {
                        if Self.isNotAuthenticated(response) {
                            throw NotAuthenticated()
                        }
                        if isResumeAttempt, let connectionId {
                            // A reply without a preceding hello: the server
                            // resumed the previous connection.
                            completeHandshake(
                                WebSocketConnectionInfo(connectionId: connectionId, serverVersion: serverVersion, resumed: true),
                                on: connection
                            )
                        }
                    }
                    continue
                }
                pendingReplies.removeValue(forKey: response.seqReply)?.resolve(.success(response))
            case .event(let event):
                try handle(event, on: connection)
            case nil:
                continue
            }
        }
    }

    private func handle(_ event: WebSocketEvent, on connection: any WebSocketConnection) throws {
        if event.type == .hello {
            let hello = event.hello
            let newConnectionId = hello?.connectionId
            let resumed = newConnectionId != nil && newConnectionId == connectionId
            if let newConnectionId {
                connectionId = newConnectionId
            }
            if let version = hello?.serverVersion {
                serverVersion = version
            }
            if let seq = event.seq {
                nextSequence = seq + 1
            } else if !resumed {
                nextSequence = 0
            }
            completeHandshake(
                WebSocketConnectionInfo(connectionId: newConnectionId ?? "", serverVersion: serverVersion, resumed: resumed),
                on: connection
            )
        } else if let seq = event.seq {
            // Events replayed on a resumed connection arrive before the probe
            // reply, so check them against the carried-over sequence too.
            if handshakeComplete || isResumeAttempt {
                if seq < nextSequence {
                    // Already delivered (replayed after a resume).
                    return
                }
                if seq > nextSequence {
                    // Missed events: reconnect so the server replays them, or
                    // reports a new connection and the sync layer catches up.
                    throw SequenceGap()
                }
            }
            nextSequence = seq + 1
        }
        eventBroadcaster.yield(event)
    }

    private func completeHandshake(_ info: WebSocketConnectionInfo, on connection: any WebSocketConnection) {
        handshakeComplete = true
        handshakeTask?.cancel()
        handshakeTask = nil
        consecutiveFailures = 0
        setState(.connected(info))
        startPinging(connection)
    }

    /// Sends a `ping` right after connecting. A new connection always queues
    /// `hello` before any reply, so a reply that arrives first means either a
    /// resumed connection (see `WebSocketConnectionInfo.resumed`) or, if it
    /// fails with `not_authenticated`, a rejected token.
    private func sendHandshakeProbe(on connection: any WebSocketConnection) async throws {
        let sequence = takeActionSequence()
        handshakeProbeSequence = sequence
        try await connection.send(Self.encodeAction("ping", sequence: sequence, data: [:]))
    }

    static func isNotAuthenticated(_ response: WebSocketResponse) -> Bool {
        guard !response.isOK else { return false }
        return response.error?.statusCode == 401
            || response.error?.id == "api.web_socket_router.not_authenticated.app_error"
    }

    private func startHandshakeTimer(_ connection: any WebSocketConnection) {
        handshakeTask?.cancel()
        handshakeTask = nil
        guard let timeout = configuration.handshakeTimeout, timeout > 0 else { return }
        handshakeTask = Task {
            await self.handshakeTimer(connection, timeout: timeout)
        }
    }

    private func handshakeTimer(_ connection: any WebSocketConnection, timeout: TimeInterval) async {
        do {
            try await clock.sleep(for: timeout)
        } catch {
            return
        }
        guard !Task.isCancelled, connection === self.connection, !handshakeComplete else { return }
        // Closing makes the receive loop fail, which triggers a reconnect.
        connection.close()
    }

    private func sendAuthenticationChallenge(on connection: any WebSocketConnection) async throws {
        guard let token, !token.isEmpty else { return }
        let text = Self.encodeAction("authentication_challenge", sequence: takeActionSequence(), data: ["token": .string(token)])
        try await connection.send(text)
    }

    private func startPinging(_ connection: any WebSocketConnection) {
        pingTask?.cancel()
        pingTask = nil
        guard let interval = configuration.pingInterval, interval > 0 else { return }
        pingTask = Task {
            await self.pingLoop(connection, interval: interval)
        }
    }

    private func pingLoop(_ connection: any WebSocketConnection, interval: TimeInterval) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, connection === self.connection else { return }
            do {
                _ = try await sendAction("ping", data: [:], timeout: configuration.actionTimeout)
            } catch MattermostWebSocketError.actionFailed {
                // Any reply proves the connection is alive.
            } catch {
                guard !Task.isCancelled, connection === self.connection else { return }
                // No pong in time: assume a dead connection. Closing it makes the
                // receive loop fail, which triggers a reconnect.
                connection.close()
                return
            }
        }
    }

    private func sendAction(_ action: String, data: [String: JSONValue], timeout: TimeInterval) async throws -> WebSocketResponse {
        guard let connection, handshakeComplete else {
            throw MattermostWebSocketError.notConnected
        }
        let sequence = takeActionSequence()
        let waiter = OneShot<WebSocketResponse>()
        pendingReplies[sequence] = waiter
        let clock = self.clock
        let timeoutTask = Task {
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            waiter.resolve(.failure(MattermostWebSocketError.timeout))
        }
        defer {
            timeoutTask.cancel()
            pendingReplies[sequence] = nil
        }
        do {
            try await connection.send(Self.encodeAction(action, sequence: sequence, data: data))
        } catch {
            throw MattermostWebSocketError.connectionClosed
        }
        let response = try await waiter.value()
        guard response.isOK else {
            throw MattermostWebSocketError.actionFailed(response)
        }
        return response
    }

    private func takeActionSequence() -> Int64 {
        defer { nextActionSequence += 1 }
        return nextActionSequence
    }

    private func tearDownConnection() {
        pingTask?.cancel()
        pingTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        connection?.close()
        connection = nil
        handshakeComplete = false
        isResumeAttempt = false
        handshakeProbeSequence = nil
        let pending = pendingReplies
        pendingReplies.removeAll()
        for waiter in pending.values {
            waiter.resolve(.failure(MattermostWebSocketError.connectionClosed))
        }
    }

    private func setState(_ newState: WebSocketConnectionState) {
        guard newState != state else { return }
        state = newState
        stateBroadcaster.yield(newState)
    }

    static func encodeAction(_ action: String, sequence: Int64, data: [String: JSONValue]) -> String {
        let object: JSONValue = .object([
            "action": .string(action),
            "seq": .int(sequence),
            "data": .object(data),
        ])
        // Encoding a JSONValue tree cannot fail (no non-finite doubles here).
        let encoded = (try? JSONEncoder().encode(object)) ?? Data("{}".utf8)
        return String(decoding: encoded, as: UTF8.self)
    }
}
