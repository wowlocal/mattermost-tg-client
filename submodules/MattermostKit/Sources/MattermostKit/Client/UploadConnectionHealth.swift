import Foundation

public final class UploadConnectionHealth: Sendable {
    struct Evidence: Sendable {
        var at: TimeInterval
        var reason: String
    }
    private let latest = Locked<Evidence?>(nil)
    private let now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func pathChanged() { latest.set(Evidence(at: now(), reason: "network path changed")) }
    func transportFailed() { latest.set(Evidence(at: now(), reason: "websocket transport failed")) }
    func evidence(after progress: TimeInterval) -> Evidence? {
        guard let latest = latest.current, latest.at > progress else { return nil }
        return latest
    }
}
