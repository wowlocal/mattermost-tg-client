import Foundation

/// Diagnostics of the call core (media publishing, connects, plugin requests that failed). Silent until a platform
/// adapter installs `handler`: iOS forwards every line to Telegram's log and to `NSLog` (the device syslog).
public enum RelayCallsLog {
    /// Receives every line, on any thread.
    public static var handler: ((String) -> Void)? {
        get {
            return RelayCallsLogStorage.shared.handler
        }
        set {
            RelayCallsLogStorage.shared.handler = newValue
        }
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard let handler = self.handler else {
            return
        }
        handler(message())
    }
}

private final class RelayCallsLogStorage: @unchecked Sendable {
    static let shared = RelayCallsLogStorage()

    private let lock = NSLock()
    private var value: ((String) -> Void)?

    var handler: ((String) -> Void)? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
        set {
            self.lock.lock()
            self.value = newValue
            self.lock.unlock()
        }
    }
}

/// Runs a plugin request whose failure changes nothing for the call (hangup, decline, received) and logs the failure.
func relayLogFailure(_ description: String, _ request: () async throws -> Void) async {
    do {
        try await request()
    } catch {
        RelayCallsLog.log("\(description) failed: \(error)")
    }
}
