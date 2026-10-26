import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

extension MattermostAccountSync {
    /// Member counts of channels and group messages for the chat title ("N members" instead of "group"):
    /// `GET /channels/{id}/stats`, written as the channel's `CachedChannelData.participantsSummary`.
    /// Refreshed after the bootstrap and whenever a channel is rewritten or someone joins or leaves it.
    ///
    /// The member list of the group info screen is not fed from here: Telegram's members pane loads
    /// supergroup members through `ChannelMemberListContext` (`channels.getParticipants`), which has no
    /// cached-data path to hook without a TelegramCore change.
    func refreshMemberCounts(_ channelIds: [String]) async {
        let targets = channelIds.filter { self.channelState($0)?.kind == .channel }
        if targets.isEmpty {
            return
        }
        let counts = MMLocked<[String: Int64]>([:])
        try? await self.forEachConcurrently(targets, limit: 6) { channelId in
            do {
                let stats = try await self.client.channelStats(channelId: channelId)
                counts.with { $0[channelId] = stats.memberCount }
            } catch {
                MMLog.log("members: stats of \(channelId) failed: \(error)")
            }
        }
        let values = counts.current
        if values.isEmpty {
            return
        }
        await self.postbox.mmTransaction { transaction in
            for (channelId, count) in values {
                guard let channelState = self.channelState(channelId) else {
                    continue
                }
                transaction.updatePeerCachedData(peerIds: [channelState.peerId], update: { _, current in
                    let data = current as? CachedChannelData ?? CachedChannelData()
                    let summary = data.participantsSummary
                    return data.withUpdatedParticipantsSummary(CachedChannelParticipantsSummary(memberCount: Int32(clamping: count), adminCount: summary.adminCount, bannedCount: summary.bannedCount, kickedCount: summary.kickedCount))
                })
            }
        }
        MMLog.log("members: counts of \(values.count) chat(s) written")
    }
}
