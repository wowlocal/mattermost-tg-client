import Foundation

public struct UserStatus: Codable, Sendable, Equatable {
    public enum Status: Sendable, Hashable, Codable, RawRepresentable {
        case online
        case away
        case dnd
        case offline
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "online": self = .online
            case "away": self = .away
            case "dnd": self = .dnd
            case "offline": self = .offline
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .online: return "online"
            case .away: return "away"
            case .dnd: return "dnd"
            case .offline: return "offline"
            case .unknown(let value): return value
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: (try? container.decode(String.self)) ?? "")
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var userId: String
    public var status: Status
    /// True when the user set the status explicitly.
    public var manual: Bool
    public var lastActivityAt: Int64
    /// Unix seconds when DND ends; 0 if not scheduled.
    public var dndEndTime: Int64
    public var prevStatus: String

    public init(
        userId: String,
        status: Status,
        manual: Bool = false,
        lastActivityAt: Int64 = 0,
        dndEndTime: Int64 = 0,
        prevStatus: String = ""
    ) {
        self.userId = userId
        self.status = status
        self.manual = manual
        self.lastActivityAt = lastActivityAt
        self.dndEndTime = dndEndTime
        self.prevStatus = prevStatus
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status
        case manual
        case lastActivityAt = "last_activity_at"
        case dndEndTime = "dnd_end_time"
        case prevStatus = "prev_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.string(.userId)
        status = Status(rawValue: c.string(.status))
        manual = c.bool(.manual)
        lastActivityAt = c.int64(.lastActivityAt)
        dndEndTime = c.int64(.dndEndTime)
        prevStatus = c.string(.prevStatus)
    }
}
