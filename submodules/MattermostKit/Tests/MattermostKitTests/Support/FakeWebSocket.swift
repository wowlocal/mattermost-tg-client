import Foundation
import XCTest
@testable import MattermostKit

/// A scripted in-memory WebSocket connection.
final class FakeWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var buffer: [Result<WebSocketFrame, Error>] = []
    private var waiter: CheckedContinuation<WebSocketFrame, Error>?
    private var sent: [String] = []
    private var closed = false

    init(request: URLRequest) {
        self.request = request
    }

    var sentTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    var sentActions: [JSONValue] {
        sentTexts.compactMap { try? JSONValue.parse(Data($0.utf8)) }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Delivers a text frame from the "server".
    func push(_ text: String) {
        deliver(.success(.text(text)))
    }

    /// Drops the connection with an error.
    func fail(_ error: Error = URLError(.networkConnectionLost)) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<WebSocketFrame, Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
        } else {
            buffer.append(result)
            lock.unlock()
        }
    }

    func send(_ text: String) async throws {
        try record(text)
    }

    private func record(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            throw URLError(.networkConnectionLost)
        }
        sent.append(text)
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let next = buffer.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(throwing: URLError(.cancelled))
    }
}

/// A transport whose connect results are scripted per attempt.
final class FakeWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    enum Outcome {
        case succeed
        case fail(Error)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var _requests: [URLRequest] = []
    private var _connections: [FakeWebSocketConnection] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    /// Script outcomes for upcoming attempts; attempts beyond the script succeed.
    func enqueue(_ newOutcomes: Outcome...) {
        lock.lock()
        outcomes.append(contentsOf: newOutcomes)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var connections: [FakeWebSocketConnection] {
        lock.lock()
        defer { lock.unlock() }
        return _connections
    }

    func connect(request: URLRequest) async throws -> any WebSocketConnection {
        try makeConnection(request)
    }

    private func makeConnection(_ request: URLRequest) throws -> FakeWebSocketConnection {
        lock.lock()
        _requests.append(request)
        let outcome = outcomes.isEmpty ? .succeed : outcomes.removeFirst()
        switch outcome {
        case .fail(let error):
            lock.unlock()
            throw error
        case .succeed:
            let connection = FakeWebSocketConnection(request: request)
            _connections.append(connection)
            lock.unlock()
            return connection
        }
    }
}

/// A clock whose sleeps only finish when the test advances time.
final class ManualClock: WebSocketClock, @unchecked Sendable {
    private struct Sleeper {
        var id: UUID
        var deadline: TimeInterval
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<UUID> = []
    private var requested: [TimeInterval] = []

    /// Every interval passed to `sleep(for:)`, in order.
    var requestedSleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    var pendingSleepers: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.map { $0.deadline - now }
    }

    func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                requested.append(interval)
                if cancelled.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: now + interval, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepers.remove(at: index)
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelled.insert(id)
                lock.unlock()
            }
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now += interval
        let due = sleepers.filter { $0.deadline <= now + 1e-9 }
        sleepers.removeAll { $0.deadline <= now + 1e-9 }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// Collects values from an `AsyncStream` in the background.
final class StreamRecorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Element] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await value in stream {
                self?.append(value)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    private func append(_ value: Element) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }
}

/// Polls `condition` until it holds or the (real-time) timeout expires.
func waitUntil(
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}
