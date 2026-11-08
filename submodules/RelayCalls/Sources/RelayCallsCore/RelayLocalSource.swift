import Foundation

/// Keeps a local source of a call (the microphone, the camera) in the state the user asked for.
///
/// `wanted` is the user's choice and is what the controllers' snapshots show: a failed publish never turns it off by
/// itself. While the media is up (`setReady(true)`) the source applies `wanted` through the engine, one request at a
/// time; a failure is logged and retried after a short, growing delay (`retryDelays`), and again whenever the
/// adapter reports that the reason may be gone (`retry(reason:)`: the audio engine became available, the room
/// reconnected). On a device the microphone can fail while CallKit has not activated the audio session yet, or while
/// the session's category does not record; the next attempt then succeeds.
@MainActor
final class RelayLocalSource {
    /// The microphone retries for about 40 s, then waits for `retry(reason:)` or a new `wanted`.
    static let microphoneRetryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 8, 8, 8]
    /// The camera retries three times (each attempt may wait 5 s for the first frame), then calls
    /// `onRetriesExhausted`.
    static let cameraRetryDelays: [TimeInterval] = [1, 2, 4]

    let name: String
    private let scheduler: RelayCallScheduler
    private let retryDelays: [TimeInterval]
    private let apply: @MainActor (Bool) async throws -> Void
    /// Names the call in log lines.
    var describe: @MainActor () -> String = { "call" }
    /// The automatic retries are used up (the source still fails).
    var onRetriesExhausted: (@MainActor () -> Void)?

    private(set) var wanted: Bool
    /// The state the engine last accepted; nil when unknown (never applied, or the last request failed).
    private var applied: Bool?
    private var isApplying = false
    private var isReady = false
    /// Failed attempts since the last success, `setWanted` or `retry` (the retry delays).
    private(set) var failures = 0
    /// Failed attempts since the last success (the log).
    private var failedAttempts = 0
    private var retryTimer: RelayCancellable?
    /// Invalidates requests still running when the media went away.
    private var generation = 0

    /// `applied`: what the room has before anything is applied (`false` skips turning off what was never published).
    init(name: String, wanted: Bool, applied: Bool? = nil, scheduler: RelayCallScheduler, retryDelays: [TimeInterval], apply: @escaping @MainActor (Bool) async throws -> Void) {
        self.name = name
        self.wanted = wanted
        self.applied = applied
        self.scheduler = scheduler
        self.retryDelays = retryDelays
        self.apply = apply
    }

    /// Whether the engine has a room to publish in (connected or reconnecting).
    func setReady(_ ready: Bool) {
        if self.isReady == ready {
            return
        }
        self.isReady = ready
        if ready {
            self.sync()
        } else {
            self.cancelRetry()
        }
    }

    /// The user's choice; applied now when the media is up.
    func setWanted(_ value: Bool) {
        self.wanted = value
        self.failures = 0
        self.cancelRetry()
        self.sync()
    }

    /// Something that may have made the last failure go away happened: try again now, with fresh retries.
    func retry(reason: String) {
        self.failures = 0
        self.cancelRetry()
        guard self.isReady, self.applied != self.wanted else {
            return
        }
        RelayCallsLog.log("\(self.describe()): \(self.name) \(Self.word(self.wanted)) again (\(reason))")
        self.sync()
    }

    /// The media is gone (the call ended): nothing more is applied.
    func stop() {
        self.isReady = false
        self.cancelRetry()
        self.generation += 1
        self.isApplying = false
        self.applied = nil
    }

    private func sync() {
        guard self.isReady, !self.isApplying, self.applied != self.wanted else {
            return
        }
        self.isApplying = true
        let target = self.wanted
        let generation = self.generation
        Task { @MainActor in
            do {
                try await self.apply(target)
                guard generation == self.generation else {
                    return
                }
                self.isApplying = false
                self.applied = target
                if self.failedAttempts > 0 {
                    RelayCallsLog.log("\(self.describe()): \(self.name) \(Self.word(target)) succeeded after \(self.failedAttempts) failed attempt(s)")
                } else {
                    RelayCallsLog.log("\(self.describe()): \(self.name) \(Self.word(target))")
                }
                self.failures = 0
                self.failedAttempts = 0
                self.cancelRetry()
                // The user may have changed it meanwhile.
                self.sync()
            } catch {
                guard generation == self.generation else {
                    return
                }
                self.isApplying = false
                self.applied = nil
                self.failures += 1
                self.failedAttempts += 1
                self.failed(target: target, error: error)
            }
        }
    }

    private func failed(target: Bool, error: Error) {
        let attempt = self.failures
        if self.wanted != target {
            // The user changed it while the request ran: apply the new choice right away.
            RelayCallsLog.log("\(self.describe()): \(self.name) \(Self.word(target)) failed: \(error)")
            self.failures = 0
            self.sync()
            return
        }
        if attempt <= self.retryDelays.count {
            let delay = self.retryDelays[attempt - 1]
            RelayCallsLog.log("\(self.describe()): \(self.name) \(Self.word(target)) failed (attempt \(attempt)): \(error); retrying in \(delay) s")
            self.cancelRetry()
            self.retryTimer = self.scheduler.schedule(at: self.scheduler.now().addingTimeInterval(delay)) { [weak self] in
                guard let self else {
                    return
                }
                self.retryTimer = nil
                self.sync()
            }
        } else {
            RelayCallsLog.log("\(self.describe()): \(self.name) \(Self.word(target)) failed (attempt \(attempt)): \(error); no more automatic retries")
            self.onRetriesExhausted?()
        }
    }

    private func cancelRetry() {
        self.retryTimer?.cancel()
        self.retryTimer = nil
    }

    private static func word(_ enabled: Bool) -> String {
        return enabled ? "on" : "off"
    }
}
