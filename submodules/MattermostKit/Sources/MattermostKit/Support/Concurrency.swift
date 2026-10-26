import Foundation

/// A value guarded by a lock. Only accessed from synchronous code.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value {
        withLock { $0 }
    }

    func set(_ newValue: Value) {
        withLock { $0 = newValue }
    }
}

/// A single-assignment result that one task can wait for. The first `resolve`
/// wins; later calls are ignored. Safe to resolve before anyone waits.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func resolve(_ newResult: Result<Value, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: newResult)
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }
}

/// Fans one sequence of values out to any number of `AsyncStream` subscribers.
final class StreamBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?
    private var isFinished = false
    private let replaysLatest: Bool

    /// - Parameter replaysLatest: New subscribers immediately receive the most
    ///   recent value (used for connection state).
    init(replaysLatest: Bool, initial: Element? = nil) {
        self.replaysLatest = replaysLatest
        self.latest = initial
    }

    func makeStream() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
                return
            }
            continuations[id] = continuation
            if replaysLatest, let latest {
                continuation.yield(latest)
            }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    func yield(_ element: Element) {
        lock.lock()
        if replaysLatest {
            latest = element
        }
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(element)
        }
    }

    func finish() {
        lock.lock()
        isFinished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
