import Foundation

/// What the user may do with a channel, from the permissions of their roles (Phase 3D-2): the union of the
/// permissions of the system roles (`user.roles`), the team member's roles and the channel member's roles. A
/// channel or team scheme's roles are part of the members' `roles` strings, so moderated channels come out
/// right. The app hides what is not allowed; the server still decides.
public enum ChannelAccessRules {
    public struct Result: Equatable {
        /// Display name, purpose, header (and URL name).
        public var canEditProperties = false
        /// Add and remove other members.
        public var canManageMembers = false
        /// Make members channel admins and back.
        public var canManageRoles = false
        public var canArchive = false
        public var canUnarchive = false
        public var canConvertToPrivate = false
        public var canLeave = false
        /// The team's default channel (town square): it can't be left, archived or made private.
        public var isDefaultChannel = false

        public init() {
        }
    }

    /// The team's default channel; everyone is in it.
    public static let defaultChannelName = "town-square"

    /// - Parameters:
    ///   - channelType: `O`, `P`, `G` (DMs have no channel settings).
    ///   - isArchived: archived channels are read-only; only unarchiving is offered.
    public static func evaluate(permissions: Set<String>, channelType: String, channelName: String, isArchived: Bool) -> Result {
        var result = Result()
        let isPublic = channelType == "O"
        let isPrivate = channelType == "P"
        guard isPublic || isPrivate else {
            // Group messages: members are fixed, there is nothing to leave or archive.
            return result
        }
        let has: (String) -> Bool = { permissions.contains($0) || permissions.contains("manage_system") }
        result.isDefaultChannel = channelName == self.defaultChannelName
        if isArchived {
            // Restoring needs `manage_team` (api4 `restoreChannel`).
            result.canUnarchive = has("manage_team") && !result.isDefaultChannel
            result.canLeave = !result.isDefaultChannel
            return result
        }
        result.canEditProperties = has(isPublic ? "manage_public_channel_properties" : "manage_private_channel_properties")
        result.canManageMembers = has(isPublic ? "manage_public_channel_members" : "manage_private_channel_members")
        result.canManageRoles = has("manage_channel_roles")
        result.canArchive = has(isPublic ? "delete_public_channel" : "delete_private_channel") && !result.isDefaultChannel
        result.canConvertToPrivate = isPublic && has("convert_public_channel_to_private") && !result.isDefaultChannel
        result.canLeave = !result.isDefaultChannel
        return result
    }

    /// The role names in a space-separated roles string (`"channel_user channel_admin"`).
    public static func roleNames(_ roles: String...) -> Set<String> {
        var names = Set<String>()
        for value in roles {
            for name in value.split(separator: " ") where !name.isEmpty {
                names.insert(String(name))
            }
        }
        return names
    }
}
