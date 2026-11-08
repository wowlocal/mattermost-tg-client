import Foundation
import XCTest
import RelayCallsCore

/// Plugin routes as the controllers call them.
enum APIRequest: Equatable {
    case call(id: String)
    case join(channelId: String, callId: String?, deviceId: String?)
    case ring(channelId: String, video: Bool, deviceId: String)
    case end(channelId: String, callId: String)
    case received(callId: String, deviceId: String)
    case accept(callId: String, deviceId: String)
    case decline(callId: String, deviceId: String, reason: RelayDeclineReason)
    case hangup(callId: String, deviceId: String)
}

final class FakeAPI: RelayCallsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [APIRequest] = []
    var callResult: Result<RelayCall?, Error> = .success(nil)
    var joinResult: Result<RelayCallJoin, Error> = .failure(RelayCallsError.invalidResponse)
    var ringResult: Result<RelayCallJoin, Error> = .failure(RelayCallsError.invalidResponse)
    var acceptResult: Result<RelayCallJoin, Error> = .failure(RelayCallsError.invalidResponse)

    var requests: [APIRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._requests
    }

    private func record(_ request: APIRequest) {
        self.lock.lock()
        self._requests.append(request)
        self.lock.unlock()
    }

    func call(id: String) async throws -> RelayCall? {
        self.record(.call(id: id))
        return try self.callResult.get()
    }

    func join(channelId: String, callId: String?, deviceId: String?) async throws -> RelayCallJoin {
        self.record(.join(channelId: channelId, callId: callId, deviceId: deviceId))
        return try self.joinResult.get()
    }

    func ring(channelId: String, video: Bool, deviceId: String) async throws -> RelayCallJoin {
        self.record(.ring(channelId: channelId, video: video, deviceId: deviceId))
        return try self.ringResult.get()
    }

    func end(channelId: String, callId: String) async throws {
        self.record(.end(channelId: channelId, callId: callId))
    }

    func received(callId: String, deviceId: String) async throws {
        self.record(.received(callId: callId, deviceId: deviceId))
    }

    func accept(callId: String, deviceId: String) async throws -> RelayCallJoin {
        self.record(.accept(callId: callId, deviceId: deviceId))
        return try self.acceptResult.get()
    }

    func decline(callId: String, deviceId: String, reason: RelayDeclineReason) async throws {
        self.record(.decline(callId: callId, deviceId: deviceId, reason: reason))
    }

    func hangup(callId: String, deviceId: String) async throws {
        self.record(.hangup(callId: callId, deviceId: deviceId))
    }
}

@MainActor
final class FakeEngine: RelayMediaEngine {
    var snapshot = RelayMediaSnapshot()
    var onChange: ((RelayMediaSnapshot) -> Void)?
    var onDisconnect: ((RelayMediaDisconnectReason) -> Void)?
    var connectError: Error?
    private(set) var connectedWith: (url: String, token: String)?
    private(set) var disconnectCount = 0
    private(set) var microphone: Bool?
    private(set) var camera: Bool?
    private(set) var screenShare: Bool?
    let localIdentity: String

    init(localIdentity: String) {
        self.localIdentity = localIdentity
    }

    func connect(url: String, token: String) async throws {
        if let connectError {
            throw connectError
        }
        self.connectedWith = (url, token)
        self.snapshot.connectionState = .connected
        self.snapshot.participants.insert(RelayMediaParticipant(identity: self.localIdentity, name: "Me", isLocal: true, joinedAt: Date(timeIntervalSince1970: 0)), at: 0)
        self.changed()
    }

    func disconnect() async {
        self.disconnectCount += 1
        self.snapshot = RelayMediaSnapshot()
        self.changed()
    }

    func setMicrophone(enabled: Bool) async throws {
        self.microphone = enabled
        self.updateLocal { $0.microphone = RelayMediaTrack(sid: "TR_mic", isMuted: !enabled) }
    }

    func setCamera(enabled: Bool) async throws {
        self.camera = enabled
        self.updateLocal { $0.camera = enabled ? RelayMediaTrack(sid: "TR_cam") : nil }
    }

    func setScreenShare(enabled: Bool) async throws {
        self.screenShare = enabled
        self.updateLocal { $0.screenShare = enabled ? RelayMediaTrack(sid: "TR_screen") : nil }
    }

    // Test controls.

    func addRemote(_ participant: RelayMediaParticipant) {
        self.snapshot.participants.append(participant)
        self.changed()
    }

    func removeRemote(identity: String) {
        self.snapshot.participants.removeAll(where: { $0.identity == identity })
        self.changed()
    }

    func setConnectionState(_ state: RelayMediaConnectionState) {
        self.snapshot.connectionState = state
        self.changed()
    }

    func dropConnection(_ reason: RelayMediaDisconnectReason) {
        self.snapshot = RelayMediaSnapshot()
        self.changed()
        self.onDisconnect?(reason)
    }

    private func updateLocal(_ update: (inout RelayMediaParticipant) -> Void) {
        if let index = self.snapshot.participants.firstIndex(where: { $0.isLocal }) {
            update(&self.snapshot.participants[index])
            self.changed()
        }
    }

    private func changed() {
        self.onChange?(self.snapshot)
    }
}

@MainActor
final class ManualScheduler: RelayCallScheduler {
    private struct Item {
        let date: Date
        let action: @MainActor () -> Void
        let id: Int
    }

    var current = Date(timeIntervalSince1970: 1_000_000)
    private var items: [Item] = []
    private var cancelled: Set<Int> = []
    private var nextId = 0

    func now() -> Date {
        return self.current
    }

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> RelayCancellable {
        let id = self.nextId
        self.nextId += 1
        self.items.append(Item(date: date, action: action, id: id))
        return RelayCancellable { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.cancelled.insert(id)
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        self.current = self.current.addingTimeInterval(seconds)
        let due = self.items.filter { $0.date <= self.current && !self.cancelled.contains($0.id) }
        self.items.removeAll(where: { $0.date <= self.current })
        for item in due {
            item.action()
        }
    }
}

/// Polls `condition` on the main actor (the controllers' tasks hop through the fake API's executor).
@MainActor
func waitUntil(_ description: String = "condition", timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Lets queued main-actor tasks run.
@MainActor
func settle() async {
    for _ in 0 ..< 20 {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

enum Fixtures {
    static let me = "meuser000000000000000000aa"
    static let peer = "peeruser0000000000000000bb"
    static let third = "thirduser000000000000000cc"
    static let channel = "abcdefghijklmnopqrstuvwxyz"
    static let myDevice = "device-mine"
    static let myOtherDevice = "device-mine-2"
    static let peerDevice = "device-peer"

    static func call(id: String = "call1", kind: RelayCallKind = .direct, state: RelayCallState = .ringing, startedBy: String = Fixtures.me, invitees: [String: RelayInviteeState]? = [Fixtures.peer: .ringing], ringExpiresAt: Int64? = 1_000_045_000, endReason: RelayCallEndReason? = nil, durationMs: Int64? = nil, video: Bool = false) -> RelayCall {
        return RelayCall(id: id, channelId: Fixtures.channel, room: "relay_" + id, kind: kind, state: state, video: video, startedBy: startedBy, startedAt: 1_000_000_000, ringExpiresAt: ringExpiresAt, endReason: endReason, durationMs: durationMs, participants: 1, participantIds: [startedBy], invitees: invitees, canEnd: true)
    }

    static func join(_ call: RelayCall) -> RelayCallJoin {
        return RelayCallJoin(url: "wss://livekit.example.com", token: "room-token", call: call)
    }

    static func device(_ userId: String, _ deviceId: String, local: Bool = false, joinedAt: TimeInterval = 10, speaking: Bool = false, level: Float = 0, mic: Bool = true, camera: Bool = false, screen: Bool = false, quality: RelayConnectionQuality = .good, name: String? = nil) -> RelayMediaParticipant {
        return RelayMediaParticipant(
            identity: userId + ":" + deviceId,
            name: name ?? userId,
            isLocal: local,
            isSpeaking: speaking,
            audioLevel: level,
            connectionQuality: quality,
            microphone: RelayMediaTrack(sid: "TR_mic_" + deviceId, isMuted: !mic),
            camera: camera ? RelayMediaTrack(sid: "TR_cam_" + deviceId, width: 1280, height: 720) : nil,
            screenShare: screen ? RelayMediaTrack(sid: "TR_screen_" + deviceId) : nil,
            joinedAt: Date(timeIntervalSince1970: joinedAt)
        )
    }
}
