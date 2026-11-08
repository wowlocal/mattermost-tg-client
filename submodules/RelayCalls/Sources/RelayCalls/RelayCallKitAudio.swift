#if os(iOS)
import AVFoundation
import Foundation
import LiveKit

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
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        }
        try AudioManager.shared.setEngineAvailability(.default)
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
