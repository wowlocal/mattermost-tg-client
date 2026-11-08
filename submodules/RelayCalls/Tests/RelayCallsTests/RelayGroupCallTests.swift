import Foundation
import XCTest
@testable import RelayCallsCore

@MainActor
final class RelayGroupCallTests: XCTestCase {
    private var api: FakeAPI!
    private var engine: FakeEngine!
    private var scheduler: ManualScheduler!

    override func setUp() async throws {
        self.api = FakeAPI()
        self.engine = FakeEngine(localIdentity: Fixtures.me + ":" + Fixtures.myDevice)
        self.scheduler = ManualScheduler()
    }

    private var channelCall: RelayCall {
        return Fixtures.call(id: "room1", kind: .channel, state: .active, startedBy: Fixtures.peer, invitees: nil, ringExpiresAt: nil)
    }

    private var groupRing: RelayCall {
        return Fixtures.call(id: "group1", kind: .group, state: .ringing, startedBy: Fixtures.peer, invitees: [Fixtures.me: .ringing, Fixtures.third: .ringing])
    }

    // MARK: Merging

    func testDevicesMergePerUserWithTheOwnUserFirst() {
        let devices = [
            Fixtures.device(Fixtures.peer, "p1", joinedAt: 5, speaking: false, level: 0.1, mic: false, quality: .poor),
            Fixtures.device(Fixtures.third, "t1", joinedAt: 3, camera: true),
            Fixtures.device(Fixtures.peer, "p2", joinedAt: 7, speaking: true, level: 0.6, mic: true, screen: true, quality: .excellent),
            Fixtures.device(Fixtures.me, Fixtures.myOtherDevice, joinedAt: 1, camera: true),
            Fixtures.device(Fixtures.me, Fixtures.myDevice, local: true, joinedAt: 9, mic: false),
        ]
        let merged = RelayGroupCall.mergeParticipants(devices, ownUserId: Fixtures.me)
        XCTAssertEqual(merged.map(\.userId), [Fixtures.me, Fixtures.third, Fixtures.peer])

        let me = merged[0]
        XCTAssertTrue(me.isSelf)
        XCTAssertEqual(me.devices.map(\.identity), [Fixtures.me + ":" + Fixtures.myDevice, Fixtures.me + ":" + Fixtures.myOtherDevice])
        // The other device's camera is the user's (this device has none).
        XCTAssertEqual(me.camera?.identity, Fixtures.me + ":" + Fixtures.myOtherDevice)
        XCTAssertEqual(me.camera?.isLocal, false)
        XCTAssertTrue(me.isMicrophoneEnabled)
        XCTAssertEqual(me.joinedAt, Date(timeIntervalSince1970: 1))

        let peer = merged[2]
        XCTAssertFalse(peer.isSelf)
        XCTAssertTrue(peer.isSpeaking)
        XCTAssertEqual(peer.audioLevel, 0.6)
        XCTAssertTrue(peer.isMicrophoneEnabled)
        XCTAssertEqual(peer.screenShare?.track.sid, "TR_screen_p2")
        XCTAssertNil(peer.camera)
        XCTAssertEqual(peer.connectionQuality, .excellent)
        XCTAssertEqual(peer.devices.count, 2)

        XCTAssertEqual(merged[1].camera?.track.sid, "TR_cam_t1")
        XCTAssertEqual(merged[1].camera?.track.width, 1280)
    }

    func testLiveTrackWinsOverAMutedOne() {
        var muted = Fixtures.device(Fixtures.peer, "p1", joinedAt: 1, camera: true)
        muted.camera?.isMuted = true
        let live = Fixtures.device(Fixtures.peer, "p2", joinedAt: 2, camera: true)
        let merged = RelayGroupCall.mergeParticipants([muted, live], ownUserId: Fixtures.me)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].camera?.identity, Fixtures.peer + ":p2")
        let onlyMuted = RelayGroupCall.mergeParticipants([muted], ownUserId: Fixtures.me)
        XCTAssertEqual(onlyMuted[0].camera?.track.isMuted, true)
    }

    func testIdentitiesWithoutAUserStandAlone() {
        let stray = RelayMediaParticipant(identity: "probe", name: "Probe", joinedAt: Date(timeIntervalSince1970: 1))
        let merged = RelayGroupCall.mergeParticipants([stray, Fixtures.device(Fixtures.peer, "p1")], ownUserId: Fixtures.me)
        XCTAssertEqual(merged.map(\.userId), ["probe", Fixtures.peer])
        XCTAssertEqual(merged[0].name, "Probe")
    }

    // MARK: Channel calls

    func testJoinConnectsAndTracksParticipants() async {
        self.api.joinResult = .success(Fixtures.join(self.channelCall))
        let call = RelayGroupCall.join(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, callId: "room1", scheduler: self.scheduler)
        XCTAssertEqual(call.state, .connecting)
        call.start()
        await waitUntil("connected") { call.state == .connected && self.engine.microphone == true }
        XCTAssertEqual(self.api.requests.first, .join(channelId: Fixtures.channel, callId: "room1", deviceId: Fixtures.myDevice))
        XCTAssertEqual(call.callId, "room1")
        XCTAssertEqual(call.snapshot.kind, .channel)
        XCTAssertTrue(call.snapshot.canEnd)

        self.engine.addRemote(Fixtures.device(Fixtures.peer, "p1", speaking: true, level: 0.4))
        self.engine.addRemote(Fixtures.device(Fixtures.peer, "p2", joinedAt: 11))
        XCTAssertEqual(call.participants.map(\.userId), [Fixtures.me, Fixtures.peer])
        XCTAssertEqual(call.participants[1].devices.count, 2)
        XCTAssertTrue(call.participants[1].isSpeaking)

        self.engine.setConnectionState(.reconnecting)
        XCTAssertEqual(call.state, .reconnecting)
        self.engine.setConnectionState(.connected)
        XCTAssertEqual(call.state, .connected)

        var updated = self.channelCall
        updated.participants = 3
        updated.participantIds = [Fixtures.peer, Fixtures.me]
        call.handle(.callUpdated(updated))
        XCTAssertEqual(call.call?.participants, 3)

        var ended = self.channelCall
        ended.state = .ended
        ended.endReason = .ended
        call.handle(.callEnded(ended))
        XCTAssertEqual(call.state, .ended(.ended))
        await waitUntil("disconnected") { self.engine.disconnectCount > 0 }
    }

    func testMuteCameraAndScreenShare() async {
        self.api.joinResult = .success(Fixtures.join(self.channelCall))
        let call = RelayGroupCall.join(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, scheduler: self.scheduler)
        call.start()
        await waitUntil("connected") { call.state == .connected && self.engine.microphone == true }
        call.setMuted(true)
        await waitUntil("muted") { self.engine.microphone == false }
        XCTAssertFalse(call.participants[0].isMicrophoneEnabled)
        call.setCameraEnabled(true)
        await waitUntil("camera") { self.engine.camera == true }
        XCTAssertEqual(call.participants[0].camera?.isLocal, true)
        call.setScreenShare(enabled: true)
        await waitUntil("screen") { self.engine.screenShare == true }
        XCTAssertTrue(call.snapshot.isScreenSharing)
        XCTAssertEqual(call.participants[0].screenShare?.track.sid, "TR_screen")
    }

    func testLeaveHangsUpAndEndForEveryoneEnds() async {
        self.api.joinResult = .success(Fixtures.join(self.channelCall))
        let call = RelayGroupCall.join(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, scheduler: self.scheduler)
        call.start()
        await waitUntil("connected") { call.state == .connected }
        call.leave()
        XCTAssertEqual(call.state, .ended(.left))
        await waitUntil("hangup") { self.api.requests.contains(.hangup(callId: "room1", deviceId: Fixtures.myDevice)) }

        let second = RelayGroupCall.join(api: self.api, engine: FakeEngine(localIdentity: Fixtures.me + ":" + Fixtures.myDevice), ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, scheduler: self.scheduler)
        second.start()
        await waitUntil("connected") { second.state == .connected }
        try? await second.endForEveryone()
        XCTAssertEqual(second.state, .ended(.ended))
        XCTAssertTrue(self.api.requests.contains(.end(channelId: Fixtures.channel, callId: "room1")))
    }

    func testJoinFailure() async {
        self.api.joinResult = .failure(RelayCallsError.server(403, "Join this channel first."))
        let call = RelayGroupCall.join(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, scheduler: self.scheduler)
        call.start()
        await waitUntil("failed") { call.state == .ended(.failed("Join this channel first.")) }
    }

    func testRemovedFromTheRoom() async {
        self.api.joinResult = .success(Fixtures.join(self.channelCall))
        self.api.callResult = .success(self.channelCall)
        let call = RelayGroupCall.join(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, scheduler: self.scheduler)
        call.start()
        await waitUntil("connected") { call.state == .connected }
        self.engine.dropConnection(.removed)
        await waitUntil("ended") { call.state.isEnded }
        XCTAssertEqual(call.state, .ended(.removed))
    }

    // MARK: Group rings

    func testRingingAGroupThatAlreadyHasACallJoinsIt() async {
        var running = self.groupRing
        running.state = .active
        self.api.ringResult = .failure(RelayCallsError.callInProgress(running))
        self.api.joinResult = .success(Fixtures.join(running))
        let call = RelayGroupCall.ring(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, video: true, scheduler: self.scheduler)
        call.start()
        await waitUntil("connected") { call.state == .connected && self.engine.camera == true }
        XCTAssertEqual(Array(self.api.requests.prefix(2)), [.ring(channelId: Fixtures.channel, video: true, deviceId: Fixtures.myDevice), .join(channelId: Fixtures.channel, callId: "group1", deviceId: Fixtures.myDevice)])
    }

    func testRingingAGroupShowsInvitees() async {
        let mine = Fixtures.call(id: "group2", kind: .group, state: .ringing, startedBy: Fixtures.me, invitees: [Fixtures.peer: .ringing, Fixtures.third: .ringing])
        self.api.ringResult = .success(Fixtures.join(mine))
        let call = RelayGroupCall.ring(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, video: false, scheduler: self.scheduler)
        call.start()
        await waitUntil("connected") { call.state == .connected }
        XCTAssertEqual(call.snapshot.invitees, [Fixtures.peer: .ringing, Fixtures.third: .ringing])
        var answered = mine
        answered.state = .active
        answered.invitees = [Fixtures.peer: .accepted, Fixtures.third: .declined]
        call.handle(.callState(call: answered, userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .accepted))
        XCTAssertEqual(call.snapshot.invitees[Fixtures.peer], .accepted)
        XCTAssertEqual(call.state, .connected)
    }

    func testIncomingGroupRingAccepted() async {
        let call = RelayGroupCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, call: self.groupRing, scheduler: self.scheduler)
        XCTAssertEqual(call.state, .ringing)
        call.start()
        await waitUntil("received") { self.api.requests.contains(.received(callId: "group1", deviceId: Fixtures.myDevice)) }
        var accepted = self.groupRing
        accepted.state = .active
        accepted.invitees?[Fixtures.me] = .accepted
        self.api.acceptResult = .success(Fixtures.join(accepted))
        call.accept()
        XCTAssertEqual(call.state, .connecting)
        await waitUntil("connected") { call.state == .connected }
        XCTAssertTrue(self.api.requests.contains(.accept(callId: "group1", deviceId: Fixtures.myDevice)))
        // Ring expiry no longer applies.
        self.scheduler.advance(by: 120)
        XCTAssertEqual(call.state, .connected)
    }

    func testIncomingGroupRingAnsweredOnAnotherDevice() async {
        let call = RelayGroupCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, call: self.groupRing, scheduler: self.scheduler)
        call.start()
        var accepted = self.groupRing
        accepted.state = .active
        accepted.invitees?[Fixtures.me] = .accepted
        call.handle(.callState(call: accepted, userId: Fixtures.me, deviceId: Fixtures.myOtherDevice, action: .accepted))
        XCTAssertEqual(call.state, .ended(.answeredElsewhere))
    }

    func testIncomingGroupRingDeclinedAndExpired() async {
        let declined = RelayGroupCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, call: self.groupRing, scheduler: self.scheduler)
        declined.start()
        declined.decline()
        XCTAssertEqual(declined.state, .ended(.declined))
        await waitUntil("decline") { self.api.requests.contains(.decline(callId: "group1", deviceId: Fixtures.myDevice, reason: .declined)) }

        let expiring = RelayGroupCall.incoming(api: self.api, engine: FakeEngine(localIdentity: "x:y"), ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, call: self.groupRing, scheduler: self.scheduler)
        expiring.start()
        self.scheduler.advance(by: 45)
        XCTAssertEqual(expiring.state, .ended(.missed))
    }

    func testAcceptAfterTheRingStoppedJoinsTheRunningCall() async {
        let call = RelayGroupCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, call: self.groupRing, scheduler: self.scheduler)
        call.start()
        var running = self.groupRing
        running.state = .active
        self.api.acceptResult = .failure(RelayCallsError.server(409, "No longer ringing."))
        self.api.joinResult = .success(Fixtures.join(running))
        call.accept()
        await waitUntil("connected") { call.state == .connected }
        XCTAssertTrue(self.api.requests.contains(.join(channelId: Fixtures.channel, callId: "group1", deviceId: Fixtures.myDevice)))
    }

    func testIncomingGroupRingFromPushThatEnded() async {
        var ended = self.groupRing
        ended.state = .ended
        ended.endReason = .ended
        self.api.callResult = .success(ended)
        let push = RelayCallPush(callId: "group1", channelId: Fixtures.channel, callerId: Fixtures.peer, callerName: "Peer", video: false, ringExpiresAt: 1_000_045_000, serverURL: "https://chat.example.com", recipientId: Fixtures.me)
        let call = RelayGroupCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, push: push, scheduler: self.scheduler)
        call.start()
        await waitUntil("ended") { call.state.isEnded }
        XCTAssertEqual(call.state, .ended(.ended))
        XCTAssertEqual(self.api.requests, [.call(id: "group1")])
    }
}
