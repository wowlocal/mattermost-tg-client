import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// The teams and channels (channels and group messages) the chat list held after the last bootstrap or catch-up
/// (`member_chats` cursor), to notice what the user left while the app wasn't listening (Phase 4B).
struct MemberChats: Codable {
    var teams: [String] = []
    var channels: [String] = []
}

extension MattermostAccountSync {
    static let memberChatsCursor = "member_chats"

    /// Takes the chats of channels the user is no longer a member of out of the chat list, and the folders of teams
    /// the user left (Phase 4B). Removing a user from a team sends no `user_removed` per channel, and memberships that
    /// ended while the app wasn't running were never noticed: their chats and team folder stayed. `channelIds`: every
    /// channel and group message the user is a member of now (DMs are user peers and are never removed here).
    func reconcileMembership(teams: [Team], channelIds: Set<String>) async {
        let previous: MemberChats = await self.postbox.mmTransaction { transaction in
            if let text = self.store.cursor(MattermostAccountSync.memberChatsCursor), let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(MemberChats.self, from: data) {
                return value
            }
            // No record yet (data from before 4B): the channels in the chat list.
            var value = MemberChats()
            for groupId in [PeerGroupId.root, Namespaces.PeerGroup.archive] {
                for peer in transaction.getChatListPeers(groupId: groupId, filterPredicate: nil, additionalFilter: nil) where peer.id.namespace == Namespaces.Peer.CloudChannel {
                    if let mattermostPeer = self.store.peer(namespace: .channel, peerId: peer.id.id._internalGetInt64Value()) {
                        value.channels.append(mattermostPeer.mattermostId)
                    }
                }
            }
            return value
        }
        let teamIds = Set(teams.map { $0.id })
        let removedChannels = Set(previous.channels).subtracting(channelIds)
        // Teams left: those recorded, and those of the channels left (data from before 4B has no team record).
        var formerTeams = Set(previous.teams)
        for channelId in removedChannels {
            if let teamId = self.store.peer(mattermostId: channelId)?.teamId, !teamId.isEmpty {
                formerTeams.insert(teamId)
            }
        }
        let removedTeams = formerTeams.subtracting(teamIds)
        if !removedChannels.isEmpty {
            let peers: [(channelId: String, peerId: PeerId)] = removedChannels.compactMap { channelId in
                guard let peer = self.store.peer(mattermostId: channelId), peer.kind == .channel || peer.kind == .groupMessage else {
                    return nil
                }
                return (channelId, MattermostPeerIds.channelPeerId(peer.peerId))
            }
            await self.postbox.mmTransaction { transaction in
                for item in peers {
                    transaction.updatePeerChatListInclusion(item.peerId, inclusion: .notIncluded)
                }
            }
            self.state.with { state in
                for item in peers {
                    state.channels.removeValue(forKey: item.channelId)
                    state.channelIdByPeerId.removeValue(forKey: item.peerId)
                }
                for (teamId, favorites) in state.favoritesByTeam {
                    state.favoritesByTeam[teamId] = favorites.filter { !removedChannels.contains($0) }
                }
            }
            self.clearStale(Array(removedChannels))
        }
        if !removedTeams.isEmpty {
            let folderIds: [String: Int32] = await self.postbox.mmTransaction { _ in
                var result: [String: Int32] = [:]
                for teamId in removedTeams {
                    if let value = self.store.cursor(MattermostCursorKey.folderId(teamId: teamId)), let id = Int32(value) {
                        result[teamId] = id
                    }
                    self.store.setCursor(MattermostCursorKey.folderId(teamId: teamId), nil)
                }
                return result
            }
            if !folderIds.isEmpty {
                let ids = Set(folderIds.values)
                let engine = TelegramEngine(account: self.account)
                let _ = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let _ = engine.peers.updateChatListFiltersInteractively({ filters in
                        return filters.filter { !ids.contains($0.id) }
                    }).start(completed: {
                        continuation.resume()
                    })
                }
            }
            self.state.with { state in
                for teamId in removedTeams {
                    state.folderPins.removeValue(forKey: teamId)
                    state.favoritesByTeam.removeValue(forKey: teamId)
                    state.threads.removeValue(forKey: teamId)
                }
            }
        }
        let current = MemberChats(teams: teams.map { $0.id }.sorted(), channels: channelIds.sorted())
        let text = (try? JSONEncoder().encode(current)).flatMap { String(data: $0, encoding: .utf8) }
        await self.postbox.mmTransaction { _ in
            self.store.setCursor(MattermostAccountSync.memberChatsCursor, text)
        }
        if !removedChannels.isEmpty || !removedTeams.isEmpty {
            MMLog.log("membership: \(removedChannels.count) chat(s) and \(removedTeams.count) team(s) left; removed from the chat list")
        }
    }
}
