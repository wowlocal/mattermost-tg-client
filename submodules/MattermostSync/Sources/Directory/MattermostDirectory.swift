import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

// Phase 3D-2: directory and membership. The user directory (compose, add members), DMs and group messages,
// browsing, joining and creating channels, channel settings (name, purpose, header, archive, privacy) and member
// management (add, remove, channel admin). MattermostUI's screens call these; every change goes to the server
// first and reaches Postbox through the normal sync path (`refreshChannel`, the WebSocket events).

/// Why a directory request failed, for the screens' alerts.
public enum MattermostDirectoryError: Error, Equatable {
    /// The account's sync isn't running (session expired, logged out).
    case unavailable
    /// No connection to the server.
    case network
    /// Another channel of the team already has this URL.
    case urlNameTaken
    /// The server refused; its message.
    case server(String)
}

/// A user of the directory, written to Postbox (so the peer has a picture and opens a chat).
public struct MattermostDirectoryUser: Equatable {
    public let peer: EnginePeer
    public let userId: String
    public let username: String
    public let nickname: String
    public let position: String
    public let isBot: Bool
}

public struct MattermostUserPage: Equatable {
    public let users: [MattermostDirectoryUser]
    public let hasMore: Bool
}

public struct MattermostDirectoryTeam: Equatable {
    public let id: String
    public let name: String
    public let displayName: String
}

/// A channel in Browse Channels.
public struct MattermostBrowsedChannel: Equatable {
    public let id: String
    public let teamId: String
    public let name: String
    public let displayName: String
    public let purpose: String
    /// The header as plain text (markdown removed).
    public let header: String
    public let memberCount: Int64?
    public let isArchived: Bool
    public let isPrivate: Bool
    /// The chat of a channel the user is a member of.
    public let memberPeerId: PeerId?
    /// An in-memory peer for the row's avatar (never stored).
    public let previewPeer: EnginePeer
}

/// A recent message of a channel the user isn't in (Browse Channels' preview).
public struct MattermostPreviewPost: Equatable {
    public let id: String
    public let author: String
    public let text: String
    public let date: Date
}

public struct MattermostChannelPage: Equatable {
    public let channels: [MattermostBrowsedChannel]
    public let hasMore: Bool
}

public struct MattermostNewChannel: Equatable {
    public var teamId: String
    public var displayName: String
    public var urlName: String
    public var isPrivate: Bool
    public var purpose: String
    public var header: String

    public init(teamId: String, displayName: String, urlName: String, isPrivate: Bool, purpose: String, header: String) {
        self.teamId = teamId
        self.displayName = displayName
        self.urlName = urlName
        self.isPrivate = isPrivate
        self.purpose = purpose
        self.header = header
    }
}

/// A channel's settings as the server has them now.
public struct MattermostChannelSettings: Equatable {
    public let channelId: String
    public let teamId: String
    public let teamName: String
    public let teamDisplayName: String
    public let displayName: String
    public let urlName: String
    public let purpose: String
    public let header: String
    public let isPrivate: Bool
    public let isArchived: Bool
    public let access: MattermostChannelAccess
    /// `<server>/<team>/channels/<name>`.
    public let link: String
}

/// The Mattermost profile of a user (the profile screen's rows).
public struct MattermostUserProfile: Equatable {
    public let userId: String
    public let username: String
    public let fullName: String
    public let nickname: String
    public let position: String
    /// Empty when the server hides email addresses.
    public let email: String
    public let isBot: Bool
    public let botDescription: String
    /// The user's time zone (automatic or manual), when set.
    public let timeZone: TimeZone?
    /// The status emoji as text (Unicode, or `:name:` for a custom emoji).
    public let customStatusEmoji: String
    public let customStatusText: String
    /// Nil: no expiry.
    public let customStatusExpiresAt: Date?
    public let isDeactivated: Bool
}

public enum MattermostDirectory {
    // MARK: Lookups (synchronous, from the running sync)

    /// The account's teams, in the server's order.
    public static func teams(accountId: AccountRecordId) -> [MattermostDirectoryTeam] {
        guard let sync = MattermostSync.sync(accountId: accountId) else {
            return []
        }
        return sync.state.with { state in
            state.teams.map { MattermostDirectoryTeam(id: $0.id, name: $0.name, displayName: $0.displayName) }
        }
    }

    /// Which channel types the user may create in a team (`create_public_channel`, `create_private_channel`);
    /// both when the roles aren't known (the server decides).
    public static func channelCreation(accountId: AccountRecordId, teamId: String) -> (publicChannel: Bool, privateChannel: Bool) {
        guard let sync = MattermostSync.sync(accountId: accountId), let permissions = sync.teamPermissions(teamId: teamId) else {
            return (true, true)
        }
        let isAdmin = permissions.contains(PermissionName.manageSystem)
        return (isAdmin || permissions.contains(PermissionName.createPublicChannel), isAdmin || permissions.contains(PermissionName.createPrivateChannel))
    }

    /// A channel's header (Mattermost markdown) as text and entities, for its profile; nil without a header.
    public static func channelHeader(accountId: AccountRecordId, peerId: PeerId) -> (text: String, entities: [MessageTextEntity])? {
        guard let sync = MattermostSync.sync(accountId: accountId), let channelId = sync.channelId(forPeerId: peerId), let channelState = sync.channelState(channelId), !channelState.channel.header.isEmpty, let context = sync.conversionContext(channelId: channelId, entries: [:]) else {
            return nil
        }
        let formatted = PostConverter.formattedMarkdown(channelState.channel.header, context: context)
        return formatted.text.isEmpty ? nil : formatted
    }

    /// The team of a channel chat, if it is one.
    public static func teamId(accountId: AccountRecordId, peerId: PeerId) -> String? {
        guard let sync = MattermostSync.sync(accountId: accountId), let channelId = sync.channelId(forPeerId: peerId), let channelState = sync.channelState(channelId), !channelState.teamId.isEmpty else {
            return nil
        }
        return channelState.teamId
    }

    /// A user's Mattermost profile, from the users the sync knows (every user with a chat or in a member list).
    public static func userProfile(accountId: AccountRecordId, peerId: PeerId) -> MattermostUserProfile? {
        guard let sync = MattermostSync.sync(accountId: accountId) else {
            return nil
        }
        guard let userId = sync.userId(forPeerId: peerId), let user = sync.state.with({ $0.users[userId] ?? ($0.me?.id == userId ? $0.me : nil) }) else {
            return nil
        }
        return MattermostDirectory.profile(user)
    }

    static func profile(_ user: User) -> MattermostUserProfile {
        var timeZone: TimeZone?
        let useAutomatic = user.timezone["useAutomaticTimezone"].map { $0 == "true" } ?? true
        let identifier = useAutomatic ? user.timezone["automaticTimezone"] : user.timezone["manualTimezone"]
        if let identifier, !identifier.isEmpty {
            timeZone = TimeZone(identifier: identifier)
        }
        var emoji = ""
        var text = ""
        var expiresAt: Date?
        if let status = user.customStatus {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            let expiry = formatter.date(from: status.expiresAt) ?? plain.date(from: status.expiresAt)
            // "0001-01-01T00:00:00Z" (or nothing): no expiry.
            let expired = expiry.map { $0.timeIntervalSince1970 > 0 && $0 < Date() } ?? false
            if !expired {
                // Mattermost stores the emoji's name (`palm_tree`); custom emoji stay `:name:`.
                emoji = status.emoji.isEmpty ? "" : (EmojiTable.unicode(forName: status.emoji) ?? ":\(status.emoji):")
                text = status.text
                if let expiry, expiry.timeIntervalSince1970 > 0 {
                    expiresAt = expiry
                }
            }
        }
        return MattermostUserProfile(
            userId: user.id,
            username: user.username,
            fullName: user.fullName.trimmingCharacters(in: .whitespaces),
            nickname: user.nickname,
            position: user.position,
            email: user.email,
            isBot: user.isBot,
            botDescription: user.botDescription,
            timeZone: timeZone,
            customStatusEmoji: emoji,
            customStatusText: text,
            customStatusExpiresAt: expiresAt,
            isDeactivated: user.isDeactivated
        )
    }

    // MARK: Users

    /// A page of the user directory: everyone the user may message (the server's `RestrictDirectMessage`:
    /// the whole server, or the user's teams' members), without the user and deactivated users. With
    /// `notInChannel`, the members of that channel's team who are not in it (Add Members). A non-empty `query`
    /// searches names (one page).
    public static func users(accountId: AccountRecordId, query: String, page: Int, notInChannel channelPeerId: PeerId? = nil) -> Signal<MattermostUserPage, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.directoryUsers(query: query, page: page, notInChannelPeerId: channelPeerId)
        }
    }

    /// Opens the DM with a user: `POST /channels/direct` (returns the existing channel), written to Postbox so
    /// its history loads. The chat is the user's peer.
    public static func openDirectMessage(accountId: AccountRecordId, userPeerId: PeerId) -> Signal<PeerId, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.openDirectMessage(userPeerId: userPeerId)
        }
    }

    /// Creates (or finds) the group message of the user and `userPeerIds` (2 to 7 others): `POST /channels/group`.
    public static func createGroupMessage(accountId: AccountRecordId, userPeerIds: [PeerId]) -> Signal<PeerId, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.createGroupMessage(userPeerIds: userPeerIds)
        }
    }

    // MARK: Channels

    /// A page of a team's public channels (`archived`: its archived channels). A non-empty `query` searches
    /// (one page). Channels the user is in are included, with their chat.
    public static func browseChannels(accountId: AccountRecordId, teamId: String, query: String, archived: Bool, page: Int) -> Signal<MattermostChannelPage, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.browseChannels(teamId: teamId, query: query, archived: archived, page: page)
        }
    }

    /// The newest messages of a public channel the user isn't in (a read-only preview; public channels are
    /// readable by the team's members): root posts other than system messages, oldest first.
    public static func previewPosts(accountId: AccountRecordId, channelId: String, limit: Int = 10) -> Signal<[MattermostPreviewPost], MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.previewPosts(channelId: channelId, limit: limit)
        }
    }

    /// One channel for its preview (by id; search opens channels the user hasn't joined with it).
    public static func channelPreview(accountId: AccountRecordId, channelId: String) -> Signal<MattermostBrowsedChannel, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.channelPreview(channelId: channelId)
        }
    }

    /// The Mattermost channel of a peer search shows for a public channel the user isn't in (3C), if it is one.
    public static func previewChannelId(accountId: AccountRecordId, peerId: PeerId) -> String? {
        guard let sync = MattermostSync.sync(accountId: accountId) else {
            return nil
        }
        return sync.state.with { $0.previewChannels[peerId]?.id }
    }

    /// Joins a public channel; returns its chat once written.
    public static func joinChannel(accountId: AccountRecordId, channelId: String) -> Signal<PeerId, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.joinChannel(channelId: channelId)
        }
    }

    /// Creates a channel (`POST /channels`); returns its chat once written.
    public static func createChannel(accountId: AccountRecordId, channel: MattermostNewChannel) -> Signal<PeerId, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.createChannel(channel)
        }
    }

    /// The channel's settings from the server, with the user's access.
    public static func channelSettings(accountId: AccountRecordId, peerId: PeerId) -> Signal<MattermostChannelSettings, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.channelSettings(peerId: peerId)
        }
    }

    /// Changes the given fields (`PUT /channels/{id}/patch`; nil fields are kept).
    public static func updateChannel(accountId: AccountRecordId, peerId: PeerId, displayName: String?, urlName: String?, purpose: String?, header: String?) -> Signal<Void, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            try await sync.updateChannel(peerId: peerId, patch: ChannelPatch(displayName: displayName, name: urlName, purpose: purpose, header: header))
        }
    }

    public static func archiveChannel(accountId: AccountRecordId, peerId: PeerId) -> Signal<Void, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            try await sync.setChannelArchived(peerId: peerId, archived: true)
        }
    }

    public static func unarchiveChannel(accountId: AccountRecordId, peerId: PeerId) -> Signal<Void, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            try await sync.setChannelArchived(peerId: peerId, archived: false)
        }
    }

    public static func convertToPrivate(accountId: AccountRecordId, peerId: PeerId) -> Signal<Void, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            try await sync.convertToPrivate(peerId: peerId)
        }
    }

    // MARK: Members

    /// Adds users to a channel one by one; returns the users the server refused, with its message.
    public static func addMembers(accountId: AccountRecordId, channelPeerId: PeerId, userPeerIds: [PeerId]) -> Signal<[(PeerId, String)], MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            return try await sync.addMembers(channelPeerId: channelPeerId, userPeerIds: userPeerIds)
        }
    }

    public static func removeMember(accountId: AccountRecordId, channelPeerId: PeerId, memberPeerId: PeerId) -> Signal<Void, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            try await sync.removeMember(channelPeerId: channelPeerId, memberPeerId: memberPeerId)
        }
    }

    /// Makes a member a channel admin (`isAdmin`) or a plain member again.
    public static func setMemberAdmin(accountId: AccountRecordId, channelPeerId: PeerId, memberPeerId: PeerId, isAdmin: Bool) -> Signal<Void, MattermostDirectoryError> {
        return self.run(accountId: accountId) { sync in
            try await sync.setMemberAdmin(channelPeerId: channelPeerId, memberPeerId: memberPeerId, isAdmin: isAdmin)
        }
    }

    // MARK: Running

    static func run<T>(accountId: AccountRecordId, _ body: @escaping (MattermostAccountSync) async throws -> T) -> Signal<T, MattermostDirectoryError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = MattermostSync.sync(accountId: accountId), !sync.isStopped else {
                    subscriber.putError(.unavailable)
                    return
                }
                await sync.waitUntilBootstrapped()
                do {
                    let value = try await body(sync)
                    if !Task.isCancelled {
                        subscriber.putNext(value)
                        subscriber.putCompletion()
                    }
                } catch {
                    if !Task.isCancelled {
                        subscriber.putError(MattermostDirectory.mapError(error))
                    }
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    static func mapError(_ error: Error) -> MattermostDirectoryError {
        if let error = error as? MattermostDirectoryError {
            return error
        }
        if let error = error as? MattermostError {
            switch error {
            case .transport:
                return .network
            default:
                if let id = error.appError?.id, id == "store.sql_channel.save_channel.exists.app_error" || id == "store.sql_channel.update.exists.app_error" {
                    return .urlNameTaken
                }
                return .server(describeError(error))
            }
        }
        return .server(describeError(error))
    }
}

extension MattermostAccountSync {
    /// The Mattermost user of a user peer the sync wrote.
    func userId(forPeerId peerId: PeerId) -> String? {
        if peerId == self.ownPeerId {
            return self.ownUserId
        }
        guard peerId.namespace == Namespaces.Peer.CloudUser, let peer = self.store.peer(namespace: .user, peerId: peerId.id._internalGetInt64Value()), peer.kind == .user else {
            return nil
        }
        return peer.mattermostId
    }

    private func channelStateOrThrow(_ peerId: PeerId) throws -> ChannelState {
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
            throw MattermostDirectoryError.server("This chat is not a Mattermost channel you are in.")
        }
        return channelState
    }

    // MARK: Users

    /// Whether the server lets users message only members of their teams (`RestrictDirectMessage: team`).
    private func directoryTeamScope() async -> String? {
        if let cached = self.directoryScope.current {
            return cached.isEmpty ? nil : cached
        }
        let restricted = (try? await self.client.clientConfig())?["RestrictDirectMessage"] == "team"
        let scope = restricted ? (self.state.with { $0.teams.first?.id } ?? "") : ""
        self.directoryScope.with { $0 = scope }
        return scope.isEmpty ? nil : scope
    }

    func directoryUsers(query: String, page: Int, notInChannelPeerId: PeerId?) async throws -> MattermostUserPage {
        let perPage = 60
        var teamId: String?
        var notInChannelId: String?
        if let channelPeerId = notInChannelPeerId {
            let channelState = try self.channelStateOrThrow(channelPeerId)
            teamId = self.teamId(for: channelState)
            notInChannelId = channelState.channel.id
        } else {
            teamId = await self.directoryTeamScope()
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let found: [User]
        let hasMore: Bool
        if trimmed.isEmpty {
            found = try await self.client.users(UserListOptions(inTeamId: teamId, notInChannelId: notInChannelId, active: true, page: page, perPage: perPage))
            hasMore = found.count == perPage
        } else {
            if page > 0 {
                return MattermostUserPage(users: [], hasMore: false)
            }
            found = try await self.client.searchUsers(UserSearchOptions(term: trimmed, teamId: teamId, notInChannelId: notInChannelId, allowInactive: false, limit: 100))
            hasMore = false
        }
        let users = found.filter { $0.id != self.ownUserId && !$0.isDeactivated }
        let result: [MattermostDirectoryUser] = await self.postbox.mmTransaction { transaction in
            self.writeUsers(users, transaction: transaction)
            return users.compactMap { user -> MattermostDirectoryUser? in
                guard let peerId = self.userPeerId(user.id), let peer = transaction.getPeer(peerId) else {
                    return nil
                }
                return MattermostDirectoryUser(peer: EnginePeer(peer), userId: user.id, username: user.username, nickname: user.nickname, position: user.position, isBot: user.isBot)
            }
        }
        return MattermostUserPage(users: result, hasMore: hasMore)
    }

    func openDirectMessage(userPeerId: PeerId) async throws -> PeerId {
        guard let userId = self.userId(forPeerId: userPeerId) else {
            throw MattermostDirectoryError.server("Unknown user.")
        }
        let channel = try await self.client.createDirectChannel(userId: self.ownUserId, otherUserId: userId)
        if self.channelState(channel.id) == nil {
            await self.refreshChannel(channel.id)
            await self.showDirectChat(channelId: channel.id)
        }
        MMLog.log("directory: DM \(channel.id) with \(userId) opened")
        return userPeerId
    }

    func createGroupMessage(userPeerIds: [PeerId]) async throws -> PeerId {
        let userIds = userPeerIds.compactMap { self.userId(forPeerId: $0) }.filter { $0 != self.ownUserId }
        guard userIds.count >= 2, userIds.count <= 7 else {
            throw MattermostDirectoryError.server("A group message has 3 to 8 members.")
        }
        let channel = try await self.client.createGroupChannel(userIds: [self.ownUserId] + userIds)
        await self.ensureUsers(Set(userIds))
        await self.refreshChannel(channel.id)
        await self.showDirectChat(channelId: channel.id)
        guard let peerId = self.channelState(channel.id)?.peerId else {
            throw MattermostDirectoryError.server("The group message could not be loaded.")
        }
        MMLog.log("directory: group message \(channel.id) with \(userIds.count) others")
        return peerId
    }

    // MARK: Channels

    func browseChannels(teamId: String, query: String, archived: Bool, page: Int) async throws -> MattermostChannelPage {
        let perPage = 60
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var channels: [Channel]
        var hasMore = false
        if trimmed.isEmpty {
            channels = archived ? try await self.client.archivedChannels(teamId: teamId, page: page, perPage: perPage) : try await self.client.publicChannels(teamId: teamId, page: page, perPage: perPage)
            hasMore = channels.count == perPage
        } else {
            if page > 0 {
                return MattermostChannelPage(channels: [], hasMore: false)
            }
            channels = archived ? try await self.client.searchArchivedChannels(teamId: teamId, term: trimmed) : try await self.client.searchChannels(teamId: teamId, term: trimmed)
        }
        channels = channels.filter { ($0.type == .publicChannel || $0.type == .privateChannel) && $0.isArchived == archived }
        var counts: [String: Int64] = [:]
        if !channels.isEmpty {
            counts = (try? await self.client.channelMemberCounts(channelIds: channels.map(\.id))) ?? [:]
        }
        let result = channels.enumerated().map { index, channel -> MattermostBrowsedChannel in
            return self.browsedChannel(channel, memberCount: counts[channel.id], index: page * perPage + index)
        }
        return MattermostChannelPage(channels: result, hasMore: hasMore)
    }

    /// A channel as Browse Channels and its preview show it; `index` picks an in-memory peer id for the avatar.
    private func browsedChannel(_ channel: Channel, memberCount: Int64?, index: Int) -> MattermostBrowsedChannel {
        let title = channel.displayName.isEmpty ? channel.name : channel.displayName
        let memberPeerId = self.channelState(channel.id)?.peerId
        let previewPeerId = memberPeerId ?? MattermostPeerIds.channelPeerId(MattermostPeerIds.suggestionPeerIdValue(Int64(index)))
        return MattermostBrowsedChannel(
            id: channel.id,
            teamId: channel.teamId,
            name: channel.name,
            displayName: title,
            purpose: channel.purpose,
            header: MattermostMarkdown.parse(channel.header).text,
            memberCount: memberCount,
            isArchived: channel.isArchived,
            isPrivate: channel.type == .privateChannel,
            memberPeerId: memberPeerId,
            previewPeer: EnginePeer(PeerConverter.channel(channel, title: title, peerId: previewPeerId))
        )
    }

    func channelPreview(channelId: String) async throws -> MattermostBrowsedChannel {
        let channel = try await self.client.channel(id: channelId)
        let counts = (try? await self.client.channelMemberCounts(channelIds: [channelId])) ?? [:]
        return self.browsedChannel(channel, memberCount: counts[channelId], index: 0)
    }

    func previewPosts(channelId: String, limit: Int) async throws -> [MattermostPreviewPost] {
        let list = try await self.client.posts(channelId: channelId, perPage: 60)
        let posts = list.order.compactMap { list.posts[$0] }.filter { $0.rootId.isEmpty && !$0.type.hasPrefix("system_") && $0.deleteAt == 0 }
        let recent = Array(posts.prefix(limit))
        await self.ensureUsers(Set(recent.map(\.userId)))
        return recent.reversed().compactMap { post -> MattermostPreviewPost? in
            var text = MattermostMarkdown.parse(post.message).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                let files = post.metadata?.files ?? []
                if files.isEmpty {
                    return nil
                }
                text = files.map { "📎 " + $0.name }.joined(separator: "\n")
            }
            let author = self.state.with { state in state.users[post.userId].map(PeerConverter.displayName) } ?? ""
            return MattermostPreviewPost(id: post.id, author: author, text: text, date: Date(timeIntervalSince1970: Double(post.createAt) / 1000.0))
        }
    }

    func joinChannel(channelId: String) async throws -> PeerId {
        if let peerId = self.channelState(channelId)?.peerId {
            return peerId
        }
        try await self.client.addChannelMember(channelId: channelId, userId: self.ownUserId)
        await self.refreshChannel(channelId)
        guard let peerId = self.channelState(channelId)?.peerId else {
            throw MattermostDirectoryError.server("The channel could not be loaded.")
        }
        MMLog.log("directory: joined \(channelId)")
        return peerId
    }

    func createChannel(_ draft: MattermostNewChannel) async throws -> PeerId {
        let channel = try await self.client.createChannel(ChannelDraft(
            teamId: draft.teamId,
            name: draft.urlName,
            displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            type: draft.isPrivate ? .privateChannel : .publicChannel,
            purpose: draft.purpose,
            header: draft.header
        ))
        await self.refreshChannel(channel.id)
        guard let peerId = self.channelState(channel.id)?.peerId else {
            throw MattermostDirectoryError.server("The channel was created but could not be loaded.")
        }
        MMLog.log("directory: created \(channel.type.rawValue) channel \(channel.id) in \(draft.teamId)")
        return peerId
    }

    func channelSettings(peerId: PeerId) async throws -> MattermostChannelSettings {
        let channelState = try self.channelStateOrThrow(peerId)
        let channel = try await self.client.channel(id: channelState.channel.id)
        let team = self.state.with { state in state.teams.first(where: { $0.id == channel.teamId }) }
        let access = self.channelAccess(channel: channel, member: channelState.member, teamId: channelState.teamId)
        var link = self.server.url
        while link.hasSuffix("/") {
            link.removeLast()
        }
        if let team {
            link += "/\(team.name)/channels/\(channel.name)"
        }
        return MattermostChannelSettings(
            channelId: channel.id,
            teamId: channel.teamId,
            teamName: team?.name ?? "",
            teamDisplayName: team?.displayName ?? "",
            displayName: channel.displayName,
            urlName: channel.name,
            purpose: channel.purpose,
            header: channel.header,
            isPrivate: channel.type == .privateChannel,
            isArchived: channel.isArchived,
            access: access,
            link: link
        )
    }

    func updateChannel(peerId: PeerId, patch: ChannelPatch) async throws {
        let channelState = try self.channelStateOrThrow(peerId)
        try await self.client.patchChannel(id: channelState.channel.id, patch: patch)
        await self.refreshChannel(channelState.channel.id)
        MMLog.log("directory: updated \(channelState.channel.id) (\(patch))")
    }

    func setChannelArchived(peerId: PeerId, archived: Bool) async throws {
        let channelState = try self.channelStateOrThrow(peerId)
        if archived {
            try await self.client.archiveChannel(id: channelState.channel.id)
        } else {
            try await self.client.restoreChannel(id: channelState.channel.id)
        }
        await self.refreshChannel(channelState.channel.id)
        MMLog.log("directory: \(archived ? "archived" : "restored") \(channelState.channel.id)")
    }

    func convertToPrivate(peerId: PeerId) async throws {
        let channelState = try self.channelStateOrThrow(peerId)
        try await self.client.updateChannelPrivacy(id: channelState.channel.id, type: .privateChannel)
        await self.refreshChannel(channelState.channel.id)
        MMLog.log("directory: \(channelState.channel.id) converted to private")
    }

    // MARK: Members

    func addMembers(channelPeerId: PeerId, userPeerIds: [PeerId]) async throws -> [(PeerId, String)] {
        let channelState = try self.channelStateOrThrow(channelPeerId)
        var failed: [(PeerId, String)] = []
        for userPeerId in userPeerIds {
            guard let userId = self.userId(forPeerId: userPeerId) else {
                failed.append((userPeerId, "Unknown user."))
                continue
            }
            do {
                try await self.client.addChannelMember(channelId: channelState.channel.id, userId: userId)
                // The `user_added` event updates the member count and open member lists as well; announce now so
                // the list the user is looking at doesn't wait for it.
                await self.announceMemberAdded(channelId: channelState.channel.id, userId: userId)
            } catch let error as MattermostError where error.isTransient {
                throw error
            } catch {
                failed.append((userPeerId, describeError(error)))
            }
        }
        await self.refreshMemberCounts([channelState.channel.id])
        MMLog.log("directory: added \(userPeerIds.count - failed.count) member(s) to \(channelState.channel.id), \(failed.count) refused")
        return failed
    }

    func removeMember(channelPeerId: PeerId, memberPeerId: PeerId) async throws {
        let channelState = try self.channelStateOrThrow(channelPeerId)
        guard let userId = self.userId(forPeerId: memberPeerId) else {
            throw MattermostDirectoryError.server("Unknown user.")
        }
        try await self.client.removeChannelMember(channelId: channelState.channel.id, userId: userId)
        self.announceMemberRemoved(channelId: channelState.channel.id, userId: userId)
        await self.refreshMemberCounts([channelState.channel.id])
        MMLog.log("directory: removed \(userId) from \(channelState.channel.id)")
    }

    func setMemberAdmin(channelPeerId: PeerId, memberPeerId: PeerId, isAdmin: Bool) async throws {
        let channelState = try self.channelStateOrThrow(channelPeerId)
        guard let userId = self.userId(forPeerId: memberPeerId) else {
            throw MattermostDirectoryError.server("Unknown user.")
        }
        try await self.client.updateChannelMemberSchemeRoles(channelId: channelState.channel.id, userId: userId, isAdmin: isAdmin)
        // Others' role changes send no event to this user: refresh the member in the open lists (an admin gets
        // the "admin" label).
        await self.announceMemberAdded(channelId: channelState.channel.id, userId: userId)
        if userId == self.ownUserId {
            await self.refreshChannel(channelState.channel.id)
        }
        MMLog.log("directory: \(userId) is \(isAdmin ? "now" : "no longer") an admin of \(channelState.channel.id)")
    }

    /// A DM or group message that (re)appears with a new post: `direct_channel_show` / `group_channel_show` back to
    /// true (as Mattermost's web app does), or the next bootstrap would hide it again.
    func showDirectChat(channelId: String) async {
        guard let channelState = self.channelState(channelId) else {
            return
        }
        let preference: Preference
        switch channelState.channel.type {
        case .directMessage:
            guard let partnerId = channelState.channel.directMessagePartnerId(myUserId: self.ownUserId), partnerId != self.ownUserId else {
                return
            }
            preference = Preference(userId: self.ownUserId, category: PreferenceCategory.directChannelShow, name: partnerId, value: "true")
        case .groupMessage:
            preference = Preference(userId: self.ownUserId, category: PreferenceCategory.groupChannelShow, name: channelId, value: "true")
        default:
            return
        }
        do {
            try await self.client.savePreferences([preference])
        } catch {
            MMLog.log("directory: could not show \(channelId) again: \(describeError(error))")
        }
    }

    /// `direct_channel_show` / `group_channel_show` changed on another client (4F, `preferences_changed`): a DM or
    /// group message closed there leaves the chat list at once and is forgotten, as after closing it here (its next
    /// post brings it back); one opened again there comes back.
    func applyDirectChannelVisibility(_ preferences: [Preference]) async {
        for preference in preferences where preference.category == PreferenceCategory.directChannelShow || preference.category == PreferenceCategory.groupChannelShow {
            let isDirect = preference.category == PreferenceCategory.directChannelShow
            if isDirect && preference.name == self.ownUserId {
                continue
            }
            let ownUserId = self.ownUserId
            let known = self.state.with { state -> ChannelState? in
                if isDirect {
                    return state.channels.values.first(where: { $0.channel.type == .directMessage && $0.channel.directMessagePartnerId(myUserId: ownUserId) == preference.name })
                } else {
                    return state.channels[preference.name]
                }
            }
            if preference.value == "false" {
                guard let channelState = known else {
                    continue
                }
                await self.postbox.mmTransaction { transaction in
                    transaction.updatePeerChatListInclusion(channelState.peerId, inclusion: .notIncluded)
                }
                self.state.with { state in
                    state.channels.removeValue(forKey: channelState.channel.id)
                    state.channelIdByPeerId.removeValue(forKey: channelState.peerId)
                }
                MMLog.log("live: \(isDirect ? "DM" : "group message") \(channelState.channel.id) closed on another client")
            } else if preference.value == "true", known == nil {
                var channelId = preference.name
                if isDirect {
                    await self.ensureUsers([preference.name])
                    guard let channel = try? await self.client.createDirectChannel(userId: ownUserId, otherUserId: preference.name) else {
                        continue
                    }
                    channelId = channel.id
                }
                await self.refreshChannel(channelId)
                MMLog.log("live: \(isDirect ? "DM" : "group message") \(channelId) opened on another client")
            }
        }
    }

    // MARK: Leaving and closing (Telegram's Leave / Delete Chat)

    /// `CloudChatRemoveChatOperation` (Telegram's Leave Group and Delete Chat, after its own confirmation): the chat
    /// already left the chat list. A channel is left on the server (`DELETE /channels/{id}/members/me`); a refusal
    /// (town square) puts the chat back with a notice. A DM or group message is closed for the user
    /// (`direct_channel_show` / `group_channel_show` = false, as Mattermost's "Close"); a new message opens it
    /// again.
    func removeChat(peerId: PeerId) async {
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
            MMLog.log("leave: \(peerId) is not a known chat")
            return
        }
        switch channelState.channel.type {
        case .publicChannel, .privateChannel:
            do {
                try await self.retryingTransient("leave \(channelId)", isStillWanted: { true }) {
                    try await self.client.removeChannelMember(channelId: channelId)
                }
                MMLog.log("leave: left \(channelId)")
                await self.applyOwnRemoval(channelId: channelId)
            } catch {
                MMLog.log("leave: \(channelId) refused (\(describeError(error))); putting the chat back")
                await self.refreshChannel(channelId)
                self.notice(.leaveFailed(detail: describeError(error)))
            }
        case .directMessage, .groupMessage:
            let isDirect = channelState.channel.type == .directMessage
            let name: String
            if isDirect {
                name = channelState.channel.directMessagePartnerId(myUserId: self.ownUserId) ?? ""
            } else {
                name = channelId
            }
            if name.isEmpty || name == self.ownUserId {
                return
            }
            let preference = Preference(userId: self.ownUserId, category: isDirect ? PreferenceCategory.directChannelShow : PreferenceCategory.groupChannelShow, name: name, value: "false")
            do {
                try await self.retryingTransient("close \(channelId)", isStillWanted: { true }) {
                    try await self.client.savePreferences([preference])
                }
                // Forget the chat: its next post (`posted`) loads it again, with a chat-list inclusion.
                self.state.with { state in
                    state.channels.removeValue(forKey: channelId)
                    state.channelIdByPeerId.removeValue(forKey: peerId)
                }
                MMLog.log("leave: closed \(isDirect ? "DM" : "group message") \(channelId)")
            } catch {
                MMLog.log("leave: closing \(channelId) failed: \(describeError(error))")
            }
        default:
            break
        }
    }
}

extension MattermostSync {
    /// The server address of an account loaded in this process (running or expired).
    public static func serverURL(accountId: AccountRecordId) -> String? {
        return self.registry.with { $0[accountId]?.server.url }
    }
}
