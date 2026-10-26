import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// A change of a channel's member list for the app's open member lists
/// (`PeerChannelMemberCategoriesContextsManager.externallyAdded/Removed`, see MattermostUI).
public enum MattermostMemberChange {
    case added(channelPeerId: PeerId, participant: RenderedChannelParticipant)
    case removed(channelPeerId: PeerId, memberPeerId: PeerId)
}

/// Member lists of channels and group messages for Telegram's member UI (group info Members pane and its
/// search, `searchPeerMembers`, admin and bot lists): TelegramCore's `_internal_channelMembers` asks this
/// provider while the Mattermost backend is on (`MattermostMemberProvider`).
///
/// - `recent` / `mentions` without a query: pages of `GET /channels/{id}/members`, in the server's order
///   (Telegram pages by offset; the page size is the request's limit).
/// - a search: `GET /users/autocomplete?in_channel=` (the channel's members matching the query), first page only.
/// - admins / bots: the members of the first pages that are channel admins / bots.
/// - contacts, restricted, banned: none (Mattermost has no such lists).
/// Channel admins (`scheme_admin`) get admin info, which the list shows as "admin". Unknown users are fetched
/// and written to Postbox before the page is delivered.
final class MemberListProvider: MattermostMemberProvider {
    private weak var sync: MattermostAccountSync?

    init(sync: MattermostAccountSync) {
        self.sync = sync
    }

    func channelMembers(peerId: PeerId, category: ChannelMembersCategory, offset: Int32, limit: Int32) -> Signal<[RenderedChannelParticipant]?, NoError> {
        return Signal { [weak self] subscriber in
            let task = Task {
                let result = await self?.load(peerId: peerId, category: category, offset: Int(max(0, offset)), limit: Int(max(1, limit))) ?? []
                if !Task.isCancelled {
                    subscriber.putNext(result)
                    subscriber.putCompletion()
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    private func load(peerId: PeerId, category: ChannelMembersCategory, offset: Int, limit: Int) async -> [RenderedChannelParticipant] {
        guard let sync = self.sync else {
            return []
        }
        await sync.waitUntilBootstrapped()
        guard let channelId = sync.channelId(forPeerId: peerId), let channelState = sync.channelState(channelId), channelState.kind == .channel else {
            return []
        }
        do {
            let members: [ChannelMember]
            switch category {
            case let .recent(filter), let .mentions(_, filter):
                switch filter {
                case .all:
                    members = try await self.page(sync: sync, channelId: channelId, offset: offset, limit: limit)
                case let .search(query):
                    members = offset == 0 ? try await self.search(sync: sync, channelState: channelState, query: query) : []
                }
            case .admins:
                members = offset == 0 ? try await self.firstMembers(sync: sync, channelId: channelId).filter { $0.schemeAdmin } : []
            case let .bots(filter):
                if offset != 0 {
                    members = []
                } else {
                    let all = try await self.firstMembers(sync: sync, channelId: channelId)
                    await sync.ensureUsers(Set(all.map(\.userId)))
                    members = sync.state.with { state in
                        all.filter { member in
                            guard let user = state.users[member.userId], user.isBot else {
                                return false
                            }
                            if case let .search(query) = filter, !query.isEmpty {
                                return MemberListProvider.matches(user, query: query)
                            }
                            return true
                        }
                    }
                }
            case .contacts, .restricted, .banned:
                members = []
            }
            return await sync.renderedParticipants(members, channelPeerId: peerId)
        } catch {
            MMLog.log("members: \(channelId) (\(category)) failed: \(error)")
            return []
        }
    }

    /// The members at `offset ..< offset + limit` (pages of `limit`).
    private func page(sync: MattermostAccountSync, channelId: String, offset: Int, limit: Int) async throws -> [ChannelMember] {
        let firstPage = offset / limit
        var members = try await sync.client.channelMembers(channelId: channelId, page: firstPage, perPage: limit)
        let skip = offset - firstPage * limit
        if skip > 0 {
            if members.count == limit {
                members += try await sync.client.channelMembers(channelId: channelId, page: firstPage + 1, perPage: limit)
            }
            members = Array(members.dropFirst(skip).prefix(limit))
        }
        return members
    }

    /// Up to 1,000 members (for the admin and bot lists).
    private func firstMembers(sync: MattermostAccountSync, channelId: String) async throws -> [ChannelMember] {
        var result: [ChannelMember] = []
        for page in 0 ..< 5 {
            let members = try await sync.client.channelMembers(channelId: channelId, page: page, perPage: 200)
            result += members
            if members.count < 200 {
                break
            }
        }
        return result
    }

    private func search(sync: MattermostAccountSync, channelState: MattermostAccountSync.ChannelState, query: String) async throws -> [ChannelMember] {
        let teamId = sync.teamId(for: channelState)
        let found = try await sync.client.autocompleteUsers(name: query.lowercased(), teamId: teamId, channelId: channelState.channel.id, limit: 100)
        if found.users.isEmpty {
            return []
        }
        await sync.postbox.mmTransaction { transaction in
            sync.writeUsers(found.users, transaction: transaction)
        }
        let memberships = try await sync.client.channelMembers(channelId: channelState.channel.id, userIds: found.users.map(\.id))
        let byUser = Dictionary(memberships.map { ($0.userId, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        return found.users.compactMap { byUser[$0.id] }
    }

    static func matches(_ user: User, query: String) -> Bool {
        let query = query.lowercased()
        if user.username.lowercased().hasPrefix(query) {
            return true
        }
        for part in [user.firstName, user.lastName, user.nickname] where part.lowercased().hasPrefix(query) {
            return true
        }
        return false
    }
}

extension MattermostAccountSync {
    /// The team for team-scoped requests about a channel: its own team, or (DMs and GMs) the first team.
    func teamId(for channelState: ChannelState) -> String {
        if !channelState.teamId.isEmpty {
            return channelState.teamId
        }
        return self.state.with { $0.teams.first?.id ?? "" }
    }

    /// Channel members as Telegram participants, with their peers (fetched if unknown) and presences.
    func renderedParticipants(_ members: [ChannelMember], channelPeerId: PeerId) async -> [RenderedChannelParticipant] {
        if members.isEmpty {
            return []
        }
        await self.ensureUsers(Set(members.map(\.userId)))
        let ownPeerId = self.ownPeerId
        return await self.postbox.mmTransaction { transaction -> [RenderedChannelParticipant] in
            var result: [RenderedChannelParticipant] = []
            for member in members {
                guard let peerId = self.userPeerId(member.userId), let peer = transaction.getPeer(peerId) else {
                    continue
                }
                var presences: [PeerId: PeerPresence] = [:]
                if let presence = transaction.getPeerPresence(peerId: peerId) {
                    presences[peerId] = presence
                }
                result.append(RenderedChannelParticipant(participant: MattermostAccountSync.participant(member, peerId: peerId, ownPeerId: ownPeerId), peer: EnginePeer(peer), peers: [peerId: EnginePeer(peer)], presences: presences))
            }
            return result
        }
    }

    static func participant(_ member: ChannelMember, peerId: PeerId, ownPeerId: PeerId) -> ChannelParticipant {
        var adminInfo: ChannelParticipantAdminInfo?
        if member.schemeAdmin {
            adminInfo = ChannelParticipantAdminInfo(rights: TelegramChatAdminRights(rights: [.canChangeInfo, .canDeleteMessages, .canBanUsers, .canInviteUsers, .canPinMessages]), promotedBy: ownPeerId, canBeEditedByAccountPeer: false)
        }
        return .member(id: peerId, invitedAt: 0, adminInfo: adminInfo, banInfo: nil, rank: nil, subscriptionUntilDate: nil)
    }

    // MARK: Live member changes

    /// `user_added` in a channel: the new member for open member lists.
    func announceMemberAdded(channelId: String, userId: String) async {
        guard let channelState = self.channelState(channelId), channelState.kind == .channel else {
            return
        }
        guard let member = try? await self.client.channelMember(channelId: channelId, userId: userId) else {
            return
        }
        let rendered = await self.renderedParticipants([member], channelPeerId: channelState.peerId)
        for participant in rendered {
            MattermostSync.memberChangePipe(accountId: self.account.id).putNext(.added(channelPeerId: channelState.peerId, participant: participant))
        }
    }

    /// `user_removed` from a channel: the member leaves open member lists.
    func announceMemberRemoved(channelId: String, userId: String) {
        guard let channelState = self.channelState(channelId), channelState.kind == .channel, let peerId = self.userPeerId(userId) else {
            return
        }
        MattermostSync.memberChangePipe(accountId: self.account.id).putNext(.removed(channelPeerId: channelState.peerId, memberPeerId: peerId))
    }
}

extension MattermostAccountSync {
    /// The user left a channel or was removed from it (`user_removed` for the own user, e.g. `/leave`): the
    /// chat leaves the chat list and the team folders. Its history stays in Postbox. (Phase 3D-2 owns the
    /// leave and archive UI.)
    func applyOwnRemoval(channelId: String) async {
        guard let channelState = self.channelState(channelId), channelState.kind == .channel else {
            return
        }
        if let member = try? await self.client.channelMember(channelId: channelId), member.userId == self.ownUserId {
            // Still a member (a stale event).
            return
        }
        let peerId = channelState.peerId
        await self.postbox.mmTransaction { transaction in
            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
        }
        self.state.with { state in
            state.channels.removeValue(forKey: channelId)
            state.channelIdByPeerId.removeValue(forKey: peerId)
            for (teamId, favorites) in state.favoritesByTeam {
                state.favoritesByTeam[teamId] = favorites.filter { $0 != channelId }
            }
        }
        await self.writeTeamFolders(teams: self.state.with { $0.teams })
        MMLog.log("live: left channel \(channelId); removed from the chat list")
    }
}

extension MattermostSync {
    private static let memberChangePipes = MMLocked<[AccountRecordId: ValuePipe<MattermostMemberChange>]>([:])

    static func memberChangePipe(accountId: AccountRecordId) -> ValuePipe<MattermostMemberChange> {
        return self.memberChangePipes.with { pipes in
            if let pipe = pipes[accountId] {
                return pipe
            }
            let pipe = ValuePipe<MattermostMemberChange>()
            pipes[accountId] = pipe
            return pipe
        }
    }

    /// Members joining and leaving channels (WebSocket `user_added` / `user_removed`), for open member lists.
    public static func memberChanges(accountId: AccountRecordId) -> Signal<MattermostMemberChange, NoError> {
        return self.memberChangePipe(accountId: accountId).signal()
    }
}
