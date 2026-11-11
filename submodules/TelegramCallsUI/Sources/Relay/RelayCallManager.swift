import Foundation
import CallKit
import SwiftSignalKit
import Display
import TelegramCore
import TelegramAudio
import TelegramPresentationData
import AccountContext
import DeviceAccess
import PresentationDataUtils
import MattermostSync
import RelayCallsCore
import RelayCalls

/// MATTERMOST: Relay's `PresentationCallManager` (docs/livekit-calls-native-ui.md, "Platform adapters"). Replaces
/// `PresentationCallManagerImpl` while the Mattermost backend is on: MTProto never rings and its requests never
/// return, so calls come from the `org.relaychat.calls` plugin instead. It
///
/// - rings incoming calls from the accounts' plugin events (`incoming`, and own rings in `GET /calls/active` after a
///   reconnect) and from VoIP pushes (`handleVoIPPush`), through CallKit when it is available (devices) and through
///   Telegram's in-app call banner otherwise (the simulator);
/// - starts outgoing calls (`requestCall`: a DM rings the other user, CallKit's start call action as in Telegram) and
///   group calls (`joinGroupCall`: a group message rings its members, a channel starts or joins its call);
/// - publishes them as `currentCallSignal`/`currentGroupCallSignal`, which `SharedAccountContextImpl` turns into
///   Telegram's own screens, ringing banner, status bar and picture in picture.
public final class RelayCallManager: PresentationCallManager {
    private static var instance: RelayCallManager?

    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    private let audioSession: ManagedAudioSession
    private let getDeviceAccessData: () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void)
    private let isMediaPlaying: () -> Bool
    private let resumeMediaPlayback: () -> Void
    private let callKitIntegration: CallKitIntegration?
    private var resumeMedia = false

    private var accountContexts: [AccountRecordId: AccountContext] = [:]
    private var eventDisposables: [AccountRecordId: Disposable] = [:]
    private var activeAccountsDisposable: Disposable?

    private var signallingAccounts = Set<AccountRecordId>()
    private var currentCall: RelayPresentationCall?
    private var currentGroupCall: RelayPresentationGroupCall?
    private let currentCallPromise = Promise<PresentationCall?>(nil)
    private let currentGroupCallPromise = Promise<VideoChatCall?>(nil)
    private let hasActivePersonalCallsPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let hasActiveGroupCallsPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let removeCurrentCallDisposable = MetaDisposable()
    private let removeCurrentGroupCallDisposable = MetaDisposable()
    private let startCallDisposable = MetaDisposable()
    /// Rings being set up (peer lookups), by call id: a second report of the same ring waits for the first.
    private var startingIncomingCallIds = Set<String>()
    private var pendingPushRetryTimer: SwiftSignalKit.Timer?
    private var pendingPushRetries = 0

    public var currentCallSignal: Signal<PresentationCall?, NoError> {
        return self.currentCallPromise.get()
    }

    public var currentGroupCallSignal: Signal<VideoChatCall?, NoError> {
        return self.currentGroupCallPromise.get()
    }

    public var hasActiveCall: Bool {
        return self.currentCall != nil || self.currentGroupCall != nil
    }

    public var hasActiveGroupCall: Bool {
        return self.currentGroupCall != nil
    }

    public var hasActiveCalls: Signal<Bool, NoError> {
        return combineLatest(queue: .mainQueue(), self.hasActivePersonalCallsPromise.get(), self.hasActiveGroupCallsPromise.get())
        |> map { $0 || $1 }
        |> distinctUntilChanged
    }

    public init(
        accountManager: AccountManager<TelegramAccountManagerTypes>,
        getDeviceAccessData: @escaping () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void),
        isMediaPlaying: @escaping () -> Bool,
        resumeMediaPlayback: @escaping () -> Void,
        audioSession: ManagedAudioSession,
        activeAccounts: Signal<[AccountContext], NoError>
    ) {
        self.accountManager = accountManager
        self.getDeviceAccessData = getDeviceAccessData
        self.isMediaPlaying = isMediaPlaying
        self.resumeMediaPlayback = resumeMediaPlayback
        self.audioSession = audioSession
        self.callKitIntegration = CallKitIntegration.shared

        RelayCallAudio.prepare()
        RelayCallKitBridge.install()
        RelayCallManager.instance = self
        #if DEBUG
        MattermostSync.debugCallCommand = { [weak self] action, command, completion in
            guard ["call-state", "call-accept", "call-hangup", "call-push"].contains(action) else { return false }
            relayOnMain {
                guard let self else { completion(false, "no call manager", [:]); return }
                if action == "call-push" {
                    guard let file = command["file"] as? String, let data = try? Data(contentsOf: URL(fileURLWithPath: file)), let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        completion(false, "missing push file", [:]); return
                    }
                    let converted = Dictionary(uniqueKeysWithValues: payload.map { (AnyHashable($0.key), $0.value) })
                    let handled = RelayCallManager.handleVoIPPush(converted, completion: {})
                    completion(handled, handled ? nil : "invalid call push", [:])
                    return
                }
                guard let call = self.currentCall else {
                    completion(action == "call-state", action == "call-state" ? nil : "no direct call", ["hasCall": self.hasActiveCall])
                    return
                }
                if action == "call-accept" { call.answer() }
                if action == "call-hangup" { let _ = call.hangUp().start() }
                let _ = (call.state |> take(1)).start(next: { state in
                    completion(true, nil, ["hasCall": true, "accountId": String(call.context.account.id.int64), "callId": call.relayCallId ?? "", "state": String(describing: state.state)])
                })
            }
            return true
        }
        #endif

        self.activeAccountsDisposable = (activeAccounts
        |> deliverOnMainQueue).start(next: { [weak self] contexts in
            relayOnMain {
                self?.updateAccounts(contexts)
            }
        })
    }

    deinit {
        self.activeAccountsDisposable?.dispose()
        for disposable in self.eventDisposables.values {
            disposable.dispose()
        }
        self.removeCurrentCallDisposable.dispose()
        self.removeCurrentGroupCallDisposable.dispose()
        self.startCallDisposable.dispose()
        self.pendingPushRetryTimer?.invalidate()
    }

    // MARK: Accounts and events

    @MainActor
    private func updateAccounts(_ contexts: [AccountContext]) {
        var updated: [AccountRecordId: AccountContext] = [:]
        for context in contexts {
            updated[context.account.id] = context
        }
        for (accountId, disposable) in self.eventDisposables where updated[accountId] == nil {
            disposable.dispose()
            self.eventDisposables[accountId] = nil
        }
        for (accountId, context) in updated where self.eventDisposables[accountId] == nil {
            self.eventDisposables[accountId] = (MattermostSync.relayCallEvents(accountId: accountId)
            |> deliverOnMainQueue).start(next: { [weak self, weak context] event in
                guard let context else {
                    return
                }
                relayOnMain {
                    self?.handle(event, context: context)
                }
            })
        }
        self.accountContexts = updated
        self.processPendingPushes()
    }

    @MainActor
    private func handle(_ event: RelayCallsEvent, context: AccountContext) {
        let accountId = context.account.id
        if let call = self.currentCall, call.context.account.id == accountId {
            call.handle(event)
        }
        if let groupCall = self.currentGroupCall, groupCall.account.id == accountId {
            groupCall.handle(event)
        }
        guard let relayAccount = MattermostSync.relayCallsAccount(accountId: accountId) else {
            return
        }
        switch event {
        case let .incoming(call, caller):
            if call.isRinging(for: relayAccount.ownUserId) {
                self.startIncoming(context: context, relayAccount: relayAccount, source: .event(call, caller), uuid: RelayCallIds.callKitUUID(callId: call.id), reportToCallKit: true)
            }
        case let .activeCalls(calls):
            for call in calls where call.kind != .channel && call.isRinging(for: relayAccount.ownUserId) {
                self.startIncoming(context: context, relayAccount: relayAccount, source: .event(call, nil), uuid: RelayCallIds.callKitUUID(callId: call.id), reportToCallKit: true)
            }
        case let .callEnded(call):
            RelayCallKitBridge.noteEnded(callId: call.id)
            if let index = RelayCallKitBridge.pendingPushes.firstIndex(where: { $0.push.callId == call.id }) {
                let pending = RelayCallKitBridge.pendingPushes.remove(at: index)
                self.callKitIntegration?.dropCall(uuid: pending.uuid)
            }
        default:
            break
        }
    }

    // MARK: Incoming

    enum IncomingSource {
        case event(RelayCall, RelayCaller?)
        case push(RelayCallPush)

        var callId: String {
            switch self {
            case let .event(call, _):
                return call.id
            case let .push(push):
                return push.callId
            }
        }
    }

    /// A ring for this user: busy when another call runs here, else Telegram's incoming call (CallKit or the banner).
    @MainActor
    private func startIncoming(context: AccountContext, relayAccount: MattermostRelayCallsAccount, source: IncomingSource, uuid: UUID, reportToCallKit: Bool) {
        let callId = source.callId
        if RelayCallKitBridge.isEnded(callId: callId) || self.startingIncomingCallIds.contains(callId) {
            return
        }
        if let call = self.currentCall, call.relayCallId == callId {
            return
        }
        if let groupCall = self.currentGroupCall, groupCall.controller.callId == callId {
            return
        }
        if self.currentCall != nil || self.currentGroupCall != nil {
            // As Telegram: a second call rings nobody here; the caller hears busy.
            RelayCallKitBridge.noteEnded(callId: callId)
            let client = relayAccount.client
            let deviceId = relayAccount.deviceId
            Task {
                await RelayDirectCall.declineBusy(api: client, callId: callId, deviceId: deviceId)
            }
            if !reportToCallKit {
                // A pushed ring was already reported to CallKit.
                self.callKitIntegration?.dropCall(uuid: uuid)
            }
            return
        }
        self.startingIncomingCallIds.insert(callId)

        let accountId = context.account.id
        let channelId: String
        let callerId: String
        let isVideo: Bool
        let sourceKind: RelayCallKind
        switch source {
        case let .event(call, _):
            channelId = call.channelId
            callerId = call.startedBy
            isVideo = call.video
            sourceKind = call.kind
        case let .push(push):
            channelId = push.channelId
            callerId = push.callerId
            isVideo = push.video
            sourceKind = .direct
        }
        Task { @MainActor [weak self] in
            var kind = sourceKind
            var channel = MattermostSync.relayCallChannel(accountId: accountId, channelId: channelId)
            if case .push = source, let channelKind = channel?.kind {
                kind = channelKind
            }
            var peerId: EnginePeer.Id?
            if kind == .direct {
                peerId = MattermostSync.relayCallPeerId(accountId: accountId, userId: callerId)
                if peerId == nil {
                    await MattermostSync.ensureRelayCallUsers(accountId: accountId, userIds: [callerId])
                    peerId = MattermostSync.relayCallPeerId(accountId: accountId, userId: callerId)
                }
            } else {
                if channel == nil {
                    await MattermostSync.refreshRelayCalls(accountId: accountId)
                    channel = MattermostSync.relayCallChannel(accountId: accountId, channelId: channelId)
                }
                peerId = channel?.peerId
            }
            guard let self else {
                return
            }
            self.startingIncomingCallIds.remove(callId)
            guard let peerId else {
                relayLog("incoming \(callId): no chat for channel \(channelId)")
                if !reportToCallKit {
                    self.callKitIntegration?.dropCall(uuid: uuid)
                }
                return
            }
            if RelayCallKitBridge.isEnded(callId: callId) {
                if !reportToCallKit {
                    self.callKitIntegration?.dropCall(uuid: uuid)
                }
                return
            }
            if self.currentCall?.relayCallId == callId || self.currentGroupCall?.controller.callId == callId {
                return
            }
            if self.currentCall != nil || self.currentGroupCall != nil {
                // Another call started while this ring was looked up.
                RelayCallKitBridge.noteEnded(callId: callId)
                let client = relayAccount.client
                let deviceId = relayAccount.deviceId
                Task {
                    await RelayDirectCall.declineBusy(api: client, callId: callId, deviceId: deviceId)
                }
                if !reportToCallKit {
                    self.callKitIntegration?.dropCall(uuid: uuid)
                }
                return
            }
            let peer = await context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)).get()
            let engine = RelayRoomEngine(options: RelayRoomEngine.Options(usesExternalCamera: true))
            let callKind: RelayPresentationCall.Kind
            switch (kind, source) {
            case let (.direct, .event(call, _)):
                callKind = .direct(RelayDirectCall.incoming(api: relayAccount.client, engine: engine, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, call: call))
            case let (.direct, .push(push)):
                callKind = .direct(RelayDirectCall.incoming(api: relayAccount.client, engine: engine, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, push: push))
            case let (_, .event(call, _)):
                callKind = .groupRing(RelayGroupCall.incoming(api: relayAccount.client, engine: engine, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, call: call))
            case let (_, .push(push)):
                callKind = .groupRing(RelayGroupCall.incoming(api: relayAccount.client, engine: engine, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, push: push))
            }
            if reportToCallKit, let callKitIntegration = self.callKitIntegration {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let title = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? "Relay"
                // Telegram's handle (the peer id), so that the Phone app's recents call back through Telegram's intent.
                let handle = kind == .direct ? "\(peerId.id._internalGetInt64Value())" : channelId
                callKitIntegration.reportIncomingRelayCall(uuid: uuid, handle: handle, isVideo: isVideo, displayTitle: title, completion: nil)
            }
            let call = RelayPresentationCall(context: context, relayAccount: relayAccount, kind: callKind, engine: engine, internalId: uuid, peerId: peerId, peer: peer, isOutgoing: false, isVideo: isVideo, audioSession: self.audioSession, callKitIntegration: self.callKitIntegration, authorizeAccess: self.callAccessAuthorization())
            call.answerGroupRing = { [weak self] call in
                relayOnMain {
                    self?.answerGroupRing(call)
                }
            }
            self.setCurrentCall(call)
            call.start()
            if RelayCallKitBridge.pendingAnswers.remove(uuid) != nil {
                call.answer(fromCallKitAction: true)
            } else if RelayCallKitBridge.pendingEnds.remove(uuid) != nil {
                let _ = call.hangUp()
            }
        }
    }

    /// An answered group ring continues as a group call (same room, same CallKit call).
    @MainActor
    private func answerGroupRing(_ call: RelayPresentationCall) {
        guard self.currentCall === call, let controller = call.groupRingController else {
            return
        }
        let groupCall = RelayPresentationGroupCall(accountContext: call.context, relayAccount: call.relayAccount, controller: controller, engine: call.engine, internalId: call.internalId, peerId: call.peerId, audioSession: self.audioSession, callKitIntegration: call.isIntegratedWithCallKit ? self.callKitIntegration : nil)
        call.handOver()
        self.setCurrentGroupCall(groupCall)
        groupCall.start(accept: true)
        self.setCurrentCall(nil)
    }

    // MARK: VoIP pushes

    /// A VoIP push (`PKPushRegistryDelegate`, any time, also before the manager exists). Returns false for pushes that
    /// are not Relay rings. A Relay ring is reported to CallKit at once, every time (iOS terminates apps that do not),
    /// then rung once its account runs; a ring this device already knows to be over is reported and ended.
    public static func handleVoIPPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) -> Bool {
        guard let push = RelayCallPush(payload: payload) else {
            return false
        }
        RelayCallAudio.installLogging()
        RelayCallKitBridge.install()
        let isKnownEnded = RelayCallKitBridge.isEnded(callId: push.callId)
        let uuid = isKnownEnded ? UUID() : RelayCallIds.callKitUUID(callId: push.callId)
        let title = push.callerName.isEmpty ? "Relay" : push.callerName
        var handle = push.callerId
        if let accountId = MattermostSync.relayCallAccountId(push: push), let peerId = MattermostSync.relayCallPeerId(accountId: accountId, userId: push.callerId) {
            handle = "\(peerId.id._internalGetInt64Value())"
        }
        relayLog("VoIP push for call \(push.callId)\(isKnownEnded ? " (already over)" : "")")
        if let callKitIntegration = CallKitIntegration.shared {
            callKitIntegration.reportIncomingRelayCall(uuid: uuid, handle: handle, isVideo: push.video, displayTitle: title, completion: { error in
                if let error {
                    relayLog("CallKit refused the pushed ring \(push.callId): \(error)")
                }
                if isKnownEnded {
                    callKitIntegration.reportCallEnded(uuid: uuid, reason: .remoteEnded)
                }
                completion()
            })
        } else {
            completion()
        }
        if isKnownEnded {
            return true
        }
        MattermostSync.prepareRelayCallSignalling(push: push)
        if !RelayCallKitBridge.pendingPushes.contains(where: { $0.push.callId == push.callId }) {
            RelayCallKitBridge.pendingPushes.append((push, uuid))
        }
        relayOnMain {
            RelayCallManager.instance?.processPendingPushes()
        }
        return true
    }

    @MainActor
    private func processPendingPushes() {
        if RelayCallKitBridge.pendingPushes.isEmpty {
            return
        }
        var remaining: [(push: RelayCallPush, uuid: UUID)] = []
        for pending in RelayCallKitBridge.pendingPushes {
            guard let accountId = MattermostSync.relayCallAccountId(push: pending.push), let context = self.accountContexts[accountId], let relayAccount = MattermostSync.relayCallsAccount(accountId: accountId) else {
                remaining.append(pending)
                continue
            }
            Task {
                await MattermostSync.refreshRelayCalls(accountId: accountId)
            }
            self.startIncoming(context: context, relayAccount: relayAccount, source: .push(pending.push), uuid: pending.uuid, reportToCallKit: false)
        }
        RelayCallKitBridge.pendingPushes = remaining
        self.pendingPushRetryTimer?.invalidate()
        self.pendingPushRetryTimer = nil
        if remaining.isEmpty {
            self.pendingPushRetries = 0
            return
        }
        // The push woke the app before its account runs: try again shortly, for as long as a ring lasts.
        self.pendingPushRetries += 1
        if self.pendingPushRetries > 90 {
            for pending in remaining {
                self.callKitIntegration?.dropCall(uuid: pending.uuid)
            }
            RelayCallKitBridge.pendingPushes = []
            self.pendingPushRetries = 0
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 0.5, repeat: false, completion: { [weak self] in
            relayOnMain {
                self?.processPendingPushes()
            }
        }, queue: .mainQueue())
        self.pendingPushRetryTimer = timer
        timer.start()
    }

    // MARK: CallKit actions

    @MainActor
    fileprivate func callKitAnswer(uuid: UUID) -> Bool {
        if let call = self.currentCall, call.internalId == uuid {
            call.answer(fromCallKitAction: true)
            return true
        }
        return false
    }

    @MainActor
    fileprivate func callKitEnd(uuid: UUID) -> Signal<Bool, NoError>? {
        // CallKit fails the action on a `false`: wait for the end.
        if let groupCall = self.currentGroupCall, groupCall.internalId == uuid {
            return groupCall.leave(terminateIfPossible: false) |> filter { $0 } |> take(1)
        }
        if let call = self.currentCall, call.internalId == uuid {
            return call.hangUp() |> filter { $0 } |> take(1)
        }
        return nil
    }

    @MainActor
    fileprivate func callKitSetMuted(uuid: UUID, isMuted: Bool) {
        if let call = self.currentCall, call.internalId == uuid {
            call.setMutedFromCallKit(isMuted)
        } else if let groupCall = self.currentGroupCall, groupCall.internalId == uuid {
            groupCall.setIsMuted(action: isMuted ? .muted(isPushToTalkActive: false) : .unmuted)
        }
    }

    fileprivate func callKitAudioSessionActivationChanged(_ value: Bool) {
        if value {
            self.audioSession.callKitActivatedAudioSession()
        } else {
            self.audioSession.callKitDeactivatedAudioSession()
        }
    }

    // MARK: Current calls

    @MainActor
    private func setCurrentCall(_ call: RelayPresentationCall?) {
        if self.currentCall === call {
            return
        }
        if let previous = self.currentCall, let callId = previous.relayCallId {
            RelayCallKitBridge.noteEnded(callId: callId)
        }
        let wasEmpty = self.currentCall == nil && self.currentGroupCall == nil
        self.currentCall = call
        self.updateSignallingAccounts()
        if let call {
            if wasEmpty {
                self.resumeMedia = self.isMediaPlaying()
            }
            self.currentCallPromise.set(.single(call))
            self.hasActivePersonalCallsPromise.set(true)
            self.removeCurrentCallDisposable.set((call.canBeRemoved
            |> filter { $0 }
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self, weak call] _ in
                relayOnMain {
                    guard let self, let call, self.currentCall === call else {
                        return
                    }
                    self.setCurrentCall(nil)
                }
            }))
        } else {
            self.removeCurrentCallDisposable.set(nil)
            self.currentCallPromise.set(.single(nil))
            self.hasActivePersonalCallsPromise.set(false)
            self.resumeMediaIfNeeded()
        }
    }

    @MainActor
    private func setCurrentGroupCall(_ call: RelayPresentationGroupCall?) {
        if self.currentGroupCall === call {
            return
        }
        if let previous = self.currentGroupCall, let callId = previous.controller.callId {
            RelayCallKitBridge.noteEnded(callId: callId)
        }
        let wasEmpty = self.currentCall == nil && self.currentGroupCall == nil
        self.currentGroupCall = call
        self.updateSignallingAccounts()
        if let call {
            if wasEmpty {
                self.resumeMedia = self.isMediaPlaying()
            }
            self.currentGroupCallPromise.set(.single(.group(call)))
            self.hasActiveGroupCallsPromise.set(true)
            self.removeCurrentGroupCallDisposable.set((call.canBeRemoved
            |> filter { $0 }
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self, weak call] _ in
                relayOnMain {
                    guard let self, let call, self.currentGroupCall === call else {
                        return
                    }
                    self.setCurrentGroupCall(nil)
                }
            }))
        } else {
            self.removeCurrentGroupCallDisposable.set(nil)
            self.currentGroupCallPromise.set(.single(nil))
            self.hasActiveGroupCallsPromise.set(false)
            self.resumeMediaIfNeeded()
        }
    }

    @MainActor
    private func updateSignallingAccounts() {
        var accounts = Set<AccountRecordId>()
        if let call = self.currentCall { accounts.insert(call.context.account.id) }
        if let call = self.currentGroupCall { accounts.insert(call.account.id) }
        for accountId in self.signallingAccounts.union(accounts) {
            MattermostSync.updateCallSignalling(accountId: accountId, required: accounts.contains(accountId))
        }
        self.signallingAccounts = accounts
    }

    @MainActor
    private func resumeMediaIfNeeded() {
        if self.currentCall == nil && self.currentGroupCall == nil && self.resumeMedia {
            self.resumeMedia = false
            self.resumeMediaPlayback()
        }
    }

    /// Ends whatever runs here before a new call starts.
    @MainActor
    private func endCurrent(then begin: @escaping () -> Void) {
        if let call = self.currentCall {
            self.startCallDisposable.set((call.hangUp()
            |> filter { $0 }
            |> take(1)
            |> deliverOnMainQueue).start(next: { _ in
                begin()
            }))
        } else if let groupCall = self.currentGroupCall {
            self.startCallDisposable.set((groupCall.leave(terminateIfPossible: false)
            |> filter { $0 }
            |> take(1)
            |> deliverOnMainQueue).start(next: { _ in
                begin()
            }))
        } else {
            begin()
        }
    }

    private func alreadyInCallType() -> CallAlreadyInProgressType? {
        if let call = self.currentCall {
            return .peer(call.peerId)
        }
        if let groupCall = self.currentGroupCall {
            return .peer(groupCall.peerId)
        }
        if CXCallObserver().calls.contains(where: { !$0.hasEnded }) {
            return .external
        }
        return nil
    }

    /// `authorizeAccess(isVideo:)` for a call to ask before it answers.
    private func callAccessAuthorization() -> (Bool) -> Signal<Bool, NoError> {
        return { [weak self] isVideo in
            guard let self else {
                return .single(false)
            }
            return self.authorizeAccess(isVideo: isVideo)
        }
    }

    /// Telegram's microphone (and camera, for video) permission prompts before a call.
    private func authorizeAccess(isVideo: Bool) -> Signal<Bool, NoError> {
        let (presentationData, present, openSettings) = self.getDeviceAccessData()
        return Signal { subscriber in
            DeviceAccess.authorizeAccess(to: .microphone(.voiceCall), presentationData: presentationData, present: { c, a in
                present(c, a)
            }, openSettings: {
                openSettings()
            }, { value in
                if isVideo && value {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), presentationData: presentationData, present: { c, a in
                        present(c, a)
                    }, openSettings: {
                        openSettings()
                    }, { value in
                        subscriber.putNext(value)
                        subscriber.putCompletion()
                    })
                } else {
                    subscriber.putNext(value)
                    subscriber.putCompletion()
                }
            })
            return EmptyDisposable
        }
        |> runOn(Queue.mainQueue())
    }

    private func presentError(context: AccountContext, title: String? = nil, text: String) {
        let (presentationData, present, _) = self.getDeviceAccessData()
        present(textAlertController(sharedContext: context.sharedContext, title: title ?? presentationData.strings.Call_StatusFailed, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]), nil)
    }

    // MARK: Outgoing

    public func requestCall(context: AccountContext, peerId: EnginePeer.Id, isVideo: Bool, endCurrentIfAny: Bool) -> RequestCallResult {
        if let alreadyInCallType = self.alreadyInCallType(), !endCurrentIfAny {
            return .alreadyInProgress(alreadyInCallType)
        }
        if peerId.namespace != Namespaces.Peer.CloudUser {
            // A group message or channel: Telegram's group call path.
            let _ = self.joinGroupCall(context: context, peerId: peerId, invite: nil, requestJoinAsPeerId: nil, initialCall: EngineGroupCallDescription(id: 0, accessHash: 0, title: nil, scheduleTimestamp: nil, subscribedToScheduled: false, isStream: false), endCurrentIfAny: true)
            return .requested
        }
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            self.endCurrent(then: { [weak self] in
                guard let self else {
                    return
                }
                let _ = (self.authorizeAccess(isVideo: isVideo)
                |> deliverOnMainQueue).start(next: { [weak self] accessEnabled in
                    guard let self, accessEnabled else {
                        return
                    }
                    if let callKitIntegration = self.callKitIntegration {
                        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                        |> deliverOnMainQueue).start(next: { [weak self] peer in
                            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                            let title = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? ""
                            // CallKit performs the start action and calls back with its uuid (`RelayCallKitBridge`).
                            callKitIntegration.startCall(context: context, peerId: peerId, phoneNumber: nil, localContactId: nil, isVideo: isVideo, displayTitle: title, completion: { [weak self] error in
                                if error != nil {
                                    self?.presentError(context: context, text: presentationData.strings.Call_SystemStartErrorMessage)
                                }
                            })
                        })
                    } else {
                        let _ = self.startOutgoing(context: context, peerId: peerId, isVideo: isVideo, uuid: UUID()).start()
                    }
                })
            })
        }
        return .requested
    }

    /// Rings a DM's other user (CallKit's start call action, or directly without CallKit).
    fileprivate func startOutgoing(context: AccountContext, peerId: EnginePeer.Id, isVideo: Bool, uuid: UUID) -> Signal<Bool, NoError> {
        return Signal { [weak self] subscriber in
            let task = Task { @MainActor [weak self] in
                let accountId = context.account.id
                guard let relayAccount = MattermostSync.relayCallsAccount(accountId: accountId) else {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }
                let channel: MattermostRelayCallChannel
                do {
                    channel = try await MattermostSync.relayCallChannel(accountId: accountId, peerId: peerId)
                } catch {
                    if let self {
                        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                        self.presentError(context: context, title: presentationData.strings.Call_ConnectionErrorTitle, text: presentationData.strings.Call_ConnectionErrorMessage)
                    }
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }
                guard let self, channel.kind == .direct, let peerUserId = channel.peerUserId, self.currentCall == nil, self.currentGroupCall == nil else {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }
                let peer = await context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)).get()
                let engine = RelayRoomEngine(options: RelayRoomEngine.Options(usesExternalCamera: true))
                let direct = RelayDirectCall.outgoing(api: relayAccount.client, engine: engine, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, channelId: channel.channelId, peerUserId: peerUserId, video: isVideo)
                let call = RelayPresentationCall(context: context, relayAccount: relayAccount, kind: .direct(direct), engine: engine, internalId: uuid, peerId: peerId, peer: peer, isOutgoing: true, isVideo: isVideo, audioSession: self.audioSession, callKitIntegration: self.callKitIntegration, authorizeAccess: self.callAccessAuthorization())
                self.setCurrentCall(call)
                call.start()
                subscriber.putNext(true)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    public func joinGroupCall(context: AccountContext, peerId: EnginePeer.Id, invite: String?, requestJoinAsPeerId: ((@escaping (EnginePeer.Id?) -> Void) -> Void)?, initialCall: EngineGroupCallDescription, endCurrentIfAny: Bool) -> JoinGroupCallManagerResult {
        if let groupCall = self.currentGroupCall, groupCall.peerId == peerId {
            return .alreadyInProgress(.peer(peerId))
        }
        if let alreadyInCallType = self.alreadyInCallType(), !endCurrentIfAny {
            return .alreadyInProgress(alreadyInCallType)
        }
        let reference = MattermostSync.relayCall(groupCallId: initialCall.id)
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            self.endCurrent(then: { [weak self] in
                guard let self else {
                    return
                }
                let _ = (self.authorizeAccess(isVideo: false)
                |> deliverOnMainQueue).start(next: { [weak self] accessEnabled in
                    guard accessEnabled else {
                        return
                    }
                    relayOnMain {
                        self?.startGroupCall(context: context, peerId: peerId, reference: reference)
                    }
                })
            })
        }
        return .joined
    }

    /// Joins the call of a channel or group message (the join panel's call when `reference` names it), starts a
    /// channel call, or rings the members of a group message.
    @MainActor
    private func startGroupCall(context: AccountContext, peerId: EnginePeer.Id, reference: MattermostRelayCallReference?) {
        let accountId = context.account.id
        Task { @MainActor [weak self] in
            guard let relayAccount = MattermostSync.relayCallsAccount(accountId: accountId) else {
                return
            }
            let channel: MattermostRelayCallChannel
            do {
                channel = try await MattermostSync.relayCallChannel(accountId: accountId, peerId: peerId)
            } catch {
                if let self {
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    self.presentError(context: context, title: presentationData.strings.Call_ConnectionErrorTitle, text: presentationData.strings.Call_ConnectionErrorMessage)
                }
                return
            }
            guard let self, self.currentCall == nil, self.currentGroupCall == nil, channel.kind != .direct else {
                return
            }
            let engine = RelayRoomEngine(options: RelayRoomEngine.Options(usesExternalCamera: true))
            let controller: RelayGroupCall
            let liveCall = reference.flatMap { $0.channelId == channel.channelId ? $0.callId : nil } ?? MattermostSync.relayLiveCall(accountId: accountId, peerId: peerId).flatMap { $0.isLive ? $0.id : nil }
            if channel.kind == .group && liveCall == nil {
                controller = RelayGroupCall.ring(api: relayAccount.client, engine: engine, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, channelId: channel.channelId, video: false)
            } else {
                controller = RelayGroupCall.join(api: relayAccount.client, engine: engine, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, channelId: channel.channelId, callId: liveCall, kind: channel.kind)
            }
            // As Telegram's voice chats: no CallKit call for a group call this device starts or joins.
            let groupCall = RelayPresentationGroupCall(accountContext: context, relayAccount: relayAccount, controller: controller, engine: engine, internalId: UUID(), peerId: peerId, audioSession: self.audioSession, callKitIntegration: nil)
            self.setCurrentGroupCall(groupCall)
            groupCall.start(accept: false)
        }
    }

    public func scheduleGroupCall(context: AccountContext, peerId: EnginePeer.Id, endCurrentIfAny: Bool, parentController: ViewController) -> RequestScheduleGroupCallResult {
        // Relay calls cannot be scheduled (the entry points are hidden).
        return .success
    }

    public func joinConferenceCall(accountContext: AccountContext, initialCall: EngineGroupCallDescription, reference: InternalGroupCallReference, beginWithVideo: Bool, invitePeerIds: [EnginePeer.Id], endCurrentIfAny: Bool, unmuteByDefault: Bool) -> JoinGroupCallManagerResult {
        // Telegram conference links have no Relay counterpart.
        return .joined
    }

    // MARK: CallKit bridge

    fileprivate static var current: RelayCallManager? {
        return self.instance
    }
}

/// CallKit's provider callbacks for Relay calls, installed as soon as a VoIP push or the manager needs them: a push can
/// wake the app and be answered on the lock screen before the manager exists, so early actions are kept for the call
/// they name.
enum RelayCallKitBridge {
    private static var isInstalled = false
    static var pendingPushes: [(push: RelayCallPush, uuid: UUID)] = []
    static var pendingAnswers = Set<UUID>()
    static var pendingEnds = Set<UUID>()
    /// Calls that ended or that this device refused, newest last (a late ring for them must not ring again).
    private static var endedCallIds: [String] = []

    static func noteEnded(callId: String) {
        if self.endedCallIds.contains(callId) {
            return
        }
        self.endedCallIds.append(callId)
        if self.endedCallIds.count > 100 {
            self.endedCallIds.removeFirst(self.endedCallIds.count - 100)
        }
    }

    static func isEnded(callId: String) -> Bool {
        return self.endedCallIds.contains(callId)
    }

    static func install() {
        if self.isInstalled {
            return
        }
        guard let callKitIntegration = CallKitIntegration.shared else {
            return
        }
        self.isInstalled = true
        callKitIntegration.setup(startCall: { context, uuid, maybePeerId, handle, isVideo in
            guard let manager = RelayCallManager.current else {
                return .single(false)
            }
            var peerId = maybePeerId
            if peerId == nil, let userId = Int64(handle) {
                peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(userId))
            }
            guard let peerId else {
                return .single(false)
            }
            return manager.startOutgoing(context: context, peerId: peerId, isVideo: isVideo, uuid: uuid)
        }, answerCall: { uuid in
            relayOnMain {
                if RelayCallManager.current?.callKitAnswer(uuid: uuid) != true {
                    self.pendingAnswers.insert(uuid)
                }
            }
        }, endCall: { uuid in
            var result: Signal<Bool, NoError> = .single(true)
            MainActor.assumeIsolated {
                if let signal = RelayCallManager.current?.callKitEnd(uuid: uuid) {
                    result = signal
                } else if let index = self.pendingPushes.firstIndex(where: { $0.uuid == uuid }) {
                    // Declined on the lock screen before the ring was set up.
                    self.pendingEnds.insert(uuid)
                    let pending = self.pendingPushes[index]
                    if let accountId = MattermostSync.relayCallAccountId(push: pending.push), let relayAccount = MattermostSync.relayCallsAccount(accountId: accountId) {
                        self.pendingPushes.remove(at: index)
                        self.pendingEnds.remove(uuid)
                        self.noteEnded(callId: pending.push.callId)
                        let client = relayAccount.client
                        let deviceId = relayAccount.deviceId
                        Task {
                            try? await client.decline(callId: pending.push.callId, deviceId: deviceId, reason: .declined)
                        }
                    }
                } else {
                    self.pendingEnds.insert(uuid)
                }
            }
            return result
        }, setCallMuted: { uuid, isMuted in
            relayOnMain {
                RelayCallManager.current?.callKitSetMuted(uuid: uuid, isMuted: isMuted)
            }
        }, audioSessionActivationChanged: { value in
            if let manager = RelayCallManager.current {
                manager.callKitAudioSessionActivationChanged(value)
            } else if value {
                sharedManagedAudioSession?.callKitActivatedAudioSession()
            } else {
                sharedManagedAudioSession?.callKitDeactivatedAudioSession()
            }
        })
    }
}
