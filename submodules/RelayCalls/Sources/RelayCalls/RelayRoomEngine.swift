import AVFoundation
import CoreMedia
import Foundation
import LiveKit
import RelayCallsCore

/// `RelayMediaEngine` over a LiveKit `Room`: what `RelayDirectCall` and `RelayGroupCall` drive, and what the platform
/// adapters attach video sinks to.
///
/// Rooms are created with adaptive stream and dynacast on, camera video published as simulcast H.264 (decoded by
/// VideoToolbox, so remote camera frames arrive as `CVPixelBuffer`s), screen sharing through the ReplayKit broadcast
/// extension on iOS and by source on macOS. The camera is either LiveKit's own (`AVCaptureDevice`, front/back) or
/// `externalCamera`, fed by the app with pixel buffers (iOS: Telegram's camera capturer).
@MainActor
public final class RelayRoomEngine: RelayMediaEngine {
    public struct Options {
        /// Camera frames come from `externalCamera` instead of LiveKit's capturer.
        public var usesExternalCamera: Bool
        public var cameraDimensions: CMVideoDimensions
        public var cameraFPS: Int
        /// iOS: share the screen through the app's ReplayKit broadcast extension (`group.<bundle id>`).
        public var usesBroadcastExtension: Bool

        public init(usesExternalCamera: Bool = false, cameraDimensions: CMVideoDimensions = CMVideoDimensions(width: 1280, height: 720), cameraFPS: Int = 30, usesBroadcastExtension: Bool = true) {
            self.usesExternalCamera = usesExternalCamera
            self.cameraDimensions = cameraDimensions
            self.cameraFPS = cameraFPS
            self.usesBroadcastExtension = usesBroadcastExtension
        }
    }

    public let room: Room
    public let options: Options
    /// Camera frames from the app (`Options.usesExternalCamera`); nil otherwise.
    public let externalCamera: RelayExternalCamera?
    public private(set) var snapshot = RelayMediaSnapshot()
    public var onChange: ((RelayMediaSnapshot) -> Void)?
    public var onDisconnect: ((RelayMediaDisconnectReason) -> Void)?

    private let observer: RoomObserver
    private var isDisconnecting = false
    private var updateScheduled = false
    private var cameraPosition: AVCaptureDevice.Position = .front

    public init(options: Options = Options()) {
        #if os(iOS) && targetEnvironment(simulator)
        RelaySimulatorNetwork.install()
        #endif
        self.options = options
        let dimensions = Dimensions(width: options.cameraDimensions.width, height: options.cameraDimensions.height)
        #if os(iOS)
        let screenShare = ScreenShareCaptureOptions(useBroadcastExtension: options.usesBroadcastExtension, useScreenCaptureKit: false)
        let camera = CameraCaptureOptions(position: .front, dimensions: dimensions, fps: options.cameraFPS)
        #else
        let screenShare = ScreenShareCaptureOptions()
        let camera = CameraCaptureOptions(dimensions: dimensions, fps: options.cameraFPS)
        #endif
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: camera,
            defaultScreenShareCaptureOptions: screenShare,
            defaultVideoPublishOptions: RelayRoomEngine.cameraPublishOptions,
            adaptiveStream: true,
            dynacast: true
        )
        self.room = Room(roomOptions: roomOptions)
        self.externalCamera = options.usesExternalCamera ? RelayExternalCamera(dimensions: dimensions, fps: options.cameraFPS) : nil
        self.observer = RoomObserver()
        self.observer.changed = { [weak self] in
            Task { @MainActor in
                self?.scheduleUpdate()
            }
        }
        self.observer.disconnected = { [weak self] error in
            Task { @MainActor in
                self?.roomDisconnected(error)
            }
        }
        self.room.delegates.add(delegate: self.observer)
    }

    /// Simulcast H.264 (VP8 backup) for camera and screen tracks.
    static let cameraPublishOptions = VideoPublishOptions(simulcast: true, preferredCodec: .h264, preferredBackupCodec: .vp8)

    // MARK: RelayMediaEngine

    public func connect(url: String, token: String) async throws {
        self.isDisconnecting = false
        self.publishSnapshot(connectionState: .connecting)
        do {
            try await self.room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: true))
        } catch {
            self.publishSnapshot()
            throw error
        }
        self.publishSnapshot()
    }

    public func disconnect() async {
        self.isDisconnecting = true
        await self.externalCamera?.stop()
        await self.room.disconnect()
        self.publishSnapshot()
    }

    public func setMicrophone(enabled: Bool) async throws {
        try await self.room.localParticipant.setMicrophone(enabled: enabled)
        self.publishSnapshot()
    }

    public func setCamera(enabled: Bool) async throws {
        if let externalCamera = self.externalCamera {
            if enabled {
                try await externalCamera.publish(to: self.room.localParticipant, options: Self.cameraPublishOptions)
            } else {
                await externalCamera.unpublish(from: self.room.localParticipant)
            }
        } else {
            #if os(iOS)
            let capture = CameraCaptureOptions(position: self.cameraPosition, dimensions: Dimensions(width: self.options.cameraDimensions.width, height: self.options.cameraDimensions.height), fps: self.options.cameraFPS)
            try await self.room.localParticipant.setCamera(enabled: enabled, captureOptions: capture, publishOptions: Self.cameraPublishOptions)
            #else
            try await self.room.localParticipant.setCamera(enabled: enabled, captureOptions: self.macOSCameraCaptureOptions, publishOptions: Self.cameraPublishOptions)
            #endif
        }
        self.publishSnapshot()
    }

    /// iOS: starts or stops the broadcast extension's screen share (the system broadcast picker must be shown by the
    /// app; see `docs/livekit-calls.md`). macOS: the main display; use `shareScreen(source:)` for a chosen one.
    public func setScreenShare(enabled: Bool) async throws {
        #if os(macOS)
        if enabled {
            let source = try await MacOSScreenCapturer.mainDisplaySource()
            try await self.shareScreen(source: source)
            return
        }
        if let publication = self.room.localParticipant.relayPublication(.screenShareVideo) as? LocalTrackPublication {
            try await self.room.localParticipant.unpublish(publication: publication)
        }
        #else
        try await self.room.localParticipant.setScreenShare(enabled: enabled)
        #endif
        self.publishSnapshot()
    }

    // MARK: Camera

    /// Switches LiveKit's camera between front and back (an external camera switches in the app's capturer). Returns
    /// the new position.
    @discardableResult
    public func switchCamera() async throws -> AVCaptureDevice.Position {
        let next: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back
        try await self.setCameraPosition(next)
        return next
    }

    public func setCameraPosition(_ position: AVCaptureDevice.Position) async throws {
        self.cameraPosition = position
        guard self.externalCamera == nil,
              let track = self.room.localParticipant.relayPublication(.camera)?.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else {
            return
        }
        _ = try await capturer.set(cameraPosition: position)
    }

    public var currentCameraPosition: AVCaptureDevice.Position {
        return self.cameraPosition
    }

    #if os(macOS)
    /// The camera LiveKit captures from on macOS (nil: the system default). The Mac app picks cameras by
    /// `AVCaptureDevice.uniqueID`; set it before `setCamera(enabled: true)`, or call `setCameraDevice(_:)` to switch a
    /// running camera.
    public private(set) var cameraDevice: AVCaptureDevice?

    public func setCameraDevice(_ device: AVCaptureDevice?) async throws {
        self.cameraDevice = device
        guard self.externalCamera == nil,
              let track = self.room.localParticipant.relayPublication(.camera)?.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else {
            return
        }
        _ = try await capturer.set(options: self.macOSCameraCaptureOptions)
    }

    private var macOSCameraCaptureOptions: CameraCaptureOptions {
        return CameraCaptureOptions(device: self.cameraDevice, dimensions: Dimensions(width: self.options.cameraDimensions.width, height: self.options.cameraDimensions.height), fps: self.options.cameraFPS)
    }
    #endif

    // MARK: Screen sharing (macOS)

    #if os(macOS)
    /// Displays and windows that can be shared.
    public func screenShareSources() async throws -> [MacOSScreenCaptureSource] {
        return try await MacOSScreenCapturer.sources(for: .any)
    }

    /// Shares a display or window, replacing a running screen share.
    public func shareScreen(source: MacOSScreenCaptureSource) async throws {
        if let publication = self.room.localParticipant.relayPublication(.screenShareVideo) as? LocalTrackPublication {
            try await self.room.localParticipant.unpublish(publication: publication)
        }
        let track = await LocalVideoTrack.createMacOSScreenShareTrack(source: source)
        try await self.room.localParticipant.publish(videoTrack: track, options: Self.cameraPublishOptions)
        self.publishSnapshot()
    }

    /// A name for a source in a picker.
    public nonisolated static func displayName(of source: MacOSScreenCaptureSource) -> String {
        if let window = source as? MacOSWindow {
            let name = [window.owningApplication?.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            return name.isEmpty ? "Window" : name
        }
        if let display = source as? MacOSDisplay {
            return "Display \(display.displayID)"
        }
        return "Screen"
    }
    #endif

    // MARK: Video

    /// The video track of a publication (`RelayMediaTrack.sid`), local or remote; nil while not subscribed.
    public func videoTrack(sid: String) -> VideoTrack? {
        for participant in [self.room.localParticipant as Participant] + Array(self.room.remoteParticipants.values) {
            for publication in participant.videoTracks where publication.sid.stringValue == sid {
                return publication.track as? VideoTrack
            }
        }
        return nil
    }

    /// Attaches a sink to a track; returns false when the track is not available (yet).
    @discardableResult
    public func attach(_ sink: RelayVideoSink, toTrackSid sid: String) -> Bool {
        guard let track = self.videoTrack(sid: sid) else {
            return false
        }
        track.add(videoRenderer: sink)
        return true
    }

    public func detach(_ sink: RelayVideoSink, fromTrackSid sid: String) {
        self.videoTrack(sid: sid)?.remove(videoRenderer: sink)
    }

    // MARK: Snapshot

    private func scheduleUpdate() {
        guard !self.updateScheduled else {
            return
        }
        self.updateScheduled = true
        Task { @MainActor in
            self.updateScheduled = false
            self.publishSnapshot()
        }
    }

    private func publishSnapshot(connectionState: RelayMediaConnectionState? = nil) {
        let snapshot = RelayMediaSnapshot(connectionState: connectionState ?? Self.map(self.room.connectionState), participants: self.currentParticipants())
        guard snapshot != self.snapshot else {
            return
        }
        self.snapshot = snapshot
        self.onChange?(snapshot)
    }

    private func currentParticipants() -> [RelayMediaParticipant] {
        guard self.room.connectionState != .disconnected else {
            return []
        }
        var result: [RelayMediaParticipant] = []
        if self.room.localParticipant.identity != nil {
            result.append(Self.participant(self.room.localParticipant, isLocal: true))
        }
        let remote = self.room.remoteParticipants.values.sorted { lhs, rhs in
            let left = lhs.joinedAt ?? .distantFuture
            let right = rhs.joinedAt ?? .distantFuture
            if left != right {
                return left < right
            }
            return (lhs.identity?.stringValue ?? "") < (rhs.identity?.stringValue ?? "")
        }
        for participant in remote {
            result.append(Self.participant(participant, isLocal: false))
        }
        return result
    }

    static func participant(_ participant: Participant, isLocal: Bool) -> RelayMediaParticipant {
        func track(_ source: Track.Source) -> RelayMediaTrack? {
            guard let publication = participant.relayPublication(source) else {
                return nil
            }
            return RelayMediaTrack(sid: publication.sid.stringValue, isMuted: publication.isMuted, width: publication.dimensions?.width, height: publication.dimensions?.height)
        }
        return RelayMediaParticipant(
            identity: participant.identity?.stringValue ?? "",
            name: participant.name,
            isLocal: isLocal,
            isSpeaking: participant.isSpeaking,
            audioLevel: participant.audioLevel,
            connectionQuality: Self.map(participant.connectionQuality),
            microphone: track(.microphone),
            camera: track(.camera),
            screenShare: track(.screenShareVideo),
            joinedAt: participant.joinedAt
        )
    }

    static func map(_ state: ConnectionState) -> RelayMediaConnectionState {
        switch state {
        case .connected:
            return .connected
        case .connecting:
            return .connecting
        case .reconnecting:
            return .reconnecting
        case .disconnected, .disconnecting:
            return .disconnected
        @unknown default:
            return .disconnected
        }
    }

    static func map(_ quality: ConnectionQuality) -> RelayConnectionQuality {
        switch quality {
        case .unknown:
            return .unknown
        case .lost:
            return .lost
        case .poor:
            return .poor
        case .good:
            return .good
        case .excellent:
            return .excellent
        @unknown default:
            return .unknown
        }
    }

    private func roomDisconnected(_ error: LiveKitError?) {
        self.publishSnapshot()
        guard !self.isDisconnecting else {
            return
        }
        self.isDisconnecting = true
        Task {
            await self.externalCamera?.stop()
        }
        let reason: RelayMediaDisconnectReason
        switch error?.type {
        case .roomDeleted?, .participantRemoved?, .serverShutdown?:
            reason = .removed
        case .duplicateIdentity?:
            reason = .duplicateIdentity
        case nil:
            reason = .removed
        default:
            reason = .failed(error?.localizedDescription ?? "The call disconnected.")
        }
        self.onDisconnect?(reason)
    }
}

extension Participant {
    /// The participant's publication of `source` (LiveKit's own lookup is internal).
    func relayPublication(_ source: Track.Source) -> TrackPublication? {
        return self.trackPublications.values.first(where: { $0.source == source })
    }
}

/// Forwards LiveKit's room events (any thread) to the engine.
private final class RoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    var changed: (@Sendable () -> Void)?
    var disconnected: (@Sendable (LiveKitError?) -> Void)?

    func room(_: Room, didUpdateConnectionState _: ConnectionState, from _: ConnectionState) { self.changed?() }
    func room(_: Room, didStartReconnectWithMode _: ReconnectMode) { self.changed?() }
    func room(_: Room, didCompleteReconnectWithMode _: ReconnectMode) { self.changed?() }
    func room(_: Room, didDisconnectWithError error: LiveKitError?) { self.disconnected?(error) }
    func room(_: Room, participantDidConnect _: RemoteParticipant) { self.changed?() }
    func room(_: Room, participantDidDisconnect _: RemoteParticipant) { self.changed?() }
    func room(_: Room, didUpdateSpeakingParticipants _: [Participant]) { self.changed?() }
    func room(_: Room, participant _: Participant, didUpdateName _: String) { self.changed?() }
    func room(_: Room, participant _: Participant, didUpdateConnectionQuality _: ConnectionQuality) { self.changed?() }
    func room(_: Room, participant _: LocalParticipant, didPublishTrack _: LocalTrackPublication) { self.changed?() }
    func room(_: Room, participant _: LocalParticipant, didUnpublishTrack _: LocalTrackPublication) { self.changed?() }
    func room(_: Room, participant _: RemoteParticipant, didPublishTrack _: RemoteTrackPublication) { self.changed?() }
    func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack _: RemoteTrackPublication) { self.changed?() }
    func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack _: RemoteTrackPublication) { self.changed?() }
    func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack _: RemoteTrackPublication) { self.changed?() }
    func room(_: Room, participant _: Participant, trackPublication _: TrackPublication, didUpdateIsMuted _: Bool) { self.changed?() }
    func room(_: Room, participant _: RemoteParticipant, trackPublication _: RemoteTrackPublication, didUpdateStreamState _: StreamState) { self.changed?() }
}
