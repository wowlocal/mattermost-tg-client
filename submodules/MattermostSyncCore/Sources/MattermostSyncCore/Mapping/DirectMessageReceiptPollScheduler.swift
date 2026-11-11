import Foundation

public struct DirectMessageReceiptPost: Sendable, Equatable {
    public var postId: String
    public var localId: Int32
    public var isOwn: Bool
    public var isDeleted: Bool
    public var eligible: Bool
    public var needsMigration: Bool

    public init(postId: String, localId: Int32, isOwn: Bool, isDeleted: Bool = false, eligible: Bool, needsMigration: Bool = false) {
        self.postId = postId
        self.localId = localId
        self.isOwn = isOwn
        self.isDeleted = isDeleted
        self.eligible = eligible
        self.needsMigration = needsMigration
    }

    public static func newestUnconfirmedRoot(in newestFirst: [Self], after watermark: Int32) -> Self? {
        return newestFirst.first { $0.localId > watermark && $0.isOwn && !$0.isDeleted && ($0.eligible || $0.needsMigration) }
    }
}

public struct DirectMessageReceiptPollCandidate: Sendable {
    public var channelId: String
    public var revision: Int64
    public var isBot: Bool
    public var priority: Int
    public var opened: Int

    public init(channelId: String, revision: Int64, isBot: Bool = false, priority: Int = 0, opened: Int = 0) {
        self.channelId = channelId
        self.revision = revision
        self.isBot = isBot
        self.priority = priority
        self.opened = opened
    }
}

public enum DirectMessageReceiptPollResult {
    case confirmed, noPending, unconfirmed, retryable, aborted
}

public struct DirectMessageReceiptPollScheduler: Sendable {
    public static let requestsPerMinute = 12
    private struct Attempt: Sendable {
        var revision: Int64
        var opened: Int
        var priority: Int
        var failures = 0
        var nextCheck: TimeInterval = 0
        var lastCheck: TimeInterval = -.infinity
        var complete = false
    }
    private var attempts: [String: Attempt] = [:]
    private var reservations: [(at: TimeInterval, count: Int)] = []

    public init() {}

    private mutating func remaining(now: TimeInterval) -> Int {
        reservations.removeAll { $0.at <= now - 60 }
        return Self.requestsPerMinute - reservations.reduce(0) { $0 + $1.count }
    }

    public mutating func reserveRequests(_ count: Int, now: TimeInterval) -> Bool {
        guard remaining(now: now) >= count else { return false }
        reservations.append((now, count))
        return true
    }

    public mutating func next(_ candidates: [DirectMessageReceiptPollCandidate], now: TimeInterval) -> DirectMessageReceiptPollCandidate? {
        guard remaining(now: now) >= 2 else { return nil }
        var due: [DirectMessageReceiptPollCandidate] = []
        for candidate in candidates {
            if attempts[candidate.channelId]?.revision != candidate.revision {
                attempts[candidate.channelId] = Attempt(revision: candidate.revision, opened: candidate.opened, priority: candidate.priority)
            }
            if var attempt = attempts[candidate.channelId], candidate.priority >= 2 && (attempt.priority < 2 || attempt.opened != candidate.opened) {
                attempt.nextCheck = now
                attempt.complete = false
                attempt.failures = 0
                attempt.opened = candidate.opened
                attempts[candidate.channelId] = attempt
            }
            attempts[candidate.channelId]?.priority = candidate.priority
            guard let attempt = attempts[candidate.channelId], !attempt.complete, attempt.nextCheck <= now else { continue }
            due.append(candidate)
        }
        due.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            let left = attempts[$0.channelId]?.lastCheck ?? -.infinity
            let right = attempts[$1.channelId]?.lastCheck ?? -.infinity
            return left == right ? $0.channelId < $1.channelId : left < right
        }
        guard let candidate = due.first else { return nil }
        attempts[candidate.channelId]?.lastCheck = now
        attempts[candidate.channelId]?.nextCheck = now + 10
        return candidate
    }

    public mutating func completed(_ candidate: DirectMessageReceiptPollCandidate, result: DirectMessageReceiptPollResult, now: TimeInterval) {
        guard var attempt = attempts[candidate.channelId], attempt.revision == candidate.revision else { return }
        switch result {
        case .confirmed, .noPending:
            attempt.complete = true
        case .aborted:
            attempt.nextCheck = now
        case .retryable:
            attempt.nextCheck = now + 10
        case .unconfirmed:
            attempt.failures = min(attempt.failures + 1, 8)
            let delay = candidate.priority >= 2 ? 10 : candidate.isBot ? 3600 : min(1800, 30 * pow(2, Double(attempt.failures - 1)))
            attempt.nextCheck = now + delay
        }
        attempts[candidate.channelId] = attempt
    }
}
