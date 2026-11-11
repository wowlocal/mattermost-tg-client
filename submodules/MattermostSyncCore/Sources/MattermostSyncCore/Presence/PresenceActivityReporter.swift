import Foundation

public struct PresenceActivityIntent: Sendable {
    public var revision: Int
    public var active: Bool
    public var connected: Bool

    public init(revision: Int = 0, active: Bool = false, connected: Bool = false) {
        self.revision = revision
        self.active = active
        self.connected = connected
    }
}

public actor PresenceActivityReporter {
    private let send: @Sendable (Bool) async throws -> Void
    private let now: @Sendable () -> TimeInterval
    private var latest = PresenceActivityIntent(revision: -1)
    private var running = false
    private var failedActive: Bool?
    private var failures = 0
    private var retryAfter: TimeInterval = 0

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, send: @escaping @Sendable (Bool) async throws -> Void) {
        self.now = now
        self.send = send
    }

    public func update(_ intent: PresenceActivityIntent) async {
        guard intent.revision > latest.revision else { return }
        latest = intent
        guard !running else { return }
        running = true
        defer { running = false }
        while true {
            let current = latest
            if current.connected && (failedActive != current.active || now() >= retryAfter) {
                do {
                    try await send(current.active)
                    failedActive = nil
                    failures = 0
                } catch {
                    failedActive = current.active
                    failures = min(failures + 1, 3)
                    retryAfter = now() + min(120, 30 * pow(2, Double(failures - 1)))
                }
            }
            if latest.revision == current.revision { return }
        }
    }
}
