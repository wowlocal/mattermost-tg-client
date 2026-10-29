import Foundation
import Postbox
import MattermostKit
import MattermostSyncCore

// Invite People: bringing people into a team, as Mattermost's apps do. The team's invite link (anyone with it can
// join the team, signing up first when the server allows new accounts), adding users who already have an account
// on the server, and email invitations. What the user may do comes from `TeamInviteRules`; the server still
// decides, and its refusals are shown per user or address. Nothing here changes the user's own chats: the people
// added join the team's default channels, which the open member lists learn from the WebSocket events.

extension MattermostAccountSync {
    func teamInvite(teamId: String) async throws -> MattermostTeamInvite {
        let team = try await self.client.team(id: teamId)
        let config = try? await self.client.clientConfig()
        let rules = TeamInviteRules.evaluate(
            permissions: self.teamPermissions(teamId: teamId),
            inviteId: team.inviteId,
            groupConstrained: team.groupConstrained ?? false,
            emailInvitationsEnabled: config?.enableEmailInvitations ?? false
        )
        return MattermostTeamInvite(
            teamId: team.id,
            teamDisplayName: team.displayName.isEmpty ? team.name : team.displayName,
            inviteLink: rules.canShareLink ? TeamInviteRules.inviteLink(serverURL: self.server.url, inviteId: team.inviteId) : nil,
            allowsSignUp: config?.enableUserCreation ?? true,
            canAddMembers: rules.canAddMembers,
            canInviteByEmail: rules.canInviteByEmail
        )
    }

    func addTeamMembers(teamId: String, userPeerIds: [PeerId]) async throws -> [(PeerId, String)] {
        var failed: [(PeerId, String)] = []
        var peerIdsByUserId: [String: PeerId] = [:]
        var userIds: [String] = []
        for userPeerId in userPeerIds {
            guard let userId = self.userId(forPeerId: userPeerId) else {
                failed.append((userPeerId, "Unknown user."))
                continue
            }
            peerIdsByUserId[userId] = userPeerId
            userIds.append(userId)
        }
        if !userIds.isEmpty {
            // One request (graceful): the users the server refuses come back with its error, the others are added.
            let results = try await self.client.addTeamMembers(teamId: teamId, userIds: userIds)
            for result in results {
                if let error = result.error, let peerId = peerIdsByUserId[result.userId] {
                    failed.append((peerId, error.errorDescription ?? error.id))
                }
            }
        }
        MMLog.log("directory: added \(userIds.count - failed.count) user(s) to team \(teamId), \(failed.count) refused")
        return failed
    }

    func inviteByEmail(teamId: String, emails: [String]) async throws -> [(String, String)] {
        let results = try await self.client.inviteToTeam(teamId: teamId, emails: emails)
        let failed = results.compactMap { result -> (String, String)? in
            return result.error.map { (result.email, $0.errorDescription ?? $0.id) }
        }
        // Counts only: the addresses are other people's.
        MMLog.log("directory: emailed \(emails.count - failed.count) invitation(s) to team \(teamId), \(failed.count) refused")
        return failed
    }
}
