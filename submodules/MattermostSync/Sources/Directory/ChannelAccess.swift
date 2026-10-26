import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// What the user may do with each channel (Phase 3D-2): edit it, manage its members and their roles, archive,
/// unarchive, convert to private, leave. Computed from the permissions of the user's system roles, team member
/// roles and channel member roles (`ChannelAccessRules`), and written into the channel's peer
/// (`MattermostChannelAccess` in `TelegramChannel.version`), where the profile screens read it.
///
/// The roles are loaded by the bootstrap (`loadRoles`) and kept in `SyncState`; a channel written before they are
/// known gets no `.known` bit (the screens hide the management actions until it is rewritten). They are reloaded
/// when the server says they changed (`role_updated`, `memberrole_updated`, the own user's `user_updated`), and
/// every channel peer whose access changed is rewritten (`refreshChannelAccess`).
extension MattermostAccountSync {
    /// The access bits of a channel from the roles in `state` (unknown roles count as none).
    func channelAccess(channel: Channel, member: ChannelMember, teamId: String) -> MattermostChannelAccess {
        let (loaded, systemRoles, teamRoles, roles) = self.state.with { state in
            return (state.rolesLoaded, state.me?.roles ?? "", state.teamRoles[teamId] ?? "", state.roles)
        }
        var access: MattermostChannelAccess = []
        switch channel.type {
        case .privateChannel:
            access.insert(.privateChannel)
        case .groupMessage:
            access.insert(.groupMessage)
        default:
            break
        }
        if channel.isArchived {
            access.insert(.archived)
        }
        guard loaded else {
            return access
        }
        access.insert(.known)
        var permissions = Set<String>()
        for name in ChannelAccessRules.roleNames(systemRoles, teamRoles, member.roles) {
            if let role = roles[name] {
                permissions.formUnion(role.permissions)
            }
        }
        let result = ChannelAccessRules.evaluate(permissions: permissions, channelType: channel.type.rawValue, channelName: channel.name, isArchived: channel.isArchived)
        if result.canEditProperties {
            access.insert(.editProperties)
        }
        if result.canManageMembers {
            access.insert(.manageMembers)
        }
        if result.canManageRoles {
            access.insert(.manageRoles)
        }
        if result.canArchive {
            access.insert(.archive)
        }
        if result.canUnarchive {
            access.insert(.unarchive)
        }
        if result.canConvertToPrivate {
            access.insert(.convertToPrivate)
        }
        if result.canLeave {
            access.insert(.leave)
        }
        if result.isDefaultChannel {
            access.insert(.defaultChannel)
        }
        if result.canDeleteOthersPosts {
            access.insert(.deleteOthersPosts)
        }
        return access
    }

    /// The permissions of the user's system and team roles in a team; nil while the roles are unknown.
    func teamPermissions(teamId: String) -> Set<String>? {
        return self.state.with { state -> Set<String>? in
            guard state.rolesLoaded else {
                return nil
            }
            var permissions = Set<String>()
            for name in ChannelAccessRules.roleNames(state.me?.roles ?? "", state.teamRoles[teamId] ?? "") {
                if let role = state.roles[name] {
                    permissions.formUnion(role.permissions)
                }
            }
            return permissions
        }
    }

    /// The access of a written channel, from its current state.
    func channelAccess(_ channelState: ChannelState) -> MattermostChannelAccess {
        return self.channelAccess(channel: channelState.channel, member: channelState.member, teamId: channelState.teamId)
    }

    /// Loads the user's team roles and the roles named by them, the system roles and `channelRoles` (bootstrap).
    /// Failures leave the roles unknown; the next role refresh tries again.
    func loadRoles(me: User, channelRoles: [String]) async {
        do {
            let teamMembers = try await self.client.teamMembers()
            var teamRoles: [String: String] = [:]
            for member in teamMembers where member.deleteAt == 0 {
                teamRoles[member.teamId] = member.roles
            }
            var names = ChannelAccessRules.roleNames(me.roles)
            for roles in teamRoles.values {
                names.formUnion(ChannelAccessRules.roleNames(roles))
            }
            for roles in channelRoles {
                names.formUnion(ChannelAccessRules.roleNames(roles))
            }
            let roles = names.isEmpty ? [] : try await self.client.roles(names: Array(names).sorted())
            self.state.with { state in
                state.teamRoles = teamRoles
                state.roles = Dictionary(roles.map { ($0.name, $0) }, uniquingKeysWith: { lhs, _ in lhs })
                state.rolesLoaded = true
            }
            MMLog.log("roles: \(roles.count) roles for \(teamRoles.count) teams loaded")
            await self.writeDirectMessageDeletePermission(systemRoles: me.roles)
        } catch {
            MMLog.log("roles: could not load the user's roles (\(error)); channel access unknown")
        }
    }

    /// Phase 4G: a DM has no channel admins, so deleting the other person's posts there takes `delete_others_posts`
    /// from the user's system roles (system admins). Telegram offers "delete for both" on an incoming message in a
    /// private chat only with `LimitsConfiguration.canRemoveIncomingMessagesInPrivateChats`; it follows the permission.
    func writeDirectMessageDeletePermission(systemRoles: String) async {
        let roles = self.state.with { $0.roles }
        var permissions = Set<String>()
        for name in ChannelAccessRules.roleNames(systemRoles) {
            if let role = roles[name] {
                permissions.formUnion(role.permissions)
            }
        }
        let canDelete = permissions.contains("delete_others_posts") || permissions.contains("manage_system")
        let changed: Bool = await self.postbox.mmTransaction { transaction in
            var limits = currentLimitsConfiguration(transaction: transaction)
            let updated = limits.canRemoveIncomingMessagesInPrivateChats != canDelete || limits.maxMessageRevokeIntervalInPrivateChats != LimitsConfiguration.timeIntervalForever
            guard updated else {
                return false
            }
            limits.canRemoveIncomingMessagesInPrivateChats = canDelete
            // Mattermost has no time limit on deleting one's own posts (Telegram's default is two days in DMs).
            limits.maxMessageRevokeIntervalInPrivateChats = LimitsConfiguration.timeIntervalForever
            transaction.setPreferencesEntry(key: PreferencesKeys.limitsConfiguration, value: PreferencesEntry(limits))
            return true
        }
        if changed {
            MMLog.log("roles: deleting others' posts in DMs \(canDelete ? "allowed" : "not allowed")")
        }
    }

    /// Loads roles named in `roles` strings that aren't known yet (a new channel scheme, a new role).
    func ensureRoles(_ roles: [String]) async {
        let missing = self.state.with { state -> [String] in
            guard state.rolesLoaded else {
                return []
            }
            var names = Set<String>()
            for value in roles {
                names.formUnion(ChannelAccessRules.roleNames(value))
            }
            return names.filter { state.roles[$0] == nil }.sorted()
        }
        if missing.isEmpty {
            return
        }
        if let loaded = try? await self.client.roles(names: missing) {
            self.state.with { state in
                for role in loaded {
                    state.roles[role.name] = role
                }
            }
        }
    }

    /// Reloads the user's roles and rewrites every channel peer whose access changed (`role_updated`,
    /// `memberrole_updated`, the own user's `user_updated`).
    func refreshChannelAccess(reason: String) async {
        let me: User?
        if let fresh = try? await self.client.me() {
            self.state.with { $0.me = fresh }
            me = fresh
        } else {
            me = self.state.with { $0.me }
        }
        guard let me else {
            return
        }
        let channelRoles = self.state.with { state in state.channels.values.map { $0.member.roles } }
        await self.loadRoles(me: me, channelRoles: channelRoles)
        RoleCache.shared.invalidate(accountId: self.account.id)
        let rewritten: Int = await self.postbox.mmTransaction { transaction in
            var count = 0
            let states = self.state.with { Array($0.channels.values) }
            for channelState in states where channelState.kind == .channel {
                guard let current = transaction.getPeer(channelState.peerId) as? TelegramChannel else {
                    continue
                }
                let access = self.channelAccess(channelState)
                if current.version == access.rawValue {
                    continue
                }
                let channel = channelState.channel
                let title = channel.displayName.isEmpty ? channel.name : channel.displayName
                updatePeersCustom(transaction: transaction, peers: [PeerConverter.channel(channel, title: title, peerId: channelState.peerId, access: access)], update: { _, updated in
                    return updated
                })
                count += 1
            }
            return count
        }
        MMLog.log("roles: refreshed (\(reason)); \(rewritten) channel(s) with changed access")
    }
}
