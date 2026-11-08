import CoreMedia
import CoreVideo
import Foundation
import LiveKit

/// Clockwise rotation to apply when displaying a frame.
public enum RelayVideoRotation: Int, Sendable {
    case rotation0 = 0
    case rotation90 = 90
    case rotation180 = 180
    case rotation270 = 270

    init(_ rotation: VideoRotation) {
        switch rotation {
        case ._0: self = .rotation0
        case ._90: self = .rotation90
        case ._180: self = .rotation180
        case ._270: self = .rotation270
        }
    }

    var liveKit: VideoRotation {
        switch self {
        case .rotation0: return ._0
        case .rotation90: return ._90
        case .rotation180: return ._180
        case .rotation270: return ._270
        }
    }
}

/// The camera of a `RelayRoomEngine` created with `Options.usesExternalCamera`: the app captures (iOS: Telegram's
/// own camera capturer) and pushes each frame here; the engine publishes them as the camera track (LiveKit
/// `BufferCapturer`, simulcast H.264).
///
/// `onActiveChange(true)` asks the app to start capturing (the engine is publishing the camera), `false` to stop.
/// Publishing waits for the first frame, since LiveKit needs the dimensions before it can publish.
public final class RelayExternalCamera: @unchecked Sendable {
    private let lock = NSLock()
    private let dimensions: Dimensions
    private let fps: Int
    private var capturer: BufferCapturer?
    private var track: LocalVideoTrack?
    private var publication: LocalTrackPublication?
    private var frames = 0
    private var _onActiveChange: ((Bool) -> Void)?
    /// The first frame waits at most this long.
    static let firstFrameTimeout: TimeInterval = 5

    init(dimensions: Dimensions, fps: Int) {
        self.dimensions = dimensions
        self.fps = fps
    }

    /// Called (on the main actor) when the engine starts or stops wanting frames.
    public var onActiveChange: ((Bool) -> Void)? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self._onActiveChange
        }
        set {
            self.lock.lock()
            self._onActiveChange = newValue
            self.lock.unlock()
        }
    }

    /// Whether frames are wanted.
    public var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.capturer != nil
    }

    /// A camera frame (any thread). NV12 (video or full range), 32BGRA or 32ARGB; others are dropped by LiveKit.
    public func push(_ pixelBuffer: CVPixelBuffer, rotation: RelayVideoRotation = .rotation0, timestampNs: Int64? = nil) {
        self.lock.lock()
        let capturer = self.capturer
        if capturer != nil {
            self.frames += 1
        }
        self.lock.unlock()
        guard let capturer else {
            return
        }
        capturer.capture(pixelBuffer, timeStampNs: timestampNs ?? VideoCapturer.createTimeStampNs(), rotation: rotation.liveKit)
    }

    /// A camera frame as a sample buffer (any thread).
    public func push(_ sampleBuffer: CMSampleBuffer) {
        self.lock.lock()
        let capturer = self.capturer
        if capturer != nil {
            self.frames += 1
        }
        self.lock.unlock()
        capturer?.capture(sampleBuffer)
    }

    @MainActor
    func publish(to participant: LocalParticipant, options: VideoPublishOptions) async throws {
        let existing = self.locked { self.publication }
        if let existing {
            try await existing.unmute()
            return
        }
        let track = await LocalVideoTrack.createBufferTrack(name: Track.cameraName, source: .camera, options: BufferCaptureOptions(dimensions: self.dimensions, fps: self.fps))
        guard let capturer = track.capturer as? BufferCapturer else {
            throw LiveKitError(.invalidState, message: "The camera track has no buffer capturer.")
        }
        self.locked {
            self.capturer = capturer
            self.track = track
            self.frames = 0
        }
        self.onActiveChange?(true)
        let deadline = Date().addingTimeInterval(Self.firstFrameTimeout)
        while self.frameCount == 0 {
            if Date() > deadline || Task.isCancelled {
                await self.reset()
                throw LiveKitError(.capturerDimensionsNotResolved, message: "The camera delivered no frames.")
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        do {
            let publication = try await participant.publish(videoTrack: track, options: options)
            self.locked { self.publication = publication }
        } catch {
            await self.reset()
            throw error
        }
    }

    @MainActor
    func unpublish(from participant: LocalParticipant) async {
        let publication = self.locked { self.publication }
        if let publication {
            try? await participant.unpublish(publication: publication)
        }
        await self.reset()
    }

    @MainActor
    func stop() async {
        await self.reset()
    }

    private var frameCount: Int {
        return self.locked { self.frames }
    }

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }

    @MainActor
    private func reset() async {
        let (wasActive, track) = self.locked { () -> (Bool, LocalVideoTrack?) in
            let state = (self.capturer != nil, self.track)
            self.capturer = nil
            self.track = nil
            self.publication = nil
            self.frames = 0
            return state
        }
        try? await track?.stop()
        if wasActive {
            self.onActiveChange?(false)
        }
    }
}
