import Foundation

/// A 1:1 call in a Mattermost DM (`kind: direct`): the state machine behind Telegram's private call screens. UI free;
/// the platform adapters map `State` onto Telegram's call states and feed `handle(_:)` with the account's
/// `RelayCallsEvent`s.
///
/// Outgoing: `outgoing(…)` + `start()` rings (`POST /channels/<id>/ring`) and connects the media right away, so the
/// call starts the moment the callee's device joins; `.requesting(ringing: true)` once a callee device reported
/// `received` (ringback). Incoming: from the `incoming` event or a VoIP push; `start()` reports `received` (and, for
/// a push, first checks the call still rings for this user); `accept()` / `decline()`. Both sides expire the ring
/// locally at `ring_expires_at`.
@MainActor
public final class RelayDirectCall {
    /// Mirrors Telegram's `PresentationCallState.State`.
    public enum State: Equatable, Sendable {
        /// Outgoing, not answered; `ringing` once a device of the callee shows the call.
        case requesting(ringing: Bool)
        /// Incoming, not answered.
        case ringing
        /// Answered; the media connects (or the other side's device has not joined yet).
        case connecting
        case active(since: Date)
        /// The media or the other side's device dropped after the call was active.
        case reconnecting(since: Date)
        /// `duration` counts from the answer; nil for calls that were never answered.
        case terminated(EndReason, duration: TimeInterval?)

        public var isTerminated: Bool {
            if case .terminated = self {
                return true
            }
            return false
        }
    }

    public enum EndReason: Equatable, Sendable {
        /// This device hung up (an outgoing call that was not answered yet: cancelled).
        case hangup
        /// The other user hung up an answered call.
        case remoteHangup
        /// Outgoing: the callee declined.
        case declined
        /// Incoming: this device declined.
        case declinedLocally
        /// Outgoing: the callee is busy. Incoming: declined as busy.
        case busy
        /// Outgoing: nobody answered in time. Incoming: the ring expired.
        case missed
        /// Incoming: the caller hung up before it was answered.
        case cancelled
        /// Incoming: another device of this user answered.
        case answeredElsewhere
        /// Incoming: another device of this user declined.
        case declinedElsewhere
        /// Ended for everyone (or the plugin forgot the call).
        case ended
        case failed(String)
    }

    public struct Snapshot: Equatable, Sendable {
        public var state: State
        /// The plugin's view of the call (nil until the ring request answered, or before a pushed call was fetched).
        public var call: RelayCall?
        public var callId: String?
        public var channelId: String
        /// The other user.
        public var peerUserId: String
        public var isOutgoing: Bool
        /// The caller asked for video.
        public var isVideo: Bool
        public var isMuted: Bool
        public var isCameraEnabled: Bool
        public var isScreenSharing: Bool
        public var mediaState: RelayMediaConnectionState
        public var local: RelayMediaParticipant?
        /// The other user's device in the room.
        public var remote: RelayMediaParticipant?
    }

    public let ownUserId: String
    public let deviceId: String
    public let channelId: String
    public let peerUserId: String
    public let isOutgoing: Bool
    public let isVideo: Bool

    private let api: RelayCallsAPI
    private let engine: RelayMediaEngine
    private let scheduler: RelayCallScheduler
    private let observers = RelayObservers<Snapshot>()
    /// Seconds to wait for the plugin's `call_ended` after the ring expired before ending locally.
    public static let ringExpiryGrace: TimeInterval = 3
    static let defaultRingTimeout: TimeInterval = 45
    /// An answered call whose media does not come up (or the other device does not join) within this ends as failed.
    public static let connectTimeout: TimeInterval = 30
    /// A call that stays reconnecting this long ends as failed.
    public static let reconnectTimeout: TimeInterval = 60

    public private(set) var state: State
    public private(set) var call: RelayCall?
    public private(set) var callId: String?
    private let fromPush: Bool
    private var started = false
    private var answered = false
    private var acceptedLocally = false
    private var calleeReceived = false
    private var activeSince: Date?
    private var mediaRequested = false
    /// `connect` returned: the room can take the local tracks.
    private var mediaConnected = false
    private var media = RelayMediaSnapshot()
    /// The user's microphone and camera choices, applied (and retried) while the media is up.
    private let microphone: RelayLocalSource
    private let camera: RelayLocalSource
    private var isScreenSharing = false
    private var ringTimer: RelayCancellable?
    private enum MediaWait {
        case connecting
        case reconnecting
    }
    private var mediaTimer: (wait: MediaWait, timer: RelayCancellable)?

    private init(api: RelayCallsAPI, engine: RelayMediaEngine, scheduler: RelayCallScheduler, ownUserId: String, deviceId: String, channelId: String, peerUserId: String, isOutgoing: Bool, isVideo: Bool, call: RelayCall?, callId: String?, fromPush: Bool) {
        self.api = api
        self.engine = engine
        self.scheduler = scheduler
        self.ownUserId = ownUserId
        self.deviceId = deviceId
        self.channelId = channelId
        self.peerUserId = peerUserId
        self.isOutgoing = isOutgoing
        self.isVideo = isVideo
        self.microphone = RelayLocalSource(name: "microphone", wanted: true, scheduler: scheduler, retryDelays: RelayLocalSource.microphoneRetryDelays, apply: { [engine] enabled in
            try await engine.setMicrophone(enabled: enabled)
        })
        // Nothing to turn off before the camera was ever published.
        self.camera = RelayLocalSource(name: "camera", wanted: isVideo && isOutgoing, applied: false, scheduler: scheduler, retryDelays: RelayLocalSource.cameraRetryDelays, apply: { [engine] enabled in
            try await engine.setCamera(enabled: enabled)
        })
        self.call = call
        self.callId = callId
        self.fromPush = fromPush
        self.state = isOutgoing ? .requesting(ringing: false) : .ringing
        self.microphone.describe = { [weak self] in
            self?.logName ?? "direct call"
        }
        self.camera.describe = self.microphone.describe
        self.camera.onRetriesExhausted = { [weak self] in
            // A camera that cannot publish shows as off (the user can turn it on again).
            guard let self, !self.state.isTerminated else {
                return
            }
            self.camera.setWanted(false)
            self.notify()
        }
        self.engine.onChange = { [weak self] snapshot in
            self?.mediaChanged(snapshot)
        }
        self.engine.onDisconnect = { [weak self] reason in
            self?.mediaDisconnected(reason)
        }
    }

    /// A call to `peerUserId` in the DM `channelId`.
    public static func outgoing(api: RelayCallsAPI, engine: RelayMediaEngine, ownUserId: String, deviceId: String, channelId: String, peerUserId: String, video: Bool, scheduler: RelayCallScheduler? = nil) -> RelayDirectCall {
        return RelayDirectCall(api: api, engine: engine, scheduler: scheduler ?? RelaySystemScheduler.shared, ownUserId: ownUserId, deviceId: deviceId, channelId: channelId, peerUserId: peerUserId, isOutgoing: true, isVideo: video, call: nil, callId: nil, fromPush: false)
    }

    /// A ring from the `incoming` event (or `GET /calls/active`).
    public static func incoming(api: RelayCallsAPI, engine: RelayMediaEngine, ownUserId: String, deviceId: String, call: RelayCall, scheduler: RelayCallScheduler? = nil) -> RelayDirectCall {
        return RelayDirectCall(api: api, engine: engine, scheduler: scheduler ?? RelaySystemScheduler.shared, ownUserId: ownUserId, deviceId: deviceId, channelId: call.channelId, peerUserId: call.startedBy, isOutgoing: false, isVideo: call.video, call: call, callId: call.id, fromPush: false)
    }

    /// A ring from a VoIP push: `start()` checks the call still rings for this user before reporting `received`.
    public static func incoming(api: RelayCallsAPI, engine: RelayMediaEngine, ownUserId: String, deviceId: String, push: RelayCallPush, scheduler: RelayCallScheduler? = nil) -> RelayDirectCall {
        let call = RelayCall(id: push.callId, channelId: push.channelId, kind: .direct, state: .ringing, video: push.video, startedBy: push.callerId, ringExpiresAt: push.ringExpiresAt, invitees: [ownUserId: .ringing])
        return RelayDirectCall(api: api, engine: engine, scheduler: scheduler ?? RelaySystemScheduler.shared, ownUserId: ownUserId, deviceId: deviceId, channelId: push.channelId, peerUserId: push.callerId, isOutgoing: false, isVideo: push.video, call: call, callId: push.callId, fromPush: true)
    }

    /// Declines a ring this device cannot take (another call is running) without creating a controller.
    public static func declineBusy(api: RelayCallsAPI, callId: String, deviceId: String) async {
        await relayLogFailure("call \(callId): busy decline") {
            try await api.decline(callId: callId, deviceId: deviceId, reason: .busy)
        }
    }

    public var snapshot: Snapshot {
        return Snapshot(
            state: self.state,
            call: self.call,
            callId: self.callId,
            channelId: self.channelId,
            peerUserId: self.peerUserId,
            isOutgoing: self.isOutgoing,
            isVideo: self.isVideo,
            isMuted: !self.microphone.wanted,
            isCameraEnabled: self.camera.wanted,
            isScreenSharing: self.isScreenSharing,
            mediaState: self.media.connectionState,
            local: self.media.local,
            remote: self.remoteParticipant
        )
    }

    /// Calls `handler` with every new snapshot (not with the current one).
    public func observe(_ handler: @escaping @MainActor (Snapshot) -> Void) -> RelayCancellable {
        return self.observers.add { snapshot in
            MainActor.assumeIsolated {
                handler(snapshot)
            }
        }
    }

    // MARK: Actions

    public func start() {
        guard !self.started, !self.state.isTerminated else {
            return
        }
        self.started = true
        if self.isOutgoing {
            Task { await self.ring() }
        } else {
            self.scheduleRingExpiry()
            Task { await self.reportReceived() }
        }
        self.notify()
    }

    /// Answers an incoming ring.
    public func accept() {
        guard !self.isOutgoing, self.state == .ringing, let callId = self.callId else {
            return
        }
        self.acceptedLocally = true
        self.answered = true
        self.ringTimer?.cancel()
        self.state = .connecting
        self.updateMediaTimer()
        self.notify()
        Task {
            do {
                let join = try await self.api.accept(callId: callId, deviceId: self.deviceId)
                guard !self.state.isTerminated else {
                    await relayLogFailure("\(self.logName): hangup") {
                        try await self.api.hangup(callId: callId, deviceId: self.deviceId)
                    }
                    return
                }
                self.apply(call: join.call)
                await self.connectMedia(join)
            } catch {
                await self.acceptFailed(error)
            }
        }
    }

    /// Declines an incoming ring (`busy` when another call is running here).
    public func decline(reason: RelayDeclineReason = .declined) {
        guard !self.isOutgoing, self.state == .ringing else {
            return
        }
        self.terminate(reason == .busy ? .busy : .declinedLocally)
        if let callId = self.callId {
            let deviceId = self.deviceId
            let api = self.api
            let logName = self.logName
            Task {
                await relayLogFailure("\(logName): decline") {
                    try await api.decline(callId: callId, deviceId: deviceId, reason: reason)
                }
            }
        }
    }

    /// Hangs up: cancels an unanswered outgoing call, declines an unanswered incoming one, ends an answered call for
    /// both sides.
    public func hangup() {
        if !self.isOutgoing && self.state == .ringing {
            self.decline()
            return
        }
        guard !self.state.isTerminated else {
            return
        }
        self.terminate(.hangup)
        if let callId = self.callId {
            self.sendHangup(callId: callId)
        }
    }

    /// The user's microphone choice. It stays what the user chose when the microphone fails to publish: the call keeps
    /// trying (`audioBecameAvailable()`, short retries) and logs every failure (`RelayCallsLog`).
    public func setMuted(_ muted: Bool) {
        self.microphone.setWanted(!muted)
        self.notify()
    }

    /// The platform's audio engine may record now (iOS: CallKit activated the call's audio session and LiveKit's engine
    /// became available, or the microphone permission was granted): a microphone that failed to publish is tried again.
    public func audioBecameAvailable() {
        guard !self.state.isTerminated else {
            return
        }
        self.microphone.retry(reason: "audio became available")
    }

    /// Camera on or off (also during a voice call: Telegram lets either side add video). A camera that keeps failing
    /// to publish turns off after a few retries.
    public func setCameraEnabled(_ enabled: Bool) {
        self.camera.setWanted(enabled)
        self.notify()
    }

    public func setScreenShare(enabled: Bool) {
        guard self.media.connectionState == .connected else {
            return
        }
        self.isScreenSharing = enabled
        self.notify()
        Task {
            do {
                try await self.engine.setScreenShare(enabled: enabled)
            } catch {
                RelayCallsLog.log("\(self.logName): screen share \(enabled ? "on" : "off") failed: \(error)")
                self.isScreenSharing = false
                self.notify()
            }
        }
    }

    // MARK: Events

    /// Feeds an account event; events about other calls are ignored.
    public func handle(_ event: RelayCallsEvent) {
        guard !self.state.isTerminated else {
            return
        }
        switch event {
        case let .incoming(call, _):
            self.apply(call: call)
        case let .callUpdated(call):
            self.apply(call: call)
        case let .callEnded(call):
            guard call.id == self.callId else {
                return
            }
            self.ended(call)
        case let .callState(call, userId, deviceId, action):
            guard call.id == self.callId else {
                return
            }
            self.apply(call: call)
            guard !self.state.isTerminated else {
                return
            }
            self.stateAction(userId: userId, deviceId: deviceId, action: action)
        case let .activeCalls(calls):
            guard let callId = self.callId else {
                return
            }
            if let call = calls.first(where: { $0.id == callId }) {
                self.apply(call: call)
            } else {
                // Missing from the active calls: it ended while the socket was away.
                Task { await self.refreshFromServer() }
            }
        }
    }

    private func stateAction(userId: String, deviceId: String, action: RelayCallStateAction) {
        if userId == self.ownUserId {
            guard deviceId != self.deviceId, !self.isOutgoing, !self.acceptedLocally else {
                return
            }
            switch action {
            case .accepted, .joined:
                self.terminate(.answeredElsewhere)
            case .declined, .busy:
                self.terminate(.declinedElsewhere)
            default:
                break
            }
            return
        }
        guard userId == self.peerUserId else {
            return
        }
        switch action {
        case .received:
            if self.isOutgoing && !self.calleeReceived {
                self.calleeReceived = true
                self.evaluate()
            }
        case .accepted, .joined:
            // Only the callee answers. The caller's device joins the room while it still rings: on an incoming call
            // that is not an answer (it used to show the call screen "Connecting" and fail after `connectTimeout`).
            if self.isOutgoing && !self.answered {
                self.answered = true
                self.ringTimer?.cancel()
                self.evaluate()
            }
        case .declined:
            self.terminate(self.isOutgoing ? .declined : .cancelled)
        case .busy:
            self.terminate(self.isOutgoing ? .busy : .cancelled)
        case .missed:
            self.terminate(.missed)
        case .cancelled:
            self.terminate(self.answered ? .remoteHangup : .cancelled)
        case .hangup, .left:
            if self.answered {
                self.terminate(.remoteHangup)
            } else if self.isOutgoing {
                self.terminate(.declined)
            } else if action == .hangup {
                self.terminate(.cancelled)
            }
            // A ringing caller's device leaving the room (a media reconnect) does not end the ring: the caller's hang
            // up arrives as `cancelled` or `call_ended`.
        }
    }

    // MARK: Flow

    private func ring() async {
        var join: RelayCallJoin?
        do {
            join = try await self.api.ring(channelId: self.channelId, video: self.isVideo, deviceId: self.deviceId)
        } catch let RelayCallsError.callInProgress(existing) {
            join = await self.joinExisting(existing)
            if join == nil {
                return
            }
        } catch {
            self.terminate(.failed(error.localizedDescription))
            return
        }
        guard let join else {
            return
        }
        self.callId = join.call.id
        if self.state.isTerminated {
            // Hung up while the ring request was in flight.
            await relayLogFailure("\(self.logName): hangup") {
                try await self.api.hangup(callId: join.call.id, deviceId: self.deviceId)
            }
            return
        }
        self.apply(call: join.call)
        guard !self.state.isTerminated else {
            // The ring answered with a call that already ended (the callee is busy: `200`, `state: ended`, a token
            // that cannot join the room). Nothing to connect.
            return
        }
        self.scheduleRingExpiry()
        await self.connectMedia(join)
    }

    /// `ring` found a call in the DM: the callee rang at the same time (answer it), or the call is already running
    /// (join it).
    private func joinExisting(_ existing: RelayCall) async -> RelayCallJoin? {
        do {
            if existing.isRinging(for: self.ownUserId) {
                self.answered = true
                self.acceptedLocally = true
                self.callId = existing.id
                return try await self.api.accept(callId: existing.id, deviceId: self.deviceId)
            }
            if existing.isLive {
                self.answered = existing.state == .active
                self.callId = existing.id
                return try await self.api.join(channelId: self.channelId, callId: existing.id, deviceId: self.deviceId)
            }
            self.terminate(.failed(RelayCallsError.callInProgress(existing).localizedDescription))
        } catch {
            self.terminate(.failed(error.localizedDescription))
        }
        return nil
    }

    private func reportReceived() async {
        guard let callId = self.callId else {
            return
        }
        if self.fromPush {
            // A device woken by a push checks the ring is still on (no push announces a cancel).
            do {
                guard let call = try await self.api.call(id: callId) else {
                    self.terminate(.ended)
                    return
                }
                self.apply(call: call)
                guard !self.state.isTerminated else {
                    return
                }
                if !call.isRinging(for: self.ownUserId) {
                    self.terminate(self.reasonForLostRing(call))
                    return
                }
            } catch {
                // Keep ringing: the accept will tell.
            }
        }
        guard !self.state.isTerminated else {
            return
        }
        await relayLogFailure("\(self.logName): received") {
            try await self.api.received(callId: callId, deviceId: self.deviceId)
        }
    }

    private func acceptFailed(_ error: Error) async {
        guard !self.state.isTerminated else {
            return
        }
        if (error as? RelayCallsError)?.statusCode == 409, let callId = self.callId {
            // No longer ringing for this user: answered elsewhere, cancelled, or expired.
            let call = try? await self.api.call(id: callId)
            guard !self.state.isTerminated else {
                return
            }
            if let call {
                self.call = call
                self.terminate(self.reasonForLostRing(call))
            } else {
                self.terminate(.ended)
            }
            return
        }
        self.terminate(.failed(error.localizedDescription))
    }

    /// Why a ring stopped for this user, from the call the plugin reports.
    private func reasonForLostRing(_ call: RelayCall) -> EndReason {
        if call.state == .ended {
            return self.endReason(for: call)
        }
        switch call.invitees?[self.ownUserId] {
        case .accepted:
            return .answeredElsewhere
        case .declined, .busy:
            return .declinedElsewhere
        case .missed:
            return .missed
        default:
            return call.state == .active ? .answeredElsewhere : .ended
        }
    }

    private func connectMedia(_ join: RelayCallJoin) async {
        guard !self.mediaRequested else {
            return
        }
        self.mediaRequested = true
        do {
            try await self.engine.connect(url: join.url, token: join.token)
        } catch {
            guard !self.state.isTerminated else {
                return
            }
            RelayCallsLog.log("\(self.logName): media connect failed: \(error)")
            self.terminate(.failed(error.localizedDescription))
            if let callId = self.callId {
                self.sendHangup(callId: callId)
            }
            return
        }
        guard !self.state.isTerminated else {
            await self.engine.disconnect()
            return
        }
        RelayCallsLog.log("\(self.logName): media connected (microphone \(self.microphone.wanted ? "on" : "off"), camera \(self.camera.wanted ? "on" : "off"))")
        self.mediaConnected = true
        // Publishes the microphone (and camera) now, retrying failures.
        self.updatePublishing()
        self.evaluate()
    }

    /// The local sources publish while the room is up.
    private func updatePublishing() {
        let isUp = self.media.connectionState == .connected || self.media.connectionState == .reconnecting
        let ready = self.mediaConnected && !self.state.isTerminated && isUp
        self.microphone.setReady(ready)
        self.camera.setReady(ready)
    }

    private func sendHangup(callId: String) {
        let api = self.api
        let deviceId = self.deviceId
        let logName = self.logName
        Task {
            await relayLogFailure("\(logName): hangup") {
                try await api.hangup(callId: callId, deviceId: deviceId)
            }
        }
    }

    /// Names the call in log lines.
    private var logName: String {
        return "direct call \(self.callId ?? "(ringing \(self.peerUserId))")"
    }

    private func refreshFromServer() async {
        guard let callId = self.callId, !self.state.isTerminated else {
            return
        }
        guard let call = try? await self.api.call(id: callId) else {
            // Forgotten (`404`) or unreachable: ended unless the media is still up.
            if self.media.connectionState != .connected {
                self.terminate(.ended)
            }
            return
        }
        self.apply(call: call)
    }

    // MARK: State

    private func apply(call: RelayCall) {
        guard call.id == self.callId else {
            return
        }
        self.call = call
        if call.state == .ended {
            self.ended(call)
            return
        }
        if let peer = call.invitees?[self.peerUserId] {
            if peer == .received {
                self.calleeReceived = true
            }
            if peer == .accepted {
                self.answered = true
            }
        }
        if call.state == .active && self.isOutgoing {
            self.answered = true
        }
        if !self.isOutgoing && !self.acceptedLocally && self.state == .ringing {
            switch call.invitees?[self.ownUserId] {
            case .accepted:
                self.terminate(.answeredElsewhere)
                return
            case .declined, .busy:
                self.terminate(.declinedElsewhere)
                return
            case .missed:
                self.terminate(.missed)
                return
            default:
                break
            }
        }
        if self.answered {
            self.ringTimer?.cancel()
        }
        self.evaluate()
    }

    private func ended(_ call: RelayCall) {
        guard !self.state.isTerminated else {
            return
        }
        self.call = call
        let duration = call.durationMs.map { Double($0) / 1000.0 }
        self.terminate(self.endReason(for: call), duration: duration)
    }

    private func endReason(for call: RelayCall) -> EndReason {
        switch call.endReason ?? .ended {
        case .missed:
            return .missed
        case .cancelled:
            return self.isOutgoing ? .hangup : .cancelled
        case .declined:
            if self.isOutgoing {
                return .declined
            }
            return self.acceptedLocally ? .remoteHangup : .declinedElsewhere
        case .busy:
            return .busy
        case .hangup:
            if self.answered || self.acceptedLocally {
                return .remoteHangup
            }
            return self.isOutgoing ? .declined : .cancelled
        case .ended:
            return .ended
        case .failed:
            return .failed("The call failed.")
        }
    }

    /// Recomputes the state of a running call from the answer and the media.
    private func evaluate() {
        guard !self.state.isTerminated else {
            return
        }
        let previous = self.state
        let remotePresent = self.remoteParticipant != nil
        if !self.answered && self.isOutgoing && remotePresent {
            // The callee's device joined before its `accepted` arrived.
            self.answered = true
            self.ringTimer?.cancel()
        }
        if !self.answered {
            self.state = self.isOutgoing ? .requesting(ringing: self.calleeReceived) : .ringing
        } else if self.media.connectionState == .reconnecting, let since = self.activeSince {
            self.state = .reconnecting(since: since)
        } else if self.media.connectionState == .connected && remotePresent {
            let since = self.activeSince ?? self.scheduler.now()
            self.activeSince = since
            self.state = .active(since: since)
        } else if let since = self.activeSince {
            // The other side's device left the room after the call was up.
            self.state = .reconnecting(since: since)
        } else {
            self.state = .connecting
        }
        self.updateMediaTimer()
        if self.state != previous {
            self.notify()
        }
    }

    /// Ends an answered call whose media stays down: `connectTimeout` while connecting, `reconnectTimeout` while
    /// reconnecting.
    private func updateMediaTimer() {
        let wait: MediaWait
        switch self.state {
        case .connecting:
            wait = .connecting
        case .reconnecting:
            wait = .reconnecting
        default:
            self.mediaTimer?.timer.cancel()
            self.mediaTimer = nil
            return
        }
        if self.mediaTimer?.wait == wait {
            return
        }
        self.mediaTimer?.timer.cancel()
        let timeout = wait == .connecting ? Self.connectTimeout : Self.reconnectTimeout
        let timer = self.scheduler.schedule(at: self.scheduler.now().addingTimeInterval(timeout)) { [weak self] in
            guard let self, self.mediaTimer?.wait == wait, !self.state.isTerminated else {
                return
            }
            self.mediaTimer = nil
            self.terminate(.failed(wait == .connecting ? "The call could not connect." : "The connection was lost."))
            if let callId = self.callId {
                self.sendHangup(callId: callId)
            }
        }
        self.mediaTimer = (wait, timer)
    }

    private var remoteParticipant: RelayMediaParticipant? {
        return self.media.remote.first(where: { $0.userId == self.peerUserId })
    }

    private func mediaChanged(_ snapshot: RelayMediaSnapshot) {
        let previous = self.media
        self.media = snapshot
        guard !self.state.isTerminated else {
            return
        }
        if let local = snapshot.local {
            self.isScreenSharing = local.isScreenSharing
        }
        self.updatePublishing()
        if previous.connectionState == .reconnecting && snapshot.connectionState == .connected {
            self.microphone.retry(reason: "reconnected")
            self.camera.retry(reason: "reconnected")
        }
        let before = self.state
        self.evaluate()
        if self.state == before && previous != snapshot {
            self.notify()
        }
    }

    private func mediaDisconnected(_ reason: RelayMediaDisconnectReason) {
        guard !self.state.isTerminated else {
            return
        }
        Task {
            // The room went away: usually the call ended (the `call_ended` event may be on its way).
            if let callId = self.callId, let call = try? await self.api.call(id: callId) {
                if call.state == .ended {
                    self.ended(call)
                    return
                }
            }
            guard !self.state.isTerminated else {
                return
            }
            switch reason {
            case .removed:
                self.terminate(.ended)
            case .duplicateIdentity:
                self.terminate(.answeredElsewhere)
            case let .failed(message):
                RelayCallsLog.log("\(self.logName): media disconnected: \(message)")
                self.terminate(.failed(message))
            }
            if let callId = self.callId {
                self.sendHangup(callId: callId)
            }
        }
    }

    private func scheduleRingExpiry() {
        self.ringTimer?.cancel()
        guard !self.answered else {
            return
        }
        // Without an expiry (an older plugin), the plugin's default ring timeout.
        let expiry = self.call?.ringExpiryDate ?? self.scheduler.now().addingTimeInterval(Self.defaultRingTimeout)
        let grace = self.isOutgoing ? Self.ringExpiryGrace : 0
        self.ringTimer = self.scheduler.schedule(at: expiry.addingTimeInterval(grace)) { [weak self] in
            self?.ringExpired()
        }
    }

    private func ringExpired() {
        guard !self.answered, !self.state.isTerminated else {
            return
        }
        self.terminate(.missed)
        if self.isOutgoing, let callId = self.callId {
            // The plugin's sweeper normally ended it as missed already.
            self.sendHangup(callId: callId)
        }
    }

    private func terminate(_ reason: EndReason, duration: TimeInterval? = nil) {
        guard !self.state.isTerminated else {
            return
        }
        self.ringTimer?.cancel()
        self.ringTimer = nil
        self.mediaTimer?.timer.cancel()
        self.mediaTimer = nil
        let elapsed = self.activeSince.map { self.scheduler.now().timeIntervalSince($0) }
        self.state = .terminated(reason, duration: duration ?? elapsed)
        self.microphone.stop()
        self.camera.stop()
        if self.mediaRequested {
            let engine = self.engine
            Task {
                await engine.disconnect()
            }
        }
        self.notify()
    }

    private func notify() {
        self.observers.notify(self.snapshot)
    }
}
