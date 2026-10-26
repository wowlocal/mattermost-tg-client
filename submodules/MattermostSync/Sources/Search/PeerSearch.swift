import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// People and channel search for the chat list search (Phase 3C). Telegram shows its local matches (chats in
/// Postbox) first; this adds the server's:
/// - users (`POST /users/search`): written as peers, so a row opens the DM (sending creates the DM channel);
///   users with a DM go with the user's chats (`myResults`), the others under "Global Search";
/// - public channels of every team (`POST /teams/{id}/channels/search`): joined ones with the user's chats,
///   not-joined ones as "Global Search" previews (a `TelegramChannel` with `participationStatus: .left`, no
///   chat-list inclusion, a stable peer id from the peers table). Opening one asks to join first
///   (`MattermostSync.joinPublicChannel`).
extension MattermostAccountSync {
    func searchPeers(query: String, scope: TelegramSearchPeersScope) async -> (myResults: [FoundPeer], otherResults: [FoundPeer]) {
        var term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = term.first, first == "@" || first == "~" {
            term.removeFirst()
        }
        guard !term.isEmpty else {
            return ([], [])
        }
        await self.waitUntilBootstrapped()
        let wantsUsers: Bool
        let wantsChannels: Bool
        switch scope {
        case .everywhere:
            wantsUsers = true
            wantsChannels = true
        case .privateChats:
            wantsUsers = true
            wantsChannels = false
        case .channels, .groups:
            wantsUsers = false
            wantsChannels = true
        case .bots, .globalPosts:
            return ([], [])
        }

        var users: [User] = []
        if wantsUsers {
            do {
                users = try await self.client.searchUsers(UserSearchOptions(term: term, allowInactive: false, limit: 20))
                users = users.filter { $0.deleteAt == 0 && $0.id != self.ownUserId }
            } catch {
                MMLog.log("search: users \"\(term)\" failed: \(error)")
            }
        }
        var channels: [Channel] = []
        if wantsChannels {
            for team in self.state.with({ $0.teams }) {
                do {
                    let found = try await self.client.searchChannels(teamId: team.id, term: term)
                    channels.append(contentsOf: found.filter { $0.deleteAt == 0 && $0.type == .publicChannel })
                } catch {
                    MMLog.log("search: channels \"\(term)\" in \(team.id) failed: \(error)")
                }
            }
        }

        let result: (myResults: [FoundPeer], otherResults: [FoundPeer]) = await self.postbox.mmTransaction { transaction in
            self.writeUsers(users, transaction: transaction)
            var myResults: [FoundPeer] = []
            var otherResults: [FoundPeer] = []
            for user in users {
                guard let peerId = self.userPeerId(user.id), let peer = transaction.getPeer(peerId) else {
                    continue
                }
                let hasChat = self.store.directChannelId(userId: user.id).flatMap { self.channelState($0) } != nil
                if hasChat {
                    myResults.append(FoundPeer(peer: EnginePeer(peer), subscribers: nil))
                } else {
                    otherResults.append(FoundPeer(peer: EnginePeer(peer), subscribers: nil))
                }
            }
            var seenChannels = Set<String>()
            for channel in channels where seenChannels.insert(channel.id).inserted {
                if let channelState = self.channelState(channel.id) {
                    if let peer = transaction.getPeer(channelState.peerId) {
                        myResults.append(FoundPeer(peer: EnginePeer(peer), subscribers: nil))
                    }
                    continue
                }
                guard let peer = self.writePreviewChannel(channel, transaction: transaction) else {
                    continue
                }
                otherResults.append(FoundPeer(peer: EnginePeer(peer), subscribers: nil))
            }
            return (myResults, otherResults)
        }
        MMLog.log("search: people/channels \"\(term)\" → \(users.count) user(s), \(channels.count) channel(s); \(result.myResults.count) mine, \(result.otherResults.count) other")
        return result
    }

    /// A public channel the user hasn't joined, as a peer that search rows can show (and keep across searches).
    func writePreviewChannel(_ channel: Channel, transaction: Transaction) -> Peer? {
        guard let stored = self.store.allocatePeer(mattermostId: channel.id, kind: .channel, teamId: channel.teamId.isEmpty ? nil : channel.teamId) else {
            return nil
        }
        let peerId = MattermostPeerIds.channelPeerId(stored.peerId)
        let title = channel.displayName.isEmpty ? channel.name : channel.displayName
        let peer = PeerConverter.channel(channel, title: title, peerId: peerId, participationStatus: .left)
        updatePeersCustom(transaction: transaction, peers: [peer], update: { _, updated in
            return updated
        })
        let about = channel.purpose.isEmpty ? channel.header : channel.purpose
        transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in
            return (current as? CachedChannelData ?? CachedChannelData())
                .withUpdatedAbout(about.isEmpty ? nil : about)
        })
        self.state.with { $0.previewChannels[peerId] = channel }
        return peer
    }

    /// Joins a public channel found by search (3D-2's `joinChannel`: `POST /channels/{id}/members`, then written
    /// like any channel the user is a member of). Returns the chat's peer.
    func joinPreviewChannel(peerId: PeerId) async -> PeerId? {
        if let channelId = self.channelId(forPeerId: peerId), self.channelState(channelId) != nil {
            return peerId
        }
        guard let channel = self.state.with({ $0.previewChannels[peerId] }) else {
            return nil
        }
        do {
            let joined = try await self.joinChannel(channelId: channel.id)
            self.state.with { $0.previewChannels[peerId] = nil }
            return joined
        } catch {
            MMLog.log("search: joining \(channel.id) failed: \(error)")
            return nil
        }
    }
}
