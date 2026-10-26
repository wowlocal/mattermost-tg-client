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
    /// Add and remove members of public / private channels.
    public static let managePublicChannelMembers = "manage_public_channel_members"
    public static let managePrivateChannelMembers = "manage_private_channel_members"
    /// Edit a channel's name, purpose and header.
    public static let managePublicChannelProperties = "manage_public_channel_properties"
    public static let managePrivateChannelProperties = "manage_private_channel_properties"
    /// Archive (and unarchive) channels.
    public static let deletePublicChannel = "delete_public_channel"
    public static let deletePrivateChannel = "delete_private_channel"
    /// Make members channel admins and back.
    public static let manageChannelRoles = "manage_channel_roles"
    public static let convertPublicChannelToPrivate = "convert_public_channel_to_private"
    public static let createPublicChannel = "create_public_channel"
    public static let createPrivateChannel = "create_private_channel"
    public static let createGroupChannel = "create_group_channel"
    public static let joinPublicChannels = "join_public_channels"
    public static let manageSystem = "manage_system"
}
