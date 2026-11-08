import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramAudio
import TelegramVoip
import AccountContext
import MattermostSync
import RelayCallsCore
import RelayCalls

/// MATTERMOST: a Relay room call (a group message or channel, `RelayGroupCall` over LiveKit) as Telegram's
/// `PresentationGroupCall`, so that Telegram's `VideoChatScreen`, call status bar and join panel run it unchanged.
///
/// Participants are Mattermost users (one per user, over all of its devices) shown as their peers, with stable
/// synthetic audio SSRCs and one video endpoint per user and track (`RelayCallIds`). Telegram features the plugin has
/// no backend for (admin rights, invite links, recording, scheduling, join-as, in-call messages, raised hands) report
/// nothing and do nothing.
final class RelayPresentationGroupCall: PresentationGroupCall, PresentationGroupCallVideoProviding {
    let account: Account
    let accountContext: AccountContext
    let internalId: CallSessionInternalId
    let peerId: EnginePeer.Id?
    let relayAccount: MattermostRelayCallsAccount
    let controller: RelayGroupCall
    let engine: RelayRoomEngine
    let channelId: String
    private let channelHash: Int64
    private let audioSession: ManagedAudioSession
    let callKitIntegration: CallKitIntegration?

    let schedulePending: Bool = false
    let isStream: Bool = false
    let isConference: Bool = false
    let conferenceSource: CallSessionInternalId? = nil
    var onMutedSpeechActivityDetected: ((Bool) -> Void)?

    private var relayCallIdValue: String?
    var callId: Int64? {
        return self.relayCallIdValue.map(MattermostSync.relayGroupCallId(callId:))
    }

    var currentReference: InternalGroupCallReference? {
        return self.callId.map { .id(id: $0, accessHash: self.channelHash) }
    }

    private var audioContext: SharedCallAudioContext?
    private let audioContextDisposables = DisposableSet()
    private let tonePlayer = RelayCallTonePlayer()
    private var cameraBridge: RelayCameraBridge?
    private var videoCapturer: OngoingCallVideoCapturer?
    private var useFrontCamera = true
    private let router: RelayVideoRouter
    private var observation: RelayCancellable?
    private var didConnectOnce = false
    private var isReconnectingTone = false
    private var didEnd = false
    private var isScreenSharingValue = false
    private var isMutedValue = false

    private var peers: [String: EnginePeer] = [:]
    private var requestedPeers: Set<String> = []
    private let peersDisposable = DisposableSet()
    private var lastSpoke: [String: Double] = [:]
    private var knownJoinedUserIds: Set<String>?
    /// Users seen in the room during this call: an invitee who joined and left is a former participant, not invited.
    private var everJoinedUserIds = Set<String>()

    private let statePromise: ValuePromise<PresentationGroupCallState>
    private let stateVersionPromise = ValuePromise<Int>(0)
    private var stateVersionValue = 0
    private let summaryStatePromise = ValuePromise<PresentationGroupCallSummaryState?>(nil)
    private let membersPromise: ValuePromise<PresentationGroupCallMembers?>
    private let invitedPeersPromise = ValuePromise<[PresentationGroupCallInvitedPeer]>([])
    private let audioLevelsPipe = ValuePipe<[(EnginePeer.Id, UInt32, Float, Bool)]>()
    private let myAudioLevelPromise = ValuePromise<Float>(0.0)
    private let myAudioLevelAndSpeakingPromise = Promise<(Float, Bool)>((0.0, false))
    private let isSpeakingPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let isMutedPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let canBeRemovedPromise = Promise<Bool>(false)
    private let audioOutputStatePromise = Promise<([AudioSessionOutput], AudioSessionOutput?)>(([], nil))
    private let memberEventsPipe = ValuePipe<PresentationGroupCallMemberEvent>()

    @MainActor
    init(accountContext: AccountContext, relayAccount: MattermostRelayCallsAccount, controller: RelayGroupCall, engine: RelayRoomEngine, internalId: CallSessionInternalId, peerId: EnginePeer.Id, audioSession: ManagedAudioSession, callKitIntegration: CallKitIntegration?) {
        self.account = accountContext.account
        self.accountContext = accountContext
        self.relayAccount = relayAccount
        self.controller = controller
        self.engine = engine
        self.internalId = internalId
        self.peerId = peerId
        self.channelId = controller.channelId
        self.channelHash = MattermostSync.relayGroupCallId(callId: controller.channelId)
        self.audioSession = audioSession
        self.callKitIntegration = callKitIntegration
        self.router = RelayVideoRouter(engine: engine)
        self.relayCallIdValue = controller.callId
        if let camera = engine.externalCamera {
            self.cameraBridge = RelayCameraBridge(camera: camera)
        }
        let myPeerId = accountContext.account.peerId
        self.statePromise = ValuePromise(Self.callState(myPeerId: myPeerId, snapshot: controller.snapshot, hasVideo: false), ignoreRepeated: true)
        self.membersPromise = ValuePromise(PresentationGroupCallMembers(participants: [], speakingParticipants: Set(), totalCount: 0, loadMoreToken: nil), ignoreRepeated: true)
        self.isMutedValue = controller.snapshot.isMuted
        self.isMutedPromise.set(self.isMutedValue)

        self.observation = controller.observe { [weak self] snapshot in
            self?.updated(snapshot)
        }
        self.updated(controller.snapshot)
    }

    deinit {
        self.audioContextDisposables.dispose()
        self.peersDisposable.dispose()
    }

    /// Joins (or rings) unless the controller already runs (an answered group ring calls `accept()` itself).
    @MainActor
    func start(accept: Bool) {
        self.ensureAudioContext()
        if accept {
            self.controller.accept()
        } else {
            self.controller.start()
        }
        self.updated(self.controller.snapshot)
    }

    @MainActor
    private func ensureAudioContext() {
        if self.audioContext != nil {
            return
        }
        let audioContext = SharedCallAudioContext.get(audioSession: self.audioSession, callKitIntegration: self.callKitIntegration, defaultToSpeaker: true, reuseCurrent: false, createsAudioDevice: false)
        self.audioContext = audioContext
        self.audioOutputStatePromise.set(audioContext.audioOutputState)
        self.audioContextDisposables.add((audioContext.isAudioSessionActive
        |> deliverOnMainQueue).start(next: { [weak self] isActive in
            guard let self else {
                return
            }
            if !self.didEnd {
                RelayCallAudio.setEngineAvailable(isActive)
            }
            self.tonePlayer.setAudioSessionActive(isActive)
        }))
    }

    // MARK: State

    private static func callState(myPeerId: EnginePeer.Id, snapshot: RelayGroupCall.Snapshot, hasVideo: Bool) -> PresentationGroupCallState {
        let networkState: PresentationGroupCallState.NetworkState
        switch snapshot.state {
        case .connected:
            networkState = .connected
        default:
            networkState = .connecting
        }
        return PresentationGroupCallState(
            myPeerId: myPeerId,
            networkState: networkState,
            connectionMode: .rtc,
            canManageCall: false,
            adminIds: Set(),
            muteState: snapshot.isMuted ? GroupCallParticipantsContext.Participant.MuteState(canUnmute: true, mutedByYou: false) : nil,
            defaultParticipantMuteState: nil,
            messagesAreEnabled: false,
            canEnableMessages: false,
            sendPaidMessageStars: nil,
            recordingStartTimestamp: nil,
            title: nil,
            raisedHand: false,
            scheduleTimestamp: nil,
            subscribedToScheduled: false,
            isVideoEnabled: true,
            isVideoWatchersLimitReached: false,
            isMyVideoActive: hasVideo,
            isUnifiedStream: false,
            defaultSendAs: nil
        )
    }

    @MainActor
    private func updated(_ snapshot: RelayGroupCall.Snapshot) {
        if let callId = snapshot.callId {
            self.relayCallIdValue = callId
        }
        self.isScreenSharingValue = snapshot.isScreenSharing
        if self.isMutedValue != snapshot.isMuted {
            self.isMutedValue = snapshot.isMuted
            self.isMutedPromise.set(snapshot.isMuted)
        }
        self.router.update()

        let myPeerId = self.account.peerId
        let state = Self.callState(myPeerId: myPeerId, snapshot: snapshot, hasVideo: self.videoCapturer != nil)
        self.statePromise.set(state)

        self.resolvePeers(userIds: snapshot.participants.map(\.userId) + Array(snapshot.invitees.keys))

        let now = Date().timeIntervalSince1970
        var participants: [GroupCallParticipantsContext.Participant] = []
        var speaking = Set<EnginePeer.Id>()
        var levels: [(EnginePeer.Id, UInt32, Float, Bool)] = []
        var hasSelf = false
        for participant in snapshot.participants {
            let peer: EnginePeer?
            if participant.isSelf {
                peer = self.peers[participant.userId] ?? self.peers[self.relayAccount.ownUserId]
                hasSelf = true
            } else {
                peer = self.peers[participant.userId]
            }
            guard let peer else {
                continue
            }
            if participant.isSpeaking {
                self.lastSpoke[participant.userId] = now
                speaking.insert(peer.id)
            }
            let ssrc = RelayCallIds.ssrc(userId: participant.userId)
            if !participant.isSelf {
                levels.append((peer.id, ssrc, participant.audioLevel, participant.isSpeaking))
            }
            participants.append(self.participant(peer: peer, userId: participant.userId, ssrc: ssrc, participant: participant, isSelf: participant.isSelf, isMuted: participant.isSelf ? snapshot.isMuted : !participant.isMicrophoneEnabled))
        }
        if !hasSelf, !snapshot.state.isEnded, let peer = self.peers[self.relayAccount.ownUserId] {
            // Before this device is in the room, Telegram lists the user already.
            participants.insert(GroupCallParticipantsContext.Participant(id: .peer(peer.id), peer: peer, ssrc: RelayCallIds.ssrc(userId: self.relayAccount.ownUserId), videoDescription: nil, presentationDescription: nil, joinTimestamp: Int32(now), raiseHandRating: nil, hasRaiseHand: false, activityTimestamp: nil, activityRank: nil, muteState: snapshot.isMuted ? GroupCallParticipantsContext.Participant.MuteState(canUnmute: true, mutedByYou: false) : nil, volume: nil, about: nil, joinedVideo: true, paidStarsTotal: nil), at: 0)
        }

        self.membersPromise.set(PresentationGroupCallMembers(participants: participants, speakingParticipants: speaking, totalCount: participants.count, loadMoreToken: nil))
        self.audioLevelsPipe.putNext(levels)

        if let local = snapshot.participants.first(where: { $0.isSelf })?.devices.first(where: { $0.isLocal }) {
            let level = snapshot.isMuted ? 0.0 : local.audioLevel
            self.myAudioLevelPromise.set(level)
            self.myAudioLevelAndSpeakingPromise.set(.single((level, local.isSpeaking && !snapshot.isMuted)))
            self.isSpeakingPromise.set(local.isSpeaking && !snapshot.isMuted)
            if snapshot.isMuted && local.isSpeaking {
                self.onMutedSpeechActivityDetected?(true)
            }
        }

        let callInfo = GroupCallInfo(id: self.callId ?? 0, accessHash: self.channelHash, participantCount: participants.count, streamDcId: nil, title: nil, scheduleTimestamp: nil, subscribedToScheduled: false, recordingStartTimestamp: nil, sortAscending: true, defaultParticipantsAreMuted: nil, messagesAreEnabled: nil, isVideoEnabled: true, unmutedVideoLimit: 1000, isStream: false, isCreator: false, defaultSendAs: nil)
        self.summaryStatePromise.set(PresentationGroupCallSummaryState(info: callInfo, participantCount: participants.count, callState: state, topParticipants: Array(participants.prefix(3)), activeSpeakers: speaking))
        self.stateVersionValue += 1
        self.stateVersionPromise.set(self.stateVersionValue)

        var invited: [PresentationGroupCallInvitedPeer] = []
        let joinedUserIds = Set(snapshot.participants.map(\.userId))
        self.everJoinedUserIds.formUnion(joinedUserIds)
        for (userId, inviteeState) in snapshot.invitees.sorted(by: { $0.key < $1.key }) where !self.everJoinedUserIds.contains(userId) {
            guard let peer = self.peers[userId] else {
                continue
            }
            switch inviteeState {
            case .ringing:
                invited.append(PresentationGroupCallInvitedPeer(id: peer.id, state: .requesting))
            case .received:
                invited.append(PresentationGroupCallInvitedPeer(id: peer.id, state: .ringing))
            case .accepted:
                invited.append(PresentationGroupCallInvitedPeer(id: peer.id, state: .connecting))
            case .declined, .busy, .missed:
                break
            }
        }
        self.invitedPeersPromise.set(invited)

        self.updateMemberEvents(snapshot)
        self.updateTones(snapshot)

        if case .ended = snapshot.state {
            self.ended()
        }
    }

    private func participant(peer: EnginePeer, userId: String, ssrc: UInt32, participant: RelayGroupCall.Participant, isSelf: Bool, isMuted: Bool) -> GroupCallParticipantsContext.Participant {
        var videoDescription: GroupCallParticipantsContext.Participant.VideoDescription?
        if let camera = participant.camera, camera.track.isLive {
            videoDescription = GroupCallParticipantsContext.Participant.VideoDescription(endpointId: RelayCallIds.cameraEndpoint(userId: userId), ssrcGroups: [], audioSsrc: ssrc, isPaused: false)
        }
        var presentationDescription: GroupCallParticipantsContext.Participant.VideoDescription?
        if let screen = participant.screenShare, screen.track.isLive {
            presentationDescription = GroupCallParticipantsContext.Participant.VideoDescription(endpointId: RelayCallIds.screenEndpoint(userId: userId), ssrcGroups: [], audioSsrc: ssrc, isPaused: false)
        }
        let joinTimestamp = Int32((participant.joinedAt ?? Date()).timeIntervalSince1970)
        return GroupCallParticipantsContext.Participant(
            id: .peer(peer.id),
            peer: peer,
            ssrc: ssrc,
            videoDescription: videoDescription,
            presentationDescription: presentationDescription,
            joinTimestamp: joinTimestamp,
            raiseHandRating: nil,
            hasRaiseHand: false,
            activityTimestamp: self.lastSpoke[userId],
            activityRank: nil,
            muteState: isMuted ? GroupCallParticipantsContext.Participant.MuteState(canUnmute: true, mutedByYou: false) : nil,
            volume: nil,
            about: nil,
            joinedVideo: true,
            paidStarsTotal: nil
        )
    }

    /// Loads the peers of users the call names (participants and invitees) once each; users the account has not
    /// stored yet are fetched first.
    @MainActor
    private func resolvePeers(userIds: [String]) {
        let accountId = self.account.id
        var missing: [String] = []
        for userId in Set(userIds + [self.relayAccount.ownUserId]) where self.peers[userId] == nil && !self.requestedPeers.contains(userId) {
            missing.append(userId)
        }
        if missing.isEmpty {
            return
        }
        self.requestedPeers.formUnion(missing)
        let engine = self.accountContext.engine
        let userIds = missing
        Task { @MainActor [weak self] in
            let unknown = userIds.filter { MattermostSync.relayCallPeerId(accountId: accountId, userId: $0) == nil }
            if !unknown.isEmpty {
                await MattermostSync.ensureRelayCallUsers(accountId: accountId, userIds: unknown)
            }
            guard let self else {
                return
            }
            for userId in userIds {
                guard let peerId = MattermostSync.relayCallPeerId(accountId: accountId, userId: userId) else {
                    self.requestedPeers.remove(userId)
                    continue
                }
                self.peersDisposable.add((engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                |> deliverOnMainQueue).start(next: { [weak self] peer in
                    guard let self, let peer else {
                        return
                    }
                    if self.peers[userId] != peer {
                        self.peers[userId] = peer
                        self.updated(self.controller.snapshot)
                    }
                }))
            }
        }
    }

    /// Telegram's "X joined" toasts: users who join after this device connected.
    @MainActor
    private func updateMemberEvents(_ snapshot: RelayGroupCall.Snapshot) {
        guard snapshot.state == .connected else {
            return
        }
        let current = Set(snapshot.participants.filter { !$0.isSelf }.map(\.userId))
        guard let known = self.knownJoinedUserIds else {
            self.knownJoinedUserIds = current
            return
        }
        var updatedKnown = known.intersection(current)
        for userId in current where !known.contains(userId) {
            // A user whose peer is not loaded yet is announced on a later update.
            if let peer = self.peers[userId] {
                self.memberEventsPipe.putNext(PresentationGroupCallMemberEvent(peer: peer, isContact: false, isInChatList: true, canUnmute: true, joined: true))
                updatedKnown.insert(userId)
            }
        }
        self.knownJoinedUserIds = updatedKnown
    }

    /// Telegram's group call tones: joined once connected, connecting while it reconnects, left when leaving.
    @MainActor
    private func updateTones(_ snapshot: RelayGroupCall.Snapshot) {
        switch snapshot.state {
        case .connected:
            if !self.didConnectOnce {
                self.didConnectOnce = true
                self.tonePlayer.play(.groupJoined)
            } else if self.isReconnectingTone {
                self.isReconnectingTone = false
                self.tonePlayer.setTone(nil)
            }
        case .reconnecting:
            if self.didConnectOnce && !self.isReconnectingTone {
                self.isReconnectingTone = true
                self.tonePlayer.setTone(.groupConnecting)
            }
        default:
            break
        }
    }

    @MainActor
    private func ended() {
        if self.didEnd {
            return
        }
        self.didEnd = true
        RelayCallAudio.setEngineAvailable(false)
        self.audioContext?.markCallFinished()
        self.observation?.cancel()
        self.observation = nil
        self.videoCapturer = nil
        self.cameraBridge?.setCapturer(nil)
        self.router.detachAll()
        self.canBeRemovedPromise.set(.single(true))
        if let callKitIntegration = self.callKitIntegration {
            callKitIntegration.dropCall(uuid: self.internalId)
        }
        if self.didConnectOnce {
            self.tonePlayer.play(.groupLeft)
            // Keep the session for the tone, as Telegram does.
            Queue.mainQueue().after(1.0, {
                self.tonePlayer.stop()
                self.audioContext = nil
            })
        } else {
            self.audioContext = nil
        }
    }

    // MARK: Signals

    var hasVideo: Bool {
        return self.videoCapturer != nil
    }

    var hasScreencast: Bool {
        return self.isScreenSharingValue
    }

    var audioOutputState: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> {
        return self.audioOutputStatePromise.get()
    }

    var isSpeaking: Signal<Bool, NoError> {
        return self.isSpeakingPromise.get()
    }

    var canBeRemoved: Signal<Bool, NoError> {
        return self.canBeRemovedPromise.get()
    }

    var state: Signal<PresentationGroupCallState, NoError> {
        return self.statePromise.get()
    }

    var stateVersion: Signal<Int, NoError> {
        return self.stateVersionPromise.get()
    }

    var summaryState: Signal<PresentationGroupCallSummaryState?, NoError> {
        return self.summaryStatePromise.get()
    }

    var members: Signal<PresentationGroupCallMembers?, NoError> {
        return self.membersPromise.get()
    }

    var audioLevels: Signal<[(EnginePeer.Id, UInt32, Float, Bool)], NoError> {
        return self.audioLevelsPipe.signal()
    }

    var myAudioLevel: Signal<Float, NoError> {
        return self.myAudioLevelPromise.get()
    }

    var myAudioLevelAndSpeaking: Signal<(Float, Bool), NoError> {
        return self.myAudioLevelAndSpeakingPromise.get()
    }

    var isMuted: Signal<Bool, NoError> {
        return self.isMutedPromise.get()
    }

    let isNoiseSuppressionEnabled: Signal<Bool, NoError> = .single(true)
    let e2eEncryptionKeyHash: Signal<Data?, NoError> = .single(nil)

    var memberEvents: Signal<PresentationGroupCallMemberEvent, NoError> {
        return self.memberEventsPipe.signal()
    }

    let reconnectedAsEvents: Signal<EnginePeer, NoError> = .never()

    var invitedPeers: Signal<[PresentationGroupCallInvitedPeer], NoError> {
        return self.invitedPeersPromise.get()
    }

    let inviteLinks: Signal<GroupCallInviteLinks?, NoError> = .single(nil)

    // MARK: Actions

    func toggleScheduledSubscription(_ subscribe: Bool) {
    }

    func schedule(timestamp: Int32) {
    }

    func startScheduled() {
    }

    func reconnect(with invite: String) {
    }

    func reconnect(as peerId: EnginePeer.Id) {
    }

    func leave(terminateIfPossible: Bool) -> Signal<Bool, NoError> {
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            if terminateIfPossible && self.controller.snapshot.canEnd {
                let controller = self.controller
                Task { @MainActor in
                    do {
                        try await controller.endForEveryone()
                    } catch {
                        controller.leave()
                    }
                }
            } else {
                self.controller.leave()
            }
        }
        return self.canBeRemovedPromise.get()
    }

    func toggleIsMuted() {
        self.setIsMuted(action: self.isMutedValue ? .unmuted : .muted(isPushToTalkActive: false))
    }

    func setIsMuted(action: PresentationGroupCallMuteAction) {
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            let muted = action.isEffectivelyMuted
            if muted != self.controller.snapshot.isMuted {
                self.controller.setMuted(muted)
            }
        }
    }

    func setIsNoiseSuppressionEnabled(_ isNoiseSuppressionEnabled: Bool) {
    }

    func raiseHand() {
    }

    func lowerHand() {
    }

    func requestVideo() {
        relayOnMain { [weak self] in
            self?.startCamera(capturer: nil)
        }
    }

    func requestVideo(capturer: OngoingCallVideoCapturer, useFrontCamera: Bool) {
        relayOnMain { [weak self] in
            self?.useFrontCamera = useFrontCamera
            self?.startCamera(capturer: capturer)
        }
    }

    @MainActor
    private func startCamera(capturer: OngoingCallVideoCapturer?) {
        let capturer = capturer ?? self.videoCapturer ?? OngoingCallVideoCapturer()
        self.videoCapturer = capturer
        // Takes the capturer's output back from the preview view.
        self.cameraBridge?.setCapturer(capturer, resubscribe: true)
        self.controller.setCameraEnabled(true)
        self.updated(self.controller.snapshot)
    }

    func disableVideo() {
        relayOnMain { [weak self] in
            guard let self else {
                return
            }
            self.videoCapturer = nil
            self.cameraBridge?.setCapturer(nil)
            self.controller.setCameraEnabled(false)
            self.updated(self.controller.snapshot)
        }
    }

    func disableScreencast() {
        relayOnMain { [weak self] in
            self?.controller.setScreenShare(enabled: false)
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

    func updateDefaultParticipantsAreMuted(isMuted: Bool) {
    }

    func updateMessagesEnabled(isEnabled: Bool, sendPaidMessageStars: Int64?) {
    }

    func setVolume(peerId: EnginePeer.Id, volume: Int32, sync: Bool) {
    }

    func setRequestedVideoList(items: [PresentationGroupCallRequestedVideo]) {
        var qualities: [String: RelayVideoRouter.Quality] = [:]
        for item in items {
            let quality: RelayVideoRouter.Quality
            switch item.maxQuality {
            case .thumbnail:
                quality = .thumbnail
            case .medium:
                quality = .medium
            case .full:
                quality = .full
            }
            qualities[item.endpointId] = quality
        }
        relayOnMain { [weak self] in
            self?.router.setRequested(qualities)
        }
    }

    func setSuspendVideoChannelRequests(_ value: Bool) {
    }

    func setCurrentAudioOutput(_ output: AudioSessionOutput) {
        relayOnMain { [weak self] in
            self?.audioContext?.setCurrentAudioOutput(output)
        }
    }

    func playTone(_ tone: PresentationGroupCallTone) {
        let name: String
        switch tone {
        case .unmuted:
            name = "voip_group_unmuted.mp3"
        case .recordingStarted:
            name = "voip_group_recording_started.mp3"
        }
        relayOnMain { [weak self] in
            self?.tonePlayer.play(.custom(name: name, loopCount: 1))
        }
    }

    func updateMuteState(peerId: EnginePeer.Id, isMuted: Bool) -> GroupCallParticipantsContext.Participant.MuteState? {
        return nil
    }

    func setShouldBeRecording(_ shouldBeRecording: Bool, title: String?, videoOrientation: Bool?) {
    }

    func updateTitle(_ title: String) {
    }

    func invitePeer(_ peerId: EnginePeer.Id, isVideo: Bool) -> Bool {
        return false
    }

    func kickPeer(id: EnginePeer.Id) {
    }

    func removedPeer(_ peerId: EnginePeer.Id) {
    }

    func makeOutgoingVideoView(requestClone: Bool, completion: @escaping (PresentationCallVideoView?, PresentationCallVideoView?) -> Void) {
        relayOnMain { [weak self] in
            guard let self else {
                completion(nil, nil)
                return
            }
            if self.videoCapturer == nil {
                self.videoCapturer = OngoingCallVideoCapturer()
            }
            self.videoCapturer?.makeOutgoingVideoView(requestClone: requestClone, completion: { mainView, cloneView in
                completion(mainView.flatMap(relayPresentationCallVideoView), cloneView.flatMap(relayPresentationCallVideoView))
            })
        }
    }

    func loadMoreMembers(token: String) {
    }

    // MARK: PresentationGroupCallVideoProviding

    func video(endpointId: String) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError>? {
        guard let endpoint = RelayCallIds.parseEndpoint(endpointId) else {
            return nil
        }
        let ownUserId = self.relayAccount.ownUserId
        if case let .camera(userId) = endpoint, userId == ownUserId, let capturer = self.videoCapturer {
            // This device's camera: Telegram's own capturer, as for Telegram's group calls. Its single output feeds
            // LiveKit, so the frames are shared (`RelayCameraBridge`).
            return self.cameraBridge?.frames ?? capturer.video()
        }
        let controller = self.controller
        return self.router.video(key: endpointId, resolve: { [weak controller] in
            guard let controller else {
                return nil
            }
            switch endpoint {
            case let .camera(userId):
                guard let video = controller.participants.first(where: { $0.userId == userId })?.camera, video.track.isLive else {
                    return nil
                }
                return video.track.sid
            case let .screen(userId):
                guard let video = controller.participants.first(where: { $0.userId == userId })?.screenShare, video.track.isLive else {
                    return nil
                }
                return video.track.sid
            }
        })
    }

    // MARK: Manager

    @MainActor
    func handle(_ event: RelayCallsEvent) {
        self.controller.handle(event)
    }
}
