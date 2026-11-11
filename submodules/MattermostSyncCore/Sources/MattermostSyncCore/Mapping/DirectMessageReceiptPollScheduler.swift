import Foundation

public struct DirectMessageReceiptPollCandidate: Sendable {
    public var channelId: String
    public var postId: String
    public var isOwn: Bool
    public var isBot: Bool
    public var isDeactivated: Bool
    public var visible: Bool
    public var recentlyWritten: Bool
    public var priority: Int
    public var needsMigration: Bool

    public init(channelId: String, postId: String, isOwn: Bool, isBot: Bool = false, isDeactivated: Bool = false, visible: Bool, recentlyWritten: Bool, priority: Int = 0, needsMigration: Bool = false) {
        self.channelId = channelId
        self.postId = postId
        self.isOwn = isOwn
        self.isBot = isBot
        self.isDeactivated = isDeactivated
        self.visible = visible
        self.recentlyWritten = recentlyWritten
        self.priority = priority
        self.needsMigration = needsMigration
    }
}

public struct DirectMessageReceiptPollScheduler: Sendable {
    public static let requestsPerMinute = 12
    private struct Attempt: Sendable {
        var postId: String
        var failures = 0
        var nextCheck: TimeInterval = 0
        var lastCheck: TimeInterval = -.infinity
        var complete = false
    }
    private var attempts: [String: Attempt] = [:]
    private var reservations: [(at: TimeInterval, count: Int)] = []

    public init() {}

    public mutating func next(_ candidates: [DirectMessageReceiptPollCandidate], now: TimeInterval) -> DirectMessageReceiptPollCandidate? {
        reservations.removeAll { $0.at <= now - 60 }
        let remaining = Self.requestsPerMinute - reservations.reduce(0) { $0 + $1.count }
        var due: [DirectMessageReceiptPollCandidate] = []
        for candidate in candidates where candidate.isOwn && !candidate.isDeactivated && (candidate.visible || candidate.recentlyWritten) {
            if attempts[candidate.channelId]?.postId != candidate.postId {
                attempts[candidate.channelId] = Attempt(postId: candidate.postId)
            }
            guard let attempt = attempts[candidate.channelId], !attempt.complete, attempt.nextCheck <= now,
                  remaining >= (candidate.needsMigration ? 3 : 2) else { continue }
            due.append(candidate)
        }
        due.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            let left = attempts[$0.channelId]?.lastCheck ?? -.infinity
            let right = attempts[$1.channelId]?.lastCheck ?? -.infinity
            if left != right { return left < right }
            return $0.channelId < $1.channelId
        }
        guard let candidate = due.first else { return nil }
        reservations.append((now, candidate.needsMigration ? 3 : 2))
        attempts[candidate.channelId]?.lastCheck = now
        attempts[candidate.channelId]?.nextCheck = now + 30
        return candidate
    }

    public mutating func completed(_ candidate: DirectMessageReceiptPollCandidate, confirmed: Bool, eligible: Bool = true, now: TimeInterval) {
        guard var attempt = attempts[candidate.channelId], attempt.postId == candidate.postId else { return }
        attempt.complete = confirmed || !eligible
        attempt.failures = min(attempt.failures + 1, 8)
        let ceiling: Double = candidate.priority >= 2 ? 120 : 1800
        let delay = candidate.isBot ? 3600 : min(ceiling, 30 * pow(2, Double(attempt.failures - 1)))
        attempt.nextCheck = now + delay
        attempts[candidate.channelId] = attempt
    }
}
