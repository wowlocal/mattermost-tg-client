import Foundation

/// A Mattermost user status (`GET/POST /users/status/ids`, WebSocket `status_change`).
public enum MattermostUserStatus: String, Hashable, Sendable, CaseIterable {
    case online
    case away
    case dnd
    case offline

    /// Parses the API value; unknown values (e.g. `out_of_office` on some servers) map to offline.
    public init(apiValue: String) {
        self = MattermostUserStatus(rawValue: apiValue.lowercased()) ?? .offline
    }
}

/// What the app shows, in terms that map onto Telegram's `UserPresenceStatus`:
/// `.online(until:)` → `.present(until:)`, `.recently` → `.recently(isHidden: false)`,
/// `.lastSeen(at:)` → `.present(until: at)` (a past "until" renders as "last seen"),
/// `.unknown` → `.none`.
public enum PresenceState: Hashable, Sendable {
    /// Unix seconds until which the user counts as online; refreshed by status events.
    case online(until: Int32)
    case recently
    /// Unix seconds.
    case lastSeen(at: Int32)
    case unknown
}

public struct MappedPresence: Hashable, Sendable {
    public var state: PresenceState
    public var isAway: Bool
    public var isDoNotDisturb: Bool
    /// End of do-not-disturb (Unix seconds), when the server reports one.
    public var doNotDisturbUntil: Int32?

    public init(state: PresenceState, isAway: Bool = false, isDoNotDisturb: Bool = false, doNotDisturbUntil: Int32? = nil) {
        self.state = state
        self.isAway = isAway
        self.isDoNotDisturb = isDoNotDisturb
        self.doNotDisturbUntil = doNotDisturbUntil
    }
}

public enum PresenceMapper {
    /// How `away` is shown (a design decision; see docs/plan/02-domain-mapping.md).
    public enum AwayPresentation: Hashable, Sendable {
        /// "recently" (default).
        case recently
        /// Online, plus the away flag for a badge.
        case online
        /// "last seen" from `last_activity_at`, falling back to "recently".
        case lastSeen
    }

    public struct Configuration: Hashable, Sendable {
        /// How long an `online`/`dnd` status counts as online without a refresh.
        public var onlineValidity: Int32
        public var awayPresentation: AwayPresentation

        public init(onlineValidity: Int32 = 60, awayPresentation: AwayPresentation = .recently) {
            self.onlineValidity = onlineValidity
            self.awayPresentation = awayPresentation
        }

        public static let `default` = Configuration()
    }

    /// - Parameters:
    ///   - lastActivityAt: `last_activity_at` in ms (0 when hidden or unknown).
    ///   - dndEndTime: `dnd_end_time` in Unix seconds (0 or nil when not set).
    ///   - now: the current time.
    public static func presence(
        status: MattermostUserStatus,
        lastActivityAt: Int64,
        dndEndTime: Int64? = nil,
        now: Date,
        configuration: Configuration = .default
    ) -> MappedPresence {
        let nowSeconds = Int32(clamping: Int64(now.timeIntervalSince1970.rounded(.down)))
        let onlineUntil = Int32(clamping: Int64(nowSeconds) + Int64(configuration.onlineValidity))
        let lastSeen: Int32? = lastActivityAt > 0 ? Int32(clamping: min(lastActivityAt / 1000, Int64(nowSeconds))) : nil

        switch status {
        case .online:
            return MappedPresence(state: .online(until: onlineUntil))
        case .away:
            let state: PresenceState
            switch configuration.awayPresentation {
            case .recently:
                state = .recently
            case .online:
                state = .online(until: onlineUntil)
            case .lastSeen:
                state = lastSeen.map { .lastSeen(at: $0) } ?? .recently
            }
            return MappedPresence(state: state, isAway: true)
        case .dnd:
            var until: Int32?
            if let end = dndEndTime, end > 0 {
                // Some servers report milliseconds.
                let seconds = end > 100_000_000_000 ? end / 1000 : end
                until = Int32(clamping: seconds)
            }
            return MappedPresence(state: .online(until: onlineUntil), isDoNotDisturb: true, doNotDisturbUntil: until)
        case .offline:
            if let lastSeen = lastSeen {
                return MappedPresence(state: .lastSeen(at: lastSeen))
            }
            return MappedPresence(state: .unknown)
        }
    }
}
