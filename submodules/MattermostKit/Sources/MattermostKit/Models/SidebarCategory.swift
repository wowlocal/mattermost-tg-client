import Foundation

public struct SidebarCategory: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Hashable, Codable, RawRepresentable {
        case custom
        case channels
        case directMessages
        case favorites
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "custom": self = .custom
            case "channels": self = .channels
            case "direct_messages": self = .directMessages
            case "favorites": self = .favorites
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .custom: return "custom"
            case .channels: return "channels"
            case .directMessages: return "direct_messages"
            case .favorites: return "favorites"
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

    public var id: String
    public var userId: String
    public var teamId: String
    public var sortOrder: Int64
    /// `""` (default), `"alpha"`, `"recent"` or `"manual"`.
    public var sorting: String
    public var type: Kind
    public var displayName: String
    public var muted: Bool
    public var collapsed: Bool
    public var channelIds: [String]

    public init(
        id: String,
        userId: String = "",
        teamId: String = "",
        sortOrder: Int64 = 0,
        sorting: String = "",
        type: Kind = .custom,
        displayName: String = "",
        muted: Bool = false,
        collapsed: Bool = false,
        channelIds: [String] = []
    ) {
        self.id = id
        self.userId = userId
        self.teamId = teamId
        self.sortOrder = sortOrder
        self.sorting = sorting
        self.type = type
        self.displayName = displayName
        self.muted = muted
        self.collapsed = collapsed
        self.channelIds = channelIds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case teamId = "team_id"
        case sortOrder = "sort_order"
        case sorting
        case type
        case displayName = "display_name"
        case muted
        case collapsed
        case channelIds = "channel_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = c.string(.userId)
        teamId = c.string(.teamId)
        sortOrder = c.int64(.sortOrder)
        sorting = c.string(.sorting)
        type = Kind(rawValue: c.string(.type))
        displayName = c.string(.displayName)
        muted = c.bool(.muted)
        collapsed = c.bool(.collapsed)
        channelIds = c.array(String.self, .channelIds)
    }
}

/// Response of `GET /users/{user_id}/teams/{team_id}/channels/categories`.
public struct OrderedSidebarCategories: Codable, Sendable, Equatable {
    public var categories: [SidebarCategory]
    /// Category IDs in display order.
    public var order: [String]

    public init(categories: [SidebarCategory] = [], order: [String] = []) {
        self.categories = categories
        self.order = order
    }

    enum CodingKeys: String, CodingKey {
        case categories, order
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = c.array(SidebarCategory.self, .categories)
        order = c.array(String.self, .order)
    }

    /// Categories sorted by `order`; categories missing from `order` come last.
    public var orderedCategories: [SidebarCategory] {
        let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = order.compactMap { byId[$0] }
        let listed = Set(order)
        result.append(contentsOf: categories.filter { !listed.contains($0.id) })
        return result
    }
}
