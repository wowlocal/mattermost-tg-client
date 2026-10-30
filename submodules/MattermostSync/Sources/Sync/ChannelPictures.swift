import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Channel pictures. Mattermost has no picture for channels, so a public or private channel shows up to four of its
/// members (`MattermostGroupAvatar`, as group messages do). The members are chosen once a day per channel, stable
/// rather than "who posted last" so a chat keeps its look in the list: active members other than the user who have a
/// picture of their own, people before bots, each by username. Bots count because a channel is often someone's room
/// with an assistant bot (the user and one bot, the bot's picture is the channel's face); members without a picture
/// don't, so a new member or a test account doesn't put a letter tile into every channel. A channel where nobody else
/// has a picture keeps its letter; one with a single such member shows that member's picture.
///
/// The choice (user ids) and when it was made are kept in the sync store (`channel_pictures_2` cursor), so the
/// pictures show at launch before the network is up; the users themselves are written as peers, and a member's new
/// picture or name rewrites the channel's peer like a group message's (`refreshPicturedChats`).
extension MattermostAccountSync {
    /// `_2`: the choice changed (bots, pictured members only), so choices kept by the first version are dropped
    /// rather than waiting out their day.
    static let channelPicturesCursor = "channel_pictures_2"
    private static let legacyChannelPicturesCursors = ["channel_pictures"]
    /// A channel's members are looked up again after this long (joins, leaves, new pictures of others).
    static let channelPicturesMaxAge: Int64 = 24 * 60 * 60

    private struct StoredChannelPictures: Codable {
        var members: [String: [String]] = [:]
        var checkedAt: [String: Int64] = [:]
    }

    /// The last known choice, before anything is written (the bootstrap writes the channel peers with it).
    func restoreChannelPictures() {
        for key in MattermostAccountSync.legacyChannelPicturesCursors where self.store.cursor(key) != nil {
            self.store.setCursor(key, nil)
        }
        guard let text = self.store.cursor(MattermostAccountSync.channelPicturesCursor), let stored = try? JSONDecoder().decode(StoredChannelPictures.self, from: Data(text.utf8)) else {
            return
        }
        self.state.with { state in
            state.channelPictureUserIds = stored.members
            state.channelPicturesCheckedAt = stored.checkedAt
        }
    }

    private func storeChannelPictures() {
        let stored = self.state.with { state in
            StoredChannelPictures(members: state.channelPictureUserIds, checkedAt: state.channelPicturesCheckedAt)
        }
        if let data = try? JSONEncoder().encode(stored) {
            self.store.setCursor(MattermostAccountSync.channelPicturesCursor, String(decoding: data, as: UTF8.self))
        }
    }

    /// The picture of a public or private channel from its chosen members (none chosen yet: no picture).
    func channelPictureMembers(_ channel: Channel) -> [MattermostGroupAvatarResource.Member] {
        let users = self.state.with { state -> [User] in
            return (state.channelPictureUserIds[channel.id] ?? []).compactMap { state.users[$0] }
        }
        return users.map { self.groupAvatarMember($0) }
    }

    /// Chooses the members of the channels whose choice is missing or older than a day, writes those users and
    /// rewrites the channels whose picture changed. Two channels at a time; a failed lookup is retried next launch.
    func refreshChannelPictures(reason: String) async {
        let now = Int64(Date().timeIntervalSince1970)
        let due = self.state.with { state -> [String] in
            return state.channels.values.filter { channelState in
                guard channelState.channel.type == .publicChannel || channelState.channel.type == .privateChannel else {
                    return false
                }
                return now - (state.channelPicturesCheckedAt[channelState.channel.id] ?? 0) >= MattermostAccountSync.channelPicturesMaxAge
            }.map { $0.channel.id }
        }
        if due.isEmpty {
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        let ownUserId = self.ownUserId
        var chosen: [String: [User]] = [:]
        var failed = 0
        for start in stride(from: 0, to: due.count, by: 2) {
            let batch = Array(due[start ..< min(due.count, start + 2)])
            let results = await withTaskGroup(of: (String, [User]?).self) { group -> [(String, [User]?)] in
                for channelId in batch {
                    group.addTask {
                        let users = try? await self.client.users(UserListOptions(inChannelId: channelId, active: true, page: 0, perPage: 100))
                        return (channelId, users)
                    }
                }
                var results: [(String, [User]?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            for (channelId, users) in results {
                guard let users else {
                    failed += 1
                    continue
                }
                let pictured = users.filter { $0.id != ownUserId && $0.deleteAt == 0 && $0.hasCustomPicture }
                chosen[channelId] = Array((pictured.filter { !$0.isBot } + pictured.filter { $0.isBot }).prefix(4))
            }
        }
        let changed: Int = await self.postbox.mmTransaction { transaction in
            var usersById: [String: User] = [:]
            for users in chosen.values {
                for user in users {
                    usersById[user.id] = user
                }
            }
            self.writeUsers(Array(usersById.values), transaction: transaction)
            var changed = 0
            let changedIds: [String] = self.state.with { state in
                var changedIds: [String] = []
                for (channelId, users) in chosen {
                    let ids = users.map { $0.id }
                    if state.channelPictureUserIds[channelId] != ids {
                        state.channelPictureUserIds[channelId] = ids
                        changedIds.append(channelId)
                    }
                    state.channelPicturesCheckedAt[channelId] = now
                }
                return changedIds
            }
            for channelId in changedIds {
                if let channelState = self.channelState(channelId), self.rewriteChannelPeerIfNeeded(channelState, transaction: transaction) {
                    changed += 1
                }
            }
            self.storeChannelPictures()
            return changed
        }
        MMLog.log("pictures: \(chosen.count) channel(s) checked (\(reason)), \(changed) picture(s) changed, \(failed) failed, in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
    }

    /// Writes a channel's peer again when its title or picture changed.
    @discardableResult
    func rewriteChannelPeerIfNeeded(_ channelState: ChannelState, transaction: Transaction) -> Bool {
        let access = self.channelAccess(channel: channelState.channel, member: channelState.member, teamId: channelState.teamId)
        let peer = self.channelPeer(channelState.channel, peerId: channelState.peerId, access: access)
        guard let current = transaction.getPeer(channelState.peerId) as? TelegramChannel, current.title != peer.title || current.photo != peer.photo else {
            return false
        }
        updatePeersCustom(transaction: transaction, peers: [peer], update: { _, updated in
            return updated
        })
        return true
    }

    /// After users are written: the group messages and channels showing a member whose name or picture changed (or
    /// who wasn't known before) get their title and picture again.
    func refreshPicturedChats(changedUserIds: Set<String>, changedUsernames: Set<String>, transaction: Transaction) {
        if changedUserIds.isEmpty && changedUsernames.isEmpty {
            return
        }
        let chats = self.state.with { state -> [ChannelState] in
            return state.channels.values.filter { channelState in
                switch channelState.channel.type {
                case .groupMessage:
                    return UserDisplayName.groupUsernames(displayName: channelState.channel.displayName).contains(where: { changedUsernames.contains($0.lowercased()) })
                case .publicChannel, .privateChannel:
                    return (state.channelPictureUserIds[channelState.channel.id] ?? []).contains(where: { changedUserIds.contains($0) })
                default:
                    return false
                }
            }
        }
        for channelState in chats {
            self.rewriteChannelPeerIfNeeded(channelState, transaction: transaction)
        }
    }
}
