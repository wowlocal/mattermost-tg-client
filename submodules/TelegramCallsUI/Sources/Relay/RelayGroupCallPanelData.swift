import Foundation
import SwiftSignalKit
import TelegramCore
import MattermostSync
import RelayCallsCore

extension AccountGroupCallContextImpl {
    /// MATTERMOST: the chat-header join panel of a channel or group message with a live Relay call
    /// (`CachedChannelData.activeCall`, written by MattermostSync): who is in it, from the plugin's call object. Telegram's
    /// MTProto participant list would never answer.
    static func relayPanelData(account: Account, engine: TelegramEngine, peerId: EnginePeer.Id?, call: EngineGroupCallDescription) -> Signal<GroupCallPanelData?, NoError> {
        guard let peerId else {
            return .single(nil)
        }
        let accountId = account.id
        return MattermostSync.relayLiveCallsSignal(accountId: accountId)
        |> map { calls -> RelayCall? in
            return calls.first(where: { $0.kind != .direct && MattermostSync.relayGroupCallId(callId: $0.id) == call.id })
        }
        |> distinctUntilChanged
        |> mapToSignal { relayCall -> Signal<GroupCallPanelData?, NoError> in
            guard let relayCall else {
                return .single(nil)
            }
            let userIds = relayCall.participantIds
            let unknown = userIds.filter { MattermostSync.relayCallPeerId(accountId: accountId, userId: $0) == nil }
            if !unknown.isEmpty {
                Task {
                    await MattermostSync.ensureRelayCallUsers(accountId: accountId, userIds: unknown)
                }
            }
            let resolved: [(userId: String, peerId: EnginePeer.Id)] = userIds.compactMap { userId in
                return MattermostSync.relayCallPeerId(accountId: accountId, userId: userId).flatMap { (userId, $0) }
            }
            return engine.data.subscribe(EngineDataList(resolved.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.peerId) }))
            |> map { peers -> GroupCallPanelData? in
                var participants: [GroupCallParticipantsContext.Participant] = []
                for (index, peer) in peers.enumerated() {
                    guard let peer else {
                        continue
                    }
                    let userId = resolved[index].userId
                    participants.append(GroupCallParticipantsContext.Participant(
                        id: .peer(peer.id),
                        peer: peer,
                        ssrc: RelayCallIds.ssrc(userId: userId),
                        videoDescription: nil,
                        presentationDescription: nil,
                        joinTimestamp: Int32(relayCall.startedAt / 1000),
                        raiseHandRating: nil,
                        hasRaiseHand: false,
                        activityTimestamp: nil,
                        activityRank: nil,
                        muteState: nil,
                        volume: nil,
                        about: nil,
                        joinedVideo: true,
                        paidStarsTotal: nil
                    ))
                }
                // The device count while users are not known yet (a version 1 plugin sends only that).
                let participantCount = max(participants.count, relayCall.participantIds.isEmpty ? relayCall.participants : 0)
                return GroupCallPanelData(
                    peerId: peerId,
                    isChannel: false,
                    info: GroupCallInfo(
                        id: call.id,
                        accessHash: call.accessHash,
                        participantCount: participantCount,
                        streamDcId: nil,
                        title: nil,
                        scheduleTimestamp: nil,
                        subscribedToScheduled: false,
                        recordingStartTimestamp: nil,
                        sortAscending: true,
                        defaultParticipantsAreMuted: nil,
                        messagesAreEnabled: nil,
                        isVideoEnabled: true,
                        unmutedVideoLimit: 1000,
                        isStream: false,
                        isCreator: false,
                        defaultSendAs: nil
                    ),
                    topParticipants: Array(participants.prefix(3)),
                    participantCount: participantCount,
                    activeSpeakers: Set(),
                    groupCall: nil
                )
            }
        }
    }
}
