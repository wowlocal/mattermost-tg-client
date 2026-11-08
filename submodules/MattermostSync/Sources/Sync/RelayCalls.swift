import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import RelayCallsCore

/// Where a Telegram group call id (`CachedChannelData.ActiveCall.id`) leads.
public struct MattermostRelayCallReference: Equatable {
    public let accountId: AccountRecordId
    public let peerId: PeerId
    public let channelId: String
    public let callId: String
    public let kind: RelayCallKind
}

/// Relay calls of one account (`docs/livekit-calls-native-ui.md`): the plugin's events and the live calls, kept by
/// account rather than by sync so that subscribers survive a re-login.
final class MattermostRelayCallsState {
    let events = ValuePipe<RelayCallsEvent>()
    /// Ringing or active calls in the user's channels, by call id.
    let calls = MMLocked<[String: RelayCall]>([:])
    let callsPromise = ValuePromise<[RelayCall]>([], ignoreRepeated: true)
    /// Whether the plugin answered `GET /calls/active` (false for a version 1 plugin).
    let supportsActiveCalls = MMLocked<Bool?>(nil)
}

extension MattermostSync {
    private static let relayCallsStates = MMLocked<[AccountRecordId: MattermostRelayCallsState]>([:])
    /// Group call ids written to `CachedChannelData.activeCall`, for every account.
    static let relayGroupCalls = MMLocked<[Int64: MattermostRelayCallReference]>([:])

    static func relayCallsState(accountId: AccountRecordId) -> MattermostRelayCallsState {
        return self.relayCallsStates.with { states in
            if let state = states[accountId] {
                return state
            }
            let state = MattermostRelayCallsState()
            states[accountId] = state
            return state
        }
    }

    /// Relay calls events of an account: the plugin's WebSocket events (`custom_org.relaychat.calls_*`), delivered
    /// whether or not the sync has bootstrapped, and `.activeCalls` after every WebSocket (re)connect. Delivered on the
    /// sync's tasks; observe on the main queue.
    public static func relayCallEvents(accountId: AccountRecordId) -> Signal<RelayCallsEvent, NoError> {
        return self.relayCallsState(accountId: accountId).events.signal()
    }

    /// The account's ringing and active calls as last reported (events and `GET /calls/active`).
    public static func relayLiveCalls(accountId: AccountRecordId) -> [RelayCall] {
        return self.relayCallsState(accountId: accountId).calls.with { Array($0.values) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// The live calls whenever they change (the current ones first).
    public static func relayLiveCallsSignal(accountId: AccountRecordId) -> Signal<[RelayCall], NoError> {
        return self.relayCallsState(accountId: accountId).callsPromise.get()
    }

    /// The live call of a chat (a DM's user peer, or a channel/group message), if any.
    public static func relayLiveCall(accountId: AccountRecordId, peerId: PeerId) -> RelayCall? {
        guard let channelId = self.sync(accountId: accountId)?.relayCallChannelId(peerId: peerId) else {
            return nil
        }
        return self.relayLiveCalls(accountId: accountId).last(where: { $0.channelId == channelId })
    }

    /// Fetches `GET /calls/active` now and delivers `.activeCalls`, also before the bootstrap (an app woken by a VoIP
    /// push). The sync does it after every WebSocket (re)connect.
    public static func refreshRelayCalls(accountId: AccountRecordId) async {
        await self.sync(accountId: accountId)?.refreshRelayCalls(reason: "requested")
    }

    /// The Telegram group call id of a plugin call (`CachedChannelData.ActiveCall.id`, call service messages).
    public static func relayGroupCallId(callId: String) -> Int64 {
        return RelayCallRecord.telegramCallId(callId)
    }

    /// The call behind a group call id from `CachedChannelData.activeCall` (registered while the call is live).
    public static func relayCall(groupCallId: Int64) -> MattermostRelayCallReference? {
        return self.relayGroupCalls.with { $0[groupCallId] }
    }
}

extension MattermostAccountSync {
    // MARK: Events

    /// A plugin WebSocket event; handled before the bootstrap guard of `handleEvent`.
    func handleRelayCallsEvent(_ event: WebSocketEvent) async {
        guard let data = try? JSONEncoder().encode(event.data), let decoded = RelayCallsEvent.decode(eventName: event.event, data: data) else {
            MMLog.log("calls: could not read \(event.event)")
            return
        }
        await self.applyRelayCallsEvent(decoded)
    }

    /// After every WebSocket (re)connect: events are not replayed.
    func refreshRelayCalls(reason: String) async {
        let state = MattermostSync.relayCallsState(accountId: self.account.id)
        do {
            let calls = try await self.relayCallsClient().activeCalls()
            state.supportsActiveCalls.with { $0 = true }
            await self.applyRelayCallsEvent(.activeCalls(calls))
        } catch let error as RelayCallsError where error.statusCode == 404 {
            // A version 1 plugin (or none): nothing rings; channel calls still come as events.
            if state.supportsActiveCalls.with({ value -> Bool in
                let first = value == nil
                value = false
                return first
            }) {
                MMLog.log("calls: no active calls route (\(reason)); the calls plugin is older than version 2 or missing")
            }
        } catch {
            MMLog.log("calls: active calls failed (\(reason)): \(error)")
        }
    }

    func applyRelayCallsEvent(_ event: RelayCallsEvent) async {
        let accountId = self.account.id
        let state = MattermostSync.relayCallsState(accountId: accountId)
        var changedChannels = Set<String>()
        let isFullRefresh: Bool
        let calls = state.calls.with { calls -> [RelayCall] in
            switch event {
            case let .activeCalls(active):
                changedChannels.formUnion(calls.values.map(\.channelId))
                calls = [:]
                for call in active where call.isLive {
                    calls[call.id] = call
                }
                changedChannels.formUnion(calls.values.map(\.channelId))
            case let .callEnded(call):
                calls[call.id] = nil
                changedChannels.insert(call.channelId)
            default:
                if let call = event.call {
                    if call.isLive {
                        calls[call.id] = call
                    } else {
                        calls[call.id] = nil
                    }
                    changedChannels.insert(call.channelId)
                }
            }
            return Array(calls.values)
        }
        if case .activeCalls = event {
            isFullRefresh = true
        } else {
            isFullRefresh = false
        }
        state.callsPromise.set(calls.sorted { $0.startedAt < $1.startedAt })
        MattermostSync.relayGroupCalls.with { registry in
            for (id, reference) in registry where reference.accountId == accountId && !calls.contains(where: { $0.id == reference.callId }) {
                registry[id] = nil
            }
            for call in calls where call.kind != .direct {
                guard let peerId = self.relayCallPeerId(channelId: call.channelId) else {
                    continue
                }
                registry[RelayCallRecord.telegramCallId(call.id)] = MattermostRelayCallReference(accountId: accountId, peerId: peerId, channelId: call.channelId, callId: call.id, kind: call.kind)
            }
        }
        // Subscribers first: a ring must not wait for Postbox.
        state.events.putNext(event)
        await self.writeRelayActiveCalls(channelIds: changedChannels, fullRefresh: isFullRefresh)
    }

    // MARK: Join panel

    /// The live room call of a channel or group message (direct calls have no panel).
    func relayRoomCall(channelId: String) -> RelayCall? {
        let calls = MattermostSync.relayCallsState(accountId: self.account.id).calls.with { calls in
            calls.values.filter { $0.channelId == channelId && $0.kind != .direct && $0.isLive }
        }
        return calls.max(by: { $0.startedAt < $1.startedAt })
    }

    /// Telegram's voice chat flags of a channel peer: a call exists (`hasVoiceChat`), someone is in it
    /// (`hasActiveVoiceChat`, the chat list's live indicator).
    func relayCallFlags(channelId: String) -> TelegramChannelFlags {
        guard let call = self.relayRoomCall(channelId: channelId) else {
            return []
        }
        var flags: TelegramChannelFlags = [.hasVoiceChat]
        if call.participants > 0 || !call.participantIds.isEmpty {
            flags.insert(.hasActiveVoiceChat)
        }
        return flags
    }

    static func relayActiveCall(_ call: RelayCall) -> CachedChannelData.ActiveCall {
        return CachedChannelData.ActiveCall(id: RelayCallRecord.telegramCallId(call.id), accessHash: RelayCallRecord.telegramCallId(call.channelId), title: nil, scheduleTimestamp: nil, subscribedToScheduled: false, isStream: false)
    }

    /// Keeps `CachedChannelData.activeCall` and the voice chat flags of channels and group messages in step with
    /// their live calls. A full refresh also clears every other channel (calls that ended while nobody listened).
    func writeRelayActiveCalls(channelIds: Set<String>, fullRefresh: Bool) async {
        var targets = channelIds
        if fullRefresh {
            targets.formUnion(self.state.with { state in state.channels.values.filter { $0.kind == .channel }.map(\.channel.id) })
        }
        let resolved: [(channelId: String, peerId: PeerId)] = targets.compactMap { channelId in
            guard let peerId = self.relayCallPeerId(channelId: channelId), peerId.namespace == Namespaces.Peer.CloudChannel else {
                return nil
            }
            return (channelId, peerId)
        }
        if resolved.isEmpty {
            return
        }
        await self.postbox.mmTransaction { transaction in
            for (channelId, peerId) in resolved {
                let activeCall = self.relayRoomCall(channelId: channelId).map(Self.relayActiveCall)
                let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData
                if cached?.activeCall != activeCall && (cached != nil || activeCall != nil) {
                    transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in
                        return (current as? CachedChannelData ?? CachedChannelData()).withUpdatedActiveCall(activeCall)
                    })
                }
                if let peer = transaction.getPeer(peerId) as? TelegramChannel {
                    var flags = peer.flags
                    flags.remove([.hasVoiceChat, .hasActiveVoiceChat])
                    flags.formUnion(self.relayCallFlags(channelId: channelId))
                    if flags != peer.flags {
                        updatePeersCustom(transaction: transaction, peers: [peer.withUpdatedFlags(flags)], update: { _, updated in
                            return updated
                        })
                    }
                }
            }
        }
    }

    // MARK: Lookups

    /// The chat of a channel: the partner's user peer for a DM, the channel peer otherwise. Works before the
    /// bootstrap from the store's id map.
    func relayCallPeerId(channelId: String) -> PeerId? {
        if let channelState = self.channelState(channelId) {
            return channelState.peerId
        }
        if let userId = self.store.directChannelUserId(channelId: channelId) {
            return self.userPeerId(userId)
        }
        if let peer = self.store.peer(mattermostId: channelId), peer.kind == .channel || peer.kind == .groupMessage {
            return MattermostPeerIds.channelPeerId(peer.peerId)
        }
        return nil
    }

    /// The channel of a chat: a DM's channel for a user peer, the channel of a channel peer.
    func relayCallChannelId(peerId: PeerId) -> String? {
        if let channelId = self.channelId(forPeerId: peerId) {
            return channelId
        }
        if peerId.namespace == Namespaces.Peer.CloudUser, let userId = self.userId(forPeerId: peerId) {
            return self.store.directChannelId(userId: userId)
        }
        if peerId.namespace == Namespaces.Peer.CloudChannel, let peer = self.store.peer(namespace: .channel, peerId: peerId.id._internalGetInt64Value()) {
            return peer.mattermostId
        }
        return nil
    }

    // MARK: Client and device

    static let relayCallsDeviceCursor = "relay_calls_device_id"
    private static let deviceIdLock = NSLock()

    /// This install's device id for the account (`device_id` of the plugin routes, the device part of the LiveKit
    /// identity): a UUID kept in the account's sync store.
    var relayCallsDeviceId: String {
        Self.deviceIdLock.lock()
        defer {
            Self.deviceIdLock.unlock()
        }
        if let existing = self.store.cursor(Self.relayCallsDeviceCursor), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        self.store.setCursor(Self.relayCallsDeviceCursor, created)
        return created
    }

    /// The plugin client of the account: its session token and pinned session, looked up per request.
    func relayCallsClient() -> RelayCallsClient {
        let client = self.client
        return RelayCallsClient(serverURL: client.serverURL, token: { [weak client] in
            return client?.token
        }, session: {
            return MattermostURLSession.current
        })
    }
}
