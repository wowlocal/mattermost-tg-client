import Foundation

/// A role (`POST /roles/names`): its permission names.
public struct Role: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var permissions: [String]
    public var schemeManaged: Bool

    public init(id: String = "", name: String, permissions: [String] = [], schemeManaged: Bool = false) {
        self.id = id
        self.name = name
        self.permissions = permissions
        self.schemeManaged = schemeManaged
    }

    enum CodingKeys: String, CodingKey {
        case id, name, permissions
        case schemeManaged = "scheme_managed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.name)
        permissions = c.array(String.self, .permissions)
        schemeManaged = c.bool(.schemeManaged)
    }
}

/// Permission names used by the client.
public enum PermissionName {
    /// `@channel`, `@all` and `@here` notify the channel.
    public static let useChannelMentions = "use_channel_mentions"
}
