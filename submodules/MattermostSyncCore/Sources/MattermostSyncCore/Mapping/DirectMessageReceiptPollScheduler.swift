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
    public var written: TimeInterval

    public init(channelId: String, revision: Int64, isBot: Bool = false, priority: Int = 0, opened: Int = 0, written: TimeInterval = 0) {
        self.channelId = channelId
        self.revision = revision
        self.isBot = isBot
        self.priority = priority
        self.opened = opened
        self.written = written
    }
}

public enum DirectMessageReceiptPollResult {
    case confirmed, noPending, unconfirmed, retryable, aborted
}

public struct DirectMessageReceiptPollScheduler: Sendable {
    public static let requestsPerMinute = 24
    private struct Attempt: Sendable {
        var revision: Int64
        var opened: Int
        var written: TimeInterval
        var priority: Int
        var listFailures = 0
        var slowOpenSamples = 0
        var fastUntil: TimeInterval
        var nextCheck: TimeInterval = 0
        var lastCheck: TimeInterval = -.infinity
        var complete = false
    }
    private var lastSelectionWasOpen = false
    private var listDue = false
    private var attempts: [String: Attempt] = [:]
    private var reservations: [(at: TimeInterval, count: Int, open: Bool)] = []

    public init() {}

    private mutating func remaining(now: TimeInterval) -> Int {
        reservations.removeAll { $0.at <= now - 60 }
        return Self.requestsPerMinute - reservations.reduce(0) { $0 + $1.count }
    }

    public mutating func reserveRequests(_ count: Int, for candidate: DirectMessageReceiptPollCandidate? = nil, now: TimeInterval) -> Bool {
        guard remaining(now: now) >= count else { return false }
        let isOpen = (candidate?.priority ?? 0) >= 2
        guard !isOpen || !listDue || reservations.filter({ $0.open }).reduce(0, { $0 + $1.count }) + count <= Self.requestsPerMinute / 2 else { return false }
        reservations.append((now, count, isOpen))
        return true
    }

    public mutating func next(_ candidates: [DirectMessageReceiptPollCandidate], now: TimeInterval) -> DirectMessageReceiptPollCandidate? {
        guard remaining(now: now) >= 2 else { return nil }
        var due: [DirectMessageReceiptPollCandidate] = []
        for candidate in candidates {
            var attempt = attempts[candidate.channelId] ?? Attempt(revision: candidate.revision, opened: candidate.opened, written: candidate.written, priority: candidate.priority, fastUntil: now + 60)
            if attempt.revision != candidate.revision {
                attempt.revision = candidate.revision
                attempt.complete = false
                attempt.nextCheck = now
                attempt.listFailures = 0
            }
            if candidate.priority >= 2 && (attempt.priority < 2 || attempt.opened != candidate.opened || attempt.written != candidate.written) {
                attempt.fastUntil = now + 60
                attempt.slowOpenSamples = 0
                attempt.nextCheck = now
                attempt.complete = false
            } else if candidate.priority < 2 && attempt.priority >= 2 {
                attempt.nextCheck = now
            }
            attempt.opened = candidate.opened
            attempt.written = candidate.written
            attempt.priority = candidate.priority
            attempts[candidate.channelId] = attempt
            if !attempt.complete && attempt.nextCheck <= now { due.append(candidate) }
        }
        listDue = due.contains(where: { $0.priority < 2 })
        if listDue && (lastSelectionWasOpen || reservations.filter({ $0.open }).reduce(0, { $0 + $1.count }) >= Self.requestsPerMinute / 2) {
            due.removeAll { $0.priority >= 2 }
        }
        due.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            let left = attempts[$0.channelId]?.lastCheck ?? -.infinity
            let right = attempts[$1.channelId]?.lastCheck ?? -.infinity
            return left == right ? $0.channelId < $1.channelId : left < right
        }
        guard let candidate = due.first else { return nil }
        lastSelectionWasOpen = candidate.priority >= 2
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
            let delay: TimeInterval
            if candidate.priority >= 2 {
                if now < attempt.fastUntil {
                    delay = 10
                } else {
                    delay = attempt.slowOpenSamples == 0 ? 30 : 60
                    attempt.slowOpenSamples += 1
                }
            } else {
                attempt.listFailures = min(attempt.listFailures + 1, 8)
                delay = candidate.isBot ? 3600 : min(1800, 30 * pow(2, Double(attempt.listFailures - 1)))
            }
            attempt.nextCheck = now + delay
        }
        attempts[candidate.channelId] = attempt
    }
}
