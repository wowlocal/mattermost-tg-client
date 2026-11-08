import Foundation
import XCTest
import RelayCallsCore

/// The microphone and camera of a call when publishing fails: on a device LiveKit refuses the microphone until CallKit
/// has activated the audio session (and while its category does not record). The user's choice must survive that, and
/// the call must keep trying.
@MainActor
final class RelayLocalSourceTests: XCTestCase {
    private var api: FakeAPI!
    private var engine: FakeEngine!
    private var scheduler: ManualScheduler!
    private var log: LogCollector!

    override func setUp() async throws {
        self.api = FakeAPI()
        self.engine = FakeEngine(localIdentity: Fixtures.me + ":" + Fixtures.myDevice)
        self.scheduler = ManualScheduler()
        self.log = LogCollector()
        self.log.install()
    }

    override func tearDown() async throws {
        if ProcessInfo.processInfo.environment["RELAY_TEST_PRINT_LOG"] == "1" {
            print(self.log.lines.joined(separator: "\n"))
        }
        self.log.uninstall()
    }

    private func outgoing(video: Bool = false) -> RelayDirectCall {
        self.api.ringResult = .success(Fixtures.join(Fixtures.call(video: video)))
        return RelayDirectCall.outgoing(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, peerUserId: Fixtures.peer, video: video, scheduler: self.scheduler)
    }

    /// An answered outgoing call whose first microphone request already ran (no ring or connect timers left).
    private func answeredOutgoing(video: Bool = false) async -> RelayDirectCall {
        let call = self.outgoing(video: video)
        call.start()
        await waitUntil("microphone requested") { !self.engine.microphoneRequests.isEmpty }
        call.handle(.callState(call: Fixtures.call(state: .active, invitees: [Fixtures.peer: .accepted]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .accepted))
        self.engine.addRemote(Fixtures.device(Fixtures.peer, Fixtures.peerDevice))
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
        return call
    }

    private func logged(_ text: String) -> Bool {
        return self.log.lines.contains(where: { $0.contains(text) })
    }

    // MARK: Direct calls

    func testFailedPublishKeepsTheMicrophoneOnAndRetriesWhenAudioBecomesAvailable() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.answeredOutgoing()
        await waitUntil("failure logged") { self.logged("microphone on failed (attempt 1)") }
        XCTAssertFalse(call.snapshot.isMuted)
        XCTAssertNil(self.engine.microphone)

        self.engine.microphoneError = nil
        call.audioBecameAvailable()
        await waitUntil("published") { self.engine.microphone == true }
        XCTAssertEqual(self.engine.microphoneRequests, [true, true])
        XCTAssertFalse(call.snapshot.isMuted)
        await waitUntil("recovery logged") { self.logged("microphone on succeeded after 1 failed attempt(s)") }
        XCTAssertTrue(self.logged("microphone on again (audio became available)"))
    }

    func testAFailureNeverShowsTheMicrophoneMuted() async {
        self.engine.microphoneError = FakeMediaError()
        let call = self.outgoing()
        var mutedSnapshots = 0
        let observation = call.observe { snapshot in
            if snapshot.isMuted {
                mutedSnapshots += 1
            }
        }
        call.start()
        await waitUntil("microphone requested") { !self.engine.microphoneRequests.isEmpty }
        call.handle(.callState(call: Fixtures.call(state: .active, invitees: [Fixtures.peer: .accepted]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .accepted))
        self.engine.addRemote(Fixtures.device(Fixtures.peer, Fixtures.peerDevice))
        // Every automatic retry fails.
        for delay in [0.5, 1, 2, 4, 8, 8, 8, 8] {
            let count = self.engine.microphoneRequests.count
            await waitUntil("failure handled") { self.logged("(attempt \(count))") }
            self.scheduler.advance(by: delay)
            await waitUntil("retried") { self.engine.microphoneRequests.count == count + 1 }
        }
        await waitUntil("gave up") { self.logged("(attempt 9)") && self.logged("no more automatic retries") }
        self.scheduler.advance(by: 60)
        await settle()
        XCTAssertEqual(self.engine.microphoneRequests.count, 9)
        XCTAssertEqual(mutedSnapshots, 0)
        XCTAssertFalse(call.snapshot.isMuted)
        XCTAssertTrue(call.state == .active(since: Date(timeIntervalSince1970: 1_000_000)))

        // Still on: the next chance publishes it.
        self.engine.microphoneError = nil
        call.audioBecameAvailable()
        await waitUntil("published") { self.engine.microphone == true }
        XCTAssertEqual(mutedSnapshots, 0)
        observation.cancel()
    }

    func testShortRetriesPublishOnceTheEngineWorks() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.answeredOutgoing()
        await waitUntil("failure logged") { self.logged("(attempt 1)") }
        self.scheduler.advance(by: 0.4)
        await settle()
        XCTAssertEqual(self.engine.microphoneRequests.count, 1)
        self.scheduler.advance(by: 0.1)
        await waitUntil("second attempt") { self.engine.microphoneRequests.count == 2 }
        await waitUntil("second failure logged") { self.logged("(attempt 2)") }
        self.engine.microphoneError = nil
        self.scheduler.advance(by: 1)
        await waitUntil("published") { self.engine.microphone == true }
        XCTAssertFalse(call.snapshot.isMuted)
    }

    func testUnmuteAfterAFailureRetriesAtOnce() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.answeredOutgoing()
        await waitUntil("failure logged") { self.logged("(attempt 1)") }

        // The engine works now; the user taps mute and unmute before the retry is due.
        self.engine.microphoneError = nil
        call.setMuted(true)
        await waitUntil("muted") { self.engine.microphone == false }
        XCTAssertTrue(call.snapshot.isMuted)
        call.setMuted(false)
        await waitUntil("unmuted") { self.engine.microphone == true }
        XCTAssertFalse(call.snapshot.isMuted)
        XCTAssertEqual(self.engine.microphoneRequests, [true, false, true])

        // The pending retry was replaced: nothing more is sent.
        self.scheduler.advance(by: 10)
        await settle()
        XCTAssertEqual(self.engine.microphoneRequests, [true, false, true])
    }

    func testUnmuteWhileTheEngineStillFailsKeepsRetrying() async {
        let call = self.outgoing()
        call.setMuted(true)
        call.start()
        await waitUntil("applied muted") { self.engine.microphone == false }
        call.handle(.callState(call: Fixtures.call(state: .active, invitees: [Fixtures.peer: .accepted]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .accepted))
        self.engine.addRemote(Fixtures.device(Fixtures.peer, Fixtures.peerDevice))

        self.engine.microphoneError = FakeMediaError()
        call.setMuted(false)
        XCTAssertFalse(call.snapshot.isMuted)
        await waitUntil("failure logged") { self.logged("microphone on failed (attempt 1)") }
        XCTAssertFalse(call.snapshot.isMuted)
        self.engine.microphoneError = nil
        self.scheduler.advance(by: 0.5)
        await waitUntil("published") { self.engine.microphone == true }
        XCTAssertEqual(self.engine.microphoneRequests, [false, true, true])
    }

    func testAMicrophoneThatFailedRetriesAfterAReconnect() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.answeredOutgoing()
        await waitUntil("failure logged") { self.logged("(attempt 1)") }
        self.engine.microphoneError = nil
        self.engine.setConnectionState(.reconnecting)
        self.engine.setConnectionState(.connected)
        await waitUntil("published") { self.engine.microphone == true }
        XCTAssertTrue(self.logged("microphone on again (reconnected)"))
        XCTAssertFalse(call.snapshot.isMuted)
    }

    func testRetriesStopWhenTheCallEnds() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.answeredOutgoing()
        await waitUntil("failure logged") { self.logged("(attempt 1)") }
        call.hangup()
        self.scheduler.advance(by: 60)
        call.audioBecameAvailable()
        await settle()
        XCTAssertEqual(self.engine.microphoneRequests, [true])
    }

    func testAudioBecomingAvailableAfterASuccessDoesNothing() async {
        let call = await self.answeredOutgoing()
        await waitUntil("published") { self.engine.microphone == true }
        call.audioBecameAvailable()
        await settle()
        XCTAssertEqual(self.engine.microphoneRequests, [true])
    }

    func testCameraRetriesThenTurnsOff() async {
        self.engine.cameraError = FakeMediaError("No first camera frame")
        let call = await self.answeredOutgoing(video: true)
        await waitUntil("camera requested") { self.engine.cameraRequests == [true] }
        XCTAssertTrue(call.snapshot.isCameraEnabled)
        for delay in [1.0, 2, 4] {
            let count = self.engine.cameraRequests.count
            await waitUntil("failure handled") { self.logged("camera on failed (attempt \(count))") }
            XCTAssertTrue(call.snapshot.isCameraEnabled)
            self.scheduler.advance(by: delay)
            // The last failure turns the camera off at once (another request).
            await waitUntil("retried") { self.engine.cameraRequests.count >= count + 1 }
        }
        await waitUntil("camera off") { !call.snapshot.isCameraEnabled }
        // Turning it off in the room is retried like any other request.
        await waitUntil("turning off requested") { self.engine.cameraRequests == [true, true, true, true, false] }
        await waitUntil("off failure handled") { self.logged("camera off failed (attempt 1)") }
        self.engine.cameraError = nil
        self.scheduler.advance(by: 1)
        await waitUntil("turned off in the room") { self.engine.camera == false }
        XCTAssertFalse(call.snapshot.isMuted)
    }

    func testCameraRecoversWithinItsRetries() async {
        self.engine.cameraError = FakeMediaError("No first camera frame")
        let call = await self.answeredOutgoing(video: true)
        await waitUntil("failure handled") { self.logged("camera on failed (attempt 1)") }
        self.engine.cameraError = nil
        self.scheduler.advance(by: 1)
        await waitUntil("camera on") { self.engine.camera == true }
        XCTAssertTrue(call.snapshot.isCameraEnabled)
    }

    // MARK: Group calls

    private var channelCall: RelayCall {
        return Fixtures.call(id: "room1", kind: .channel, state: .active, startedBy: Fixtures.peer, invitees: nil, ringExpiresAt: nil)
    }

    private func joinedChannelCall() async -> RelayGroupCall {
        self.api.joinResult = .success(Fixtures.join(self.channelCall))
        let call = RelayGroupCall.join(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, scheduler: self.scheduler)
        call.start()
        await waitUntil("microphone requested") { call.state == .connected && !self.engine.microphoneRequests.isEmpty }
        return call
    }

    func testGroupCallKeepsTheMicrophoneOnAndRetriesWhenAudioBecomesAvailable() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.joinedChannelCall()
        await waitUntil("failure logged") { self.logged("channel call room1: microphone on failed (attempt 1)") }
        XCTAssertFalse(call.snapshot.isMuted)

        self.engine.microphoneError = nil
        call.audioBecameAvailable()
        await waitUntil("published") { self.engine.microphone == true }
        XCTAssertFalse(call.snapshot.isMuted)
        XCTAssertTrue(call.participants[0].isMicrophoneEnabled)
    }

    func testGroupCallUnmuteAfterAFailureRetries() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.joinedChannelCall()
        await waitUntil("failure logged") { self.logged("(attempt 1)") }
        self.engine.microphoneError = nil
        call.setMuted(true)
        await waitUntil("muted") { self.engine.microphone == false }
        call.setMuted(false)
        await waitUntil("unmuted") { self.engine.microphone == true }
        XCTAssertFalse(call.snapshot.isMuted)

        self.scheduler.advance(by: 30)
        await settle()
        XCTAssertEqual(self.engine.microphoneRequests, [true, false, true])
    }

    func testGroupCallRetriesWithBackoff() async {
        self.engine.microphoneError = FakeMediaError()
        let call = await self.joinedChannelCall()
        await waitUntil("failure logged") { self.logged("(attempt 1)") }
        self.scheduler.advance(by: 0.5)
        await waitUntil("second attempt") { self.engine.microphoneRequests.count == 2 }
        await waitUntil("second failure logged") { self.logged("(attempt 2)") }
        XCTAssertFalse(call.snapshot.isMuted)
        self.engine.microphoneError = nil
        self.scheduler.advance(by: 1)
        await waitUntil("published") { self.engine.microphone == true }
    }
}
