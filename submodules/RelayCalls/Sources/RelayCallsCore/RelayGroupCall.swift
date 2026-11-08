import Foundation

/// A room call (`kind: group` in a group message, `kind: channel` in a public/private channel): the state machine
/// behind Telegram's group call / video chat screens. Telegram's UI keys participants by peer, so the room's devices
/// are merged per Mattermost user (`participants`): one entry per user, speaking and audio level over all of its
/// devices, its camera and screen share from whichever device publishes them.
///
/// `join(…)` joins a channel's call or starts one (`POST /channels/<id>/join`); `ring(…)` rings the other members of a
/// group message (`POST /channels/<id>/ring`); `incoming(…)` is a group ring for this user, answered with `accept()`.
@MainActor
public final class RelayGroupCall {
    public enum State: Equatable, Sendable {
        /// An incoming group ring, not answered.
        case ringing
        case connecting
        case connected
        case reconnecting
        case ended(EndReason)

        public var isEnded: Bool {
            if case .ended = self {
                return true
            }
            return false
        }
    }

    public enum EndReason: Equatable, Sendable {
        /// This device left.
        case left
        /// The call ended (for everyone, or the room emptied).
        case ended
        /// An incoming ring this device declined.
        case declined
        /// An incoming ring nobody answered here in time.
        case missed
        /// Another device of this user answered the ring.
        case answeredElsewhere
        /// The server removed this device (left the channel, replaced by a second connection).
        case removed
        case failed(String)
    }

    /// A video track of a participant: attach a sink with the engine's `videoTrack(sid:)`.
    public struct Video: Equatable, Sendable {
        /// The publishing device.
        public var identity: String
        public var track: RelayMediaTrack
        public var isLocal: Bool
    }

    /// One user in the room, over all of its devices.
    public struct Participant: Equatable, Sendable, Identifiable {
        public var userId: String
        public var name: String?
        /// The own user (this device and the user's other devices in the room).
        public var isSelf: Bool
        /// The user's devices, this device first.
        public var devices: [RelayMediaParticipant]
        public var isSpeaking: Bool
        /// The loudest device, 0…1.
        public var audioLevel: Float
        public var isMicrophoneEnabled: Bool
        public var camera: Video?
        public var screenShare: Video?
        /// The best device's.
        public var connectionQuality: RelayConnectionQuality
        public var joinedAt: Date?

        public var id: String {
            return self.userId
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var state: State
        public var call: RelayCall?
        public var callId: String?
        public var channelId: String
        public var kind: RelayCallKind
        /// The own user first, then by join time.
        public var participants: [Participant]
        /// Invited users of a group ring and what they did (empty for channel calls).
        public var invitees: [String: RelayInviteeState]
        public var isMuted: Bool
        public var isCameraEnabled: Bool
        public var isScreenSharing: Bool
        public var mediaState: RelayMediaConnectionState
        /// Whether this user may end the call for everyone.
        public var canEnd: Bool
    }

    private enum Mode {
        case join(callId: String?)
        case ring(video: Bool)
        case incoming(fromPush: Bool)
    }

    public let ownUserId: String
    public let deviceId: String
    public let channelId: String

    private let api: RelayCallsAPI
    private let engine: RelayMediaEngine
    private let scheduler: RelayCallScheduler
    private let mode: Mode
    private let observers = RelayObservers<Snapshot>()

    public private(set) var state: State
    public private(set) var call: RelayCall?
    public private(set) var callId: String?
    public private(set) var participants: [Participant] = []
    private var kind: RelayCallKind
    private var started = false
    private var answered = false
    private var mediaRequested = false
    private var media = RelayMediaSnapshot()
    private var isMuted = false
    private var isCameraEnabled: Bool
    private var isScreenSharing = false
    private var ringTimer: RelayCancellable?

    private init(api: RelayCallsAPI, engine: RelayMediaEngine, scheduler: RelayCallScheduler, ownUserId: String, deviceId: String, channelId: String, kind: RelayCallKind, mode: Mode, call: RelayCall?, video: Bool) {
        self.api = api
        self.engine = engine
        self.scheduler = scheduler
        self.ownUserId = ownUserId
        self.deviceId = deviceId
        self.channelId = channelId
        self.kind = kind
        self.mode = mode
        self.call = call
        self.callId = call?.id
        self.isCameraEnabled = video
        if case .incoming = mode {
            self.state = .ringing
        } else {
            self.state = .connecting
        }
        self.engine.onChange = { [weak self] snapshot in
            self?.mediaChanged(snapshot)
        }
        self.engine.onDisconnect = { [weak self] reason in
            self?.mediaDisconnected(reason)
        }
    }

    /// Joins the channel's call, or starts a channel call. `callId`: the call the join panel showed (the join fails
    /// when the channel's call is another one by now).
    public static func join(api: RelayCallsAPI, engine: RelayMediaEngine, ownUserId: String, deviceId: String, channelId: String, callId: String? = nil, kind: RelayCallKind = .channel, scheduler: RelayCallScheduler? = nil) -> RelayGroupCall {
        return RelayGroupCall(api: api, engine: engine, scheduler: scheduler ?? RelaySystemScheduler.shared, ownUserId: ownUserId, deviceId: deviceId, channelId: channelId, kind: kind, mode: .join(callId: callId), call: nil, video: false)
    }

    /// Rings the other members of a group message.
    public static func ring(api: RelayCallsAPI, engine: RelayMediaEngine, ownUserId: String, deviceId: String, channelId: String, video: Bool, scheduler: RelayCallScheduler? = nil) -> RelayGroupCall {
        return RelayGroupCall(api: api, engine: engine, scheduler: scheduler ?? RelaySystemScheduler.shared, ownUserId: ownUserId, deviceId: deviceId, channelId: channelId, kind: .group, mode: .ring(video: video), call: nil, video: video)
    }

    /// A group ring for this user (the `incoming` event or `GET /calls/active`).
    public static func incoming(api: RelayCallsAPI, engine: RelayMediaEngine, ownUserId: String, deviceId: String, call: RelayCall, scheduler: RelayCallScheduler? = nil) -> RelayGroupCall {
        return RelayGroupCall(api: api, engine: engine, scheduler: scheduler ?? RelaySystemScheduler.shared, ownUserId: ownUserId, deviceId: deviceId, channelId: call.channelId, kind: call.kind, mode: .incoming(fromPush: false), call: call, video: false)
    }

    /// A group ring from a VoIP push; `start()` checks it still rings for this user.
    public static func incoming(api: RelayCallsAPI, engine: RelayMediaEngine, ownUserId: String, deviceId: String, push: RelayCallPush, scheduler: RelayCallScheduler? = nil) -> RelayGroupCall {
        let call = RelayCall(id: push.callId, channelId: push.channelId, kind: .group, state: .ringing, video: push.video, startedBy: push.callerId, ringExpiresAt: push.ringExpiresAt, invitees: [ownUserId: .ringing])
        return RelayGroupCall(api: api, engine: engine, scheduler: scheduler ?? RelaySystemScheduler.shared, ownUserId: ownUserId, deviceId: deviceId, channelId: push.channelId, kind: .group, mode: .incoming(fromPush: true), call: call, video: false)
    }

    public var snapshot: Snapshot {
        return Snapshot(
            state: self.state,
            call: self.call,
            callId: self.callId,
            channelId: self.channelId,
            kind: self.kind,
            participants: self.participants,
            invitees: self.call?.invitees ?? [:],
            isMuted: self.isMuted,
            isCameraEnabled: self.isCameraEnabled,
            isScreenSharing: self.isScreenSharing,
            mediaState: self.media.connectionState,
            canEnd: self.call?.canEnd ?? false
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
        guard !self.started, !self.state.isEnded else {
            return
        }
        self.started = true
        switch self.mode {
        case let .join(callId):
            Task {
                await self.run { try await self.api.join(channelId: self.channelId, callId: callId, deviceId: self.deviceId) }
            }
        case let .ring(video):
            Task {
                await self.run {
                    do {
                        return try await self.api.ring(channelId: self.channelId, video: video, deviceId: self.deviceId)
                    } catch let RelayCallsError.callInProgress(existing) {
                        // A call is already running in the group: join it.
                        return try await self.api.join(channelId: self.channelId, callId: existing.id, deviceId: self.deviceId)
                    }
                }
            }
        case let .incoming(fromPush):
            self.scheduleRingExpiry()
            Task { await self.reportReceived(fromPush: fromPush) }
        }
        self.notify()
    }

    /// Answers an incoming group ring.
    public func accept() {
        guard case .incoming = self.mode, self.state == .ringing, let callId = self.callId else {
            return
        }
        self.answered = true
        self.ringTimer?.cancel()
        self.state = .connecting
        self.notify()
        Task {
            await self.run {
                do {
                    return try await self.api.accept(callId: callId, deviceId: self.deviceId)
                } catch let error as RelayCallsError where error.statusCode == 409 {
                    // No longer ringing for this user (answered on another device, or expired); the call may still
                    // be running: join it.
                    return try await self.api.join(channelId: self.channelId, callId: callId, deviceId: self.deviceId)
                }
            }
        }
    }

    public func decline(reason: RelayDeclineReason = .declined) {
        guard case .incoming = self.mode, self.state == .ringing else {
            return
        }
        self.end(.declined)
        if let callId = self.callId {
            let api = self.api
            let deviceId = self.deviceId
            Task {
                try? await api.decline(callId: callId, deviceId: deviceId, reason: reason)
            }
        }
    }

    /// Leaves the call; it continues for the others.
    public func leave() {
        if self.state == .ringing {
            self.decline()
            return
        }
        guard !self.state.isEnded else {
            return
        }
        self.end(.left)
        if let callId = self.callId {
            let api = self.api
            let deviceId = self.deviceId
            Task {
                try? await api.hangup(callId: callId, deviceId: deviceId)
            }
        }
    }

    /// Ends the call for everyone (`canEnd`).
    public func endForEveryone() async throws {
        guard let callId = self.callId else {
            return
        }
        try await self.api.end(channelId: self.channelId, callId: callId)
        self.end(.ended)
    }

    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
        self.notify()
        if self.isMediaUp {
            Task {
                try? await self.engine.setMicrophone(enabled: !muted)
            }
        }
    }

    public func setCameraEnabled(_ enabled: Bool) {
        self.isCameraEnabled = enabled
        self.notify()
        if self.isMediaUp {
            Task {
                do {
                    try await self.engine.setCamera(enabled: enabled)
                } catch {
                    self.isCameraEnabled = false
                    self.notify()
                }
            }
        }
    }

    public func setScreenShare(enabled: Bool) {
        guard self.isMediaUp else {
            return
        }
        self.isScreenSharing = enabled
        self.notify()
        Task {
            do {
                try await self.engine.setScreenShare(enabled: enabled)
            } catch {
                self.isScreenSharing = false
                self.notify()
            }
        }
    }

    // MARK: Events

    public func handle(_ event: RelayCallsEvent) {
        guard !self.state.isEnded else {
            return
        }
        switch event {
        case let .incoming(call, _), let .callUpdated(call):
            self.apply(call: call)
        case let .callEnded(call):
            guard call.id == self.callId else {
                return
            }
            self.call = call
            self.end(.ended)
        case let .callState(call, userId, deviceId, action):
            guard call.id == self.callId else {
                return
            }
            self.apply(call: call)
            if self.state == .ringing, userId == self.ownUserId, deviceId != self.deviceId {
                switch action {
                case .accepted, .joined:
                    self.end(.answeredElsewhere)
                case .declined, .busy:
                    self.end(.declined)
                default:
                    break
                }
            }
        case let .activeCalls(calls):
            guard let callId = self.callId else {
                return
            }
            if let call = calls.first(where: { $0.id == callId }) {
                self.apply(call: call)
            } else {
                Task { await self.refreshFromServer() }
            }
        }
    }

    // MARK: Flow

    private func run(_ request: () async throws -> RelayCallJoin) async {
        let join: RelayCallJoin
        do {
            join = try await request()
        } catch {
            if !self.state.isEnded {
                self.end(.failed(error.localizedDescription))
            }
            return
        }
        self.callId = join.call.id
        if self.state.isEnded {
            try? await self.api.hangup(callId: join.call.id, deviceId: self.deviceId)
            return
        }
        self.apply(call: join.call)
        guard !self.state.isEnded else {
            return
        }
        self.mediaRequested = true
        do {
            try await self.engine.connect(url: join.url, token: join.token)
        } catch {
            if !self.state.isEnded {
                self.end(.failed(error.localizedDescription))
                try? await self.api.hangup(callId: join.call.id, deviceId: self.deviceId)
            }
            return
        }
        guard !self.state.isEnded else {
            await self.engine.disconnect()
            return
        }
        do {
            try await self.engine.setMicrophone(enabled: !self.isMuted)
        } catch {
            self.isMuted = true
        }
        if self.isCameraEnabled {
            do {
                try await self.engine.setCamera(enabled: true)
            } catch {
                self.isCameraEnabled = false
            }
        }
        self.evaluate()
        self.notify()
    }

    private func reportReceived(fromPush: Bool) async {
        guard let callId = self.callId else {
            return
        }
        if fromPush {
            if let call = try? await self.api.call(id: callId) {
                self.apply(call: call)
                if !self.state.isEnded, !call.isRinging(for: self.ownUserId) {
                    self.end(call.state == .ended ? .ended : (call.invitees?[self.ownUserId] == .accepted ? .answeredElsewhere : .missed))
                }
            } else {
                self.end(.ended)
            }
        }
        guard !self.state.isEnded else {
            return
        }
        try? await self.api.received(callId: callId, deviceId: self.deviceId)
    }

    private func refreshFromServer() async {
        guard let callId = self.callId, !self.state.isEnded else {
            return
        }
        if let call = try? await self.api.call(id: callId) {
            self.apply(call: call)
        } else if self.media.connectionState != .connected {
            self.end(.ended)
        }
    }

    // MARK: State

    private var isMediaUp: Bool {
        return self.media.connectionState == .connected || self.media.connectionState == .reconnecting
    }

    private func apply(call: RelayCall) {
        guard call.id == self.callId else {
            return
        }
        self.call = call
        self.kind = call.kind
        if call.state == .ended {
            self.end(.ended)
            return
        }
        if self.state == .ringing && !self.answered {
            switch call.invitees?[self.ownUserId] {
            case .accepted:
                self.end(.answeredElsewhere)
                return
            case .declined, .busy:
                self.end(.declined)
                return
            case .missed:
                self.end(.missed)
                return
            default:
                break
            }
        }
        self.notify()
    }

    private func evaluate() {
        guard !self.state.isEnded, self.state != .ringing else {
            return
        }
        let previous = self.state
        switch self.media.connectionState {
        case .connected:
            self.state = .connected
        case .reconnecting:
            self.state = .reconnecting
        case .connecting, .disconnected:
            self.state = .connecting
        }
        if previous != self.state {
            self.notify()
        }
    }

    private func mediaChanged(_ snapshot: RelayMediaSnapshot) {
        self.media = snapshot
        guard !self.state.isEnded else {
            return
        }
        self.participants = Self.mergeParticipants(snapshot.participants, ownUserId: self.ownUserId)
        if let local = snapshot.local {
            self.isScreenSharing = local.isScreenSharing
        }
        let before = self.state
        self.evaluate()
        if before == self.state {
            self.notify()
        }
    }

    private func mediaDisconnected(_ reason: RelayMediaDisconnectReason) {
        guard !self.state.isEnded else {
            return
        }
        Task {
            if let callId = self.callId, let call = try? await self.api.call(id: callId), call.state == .ended {
                self.call = call
                self.end(.ended)
                return
            }
            guard !self.state.isEnded else {
                return
            }
            switch reason {
            case .removed, .duplicateIdentity:
                self.end(.removed)
            case let .failed(message):
                self.end(.failed(message))
                if let callId = self.callId {
                    try? await self.api.hangup(callId: callId, deviceId: self.deviceId)
                }
            }
        }
    }

    private func scheduleRingExpiry() {
        self.ringTimer?.cancel()
        let expiry = self.call?.ringExpiryDate ?? self.scheduler.now().addingTimeInterval(RelayDirectCall.defaultRingTimeout)
        self.ringTimer = self.scheduler.schedule(at: expiry) { [weak self] in
            guard let self, self.state == .ringing else {
                return
            }
            self.end(.missed)
        }
    }

    private func end(_ reason: EndReason) {
        guard !self.state.isEnded else {
            return
        }
        self.ringTimer?.cancel()
        self.ringTimer = nil
        self.state = .ended(reason)
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

    // MARK: Merging

    /// The room's devices as one participant per user: the own user first (this device leading its devices), then
    /// users by their first device's join time.
    public nonisolated static func mergeParticipants(_ devices: [RelayMediaParticipant], ownUserId: String) -> [Participant] {
        var order: [String] = []
        var byUser: [String: [RelayMediaParticipant]] = [:]
        for device in devices {
            // A device without a user part (not issued by the plugin) stands for itself.
            let userId = device.userId ?? device.identity
            if byUser[userId] == nil {
                order.append(userId)
            }
            byUser[userId, default: []].append(device)
        }
        var result: [Participant] = []
        for userId in order {
            guard var userDevices = byUser[userId], !userDevices.isEmpty else {
                continue
            }
            userDevices.sort { lhs, rhs in
                if lhs.isLocal != rhs.isLocal {
                    return lhs.isLocal
                }
                return (lhs.joinedAt ?? .distantFuture) < (rhs.joinedAt ?? .distantFuture)
            }
            let isSelf = userId == ownUserId || userDevices.contains(where: { $0.isLocal })
            func video(_ path: KeyPath<RelayMediaParticipant, RelayMediaTrack?>) -> Video? {
                // The live track of the first device that has one (this device first), else a muted one.
                let live = userDevices.first(where: { $0[keyPath: path]?.isLive == true })
                guard let device = live ?? userDevices.first(where: { $0[keyPath: path] != nil }), let track = device[keyPath: path] else {
                    return nil
                }
                return Video(identity: device.identity, track: track, isLocal: device.isLocal)
            }
            let name = userDevices.lazy.compactMap { $0.name?.isEmpty == false ? $0.name : nil }.first
            result.append(Participant(
                userId: userId,
                name: name,
                isSelf: isSelf,
                devices: userDevices,
                isSpeaking: userDevices.contains(where: { $0.isSpeaking }),
                audioLevel: userDevices.map(\.audioLevel).max() ?? 0,
                isMicrophoneEnabled: userDevices.contains(where: { $0.isMicrophoneEnabled }),
                camera: video(\.camera),
                screenShare: video(\.screenShare),
                connectionQuality: userDevices.map(\.connectionQuality).max() ?? .unknown,
                joinedAt: userDevices.compactMap(\.joinedAt).min()
            ))
        }
        return result.enumerated().sorted { lhs, rhs in
            if lhs.element.isSelf != rhs.element.isSelf {
                return lhs.element.isSelf
            }
            let left = lhs.element.joinedAt ?? .distantFuture
            let right = rhs.element.joinedAt ?? .distantFuture
            if left != right {
                return left < right
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
