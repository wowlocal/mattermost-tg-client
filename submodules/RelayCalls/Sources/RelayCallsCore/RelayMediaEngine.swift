import Foundation

// The media side of a call, without LiveKit: `RelayRoomEngine` (module RelayCalls) implements `RelayMediaEngine`
// over a LiveKit `Room`; the controllers (`RelayDirectCall`, `RelayGroupCall`) only see this protocol, so tests drive
// them with a fake.

public enum RelayMediaConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

public enum RelayConnectionQuality: Int, Sendable, Equatable, Comparable {
    case unknown = 0
    case lost
    case poor
    case good
    case excellent

    public static func < (lhs: RelayConnectionQuality, rhs: RelayConnectionQuality) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// A published track of a participant.
public struct RelayMediaTrack: Sendable, Equatable {
    /// The LiveKit track sid; video sinks attach to it (`RelayRoomEngine.videoTrack(sid:)`).
    public var sid: String
    public var isMuted: Bool
    /// Width and height in pixels when known (video).
    public var width: Int32?
    public var height: Int32?

    public init(sid: String, isMuted: Bool = false, width: Int32? = nil, height: Int32? = nil) {
        self.sid = sid
        self.isMuted = isMuted
        self.width = width
        self.height = height
    }

    /// Published and not muted.
    public var isLive: Bool {
        return !self.isMuted
    }
}

/// One device in the room (a LiveKit participant).
public struct RelayMediaParticipant: Sendable, Equatable {
    /// The LiveKit identity (`<user id>:<device id>`).
    public var identity: String
    public var name: String?
    public var isLocal: Bool
    public var isSpeaking: Bool
    /// 0…1.
    public var audioLevel: Float
    public var connectionQuality: RelayConnectionQuality
    public var microphone: RelayMediaTrack?
    public var camera: RelayMediaTrack?
    public var screenShare: RelayMediaTrack?
    public var joinedAt: Date?

    public init(identity: String, name: String? = nil, isLocal: Bool = false, isSpeaking: Bool = false, audioLevel: Float = 0, connectionQuality: RelayConnectionQuality = .unknown, microphone: RelayMediaTrack? = nil, camera: RelayMediaTrack? = nil, screenShare: RelayMediaTrack? = nil, joinedAt: Date? = nil) {
        self.identity = identity
        self.name = name
        self.isLocal = isLocal
        self.isSpeaking = isSpeaking
        self.audioLevel = audioLevel
        self.connectionQuality = connectionQuality
        self.microphone = microphone
        self.camera = camera
        self.screenShare = screenShare
        self.joinedAt = joinedAt
    }

    public var parsedIdentity: RelayParticipantIdentity? {
        return RelayParticipantIdentity(self.identity)
    }

    /// The Mattermost user of the device (nil for identities without a user part).
    public var userId: String? {
        return self.parsedIdentity?.userId
    }

    public var isMicrophoneEnabled: Bool {
        return self.microphone?.isLive == true
    }

    public var isCameraEnabled: Bool {
        return self.camera?.isLive == true
    }

    public var isScreenSharing: Bool {
        return self.screenShare?.isLive == true
    }
}

public struct RelayMediaSnapshot: Sendable, Equatable {
    public var connectionState: RelayMediaConnectionState
    /// The local device first, then remote devices in join order.
    public var participants: [RelayMediaParticipant]

    public init(connectionState: RelayMediaConnectionState = .disconnected, participants: [RelayMediaParticipant] = []) {
        self.connectionState = connectionState
        self.participants = participants
    }

    public var local: RelayMediaParticipant? {
        return self.participants.first(where: { $0.isLocal })
    }

    public var remote: [RelayMediaParticipant] {
        return self.participants.filter { !$0.isLocal }
    }
}

/// Why the media connection ended without `disconnect()`.
public enum RelayMediaDisconnectReason: Sendable, Equatable {
    /// The server removed the room (the call ended for everyone) or this participant.
    case removed
    /// Another connection with the same identity replaced this one.
    case duplicateIdentity
    case failed(String)
}

/// The media of one call: a LiveKit room for `RelayRoomEngine`.
@MainActor
public protocol RelayMediaEngine: AnyObject {
    var snapshot: RelayMediaSnapshot { get }
    /// Called on the main actor after every change of `snapshot` (participants, tracks, speaking, audio levels,
    /// connection state).
    var onChange: ((RelayMediaSnapshot) -> Void)? { get set }
    /// Called when the room disconnects on its own (not after `disconnect()`).
    var onDisconnect: ((RelayMediaDisconnectReason) -> Void)? { get set }

    func connect(url: String, token: String) async throws
    func disconnect() async
    func setMicrophone(enabled: Bool) async throws
    func setCamera(enabled: Bool) async throws
    /// iOS: through the broadcast extension; macOS: the main display (use the engine's source-specific call for others).
    func setScreenShare(enabled: Bool) async throws
}

// MARK: - Scheduling

/// Cancels a scheduled action or an observation.
public final class RelayCancellable: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    public init(_ action: @escaping () -> Void) {
        self.action = action
    }

    public func cancel() {
        self.lock.lock()
        let action = self.action
        self.action = nil
        self.lock.unlock()
        action?()
    }

    deinit {
        self.cancel()
    }
}

/// Time for the controllers' local timers (ring expiry); tests use a manual clock.
@MainActor
public protocol RelayCallScheduler: AnyObject {
    func now() -> Date
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> RelayCancellable
}

@MainActor
public final class RelaySystemScheduler: RelayCallScheduler {
    public static let shared = RelaySystemScheduler()

    public init() {
    }

    public func now() -> Date {
        return Date()
    }

    public func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> RelayCancellable {
        let task = Task { @MainActor in
            let delay = date.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if Task.isCancelled {
                return
            }
            action()
        }
        return RelayCancellable {
            task.cancel()
        }
    }
}

/// Observers of a controller's snapshot (notified on the main actor; removal works from any thread).
final class RelayObservers<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: (Value) -> Void] = [:]
    private var nextId = 0

    func add(_ handler: @escaping (Value) -> Void) -> RelayCancellable {
        self.lock.lock()
        let id = self.nextId
        self.nextId += 1
        self.handlers[id] = handler
        self.lock.unlock()
        return RelayCancellable { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            self.handlers[id] = nil
            self.lock.unlock()
        }
    }

    func notify(_ value: Value) {
        self.lock.lock()
        let handlers = self.handlers.sorted(by: { $0.key < $1.key }).map(\.value)
        self.lock.unlock()
        for handler in handlers {
            handler(value)
        }
    }
}
