import Foundation
import Postbox

// MATTERMOST: what the user may do with a Mattermost channel (Phase 3D-2), carried by the channel's peer.
//
// MattermostSync computes it from the permissions of the user's system, team and channel roles
// (MattermostSyncCore `ChannelAccessRules`) and writes it into `TelegramChannel.version`, a field Telegram's UI
// never reads for these peers. Being part of the peer, it is persisted, and a change (a role update, a new
// channel admin, an archived channel) updates every screen that observes the peer. Screens read it with
// `TelegramChannel.mattermostAccess` to show or hide channel settings, member management and Leave.
public struct MattermostChannelAccess: OptionSet, Equatable, Hashable {
    public var rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Set on every channel MattermostSync wrote with its roles known; without it the access is unknown.
    public static let known = MattermostChannelAccess(rawValue: 1 << 0)
    /// Display name, URL, purpose, header.
    public static let editProperties = MattermostChannelAccess(rawValue: 1 << 1)
    /// Add and remove other members.
    public static let manageMembers = MattermostChannelAccess(rawValue: 1 << 2)
    /// Make members channel admins and back.
    public static let manageRoles = MattermostChannelAccess(rawValue: 1 << 3)
    public static let archive = MattermostChannelAccess(rawValue: 1 << 4)
    public static let unarchive = MattermostChannelAccess(rawValue: 1 << 5)
    public static let convertToPrivate = MattermostChannelAccess(rawValue: 1 << 6)
    public static let leave = MattermostChannelAccess(rawValue: 1 << 7)
    /// The team's town square.
    public static let defaultChannel = MattermostChannelAccess(rawValue: 1 << 8)
    public static let privateChannel = MattermostChannelAccess(rawValue: 1 << 9)
    public static let groupMessage = MattermostChannelAccess(rawValue: 1 << 10)
    public static let archived = MattermostChannelAccess(rawValue: 1 << 11)
    /// Delete other users' posts (`delete_others_posts`, 4F): the message menu offers Delete for them.
    public static let deleteOthersPosts = MattermostChannelAccess(rawValue: 1 << 12)

    /// Whether the channel settings screen (the profile's Edit button) has anything for the user.
    public var hasSettings: Bool {
        return !self.intersection([.editProperties, .archive, .unarchive, .convertToPrivate]).isEmpty
    }
}

public extension TelegramChannel {
    /// The Mattermost access of this channel; nil when the Mattermost backend is off or the access is unknown
    /// (written before Phase 3D-2, or the roles weren't loaded yet).
    var mattermostAccess: MattermostChannelAccess? {
        guard MattermostBackend.isEnabled else {
            return nil
        }
        let access = MattermostChannelAccess(rawValue: self.version)
        return access.contains(.known) ? access : nil
    }
}
