import Foundation
import AVFoundation
import CoreVideo
import CryptoKit
import SwiftSignalKit
import TelegramCore
import TelegramVoip
import AccountContext
import LibYuvBinding
import RelayCallsCore
import RelayCalls

// MATTERMOST: shared pieces of the Relay call adapters (docs/livekit-calls-native-ui.md, "Platform adapters"):
// threading, stable ids, Telegram's call tones without tgcalls, Telegram's camera capturer feeding LiveKit, and
// LiveKit video tracks as Telegram's `VideoFrameData`.

/// Runs `body` on the main actor: now when already on the main thread (Telegram's call UI, CallKit's delegate queue),
/// else on the next main queue turn.
func relayOnMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}

enum RelayCallIds {
    /// The CallKit call of a plugin call: the same for the `incoming` event and the VoIP push of one ring, on every
    /// launch (a name-based UUID of the call id).
    static func callKitUUID(callId: String) -> UUID {
        let digest = SHA256.hash(data: Data(("relay-call:" + callId).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A stable non-zero audio "SSRC" for a Mattermost user: Telegram's group call UI keys audio levels and requested
    /// video channels by it.
    static func ssrc(userId: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in userId.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash == 0 ? 1 : hash
    }

    /// Video endpoints of a user (`VideoDescription.endpointId`), whichever of its devices publishes the track.
    static func cameraEndpoint(userId: String) -> String {
        return "relay:camera:" + userId
    }

    static func screenEndpoint(userId: String) -> String {
        return "relay:screen:" + userId
    }

    enum Endpoint: Equatable {
        case camera(userId: String)
        case screen(userId: String)
    }

    static func parseEndpoint(_ endpointId: String) -> Endpoint? {
        if endpointId.hasPrefix("relay:camera:") {
            return .camera(userId: String(endpointId.dropFirst("relay:camera:".count)))
        }
        if endpointId.hasPrefix("relay:screen:") {
            return .screen(userId: String(endpointId.dropFirst("relay:screen:".count)))
        }
        return nil
    }
}

// MARK: - Tones

/// Telegram's call tones (`PresentationCallToneData`) without tgcalls' audio device: played with `AVAudioPlayer` on
/// the call's audio session while it is active. Called on the main thread; the work runs on a serial queue, because
/// decoding a tone (`AVAssetReader` mixes it down through an offline audio queue) and starting a player wait on the
/// audio server: on the simulator such a call blocked for minutes, and on the main thread it froze the app right after
/// a call was answered.
final class RelayCallTonePlayer {
    private final class Output {
        var player: AVAudioPlayer?
    }

    private static let queue = DispatchQueue(label: "org.relaychat.Relay.callTones", qos: .userInitiated)
    /// Decoded tones, on `queue` only.
    private static var cache: [String: Data] = [:]

    private let output = Output()
    private(set) var tone: PresentationCallTone?
    private var isAudioSessionActive = false

    deinit {
        let output = self.output
        Self.queue.async {
            output.player?.stop()
            output.player = nil
        }
    }

    func setAudioSessionActive(_ value: Bool) {
        if self.isAudioSessionActive != value {
            self.isAudioSessionActive = value
            self.apply()
        }
    }

    func setTone(_ tone: PresentationCallTone?) {
        if self.tone != tone {
            self.tone = tone
            self.apply()
        }
    }

    /// Plays a tone once, also when it is the current one.
    func play(_ tone: PresentationCallTone) {
        self.tone = tone
        self.apply()
    }

    func stop() {
        self.tone = nil
        self.apply()
    }

    private func apply() {
        let tone = self.isAudioSessionActive && !RelayCallAudio.isAudioDeviceDisabled ? self.tone : nil
        let output = self.output
        // The queue is serial: the last request wins.
        Self.queue.async {
            output.player?.stop()
            output.player = nil
            guard let tone, let data = Self.wavData(tone), let player = try? AVAudioPlayer(data: data) else {
                return
            }
            player.numberOfLoops = tone.loopCount.map { max(0, $0 - 1) } ?? -1
            player.prepareToPlay()
            player.play()
            output.player = player
        }
    }

    private static func key(_ tone: PresentationCallTone) -> String {
        switch tone {
        case .ringing:
            return "ringing"
        case .connecting:
            return "connecting"
        case .busy:
            return "busy"
        case .failed:
            return "failed"
        case .ended:
            return "ended"
        case .groupJoined:
            return "groupJoined"
        case .groupLeft:
            return "groupLeft"
        case .groupConnecting:
            return "groupConnecting"
        case let .custom(name, _):
            return "custom:" + name
        }
    }

    /// The tone's samples (48 kHz, 16-bit mono PCM) as a WAV file.
    private static func wavData(_ tone: PresentationCallTone) -> Data? {
        let key = self.key(tone)
        if let cached = self.cache[key] {
            return cached
        }
        guard let samples = presentationCallToneData(tone), !samples.isEmpty else {
            return nil
        }
        var data = Data()
        func append32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        let sampleRate: UInt32 = 48000
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(samples.count))
        data.append(samples)
        self.cache[key] = data
        return data
    }
}

// MARK: - Camera

/// Telegram's own camera capturer (`OngoingCallVideoCapturer`, which the call screens create for their preview and
/// switch between cameras) feeding the LiveKit camera track (`RelayExternalCamera`), so the preview, camera switching
/// and mirroring stay Telegram's.
final class RelayCameraBridge {
    private let camera: RelayExternalCamera
    private(set) var capturer: OngoingCallVideoCapturer?
    private let frameDisposable = MetaDisposable()

    init(camera: RelayExternalCamera) {
        self.camera = camera
    }

    deinit {
        self.frameDisposable.dispose()
    }

    func setCapturer(_ capturer: OngoingCallVideoCapturer?) {
        if self.capturer === capturer {
            return
        }
        self.capturer = capturer
        guard let capturer else {
            self.frameDisposable.set(nil)
            return
        }
        let camera = self.camera
        self.frameDisposable.set(capturer.video().start(next: { frame in
            let pixelBuffer: CVPixelBuffer
            switch frame.buffer {
            case let .native(buffer), let .argb(buffer), let .bgra(buffer):
                pixelBuffer = buffer.pixelBuffer
            case .nv12, .i420:
                return
            }
            camera.push(pixelBuffer, rotation: RelayVideoFrameConverter.rotation(frame.orientation))
        }))
    }
}

// MARK: - Video

/// Converts LiveKit frames into what Telegram's call renderers draw (`VideoFrameData` with an NV12 pixel buffer;
/// I420 frames from software decoders are copied into pooled NV12 buffers). Called on WebRTC's decoding thread.
final class RelayVideoFrameConverter {
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    static func orientation(_ rotation: RelayVideoRotation) -> OngoingCallVideoOrientation {
        switch rotation {
        case .rotation0:
            return .rotation0
        case .rotation90:
            return .rotation90
        case .rotation180:
            return .rotation180
        case .rotation270:
            return .rotation270
        }
    }

    static func rotation(_ orientation: OngoingCallVideoOrientation) -> RelayVideoRotation {
        switch orientation {
        case .rotation0:
            return .rotation0
        case .rotation90:
            return .rotation90
        case .rotation180:
            return .rotation180
        case .rotation270:
            return .rotation270
        }
    }

    func convert(_ frame: RelayVideoFrame) -> OngoingGroupCallContext.VideoFrameData? {
        let pixelBuffer: CVPixelBuffer
        switch frame.buffer {
        case let .pixelBuffer(buffer):
            switch CVPixelBufferGetPixelFormatType(buffer) {
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
                pixelBuffer = buffer
            default:
                // The renderers draw bi-planar NV12 only (hardware H.264 decoding always gives it).
                return nil
            }
        case let .i420(buffer):
            guard let converted = self.nv12(from: buffer) else {
                return nil
            }
            pixelBuffer = converted
        }
        return OngoingGroupCallContext.VideoFrameData(
            pixelBuffer: pixelBuffer,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            orientation: Self.orientation(frame.rotation)
        )
    }

    private func nv12(from buffer: RelayI420Buffer) -> CVPixelBuffer? {
        let width = buffer.width
        let height = buffer.height
        guard width > 0, height > 0 else {
            return nil
        }
        self.lock.lock()
        if self.pool == nil || self.poolSize.width != width || self.poolSize.height != height {
            let poolOptions: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4 as NSNumber]
            let bufferOptions: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange as NSNumber,
                kCVPixelBufferWidthKey as String: width as NSNumber,
                kCVPixelBufferHeightKey as String: height as NSNumber,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolOptions as CFDictionary, bufferOptions as CFDictionary, &pool)
            self.pool = pool
            self.poolSize = (width, height)
        }
        let pool = self.pool
        self.lock.unlock()
        guard let pool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer?
        let auxAttributes: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: 6 as NSNumber]
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let dstY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), let dstUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }
        let dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let converted = buffer.withPlanes { y, u, v -> Bool in
            return libyuv_I420ToNV12(
                y,
                Int32(buffer.strideY),
                u,
                Int32(buffer.strideU),
                v,
                Int32(buffer.strideV),
                dstY.assumingMemoryBound(to: UInt8.self),
                Int32(dstStrideY),
                dstUV.assumingMemoryBound(to: UInt8.self),
                Int32(dstStrideUV),
                Int32(width),
                Int32(height)
            )
        }
        return converted ? pixelBuffer : nil
    }
}

/// The video of a Relay call for Telegram's renderers: each subscriber gets a LiveKit sink on the track that its key
/// resolves to now (a user's camera or screen share, the other side of a 1:1 call), re-attached whenever the track
/// changes (a republish, another device) or becomes subscribed.
@MainActor
final class RelayVideoRouter {
    struct Quality: Equatable {
        var viewSize: CGSize

        static let thumbnail = Quality(viewSize: CGSize(width: 320.0, height: 180.0))
        static let medium = Quality(viewSize: CGSize(width: 640.0, height: 360.0))
        static let full = Quality(viewSize: CGSize(width: 1280.0, height: 720.0))
    }

    private final class Subscription {
        let key: String
        let resolve: @MainActor () -> String?
        let sink: RelayVideoSink
        var attachedSid: String?

        init(key: String, resolve: @escaping @MainActor () -> String?, sink: RelayVideoSink) {
            self.key = key
            self.resolve = resolve
            self.sink = sink
        }
    }

    private weak var engine: RelayRoomEngine?
    private var subscriptions: [Int: Subscription] = [:]
    private var nextId = 0
    private var qualities: [String: Quality] = [:]
    private var visibleKeys: Set<String>?
    /// A track subscription does not always change the room snapshot: tracks that are not attachable yet are retried.
    private var retryTimer: Foundation.Timer?

    init(engine: RelayRoomEngine) {
        self.engine = engine
    }

    /// Frames of the track `resolve` names (nil: none now). `key` groups subscribers for `setRequested`.
    nonisolated func video(key: String, resolve: @escaping @MainActor () -> String?) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError> {
        return Signal { [weak self] subscriber in
            let converter = RelayVideoFrameConverter()
            let sink = RelayVideoSink(onFrame: { frame in
                if let data = converter.convert(frame) {
                    subscriber.putNext(data)
                }
            })
            let id = Atomic<Int?>(value: nil)
            relayOnMain {
                guard let self else {
                    return
                }
                let subscription = Subscription(key: key, resolve: resolve, sink: sink)
                let subscriptionId = self.nextId
                self.nextId += 1
                self.subscriptions[subscriptionId] = subscription
                let _ = id.swap(subscriptionId)
                self.apply(subscription)
            }
            return ActionDisposable { [weak self] in
                relayOnMain {
                    guard let self, let subscriptionId = id.with({ $0 }), let subscription = self.subscriptions.removeValue(forKey: subscriptionId) else {
                        return
                    }
                    if let sid = subscription.attachedSid {
                        self.engine?.detach(subscription.sink, fromTrackSid: sid)
                    }
                }
            }
        }
    }

    /// After every change of the room (tracks published, subscribed, muted).
    func update() {
        for subscription in self.subscriptions.values {
            self.apply(subscription)
        }
    }

    private func scheduleRetryIfNeeded() {
        let isPending = self.subscriptions.values.contains(where: { $0.attachedSid == nil && $0.resolve() != nil })
        if !isPending {
            self.retryTimer?.invalidate()
            self.retryTimer = nil
            return
        }
        if self.retryTimer != nil {
            return
        }
        self.retryTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false, block: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.retryTimer = nil
                self.update()
            }
        })
    }

    /// The qualities Telegram's group call screen asks for, by key (`setRequestedVideoList`); keys not in the list are
    /// hidden (adaptive stream pauses them).
    func setRequested(_ qualities: [String: Quality]) {
        self.qualities = qualities
        self.visibleKeys = Set(qualities.keys)
        for subscription in self.subscriptions.values {
            self.applyQuality(subscription)
        }
    }

    func detachAll() {
        self.retryTimer?.invalidate()
        self.retryTimer = nil
        for subscription in self.subscriptions.values {
            if let sid = subscription.attachedSid {
                self.engine?.detach(subscription.sink, fromTrackSid: sid)
                subscription.attachedSid = nil
            }
        }
        self.subscriptions.removeAll()
    }

    private func apply(_ subscription: Subscription) {
        self.applyQuality(subscription)
        guard let engine = self.engine else {
            return
        }
        let sid = subscription.resolve()
        if subscription.attachedSid == sid, sid == nil || engine.videoTrack(sid: sid!) != nil {
            return
        }
        if let attached = subscription.attachedSid {
            engine.detach(subscription.sink, fromTrackSid: attached)
            subscription.attachedSid = nil
        }
        if let sid, engine.attach(subscription.sink, toTrackSid: sid) {
            subscription.attachedSid = sid
        }
        self.scheduleRetryIfNeeded()
    }

    private func applyQuality(_ subscription: Subscription) {
        let quality = self.qualities[subscription.key] ?? .medium
        subscription.sink.viewSize = quality.viewSize
        if let visibleKeys = self.visibleKeys {
            subscription.sink.isVisible = visibleKeys.contains(subscription.key)
        } else {
            subscription.sink.isVisible = true
        }
    }
}

// MARK: - Outgoing video views

/// `PresentationCallVideoView` for a view of Telegram's camera capturer (as `PresentationCallImpl` builds it).
func relayPresentationCallVideoView(_ view: OngoingCallContextPresentationCallVideoView) -> PresentationCallVideoView {
    func map(_ orientation: OngoingCallVideoOrientation) -> PresentationCallVideoView.Orientation {
        switch orientation {
        case .rotation0:
            return .rotation0
        case .rotation90:
            return .rotation90
        case .rotation180:
            return .rotation180
        case .rotation270:
            return .rotation270
        }
    }
    let setOnFirstFrameReceived = view.setOnFirstFrameReceived
    let setOnOrientationUpdated = view.setOnOrientationUpdated
    let setOnIsMirroredUpdated = view.setOnIsMirroredUpdated
    let updateIsEnabled = view.updateIsEnabled
    return PresentationCallVideoView(
        holder: view,
        view: view.view,
        setOnFirstFrameReceived: { f in
            setOnFirstFrameReceived(f)
        },
        getOrientation: { [weak view] in
            guard let view else {
                return .rotation0
            }
            return map(view.getOrientation())
        },
        getAspect: { [weak view] in
            guard let view else {
                return 0.0
            }
            return view.getAspect()
        },
        setOnOrientationUpdated: { f in
            setOnOrientationUpdated { value, aspect in
                f?(map(value), aspect)
            }
        },
        setOnIsMirroredUpdated: { f in
            setOnIsMirroredUpdated { value in
                f?(value)
            }
        },
        updateIsEnabled: { value in
            updateIsEnabled(value)
        }
    )
}

// MARK: - Audio

/// LiveKit's audio engine under Telegram's audio session handling (`SharedCallAudioContext`, CallKit): the engine runs
/// only while the call's session is active (`RelayCallKitAudio`, the LiveKit SDK's CallKit integration).
enum RelayCallAudio {
    private static var isPrepared = false
    /// Debug builds launched with `RELAY_DEBUG_CALLS_NO_AUDIO_DEVICE=1`: calls run without an audio device (no tones, no
    /// playback, a silent microphone). For simulator tests on a Mac whose audio device does not start, where every call
    /// otherwise aborts in `AURemoteIO::Initialize`.
    private(set) static var isAudioDeviceDisabled = false

    /// Once, before any room connects.
    static func prepare() {
        if self.isPrepared {
            return
        }
        self.isPrepared = true
        do {
            try RelayCallKitAudio.prepare()
            #if DEBUG
            if ProcessInfo.processInfo.environment["RELAY_DEBUG_CALLS_NO_AUDIO_DEVICE"] == "1" {
                try RelayCallKitAudio.disableAudioDevice()
                self.isAudioDeviceDisabled = true
                Logger.shared.log("RelayCalls", "audio: no audio device (RELAY_DEBUG_CALLS_NO_AUDIO_DEVICE)")
            }
            #endif
        } catch {
            Logger.shared.log("RelayCalls", "audio: prepare failed: \(error)")
        }
    }

    /// Off the main thread, in order: starting or stopping LiveKit's engine waits on the audio server.
    private static let queue = DispatchQueue(label: "org.relaychat.Relay.callAudio", qos: .userInitiated)

    static func setEngineAvailable(_ value: Bool) {
        self.prepare()
        self.queue.async {
            do {
                if value {
                    try RelayCallKitAudio.didActivate(AVAudioSession.sharedInstance())
                } else {
                    try RelayCallKitAudio.didDeactivate(AVAudioSession.sharedInstance())
                }
            } catch {
                Logger.shared.log("RelayCalls", "audio: engine availability \(value) failed: \(error)")
            }
        }
    }
}
