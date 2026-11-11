import Foundation

public struct AccountSocketIntent: Sendable {
    public var revision: Int
    public var required: Bool
    public var reconnect: Int
    public var verify: Int

    public init(revision: Int = 0, required: Bool = false, reconnect: Int = 0, verify: Int = 0) {
        self.revision = revision
        self.required = required
        self.reconnect = reconnect
        self.verify = verify
    }
}

public actor AccountSocketLifecycle {
    private let connect: @Sendable () async -> Void
    private let disconnect: @Sendable () async -> Void
    private let reconnect: @Sendable () async -> Void
    private let verify: @Sendable () async -> Void
    private var latest = AccountSocketIntent(revision: -1)
    private var applied = AccountSocketIntent(revision: -1)
    private var running = false

    public init(connect: @escaping @Sendable () async -> Void, disconnect: @escaping @Sendable () async -> Void, reconnect: @escaping @Sendable () async -> Void, verify: @escaping @Sendable () async -> Void) {
        self.connect = connect
        self.disconnect = disconnect
        self.reconnect = reconnect
        self.verify = verify
    }

    public nonisolated static func requiresSocket(mobile: Bool, foreground: Bool, callSignalling: Bool, stopped: Bool) -> Bool {
        return !stopped && (!mobile || foreground || callSignalling)
    }

    public func update(_ intent: AccountSocketIntent) async {
        guard intent.revision > latest.revision else { return }
        latest = intent
        guard !running else { return }
        running = true
        defer { running = false }
        while true {
            let current = latest
            if current.required != applied.required {
                if current.required { await connect() } else { await disconnect() }
            } else if current.required {
                if current.reconnect > applied.reconnect { await reconnect() }
                else if current.verify > applied.verify { await verify() }
            }
            applied = current
            if latest.revision == current.revision { return }
        }
    }
}
