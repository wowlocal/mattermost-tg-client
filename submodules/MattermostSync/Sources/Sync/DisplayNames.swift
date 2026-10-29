import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import MattermostPush

/// 4H: users are named as the user's display setting has them (Mattermost's "Teammate Name Display": the
/// `display_settings` / `name_format` preference, else the server's `TeammateNameDisplay`, the server's setting when
/// `LockTeammateNameDisplay` is on; the same format the notification extension uses, 4F).
///
/// The names go into the users' peers (`UserDisplayName.peerNames`), so every Telegram screen that shows a peer's name
/// follows: chat titles, chat list rows, message authors, the mention list, member lists, profiles, search. Group
/// messages are titled with their other members' display names, as Mattermost's clients title them. The own user
/// keeps the real first and last name (Settings, Edit Profile: Mattermost's own profile shows the full name too).
///
/// A change of the format (another client, the server's config) rewrites every stored user (fetched again, 100 per
/// request) and every group message title; the stored users' format (and `userPeersVersion`) is kept in the
/// `user_names_format` cursor, so a build or a change while the app wasn't running is caught up at the next bootstrap.
extension MattermostAccountSync {
    static let userNamesFormatCursor = "user_names_format"
    /// Bumped when every stored user must be written again whatever the format (2: users get a non-zero access hash,
    /// `PeerConverter.userAccessHash`).
    static let userPeersVersion = 2

    /// The cursor value of users written in `format` by this version.
    static func userNamesCursorValue(_ format: String) -> String {
        return "\(format)/\(MattermostAccountSync.userPeersVersion)"
    }

    var nameFormat: String {
        return self.state.with { $0.nameFormat }
    }

    /// The last known format, before anything is written (the bootstrap reads the server's).
    func restoreNameFormat() {
        if let format = self.store.cursor(MattermostPushSenderName.nameFormatCursor) {
            self.state.with { $0.nameFormat = format }
        }
    }

    /// The first and last name of a user's peer.
    func peerNames(for user: User) -> (first: String, last: String?) {
        if user.id == self.ownUserId {
            // The own user: the real names (Settings and Edit Profile show and edit them).
            return UserDisplayName.peerNames(username: user.username, firstName: user.firstName, lastName: user.lastName, nickname: "", format: UserDisplayName.fullNameFormat)
        }
        return UserDisplayName.peerNames(username: user.username, firstName: user.firstName, lastName: user.lastName, nickname: user.nickname, format: self.nameFormat)
    }

    /// A user's display name in the current format (interactive menus, dialogs, link preview titles).
    func displayName(of user: User) -> String {
        return UserDisplayName.displayName(username: user.username, firstName: user.firstName, lastName: user.lastName, nickname: user.nickname, format: self.nameFormat)
    }

    /// A group message's title: the other members' display names (members the sync doesn't know yet by username,
    /// as the server names them); the server's `display_name` (usernames) when it can't be split.
    func groupMessageTitle(_ channel: Channel) -> String {
        let usernames = UserDisplayName.groupUsernames(displayName: channel.displayName)
        if usernames.isEmpty {
            return channel.displayName.isEmpty ? channel.name : channel.displayName
        }
        let ownUsername = self.ownUsername.lowercased()
        let names = self.state.with { state -> [String] in
            return usernames.filter { $0.lowercased() != ownUsername }.map { username in
                if let userId = state.userIdByUsername[username.lowercased()], let user = state.users[userId] {
                    return UserDisplayName.displayName(username: user.username, firstName: user.firstName, lastName: user.lastName, nickname: user.nickname, format: state.nameFormat)
                }
                return username
            }
        }
        if names.isEmpty {
            // A group message with the user alone (all others deactivated): the server's name.
            return channel.displayName
        }
        return UserDisplayName.groupTitle(names)
    }

    /// Loads the members of these group messages that aren't known yet (by username), so their titles use display
    /// names.
    func ensureGroupMessageMembers(_ channels: [Channel]) async {
        let ownUsername = self.ownUsername.lowercased()
        let wanted = Set(channels.filter { $0.type == .groupMessage }.flatMap { UserDisplayName.groupUsernames(displayName: $0.displayName) }.map { $0.lowercased() }.filter { $0 != ownUsername })
        let missing = self.state.with { state in wanted.filter { state.userIdByUsername[$0] == nil } }
        if missing.isEmpty {
            return
        }
        do {
            let names = Array(missing).sorted()
            var users: [User] = []
            for start in stride(from: 0, to: names.count, by: 100) {
                users.append(contentsOf: try await self.client.users(usernames: Array(names[start ..< min(names.count, start + 100)])))
            }
            await self.postbox.mmTransaction { transaction in
                self.writeUsers(users, transaction: transaction)
            }
        } catch {
            MMLog.log("names: could not load \(missing.count) group message member(s): \(error)")
        }
    }

    /// Rewrites every stored user and group message title when the format they were written with isn't the current
    /// one (a change on another client, the server's config, or the first launch of a build with 4H).
    func applyNameFormatIfNeeded(reason: String) async {
        let format = self.nameFormat
        let written = await self.postbox.mmTransaction { _ in
            return self.store.cursor(MattermostAccountSync.userNamesFormatCursor)
        }
        if written == MattermostAccountSync.userNamesCursorValue(format) {
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        // Every stored user (override peers of webhooks and bots have no user id and keep their names).
        let ids = self.store.peers(kind: .user).map { $0.mattermostId }.filter { MattermostAccountSync.isUserId($0) }
        var users: [User] = []
        do {
            for start in stride(from: 0, to: ids.count, by: 100) {
                users.append(contentsOf: try await self.client.users(ids: Array(ids[start ..< min(ids.count, start + 100)])))
            }
        } catch {
            // Offline: the users written from now on follow the format; the rest at the next bootstrap.
            MMLog.log("names: could not reload the stored users (\(reason)): \(error)")
            return
        }
        let groupMessages = self.state.with { state in state.channels.values.filter { $0.channel.type == .groupMessage } }
        await self.ensureGroupMessageMembers(groupMessages.map { $0.channel })
        let format2 = self.nameFormat
        await self.postbox.mmTransaction { transaction in
            self.writeUsers(users, transaction: transaction)
            for channelState in groupMessages {
                self.retitleGroupMessage(channelState, transaction: transaction)
            }
            self.store.setCursor(MattermostAccountSync.userNamesFormatCursor, MattermostAccountSync.userNamesCursorValue(format2))
        }
        MMLog.log("names: \(users.count) user(s) and \(groupMessages.count) group message(s) renamed as \(format2) (was \(written ?? "none"), \(reason)) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
    }

    /// Writes a group message's peer again when its title or picture (its members' names and pictures) changed.
    func retitleGroupMessage(_ channelState: ChannelState, transaction: Transaction) {
        let access = self.channelAccess(channel: channelState.channel, member: channelState.member, teamId: channelState.teamId)
        let peer = self.channelPeer(channelState.channel, peerId: channelState.peerId, access: access)
        guard let current = transaction.getPeer(channelState.peerId) as? TelegramChannel, current.title != peer.title || current.photo != peer.photo else {
            return
        }
        updatePeersCustom(transaction: transaction, peers: [peer], update: { _, updated in
            return updated
        })
    }

    /// The peer of a channel the user is in. 4H: a group message is titled with its other members' display names, as
    /// Mattermost's clients do, and pictured with their pictures (`MattermostGroupAvatar`; Mattermost has no picture
    /// for channels or group messages).
    func channelPeer(_ channel: Channel, peerId: PeerId, access: MattermostChannelAccess) -> TelegramChannel {
        if channel.type == .groupMessage {
            return PeerConverter.channel(channel, title: self.groupMessageTitle(channel), peerId: peerId, access: access, photo: MattermostGroupAvatar.photo(members: self.groupMessageAvatarMembers(channel)))
        }
        return PeerConverter.channel(channel, title: channel.displayName.isEmpty ? channel.name : channel.displayName, peerId: peerId, access: access)
    }

    /// A group message's other members as its picture shows them, in the title's order: their own picture, or the
    /// letter and colour of their initials avatar (a member the sync doesn't know yet: the username's).
    func groupMessageAvatarMembers(_ channel: Channel) -> [MattermostGroupAvatarResource.Member] {
        let ownUsername = self.ownUsername.lowercased()
        let usernames = UserDisplayName.groupUsernames(displayName: channel.displayName).filter { $0.lowercased() != ownUsername }
        return usernames.prefix(4).map { username -> MattermostGroupAvatarResource.Member in
            let user = self.state.with { state -> User? in
                return state.userIdByUsername[username.lowercased()].flatMap { state.users[$0] }
            }
            guard let user else {
                let hash = UInt64(username.lowercased().persistentHashString, radix: 16) ?? 0
                return MattermostGroupAvatarResource.Member(userId: "", pictureUpdate: 0, letter: String(username.prefix(1)).uppercased(), colorIndex: Int32(hash % 7))
            }
            let name = self.displayName(of: user)
            let letter = String((name.isEmpty ? user.username : name).prefix(1)).uppercased()
            // The colour Telegram gives the member's own initials avatar: the peer id's value modulo the gradients.
            let colorIndex = self.store.allocatePeer(mattermostId: user.id, kind: .user, teamId: nil).map { Int32(abs(MattermostPeerIds.userPeerId($0.peerId).id._internalGetInt64Value()) % 7) } ?? 0
            return MattermostGroupAvatarResource.Member(userId: user.id, pictureUpdate: user.hasCustomPicture ? user.lastPictureUpdate : 0, letter: letter, colorIndex: colorIndex)
        }
    }

    /// After users are written: the group messages with a member whose name or picture changed (or who wasn't known
    /// before) get their title and picture again.
    func refreshGroupMessages(changedUsernames: Set<String>, transaction: Transaction) {
        if changedUsernames.isEmpty {
            return
        }
        let groupMessages = self.state.with { state in state.channels.values.filter { $0.channel.type == .groupMessage } }
        for channelState in groupMessages {
            let usernames = UserDisplayName.groupUsernames(displayName: channelState.channel.displayName).map { $0.lowercased() }
            if usernames.contains(where: { changedUsernames.contains($0) }) {
                self.retitleGroupMessage(channelState, transaction: transaction)
            }
        }
    }

    /// A Mattermost id (26 lowercase letters and digits), as opposed to the override peers' keys.
    static func isUserId(_ value: String) -> Bool {
        return value.count == 26 && value.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
    }
}
