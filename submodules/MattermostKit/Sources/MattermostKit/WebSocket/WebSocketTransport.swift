import Foundation

public enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// One open WebSocket connection.
public protocol WebSocketConnection: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// Waits for the next frame. Throws when the connection fails or is closed.
    func receive() async throws -> WebSocketFrame
    /// Closes the connection. A pending `receive()` must then throw.
    func close()
}

/// Opens WebSocket connections. Injectable so tests can use a fake transport.
public protocol WebSocketTransport: Sendable {
    func connect(request: URLRequest) async throws -> any WebSocketConnection
}

public enum WebSocketTransportError: Error, Sendable, Equatable {
    /// The HTTP upgrade was rejected, e.g. 401 for an invalid token.
    case handshakeFailed(statusCode: Int)
    case unsupportedFrame
    case serverClosed(code: Int)
}

/// `URLSessionWebSocketTask`-based transport.
public final class URLSessionWebSocketTransport: WebSocketTransport {
    private let injectedSession: URLSession?
    private let maximumMessageSize: Int

    /// - Parameter session: Defaults to `MattermostURLSession.current` at each
    ///   connection, which applies the certificate pins of
    ///   `MattermostServerTrust.shared` (Phase 4G).
    public init(session: URLSession? = nil, maximumMessageSize: Int = 16 * 1024 * 1024) {
        self.injectedSession = session
        self.maximumMessageSize = maximumMessageSize
    }

    public func connect(request: URLRequest) async throws -> any WebSocketConnection {
        let session = self.injectedSession ?? MattermostURLSession.current
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let operations = WebSocketOperations()

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await operations.perform { [task] in try await task.send(.string(text)) }
    }

    func receive() async throws -> WebSocketFrame {
        do {
            let message = try await operations.perform { [task] in try await task.receive() }
            switch message {
            case .string(let text):
                return .text(text)
            case .data(let data):
                return .binary(data)
            @unknown default:
                throw WebSocketTransportError.unsupportedFrame
            }
        } catch {
            if let response = task.response as? HTTPURLResponse, response.statusCode >= 400 {
                throw WebSocketTransportError.handshakeFailed(statusCode: response.statusCode)
            }
            if task.closeCode != .invalid && task.closeCode != .abnormalClosure {
                throw WebSocketTransportError.serverClosed(code: task.closeCode.rawValue)
            }
            throw error
        }
    }

    func close() {
        operations.close()
        task.cancel(with: .goingAway, reason: nil)
        task.cancel()
    }
}

final class WebSocketOperations: Sendable {
    private let pending = Locked<[UUID: @Sendable () -> Void]?>([:])

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        let reply = OneShot<Value>()
        let accepted = pending.withLock { pending -> Bool in
            guard pending != nil else { return false }
            pending?[id] = { reply.resolve(.failure(MattermostWebSocketError.connectionClosed)) }
            return true
        }
        guard accepted else { throw MattermostWebSocketError.connectionClosed }
        let work = Task {
            do { reply.resolve(.success(try await operation())) }
            catch { reply.resolve(.failure(error)) }
        }
        defer {
            work.cancel()
            pending.withLock { $0?[id] = nil }
        }
        return try await reply.value()
    }

    func close() {
        let callbacks = pending.withLock { pending -> [@Sendable () -> Void] in
            let callbacks = pending.map { Array($0.values) } ?? []
            pending = nil
            return callbacks
        }
        for callback in callbacks { callback() }
    }
}

/// Time source for reconnect delays, pings and action timeouts. Injectable so
/// tests are deterministic.
public protocol WebSocketClock: Sendable {
    /// Suspends for `interval` seconds. Must throw `CancellationError` when the
    /// calling task is cancelled.
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemWebSocketClock: WebSocketClock {
    public init() {}

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

/// Exponential backoff with jitter.
///
/// `delay(n) = base * (1 - jitter) + base * jitter * random`, where
/// `base = min(maximumDelay, initialDelay * multiplier^(n-1))` and `random` is
/// in `0..<1`.
public struct BackoffPolicy: Sendable, Equatable {
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maximumDelay: TimeInterval
    /// Fraction of the delay that is randomised, `0...1`.
    public var jitter: Double

    public init(initialDelay: TimeInterval = 1, multiplier: Double = 2, maximumDelay: TimeInterval = 60, jitter: Double = 0.5) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
        self.jitter = jitter
    }

    /// - Parameters:
    ///   - attempt: 1 for the first retry.
    ///   - random: A value in `0..<1`.
    public func delay(forAttempt attempt: Int, random: Double) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let base = min(maximumDelay, initialDelay * pow(multiplier, exponent))
        let jitter = min(max(self.jitter, 0), 1)
        let random = min(max(random, 0), 1)
        return base * (1 - jitter) + base * jitter * random
    }
}
