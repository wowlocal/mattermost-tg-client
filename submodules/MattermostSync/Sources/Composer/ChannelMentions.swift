import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// 4H: what the composer asks before sending `@all`, `@channel` or `@here` to a large channel, as Mattermost's
/// clients ask ("Confirm sending notifications to entire channel").
public struct MattermostChannelMentionConfirmation: Equatable {
    /// Only `@here` (the web app words it "at least N other people").
    public var isHereOnly: Bool
    /// The people who would be notified: the channel's members but the sender.
    public var memberCount: Int
    /// The distinct time zones of the members (0 when none are set: the text then names none).
    public var timezoneCount: Int
}

extension MattermostComposer {
    /// The channel-wide mentions in a message about to be sent (`ChannelWideMention.mentions`), checked on the main
    /// thread before anything else so other messages are sent without waiting.
    public static func containsChannelWideMention(_ text: String) -> Bool {
        return !ChannelWideMention.mentions(in: text).isEmpty
    }

    /// Whether sending `text` to the chat should ask first, and with which numbers; nil to send at once. The web
    /// app's check (11.7): the server's `EnableConfirmNotificationsToChannel`, the user's `use_channel_mentions`
    /// permission in the channel, and more than 5 members (`GET /channels/{id}/stats`, asked at send time). DMs never
    /// ask. Unknown (offline): nil, the server decides.
    public static func channelMentionConfirmation(accountId: AccountRecordId, peerId: PeerId, text: String) -> Signal<MattermostChannelMentionConfirmation?, NoError> {
        let mentions = ChannelWideMention.mentions(in: text)
        if mentions.isEmpty {
            return .single(nil)
        }
        return Signal { subscriber in
            let task = Task {
                var result: MattermostChannelMentionConfirmation?
                if let sync = MattermostSync.sync(accountId: accountId) {
                    result = await sync.channelMentionConfirmation(peerId: peerId, mentions: mentions)
                }
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
}

extension MattermostAccountSync {
    func channelMentionConfirmation(peerId: PeerId, mentions: [SpecialMentionKind]) async -> MattermostChannelMentionConfirmation? {
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId), channelState.kind == .channel else {
            return nil
        }
        let enabled = self.state.with { $0.confirmChannelMentions }
        guard enabled else {
            return nil
        }
        let canUse = await self.channelMentionsAllowed(channelState)
        guard canUse else {
            // The server sends no channel-wide notification for this user (`use_channel_mentions`).
            return nil
        }
        let memberCount: Int
        do {
            memberCount = Int(try await self.client.channelStats(channelId: channelId).memberCount)
        } catch {
            MMLog.log("channel mention: member count of \(channelId) failed: \(error)")
            return nil
        }
        guard ChannelWideMention.needsConfirmation(mentions: mentions, memberCount: memberCount, confirmationEnabled: enabled, canUseChannelMentions: canUse) else {
            return nil
        }
        let timezones = (try? await self.client.channelTimezones(channelId: channelId)) ?? []
        MMLog.log("channel mention: \(mentions.map { "@" + $0.rawValue }) to \(memberCount) members in \(timezones.count) time zone(s) asks first")
        return MattermostChannelMentionConfirmation(isHereOnly: mentions == [.here], memberCount: memberCount - 1, timezoneCount: timezones.count)
    }
}
