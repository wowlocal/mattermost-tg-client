import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Where a Mattermost link opens in the app (Phase 3E).
public enum MattermostLinkDestination: Equatable {
    /// A post: its chat at the post, or its thread (`threadId` = the root's local id) when it is a reply hidden
    /// by collapsed reply threads, or a thread link.
    case message(peerId: PeerId, threadId: Int64?, messageId: MessageId)
    /// A chat: a channel, a DM (created when needed), a group message, or a public channel the user hasn't
    /// joined (a preview peer: opening it asks to join, see TelegramUI `mattermostNavigateToChat`).
    case chat(peerId: PeerId)
    case failed(MattermostLinkFailure)
}

public enum MattermostLinkFailure: Equatable {
    /// The post is deleted, or in a channel the user can't read.
    case postNotFound
    /// No such channel, or a private one the user isn't in.
    case channelNotFound
    case userNotFound
    /// The server couldn't be asked (offline).
    case unreachable
}

/// A link into a signed-in server: the account and the route.
public struct MattermostLinkTarget: Equatable {
    public let accountId: AccountRecordId
    public let route: MattermostLinkRoute
}

/// Permalinks and app links (Phase 3E). A web link opens in the app when its host, port and path are a signed-in
/// server's (the URL used to log in, or the server's `SiteURL`); `relay://<host>[:port][/path]/<route>` and
/// `mattermost://…` links name the server the same way. With several accounts on one server, the current account
/// (`preferredAccountId`) wins.
public extension MattermostSync {
    static func linkTarget(url: String, preferredAccountId: AccountRecordId?) -> MattermostLinkTarget? {
        // Accounts and their server base URLs, the preferred account first.
        var bases: [(AccountRecordId, String)] = []
        let registered = self.registry.with { registry in registry.map { ($0.key, $0.value.server.url) } }
        let ordered = registered.sorted { lhs, rhs in
            if (lhs.0 == preferredAccountId) != (rhs.0 == preferredAccountId) {
                return lhs.0 == preferredAccountId
            }
            return lhs.0.int64 < rhs.0.int64
        }
        for (accountId, serverURL) in ordered {
            bases.append((accountId, serverURL))
            if let siteURL = self.sync(accountId: accountId)?.siteURL, !siteURL.isEmpty, siteURL != serverURL {
                bases.append((accountId, siteURL))
            }
        }
        guard let link = MattermostLink.parse(url, servers: bases.map { $0.1 }) else {
            return nil
        }
        return MattermostLinkTarget(accountId: bases[link.serverIndex].0, route: link.route)
    }

    /// Resolves a link of the account: maps (and stores) the post, finds or previews the channel, opens the DM.
    static func linkDestination(target: MattermostLinkTarget) -> Signal<MattermostLinkDestination, NoError> {
        return self.signal {
            guard let sync = await self.waitForRunningSync(accountId: target.accountId) else {
                return .failed(.unreachable)
            }
            let destination = await sync.linkDestination(route: target.route)
            MMLog.log("link: \(target.route) → \(destination)")
            return destination
        }
    }

    /// The web permalink of a message (Copy Link, Share): `<SiteURL or server>/<team>/pl/<post id>`, with the
    /// channel's team, or the user's first team for DMs and group messages (Mattermost resolves the team of a
    /// post on its own; any team of the user works). Nil for messages not on the server (sending, ephemeral).
    static func permalink(accountId: AccountRecordId, messageId: MessageId) -> String? {
        guard let sync = self.sync(accountId: accountId), messageId.namespace == Namespaces.Message.Cloud, let channelId = sync.channelId(forPeerId: messageId.peerId) else {
            return nil
        }
        guard let entry = sync.store.entries(channelId: channelId, fromLocalId: messageId.id, ascending: true, limit: 1).first, entry.localId == messageId.id, !entry.isDeleted else {
            return nil
        }
        let teams = sync.state.with { $0.teams }
        let teamId = sync.channelState(channelId)?.teamId ?? ""
        guard let team = teams.first(where: { $0.id == teamId }) ?? teams.first else {
            return nil
        }
        let base = sync.siteURL.flatMap { $0.isEmpty ? nil : $0 } ?? sync.server.url
        return MattermostLink.permalink(serverURL: base, teamName: team.name, postId: entry.serverPostId)
    }
}

extension MattermostAccountSync {
    /// The server's `SiteURL` (client config), which permalinks from other clients use.
    var siteURL: String? {
        return self.state.with { $0.siteURL }
    }

    func linkDestination(route: MattermostLinkRoute) async -> MattermostLinkDestination {
        switch route {
        case let .post(_, postId):
            return await self.postLinkDestination(postId: postId, asThread: false)
        case let .thread(_, rootId):
            return await self.postLinkDestination(postId: rootId, asThread: true)
        case let .channel(teamName, channelName):
            return await self.channelLinkDestination(teamName: teamName, channelName: channelName)
        case let .groupMessage(_, channelName):
            if let peerId = self.state.with({ state in state.channels.values.first(where: { $0.channel.name == channelName })?.peerId }) {
                return .chat(peerId: peerId)
            }
            return .failed(.channelNotFound)
        case let .directMessage(_, username):
            return await self.directMessageLinkDestination(username: username)
        }
    }

    private func postLinkDestination(postId: String, asThread: Bool) async -> MattermostLinkDestination {
        let post: Post
        do {
            post = try await self.client.post(id: postId)
        } catch let error as MattermostError {
            switch error {
            case .transport:
                return .failed(.unreachable)
            default:
                return .failed(.postNotFound)
            }
        } catch {
            return .failed(.unreachable)
        }
        guard post.deleteAt == 0 else {
            return .failed(.postNotFound)
        }
        guard let channelState = self.channelState(post.channelId) else {
            // A public channel the user isn't in: offer to join (the post itself can't be shown before that).
            return await self.previewChannelDestination(channelId: post.channelId)
        }
        await self.ensureUsers(referencedUserIds([post]))
        var threadId: Int64?
        let rootId = post.rootId.isEmpty ? (asThread ? post.id : nil) : post.rootId
        if channelState.kind != .saved, self.isCollapsedThreads, let rootId = rootId, let rootLocalId = await self.notificationLocalId(postId: rootId, channelId: post.channelId) {
            threadId = Int64(rootLocalId)
        }
        guard let localId = await self.notificationLocalId(postId: post.id, channelId: post.channelId) else {
            return .failed(.postNotFound)
        }
        return .message(peerId: channelState.peerId, threadId: threadId, messageId: MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: localId))
    }

    private func channelLinkDestination(teamName: String?, channelName: String) async -> MattermostLinkDestination {
        let teams = self.state.with { $0.teams }
        let team = teamName.flatMap { name in teams.first(where: { $0.name == name }) }
        // A channel the user is in: in the named team (DMs and group messages have none), or in any team for
        // `_redirect` links and unknown team names.
        let known = self.state.with { state -> PeerId? in
            let candidates = state.channels.values.filter { $0.channel.name == channelName }
            if let team = team, let match = candidates.first(where: { $0.teamId == team.id || $0.channel.teamId.isEmpty }) {
                return match.peerId
            }
            return candidates.first?.peerId
        }
        if let peerId = known {
            return .chat(peerId: peerId)
        }
        for candidate in (team.map { [$0] } ?? teams) {
            do {
                let channel = try await self.client.channel(teamId: candidate.id, name: channelName)
                if let channelState = self.channelState(channel.id) {
                    return .chat(peerId: channelState.peerId)
                }
                return await self.previewChannelDestination(channelId: channel.id, channel: channel)
            } catch let error as MattermostError {
                if case .transport = error {
                    return .failed(.unreachable)
                }
                continue
            } catch {
                continue
            }
        }
        return .failed(.channelNotFound)
    }

    private func previewChannelDestination(channelId: String, channel: Channel? = nil) async -> MattermostLinkDestination {
        var channel = channel
        if channel == nil {
            channel = try? await self.client.channel(id: channelId)
        }
        guard let channel = channel, channel.type == .publicChannel, channel.deleteAt == 0 else {
            return .failed(channel == nil ? .postNotFound : .channelNotFound)
        }
        let peerId: PeerId? = await self.postbox.mmTransaction { transaction in
            return self.writePreviewChannel(channel, transaction: transaction)?.id
        }
        guard let peerId = peerId else {
            return .failed(.channelNotFound)
        }
        return .chat(peerId: peerId)
    }

    private func directMessageLinkDestination(username: String) async -> MattermostLinkDestination {
        if username == self.ownUsername.lowercased() {
            return .chat(peerId: self.ownPeerId)
        }
        var userId = self.state.with { $0.userIdByUsername[username] }
        if userId == nil {
            do {
                let users = try await self.client.users(usernames: [username])
                if let user = users.first {
                    await self.postbox.mmTransaction { transaction in
                        self.writeUsers([user], transaction: transaction)
                    }
                    userId = user.id
                }
            } catch let error as MattermostError {
                if case .transport = error {
                    return .failed(.unreachable)
                }
            } catch {
                return .failed(.unreachable)
            }
        }
        guard let userId = userId, let userPeerId = self.userPeerId(userId) else {
            return .failed(.userNotFound)
        }
        do {
            return .chat(peerId: try await self.openDirectMessage(userPeerId: userPeerId))
        } catch {
            // The chat still opens; the DM channel is created with the first message.
            return .chat(peerId: userPeerId)
        }
    }
}
