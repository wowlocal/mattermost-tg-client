#if os(iOS)
import AVFoundation
import Foundation
import LiveKit
import RelayCallsCore

/// LiveKit's audio under CallKit (the SDK README's "Integration with CallKit"): the app (Telegram's
/// `ManagedAudioSession`) owns the `AVAudioSession`, and LiveKit's audio engine runs only between CallKit's
/// `provider(_:didActivate:)` and `provider(_:didDeactivate:)`.
public enum RelayCallKitAudio {
    /// Call once, before any room connects (app launch, when calls go through CallKit): turns off LiveKit's own
    /// session configuration and keeps its engine off until CallKit activates the session.
    public static func prepare() throws {
        #if targetEnvironment(simulator)
        RelaySimulatorNetwork.install()
        #endif
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try AudioManager.shared.setEngineAvailability(.none)
    }

    /// `CXProviderDelegate.provider(_:didActivate:)`. With `configureSession`, also sets the call category
    /// (`.playAndRecord`, `.voiceChat`); leave it off when the app configures the session itself.
    public static func didActivate(_ session: AVAudioSession, configureSession: Bool = false) throws {
        if configureSession {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: self.callCategoryOptions)
        }
        try AudioManager.shared.setEngineAvailability(.default)
    }

    /// The options of Telegram's `.voiceCall` session (`ManagedAudioSession`).
    public static let callCategoryOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]

    /// With automatic configuration off nothing else gives the session a category that records: under CallKit
    /// Telegram's `ManagedAudioSession` never sets up a call's session (tgcalls' audio device did), so CallKit activates
    /// it in whatever category the app had (`.soloAmbient`, or `.playback` after media), and LiveKit's engine cannot
    /// start the microphone ("Audio session category does not support recording"). Sets `.playAndRecord` /
    /// `.voiceChat` unless the session already plays and records. Best before CallKit activates the session (a
    /// category change on an active session can reset the output route). Returns whether it changed the category.
    @discardableResult
    public static func ensureCallCategory(_ session: AVAudioSession = .sharedInstance()) throws -> Bool {
        if session.category == .playAndRecord {
            return false
        }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: self.callCategoryOptions)
        return true
    }

    /// The audio state behind a microphone that does not publish, for logs. Waits on WebRTC's worker thread: not on
    /// the main thread.
    public static var diagnostics: String {
        let session = AVAudioSession.sharedInstance()
        let availability = AudioManager.shared.engineAvailability
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permission = "granted"
        case .denied:
            permission = "denied"
        case .restricted:
            permission = "restricted"
        case .notDetermined:
            permission = "undetermined"
        @unknown default:
            permission = "unknown"
        }
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        // `sessionInput=false` (a category that does not record): LiveKit builds its engine output-only ("inputFormat -"
        // in the AURemoteIO log) and the microphone fails.
        return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) options=\(session.categoryOptions.rawValue) sessionInput=\(session.isInputAvailable) engineInput=\(availability.isInputAvailable) engineOutput=\(availability.isOutputAvailable) engineRunning=\(AudioManager.shared.isEngineRunning) engineMicMuted=\(AudioManager.shared.isMicrophoneMuted) manualRendering=\(AudioManager.shared.isManualRenderingMode) microphonePermission=\(permission) inputs=[\(inputs)] outputs=[\(outputs)]"
    }

    /// `CXProviderDelegate.provider(_:didDeactivate:)`.
    public static func didDeactivate(_: AVAudioSession) throws {
        try AudioManager.shared.setEngineAvailability(.none)
    }

    /// Without CallKit (e.g. a channel call joined from the panel while no CallKit call exists): let the engine run
    /// on the session the app activated.
    public static func activateWithoutCallKit() throws {
        try AudioManager.shared.setEngineAvailability(.default)
    }

    /// Whether LiveKit's engine may use the microphone and speaker now.
    public static var isEngineAvailable: Bool {
        let availability = AudioManager.shared.engineAvailability
        return availability.isInputAvailable && availability.isOutputAvailable
    }

    /// Calls without an audio device (LiveKit's manual rendering): remote audio is not played and the microphone
    /// sends silence. Only for tests on a host whose audio device does not start, where the simulator aborts in
    /// `AURemoteIO::Initialize` ("RPC timeout. Apparently deadlocked") as soon as an engine starts. Before any room
    /// connects.
    public static func disableAudioDevice() throws {
        try AudioManager.shared.setManualRenderingMode(true)
    }

    /// Prefer the loudspeaker (video calls) or the receiver.
    public static func setSpeakerOutputPreferred(_ preferred: Bool) {
        AudioManager.shared.isSpeakerOutputPreferred = preferred
    }
}
#endif
