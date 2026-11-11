import Foundation

public enum UploadStall: Sendable, Equatable {
    case bodyProgress
    case responseWait
    case connectionReplaced(String)
}

public final class UploadRetryState: Sendable {
    private struct State {
        var evidenceRestarted = false
        var bodyStalls = 0
    }
    private let state = Locked(State())

    public init() {}

    func claimEvidenceRestart() -> Bool {
        return state.withLock {
            guard !$0.evidenceRestarted else { return false }
            $0.evidenceRestarted = true
            return true
        }
    }

    public func shouldRetry(_ error: MattermostError) -> Bool {
        guard error.isTransient else { return false }
        if case .uploadStalled(.bodyProgress) = error {
            return state.withLock { $0.bodyStalls += 1; return $0.bodyStalls < 3 }
        }
        return true
    }
}

public final class UploadConnectionHealth: Sendable {
    struct Evidence: Sendable {
        var at: TimeInterval
        var reason: String
    }
    private struct State {
        var latest: Evidence?
        var failedConnection: UUID?
    }
    private let state = Locked(State())
    private let now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func pathChanged(from usedInterfaces: Set<String>, to newUsedInterfaces: Set<String>) {
        guard !usedInterfaces.isEmpty, !usedInterfaces.isSubset(of: newUsedInterfaces) else { return }
        state.withLock { $0.latest = Evidence(at: now(), reason: "network path removed or replaced a used interface") }
    }

    func transportFailed(connection: UUID) {
        state.withLock { $0.failedConnection = connection }
    }

    func transportConnected(connection: UUID) {
        state.withLock {
            guard let failed = $0.failedConnection, failed != connection else { return }
            $0.failedConnection = nil
            $0.latest = Evidence(at: now(), reason: "failed websocket reconnected on a new transport")
        }
    }

    func evidence(after progress: TimeInterval) -> Evidence? {
        return state.withLock {
            guard let latest = $0.latest, latest.at > progress else { return nil }
            return latest
        }
    }
}
