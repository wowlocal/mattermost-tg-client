import Foundation
import CallKit
import SwiftSignalKit
import TelegramCore
import TelegramAudio
import TelegramVoip
import AccountContext
import MattermostSync
import RelayCallsCore
import RelayCalls

/// MATTERMOST: a Relay 1:1 call (a Mattermost DM, `RelayDirectCall` over LiveKit) as Telegram's `PresentationCall`, so
/// that Telegram's own ringing (CallKit or the in-app banner), `CallController`/`PrivateCallScreen`, tones, call status
/// bar and picture in picture run it unchanged.
///
/// It also stands for an incoming ring of a group message (`RelayGroupCall`) while it rings: Telegram rings it as a
/// call, and answering hands it to `RelayCallManager`, which continues it as a group call in `VideoChatScreen`.
final class RelayPresentationCall: PresentationCall, PresentationCallVideoProviding {
    enum Kind {
        case direct(RelayDirectCall)
        case groupRing(RelayGroupCall)
    }

    let context: AccountContext
    let internalId: CallSessionInternalId
    let peerId: EnginePeer.Id
    let isOutgoing: Bool
    let isVideo: Bool
    let isVideoPossible: Bool = true
    let peer: EnginePeer?
    /// The plugin's call id, once known (an outgoing call learns it from the ring answer).
    @MainActor
    var relayCallId: String? {
        switch self.kind {
        case let .direct(call):
            return call.callId
        case let .groupRing(call):
            return call.callId
        }
    }

    let kind: Kind
    let engine: RelayRoomEngine
    let relayAccount: MattermostRelayCallsAccount
    private let audioSession: ManagedAudioSession
    private let callKitIntegration: CallKitIntegration?
    var isIntegratedWithCallKit: Bool {
        return self.callKitIntegration != nil
    }

    /// The manager continues an answered group ring as a group call.
    var answerGroupRing: ((RelayPresentationCall) -> Void)?

    private var audioContext: SharedCallAudioContext?
    private let audioContextDisposables = DisposableSet()
    private let tonePlayer = RelayCallTonePlayer()
    private var cameraBridge: RelayCameraBridge?
    private var videoCapturer: OngoingCallVideoCapturer?
    private var useFrontCamera = true
    private let router: RelayVideoRouter
    private var observation: RelayCancellable?
    private var lastState: RelayDirectCall.State?
    private var wasAnswered = false
    private var reportedConnected = false
    private var didTerminate = false
    private var isHandedOver = false

    private let statePromise: ValuePromise<PresentationCallState>
    private let audioLevelPromise = ValuePromise<Float>(0.0)
    private let isMutedPromise = ValuePromise<Bool>(false)
    private let audioOutputStatePromise = Promise<([AudioSessionOutput], AudioSessionOutput?)>(([], nil))
    private let canBeRemovedPromise = Promise<Bool>(false)
    private let hungUpPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var isMutedValue = false
    private var isScreenSharingValue = false

    var state: Signal<PresentationCallState, NoError> {
        return self.statePromise.get()
    }

    var audioLevel: Signal<Float, NoError> {
        return self.audioLevelPromise.get()
    }

    var isMuted: Signal<Bool, NoError> {
        return self.isMutedPromise.get()
    }

    var audioOutputState: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> {
        return self.audioOutputStatePromise.get()
    }

    var canBeRemoved: Signal<Bool, NoError> {
        return self.canBeRemovedPromise.get()
    }

    let conferenceState: Signal<PresentationCallConferenceState?, NoError> = .single(nil)
    let conferenceStateValue: PresentationCallConferenceState? = nil
    let conferenceCall: PresentationGroupCall? = nil
    let pendingInviteToConferencePeerIds: [(id: EnginePeer.Id, isVideo: Bool)] = []

    @MainActor
    init(context: AccountContext, relayAccount: MattermostRelayCallsAccount, kind: Kind, engine: RelayRoomEngine, internalId: CallSessionInternalId, peerId: EnginePeer.Id, peer: EnginePeer?, isOutgoing: Bool, isVideo: Bool, audioSession: ManagedAudioSession, callKitIntegration: CallKitIntegration?) {
        self.context = context
        self.relayAccount = relayAccount
        self.kind = kind
        self.engine = engine
        self.internalId = internalId
        self.peerId = peerId
        self.peer = peer
        self.isOutgoing = isOutgoing
        self.isVideo = isVideo
        self.audioSession = audioSession
        self.callKitIntegration = callKitIntegration
        self.router = RelayVideoRouter(engine: engine)
        let initialState: PresentationCallState.State = isOutgoing ? .waiting : .ringing
        self.statePromise = ValuePromise(PresentationCallState(state: initialState, videoState: .inactive, remoteVideoState: .inactive, remoteAudioState: .active, remoteBatteryLevel: .normal, supportsConferenceCalls: false))

        if let camera = engine.externalCamera {
            self.cameraBridge = RelayCameraBridge(camera: camera)
        }

        switch kind {
        case let .direct(call):
            self.observation = call.observe { [weak self] snapshot in
                self?.directUpdated(snapshot)
            }
        case let .groupRing(call):
            self.observation = call.observe { [weak self] snapshot in
                self?.groupRingUpdated(snapshot)
            }
        }
    }

    deinit {
        self.audioContextDisposables.dispose()
    }

    /// Starts ringing (outgoing) or reports the incoming ring as shown.
    @MainActor
    func start() {
        if self.isOutgoing {
            self.ensureAudioContext()
            if self.isVideo {
                self.startCamera(capturer: nil)
            }
        }
        switch self.kind {
        case let .direct(call):
            call.start()
            self.directUpdated(call.snapshot)
        case let .groupRing(call):
            call.start()
        }
    }

    // MARK: Audio

    @MainActor
    private func ensureAudioContext() {
        if self.audioContext != nil {
            return
        }
        let audioContext = SharedCallAudioContext.get(audioSession: self.audioSession, callKitIntegration: self.callKitIntegration, defaultToSpeaker: self.isVideo, reuseCurrent: false, createsAudioDevice: false)
        self.audioContext = audioContext
        self.audioOutputStatePromise.set(audioContext.audioOutputState)
        self.audioContextDisposables.add((audioContext.isAudioSessionActive
        |> deliverOnMainQueue).start(next: { [weak self] isActive in
            guard let self else {
                return
            }
            if !self.didTerminate {
                RelayCallAudio.setEngineAvailable(isActive)
            }
            self.tonePlayer.setAudioSessionActive(isActive)
        }))
    }

    // MARK: State

    @MainActor
    private func directUpdated(_ snapshot: RelayDirectCall.Snapshot) {
        if self.isHandedOver {
            return
        }
        let previous = self.lastState
        self.lastState = snapshot.state
        switch snapshot.state {
        case .connecting, .active, .reconnecting:
            self.wasAnswered = true
        default:
            break
        }
        self.isScreenSharingValue = snapshot.isScreenSharing

        self.router.update()

        if self.isMutedValue != snapshot.isMuted {
            self.isMutedValue = snapshot.isMuted
            self.isMutedPromise.set(snapshot.isMuted)
        }
        self.audioLevelPromise.set(snapshot.remote?.audioLevel ?? 0.0)

        let mappedState: PresentationCallState.State
        switch snapshot.state {
        case let .requesting(ringing):
            mappedState = .requesting(ringing)
        case .ringing:
            mappedState = .ringing
        case .connecting:
            mappedState = .connecting(nil)
        case let .active(since):
            mappedState = .active(since.timeIntervalSinceReferenceDate, Self.signalQuality(snapshot.local?.connectionQuality), Data())
            if self.isOutgoing && !self.reportedConnected {
                self.reportedConnected = true
                self.callKitIntegration?.reportOutgoingCallConnected(uuid: self.internalId, at: Date())
            }
        case let .reconnecting(since):
            mappedState = .reconnecting(since.timeIntervalSinceReferenceDate, nil, Data())
        case let .terminated(reason, _):
            mappedState = .terminated(nil, Self.terminationReason(reason), false)
        }

        let videoState: PresentationCallState.VideoState
        if snapshot.isScreenSharing {
            videoState = .active(isScreencast: true, endpointId: "relay:local:screen")
        } else if self.videoCapturer != nil && snapshot.isCameraEnabled {
            videoState = .active(isScreencast: false, endpointId: "relay:local:camera")
        } else {
            videoState = .inactive
        }
        let remoteVideoState: PresentationCallState.RemoteVideoState
        if let sid = Self.remoteVideoSid(snapshot) {
            remoteVideoState = .active(endpointId: sid)
        } else {
            remoteVideoState = .inactive
        }
        let remoteAudioState: PresentationCallState.RemoteAudioState
        if let remote = snapshot.remote, !remote.isMicrophoneEnabled {
            remoteAudioState = .muted
        } else {
            remoteAudioState = .active
        }
        self.statePromise.set(PresentationCallState(state: mappedState, videoState: videoState, remoteVideoState: remoteVideoState, remoteAudioState: remoteAudioState, remoteBatteryLevel: .normal, supportsConferenceCalls: false))

        self.updateTone(state: snapshot.state, previous: previous)

        if case let .terminated(reason, _) = snapshot.state {
            self.terminated(reason: reason)
        }
    }

    @MainActor
    private func groupRingUpdated(_ snapshot: RelayGroupCall.Snapshot) {
        if self.isHandedOver {
            return
        }
        switch snapshot.state {
        case .ringing, .connecting, .connected, .reconnecting:
            break
        case let .ended(reason):
            let mapped: RelayDirectCall.EndReason
            switch reason {
            case .answeredElsewhere:
                mapped = .answeredElsewhere
            case .declined:
                mapped = .declinedLocally
            case .missed:
                mapped = .missed
            case let .failed(message):
                mapped = .failed(message)
            case .left, .ended, .removed:
                mapped = .cancelled
            }
            self.statePromise.set(PresentationCallState(state: .terminated(nil, Self.terminationReason(mapped), false), videoState: .inactive, remoteVideoState: .inactive, remoteAudioState: .active, remoteBatteryLevel: .normal, supportsConferenceCalls: false))
            self.terminated(reason: mapped)
        }
    }

    private static func remoteVideoSid(_ snapshot: RelayDirectCall.Snapshot) -> String? {
        guard let remote = snapshot.remote else {
            return nil
        }
        if let screen = remote.screenShare, screen.isLive {
            return screen.sid
        }
        if let camera = remote.camera, camera.isLive {
            return camera.sid
        }
        return nil
    }

    private static func signalQuality(_ quality: RelayConnectionQuality?) -> Int32? {
        switch quality {
        case .excellent?:
            return 4
        case .good?:
            return 3
        case .poor?:
            return 1
        case .lost?:
            return 0
        case .unknown?, nil:
            return nil
        }
    }

    /// The shared core's end reasons in Telegram's terms (docs/livekit-calls-native-ui.md, `RelayDirectCall`):
    /// `PrivateCallScreen` shows a hung up call that never started as declined.
    static func terminationReason(_ reason: RelayDirectCall.EndReason) -> CallSessionTerminationReason {
        switch reason {
        case .hangup, .remoteHangup, .declined, .declinedLocally, .answeredElsewhere, .declinedElsewhere, .ended:
            return .ended(.hungUp)
        case .busy:
            return .ended(.busy)
        case .missed, .cancelled:
            return .ended(.missed)
        case .failed:
            return .error(.generic)
        }
    }

    /// Telegram's `PresentationCallImpl.updateTone`: ringback while the callee's device rings, the connecting tone while
    /// an answered voice call connects, busy/ended/failed when a call that was going ends.
    @MainActor
    private func updateTone(state: RelayDirectCall.State, previous: RelayDirectCall.State?) {
        var tone: PresentationCallTone?
        switch state {
        case .requesting(true):
            tone = .ringing
        case .connecting:
            if case .requesting? = previous {
                tone = .ringing
            } else if self.tonePlayer.tone == .ringing {
                tone = .ringing
            } else if !self.isVideo {
                tone = .connecting
            }
        case .reconnecting:
            if !self.isVideo {
                tone = .connecting
            }
        case let .terminated(reason, _):
            guard self.isOutgoing || self.wasAnswered else {
                break
            }
            switch Self.terminationReason(reason) {
            case .ended(.busy):
                tone = .busy
            case .ended(.hungUp), .ended(.missed):
                tone = .ended
            case .ended(.switchedToConference):
                tone = nil
            case .error:
                tone = .failed
            }
        default:
            tone = nil
        }
        if case .terminated = state, let tone {
            self.tonePlayer.play(tone)
        } else {
            self.tonePlayer.setTone(tone)
        }
    }

    @MainActor
    private func terminated(reason: RelayDirectCall.EndReason) {
        if self.didTerminate {
            return
        }
        self.didTerminate = true
        if self.audioContext != nil {
            RelayCallAudio.setEngineAvailable(false)
        }
        self.audioContext?.markCallFinished()
        self.stopCamera()
        self.router.detachAll()
        self.hungUpPromise.set(true)
        self.canBeRemovedPromise.set(.single(true) |> delay(2.0, queue: Queue.mainQueue()))

        guard let callKitIntegration = self.callKitIntegration else {
            return
        }
        let uuid = self.internalId
        switch reason {
        case .answeredElsewhere:
            callKitIntegration.reportCallEnded(uuid: uuid, reason: .answeredElsewhere)
        case .declinedElsewhere:
            callKitIntegration.reportCallEnded(uuid: uuid, reason: .declinedElsewhere)
        case .missed where !self.isOutgoing:
            callKitIntegration.reportCallEnded(uuid: uuid, reason: .unanswered)
        default:
            if self.isOutgoing || self.wasAnswered {
                // As Telegram: keep the session for the end tone (CallKit deactivates it with the call).
                Queue.mainQueue().after(2.0, {
                    callKitIntegration.dropCall(uuid: uuid)
                })
            } else {
                callKitIntegration.dropCall(uuid: uuid)
            }
        }
    }

    /// Ends this ring's part: the manager continues it as a group call (same CallKit call, same room).
    @MainActor
    func handOver() {
        self.isHandedOver = true
        self.observation?.cancel()
        self.observation = nil
        self.tonePlayer.stop()
        self.canBeRemovedPromise.set(.single(true))
    }

    // MARK: Camera

    @MainActor
    private func startCamera(capturer: OngoingCallVideoCapturer?) {
        let capturer = capturer ?? self.videoCapturer ?? OngoingCallVideoCapturer()
        self.videoCapturer = capturer
        self.cameraBridge?.setCapturer(capturer)
        if case let .direct(call) = self.kind {
            call.setCameraEnabled(true)
            self.directUpdated(call.snapshot)
        }
    }

    @MainActor
    private func stopCamera() {
        self.videoCapturer = nil
        self.cameraBridge?.setCapturer(nil)
    }

    // MARK: PresentationCall

    func answer() {
        self.answer(fromCallKitAction: false)
    }

    func answer(fromCallKitAction: Bool) {
        relayOnMain { [weak self] in
            guard let self, !self.didTerminate else {
                return
            }
            if let callKitIntegration = self.callKitIntegration, !fromCallKitAction {
                // CallKit performs the answer and calls back (`RelayCallManager`).
                callKitIntegration.answerCall(uuid: self.internalId)
                return
            }
            switch self.kind {
            case let .direct(call):
                guard call.state == .ringing else {
                    return
                }
                self.wasAnswered = true
                self.ensureAudioContext()
                call.accept()
                if self.isVideo {
                    self.startCamera(capturer: nil)
                }
            case .groupRing:
                self.answerGroupRing?(self)
            }
        }
    }

    func hangUp() -> Signal<Bool, NoError> {
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            switch self.kind {
            case let .direct(call):
                call.hangup()
            case let .groupRing(call):
                call.decline()
            }
        }
        return self.hungUpPromise.get()
    }

    func rejectBusy() {
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            switch self.kind {
            case let .direct(call):
                if call.state == .ringing {
                    call.decline(reason: .busy)
                } else {
                    call.hangup()
                }
            case let .groupRing(call):
                call.decline(reason: .busy)
            }
        }
    }

    func toggleIsMuted() {
        self.setIsMuted(!self.isMutedValue)
    }

    func setIsMuted(_ value: Bool) {
        relayOnMain { [weak self] in
            guard let self, case let .direct(call) = self.kind else {
                return
            }
            call.setMuted(value)
        }
    }

    func requestVideo() {
        relayOnMain { [weak self] in
            self?.startCamera(capturer: nil)
        }
    }

    func requestVideo(capturer: OngoingCallVideoCapturer) {
        relayOnMain { [weak self] in
            self?.startCamera(capturer: capturer)
        }
    }

    func setRequestedVideoAspect(_ aspect: Float) {
    }

    func disableVideo() {
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            self.stopCamera()
            if case let .direct(call) = self.kind {
                call.setCameraEnabled(false)
                self.directUpdated(call.snapshot)
            }
        }
    }

    func setOutgoingVideoIsPaused(_ isPaused: Bool) {
        relayOnMain { [weak self] in
            self?.videoCapturer?.setIsVideoEnabled(!isPaused)
        }
    }

    func switchVideoCamera() {
        relayOnMain { [weak self] in
            guard let self, let capturer = self.videoCapturer else {
                return
            }
            self.useFrontCamera = !self.useFrontCamera
            capturer.switchVideoInput(isFront: self.useFrontCamera)
        }
    }

    func setCurrentAudioOutput(_ output: AudioSessionOutput) {
        relayOnMain { [weak self] in
            self?.audioContext?.setCurrentAudioOutput(output)
        }
    }

    func debugInfo() -> Signal<(String, String), NoError> {
        return .single(("", ""))
    }

    func upgradeToConference(invitePeers: [(id: EnginePeer.Id, isVideo: Bool)], completion: @escaping (PresentationGroupCall) -> Void) -> Disposable {
        return EmptyDisposable
    }

    func makeOutgoingVideoView(completion: @escaping (PresentationCallVideoView?) -> Void) {
        relayOnMain { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            if self.videoCapturer == nil {
                // The camera preview's capturer; sending starts with `requestVideo()`.
                self.videoCapturer = OngoingCallVideoCapturer()
            }
            self.videoCapturer?.makeOutgoingVideoView(requestClone: false, completion: { view, _ in
                completion(view.flatMap(relayPresentationCallVideoView))
            })
        }
    }

    // MARK: PresentationCallVideoProviding

    var hasVideo: Bool {
        return self.videoCapturer != nil
    }

    var hasScreencast: Bool {
        return self.isScreenSharingValue
    }

    var isAudioOutputBuiltin: Bool {
        if let audioContext = self.audioContext, case .builtin = audioContext.currentAudioOutputValue {
            return true
        }
        return false
    }

    func video(isIncoming: Bool) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError>? {
        if !isIncoming {
            return self.videoCapturer?.video()
        }
        guard case let .direct(call) = self.kind else {
            return nil
        }
        return self.router.video(key: "remote", resolve: { [weak call] in
            guard let call else {
                return nil
            }
            return Self.remoteVideoSid(call.snapshot)
        })
    }

    func disableScreencast() {
        relayOnMain { [weak self] in
            guard let self, case let .direct(call) = self.kind else {
                return
            }
            call.setScreenShare(enabled: false)
        }
    }

    func playRemoteCameraTone() {
        relayOnMain { [weak self] in
            self?.tonePlayer.play(.custom(name: "voip_group_recording_started.mp3", loopCount: 1))
        }
    }

    // MARK: Manager

    /// CallKit's mute button.
    func setMutedFromCallKit(_ value: Bool) {
        self.setIsMuted(value)
    }

    /// Feeds the account's plugin events.
    @MainActor
    func handle(_ event: RelayCallsEvent) {
        switch self.kind {
        case let .direct(call):
            call.handle(event)
        case let .groupRing(call):
            call.handle(event)
        }
    }

    @MainActor
    var groupRingController: RelayGroupCall? {
        if case let .groupRing(call) = self.kind {
            return call
        }
        return nil
    }
}
