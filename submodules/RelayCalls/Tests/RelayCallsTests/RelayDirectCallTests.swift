import Foundation
import XCTest
import RelayCallsCore

@MainActor
final class RelayDirectCallTests: XCTestCase {
    private var api: FakeAPI!
    private var engine: FakeEngine!
    private var scheduler: ManualScheduler!

    override func setUp() async throws {
        self.api = FakeAPI()
        self.engine = FakeEngine(localIdentity: Fixtures.me + ":" + Fixtures.myDevice)
        self.scheduler = ManualScheduler()
    }

    private func outgoing(video: Bool = false, ring: RelayCall = Fixtures.call()) -> RelayDirectCall {
        self.api.ringResult = .success(Fixtures.join(ring))
        return RelayDirectCall.outgoing(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, channelId: Fixtures.channel, peerUserId: Fixtures.peer, video: video, scheduler: self.scheduler)
    }

    private var incomingCall: RelayCall {
        return Fixtures.call(startedBy: Fixtures.peer, invitees: [Fixtures.me: .ringing])
    }

    private func incoming() -> RelayDirectCall {
        return RelayDirectCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, call: self.incomingCall, scheduler: self.scheduler)
    }

    private var peerDevice: RelayMediaParticipant {
        return Fixtures.device(Fixtures.peer, Fixtures.peerDevice)
    }

    /// An outgoing call the callee answered, with the callee's device in the room.
    private func activeOutgoing() async -> RelayDirectCall {
        let call = self.outgoing()
        call.start()
        await waitUntil("media connected") { self.engine.connectedWith != nil && self.engine.microphone != nil }
        call.handle(.callState(call: Fixtures.call(state: .active, invitees: [Fixtures.peer: .accepted]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .accepted))
        self.engine.addRemote(self.peerDevice)
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
        return call
    }

    // MARK: Outgoing

    func testOutgoingRingsConnectsEarlyRingsBackAndBecomesActive() async {
        let call = self.outgoing()
        var states: [RelayDirectCall.State] = []
        let observation = call.observe { states.append($0.state) }
        XCTAssertEqual(call.state, .requesting(ringing: false))
        call.start()
        await waitUntil("media connected") { self.engine.microphone == true }
        XCTAssertEqual(self.api.requests.first, .ring(channelId: Fixtures.channel, video: false, deviceId: Fixtures.myDevice))
        XCTAssertEqual(self.engine.connectedWith?.token, "room-token")
        XCTAssertEqual(call.callId, "call1")
        XCTAssertEqual(call.state, .requesting(ringing: false))

        call.handle(.callState(call: Fixtures.call(invitees: [Fixtures.peer: .received]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .received))
        XCTAssertEqual(call.state, .requesting(ringing: true))

        call.handle(.callState(call: Fixtures.call(state: .active, invitees: [Fixtures.peer: .accepted]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .accepted))
        XCTAssertEqual(call.state, .connecting)

        self.engine.addRemote(self.peerDevice)
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
        XCTAssertEqual(call.snapshot.remote?.identity, self.peerDevice.identity)
        XCTAssertTrue(states.contains(.requesting(ringing: true)))
        XCTAssertTrue(states.contains(.connecting))
        observation.cancel()
    }

    func testOutgoingShowsRingingWhenTheRingResponseAlreadyHasAReceivedInvitee() async {
        let call = self.outgoing(ring: Fixtures.call(invitees: [Fixtures.peer: .received]))
        call.start()
        await waitUntil("ringing") { call.state == .requesting(ringing: true) }
    }

    func testOutgoingCalleeJoiningBeforeAcceptedEventIsActive() async {
        let call = self.outgoing()
        call.start()
        await waitUntil("media connected") { self.engine.microphone != nil }
        self.engine.addRemote(self.peerDevice)
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
    }

    func testOutgoingDeclinedByCallee() async {
        let call = self.outgoing()
        call.start()
        await waitUntil("media connected") { self.engine.microphone != nil }
        call.handle(.callState(call: Fixtures.call(invitees: [Fixtures.peer: .declined]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .declined))
        XCTAssertEqual(call.state, .terminated(.declined, duration: nil))
        await waitUntil("disconnected") { self.engine.disconnectCount > 0 }
    }

    func testOutgoingBusyFromCallEnded() async {
        let call = self.outgoing()
        call.start()
        await waitUntil("call id") { call.callId != nil }
        call.handle(.callEnded(Fixtures.call(state: .ended, invitees: [Fixtures.peer: .busy], endReason: .busy)))
        XCTAssertEqual(call.state, .terminated(.busy, duration: nil))
    }

    func testOutgoingMissedFromServer() async {
        let call = self.outgoing()
        call.start()
        await waitUntil("call id") { call.callId != nil }
        call.handle(.callEnded(Fixtures.call(state: .ended, invitees: [Fixtures.peer: .missed], endReason: .missed)))
        XCTAssertEqual(call.state, .terminated(.missed, duration: nil))
    }

    func testOutgoingRingExpiresLocallyAfterGrace() async {
        let call = self.outgoing()
        call.start()
        await waitUntil("media connected") { self.engine.microphone != nil }
        // `ring_expires_at` is 45 s after the scheduler's start.
        self.scheduler.advance(by: 45)
        XCTAssertEqual(call.state, .requesting(ringing: false))
        self.scheduler.advance(by: RelayDirectCall.ringExpiryGrace)
        XCTAssertEqual(call.state, .terminated(.missed, duration: nil))
        await waitUntil("hangup sent") { self.api.requests.contains(.hangup(callId: "call1", deviceId: Fixtures.myDevice)) }
    }

    func testOutgoingRingExpiryIsCancelledByTheAnswer() async {
        let call = await self.activeOutgoing()
        self.scheduler.advance(by: 60)
        XCTAssertEqual(call.state, .active(since: Date(timeIntervalSince1970: 1_000_000)))
    }

    func testOutgoingHangupBeforeAnswerCancels() async {
        let call = self.outgoing()
        call.start()
        await waitUntil("media connected") { self.engine.microphone != nil }
        call.hangup()
        XCTAssertEqual(call.state, .terminated(.hangup, duration: nil))
        await waitUntil("hangup sent") { self.api.requests.contains(.hangup(callId: "call1", deviceId: Fixtures.myDevice)) }
        await waitUntil("disconnected") { self.engine.disconnectCount > 0 }
    }

    func testHangupWhileRingRequestIsInFlightHangsUpTheCreatedCall() async {
        let call = self.outgoing()
        call.start()
        call.hangup()
        XCTAssertEqual(call.state, .terminated(.hangup, duration: nil))
        await waitUntil("hangup sent") { self.api.requests.contains(.hangup(callId: "call1", deviceId: Fixtures.myDevice)) }
        XCTAssertNil(self.engine.connectedWith)
    }

    func testRingFailureTerminates() async {
        let call = self.outgoing()
        self.api.ringResult = .failure(RelayCallsError.server(400, "Calls ring in direct and group messages only."))
        call.start()
        await waitUntil("failed") { call.state == .terminated(.failed("Calls ring in direct and group messages only."), duration: nil) }
    }

    func testMediaConnectFailureTerminatesAndHangsUp() async {
        let call = self.outgoing()
        self.engine.connectError = RelayCallsError.invalidServer
        call.start()
        await waitUntil("failed") { call.state.isTerminated }
        await waitUntil("hangup sent") { self.api.requests.contains(.hangup(callId: "call1", deviceId: Fixtures.myDevice)) }
    }

    func testRemoteHangupUsesServerDuration() async {
        let call = await self.activeOutgoing()
        call.handle(.callEnded(Fixtures.call(state: .ended, invitees: [Fixtures.peer: .accepted], endReason: .hangup, durationMs: 42_000)))
        XCTAssertEqual(call.state, .terminated(.remoteHangup, duration: 42))
    }

    func testRemoteHangupFromCallState() async {
        let call = await self.activeOutgoing()
        self.scheduler.advance(by: 12)
        call.handle(.callState(call: Fixtures.call(state: .active, invitees: [Fixtures.peer: .accepted]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .hangup))
        XCTAssertEqual(call.state, .terminated(.remoteHangup, duration: 12))
    }

    func testLocalHangupOfActiveCallCountsDurationFromAnswer() async {
        let call = await self.activeOutgoing()
        self.scheduler.advance(by: 30)
        call.hangup()
        XCTAssertEqual(call.state, .terminated(.hangup, duration: 30))
        await waitUntil("hangup sent") { self.api.requests.contains(.hangup(callId: "call1", deviceId: Fixtures.myDevice)) }
    }

    func testReconnectingKeepsTheStartTime() async {
        let call = await self.activeOutgoing()
        let since = self.scheduler.current
        self.scheduler.advance(by: 5)
        self.engine.setConnectionState(.reconnecting)
        XCTAssertEqual(call.state, .reconnecting(since: since))
        self.engine.setConnectionState(.connected)
        XCTAssertEqual(call.state, .active(since: since))
        // The other side's device dropping out of the room reads as reconnecting too.
        self.engine.removeRemote(identity: self.peerDevice.identity)
        XCTAssertEqual(call.state, .reconnecting(since: since))
        self.engine.addRemote(self.peerDevice)
        XCTAssertEqual(call.state, .active(since: since))
    }

    func testGlareAnswersTheCalleesRing() async {
        let theirs = Fixtures.call(id: "call2", startedBy: Fixtures.peer, invitees: [Fixtures.me: .ringing])
        let call = self.outgoing()
        self.api.ringResult = .failure(RelayCallsError.callInProgress(theirs))
        self.api.acceptResult = .success(Fixtures.join(Fixtures.call(id: "call2", state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted])))
        call.start()
        await waitUntil("media connected") { self.engine.microphone != nil }
        XCTAssertTrue(self.api.requests.contains(.accept(callId: "call2", deviceId: Fixtures.myDevice)))
        XCTAssertEqual(call.callId, "call2")
        XCTAssertEqual(call.state, .connecting)
        self.engine.addRemote(self.peerDevice)
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
    }

    func testRunningCallInTheChannelIsJoined() async {
        let running = Fixtures.call(id: "call3", state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted])
        let call = self.outgoing()
        self.api.ringResult = .failure(RelayCallsError.callInProgress(running))
        self.api.joinResult = .success(Fixtures.join(running))
        call.start()
        await waitUntil("joined") { self.api.requests.contains(.join(channelId: Fixtures.channel, callId: "call3", deviceId: Fixtures.myDevice)) }
        await waitUntil("media connected") { self.engine.microphone != nil }
        XCTAssertEqual(call.state, .connecting)
    }

    func testVideoCallPublishesTheCameraAndCanTurnItOff() async {
        let call = self.outgoing(video: true)
        call.start()
        await waitUntil("camera on") { self.engine.camera == true }
        XCTAssertEqual(self.api.requests.first, .ring(channelId: Fixtures.channel, video: true, deviceId: Fixtures.myDevice))
        XCTAssertTrue(call.snapshot.isCameraEnabled)
        call.setCameraEnabled(false)
        await waitUntil("camera off") { self.engine.camera == false }
        XCTAssertFalse(call.snapshot.isCameraEnabled)
    }

    func testMuteChosenBeforeConnectingIsApplied() async {
        let call = self.outgoing()
        call.setMuted(true)
        call.start()
        await waitUntil("media connected") { self.engine.microphone != nil }
        XCTAssertEqual(self.engine.microphone, false)
        call.setMuted(false)
        await waitUntil("unmuted") { self.engine.microphone == true }
    }

    func testDroppedMediaEndsWithTheServersReason() async {
        let call = await self.activeOutgoing()
        self.api.callResult = .success(Fixtures.call(state: .ended, invitees: [Fixtures.peer: .accepted], endReason: .hangup, durationMs: 9_000))
        self.engine.dropConnection(.removed)
        await waitUntil("terminated") { call.state.isTerminated }
        XCTAssertEqual(call.state, .terminated(.remoteHangup, duration: 9))
    }

    func testDroppedMediaOfARunningCallFails() async {
        let call = await self.activeOutgoing()
        self.api.callResult = .success(Fixtures.call(state: .active, invitees: [Fixtures.peer: .accepted]))
        self.engine.dropConnection(.failed("network"))
        await waitUntil("terminated") { call.state.isTerminated }
        XCTAssertEqual(call.state, .terminated(.failed("network"), duration: 0))
        await waitUntil("hangup sent") { self.api.requests.contains(.hangup(callId: "call1", deviceId: Fixtures.myDevice)) }
    }

    func testActiveCallsWithoutTheCallChecksTheServer() async {
        let call = await self.activeOutgoing()
        self.api.callResult = .success(Fixtures.call(state: .ended, invitees: [Fixtures.peer: .accepted], endReason: .ended))
        call.handle(.activeCalls([]))
        await waitUntil("terminated") { call.state.isTerminated }
        XCTAssertEqual(call.state, .terminated(.ended, duration: 0))
        XCTAssertTrue(self.api.requests.contains(.call(id: "call1")))
    }

    func testEventsOfOtherCallsAreIgnored() async {
        let call = await self.activeOutgoing()
        call.handle(.callEnded(Fixtures.call(id: "other", state: .ended, endReason: .hangup)))
        call.handle(.callState(call: Fixtures.call(id: "other"), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .hangup))
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
    }

    // MARK: Incoming

    func testIncomingReportsReceivedAcceptsAndBecomesActive() async {
        let call = self.incoming()
        XCTAssertEqual(call.peerUserId, Fixtures.peer)
        call.start()
        XCTAssertEqual(call.state, .ringing)
        await waitUntil("received") { self.api.requests.contains(.received(callId: "call1", deviceId: Fixtures.myDevice)) }

        self.api.acceptResult = .success(Fixtures.join(Fixtures.call(state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted])))
        call.accept()
        XCTAssertEqual(call.state, .connecting)
        await waitUntil("media connected") { self.engine.microphone == true }
        XCTAssertTrue(self.api.requests.contains(.accept(callId: "call1", deviceId: Fixtures.myDevice)))
        XCTAssertEqual(call.state, .connecting)
        self.engine.addRemote(self.peerDevice)
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
        // Our own accept echoed back changes nothing.
        call.handle(.callState(call: Fixtures.call(state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted]), userId: Fixtures.me, deviceId: Fixtures.myDevice, action: .accepted))
        XCTAssertEqual(call.state, .active(since: self.scheduler.current))
    }

    func testIncomingDecline() async {
        let call = self.incoming()
        call.start()
        call.decline()
        XCTAssertEqual(call.state, .terminated(.declinedLocally, duration: nil))
        await waitUntil("decline sent") { self.api.requests.contains(.decline(callId: "call1", deviceId: Fixtures.myDevice, reason: .declined)) }
        XCTAssertNil(self.engine.connectedWith)
    }

    func testIncomingHangupWhileRingingDeclines() async {
        let call = self.incoming()
        call.start()
        call.hangup()
        XCTAssertEqual(call.state, .terminated(.declinedLocally, duration: nil))
        await waitUntil("decline sent") { self.api.requests.contains(.decline(callId: "call1", deviceId: Fixtures.myDevice, reason: .declined)) }
    }

    func testIncomingDeclineAsBusy() async {
        let call = self.incoming()
        call.start()
        call.decline(reason: .busy)
        XCTAssertEqual(call.state, .terminated(.busy, duration: nil))
        await waitUntil("decline sent") { self.api.requests.contains(.decline(callId: "call1", deviceId: Fixtures.myDevice, reason: .busy)) }
    }

    func testBusyDeclineWithoutAController() async {
        await RelayDirectCall.declineBusy(api: self.api, callId: "call9", deviceId: Fixtures.myDevice)
        XCTAssertEqual(self.api.requests, [.decline(callId: "call9", deviceId: Fixtures.myDevice, reason: .busy)])
    }

    func testIncomingAnsweredOnAnotherDevice() async {
        let call = self.incoming()
        call.start()
        call.handle(.callState(call: Fixtures.call(state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted]), userId: Fixtures.me, deviceId: Fixtures.myOtherDevice, action: .accepted))
        XCTAssertEqual(call.state, .terminated(.answeredElsewhere, duration: nil))
        await settle()
        XCTAssertFalse(self.api.requests.contains(where: { if case .decline = $0 { return true }; return false }))
    }

    func testIncomingAnsweredElsewhereSeenInACallUpdate() async {
        let call = self.incoming()
        call.start()
        call.handle(.callUpdated(Fixtures.call(state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted])))
        XCTAssertEqual(call.state, .terminated(.answeredElsewhere, duration: nil))
    }

    func testIncomingDeclinedOnAnotherDevice() async {
        let call = self.incoming()
        call.start()
        call.handle(.callState(call: Fixtures.call(startedBy: Fixtures.peer, invitees: [Fixtures.me: .declined]), userId: Fixtures.me, deviceId: Fixtures.myOtherDevice, action: .declined))
        XCTAssertEqual(call.state, .terminated(.declinedElsewhere, duration: nil))
    }

    func testIncomingCancelledByTheCaller() async {
        let call = self.incoming()
        call.start()
        call.handle(.callEnded(Fixtures.call(state: .ended, startedBy: Fixtures.peer, invitees: [Fixtures.me: .ringing], endReason: .cancelled)))
        XCTAssertEqual(call.state, .terminated(.cancelled, duration: nil))
    }

    func testIncomingCancelledFromCallState() async {
        let call = self.incoming()
        call.start()
        call.handle(.callState(call: Fixtures.call(startedBy: Fixtures.peer, invitees: [Fixtures.me: .ringing]), userId: Fixtures.peer, deviceId: Fixtures.peerDevice, action: .cancelled))
        XCTAssertEqual(call.state, .terminated(.cancelled, duration: nil))
    }

    func testIncomingRingExpiresLocally() async {
        let call = self.incoming()
        call.start()
        await waitUntil("received") { !self.api.requests.isEmpty }
        self.scheduler.advance(by: 44)
        XCTAssertEqual(call.state, .ringing)
        self.scheduler.advance(by: 1)
        XCTAssertEqual(call.state, .terminated(.missed, duration: nil))
        await settle()
        XCTAssertEqual(self.api.requests, [.received(callId: "call1", deviceId: Fixtures.myDevice)])
    }

    func testIncomingFromPushStillRingingReportsReceived() async {
        self.api.callResult = .success(self.incomingCall)
        let push = RelayCallPush(callId: "call1", channelId: Fixtures.channel, callerId: Fixtures.peer, callerName: "Peer", video: true, ringExpiresAt: 1_000_045_000, serverURL: "https://chat.example.com", recipientId: Fixtures.me)
        let call = RelayDirectCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, push: push, scheduler: self.scheduler)
        XCTAssertTrue(call.isVideo)
        call.start()
        await waitUntil("received") { self.api.requests.contains(.received(callId: "call1", deviceId: Fixtures.myDevice)) }
        XCTAssertEqual(self.api.requests.first, .call(id: "call1"))
        XCTAssertEqual(call.state, .ringing)
    }

    func testIncomingFromPushAlreadyAnsweredElsewhere() async {
        self.api.callResult = .success(Fixtures.call(state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted]))
        let push = RelayCallPush(callId: "call1", channelId: Fixtures.channel, callerId: Fixtures.peer, callerName: "Peer", video: false, ringExpiresAt: 1_000_045_000, serverURL: "https://chat.example.com", recipientId: Fixtures.me)
        let call = RelayDirectCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, push: push, scheduler: self.scheduler)
        call.start()
        await waitUntil("terminated") { call.state.isTerminated }
        XCTAssertEqual(call.state, .terminated(.answeredElsewhere, duration: nil))
        await settle()
        XCTAssertEqual(self.api.requests, [.call(id: "call1")])
    }

    func testIncomingFromPushOfAForgottenCall() async {
        self.api.callResult = .success(nil)
        let push = RelayCallPush(callId: "call1", channelId: Fixtures.channel, callerId: Fixtures.peer, callerName: "Peer", video: false, ringExpiresAt: nil, serverURL: "https://chat.example.com", recipientId: Fixtures.me)
        let call = RelayDirectCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, push: push, scheduler: self.scheduler)
        call.start()
        await waitUntil("terminated") { call.state.isTerminated }
        XCTAssertEqual(call.state, .terminated(.ended, duration: nil))
    }

    func testIncomingFromPushOfACancelledCall() async {
        self.api.callResult = .success(Fixtures.call(state: .ended, startedBy: Fixtures.peer, invitees: [Fixtures.me: .ringing], endReason: .cancelled))
        let push = RelayCallPush(callId: "call1", channelId: Fixtures.channel, callerId: Fixtures.peer, callerName: "Peer", video: false, ringExpiresAt: nil, serverURL: "https://chat.example.com", recipientId: Fixtures.me)
        let call = RelayDirectCall.incoming(api: self.api, engine: self.engine, ownUserId: Fixtures.me, deviceId: Fixtures.myDevice, push: push, scheduler: self.scheduler)
        call.start()
        await waitUntil("terminated") { call.state.isTerminated }
        XCTAssertEqual(call.state, .terminated(.cancelled, duration: nil))
    }

    func testAcceptConflictMeansAnsweredElsewhere() async {
        let call = self.incoming()
        call.start()
        self.api.acceptResult = .failure(RelayCallsError.server(409, "This call no longer rings for you."))
        self.api.callResult = .success(Fixtures.call(state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted]))
        call.accept()
        await waitUntil("terminated") { call.state.isTerminated }
        XCTAssertEqual(call.state, .terminated(.answeredElsewhere, duration: nil))
        XCTAssertNil(self.engine.connectedWith)
    }

    func testIncomingRemoteHangupAfterAnswer() async {
        let call = self.incoming()
        call.start()
        self.api.acceptResult = .success(Fixtures.join(Fixtures.call(state: .active, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted])))
        call.accept()
        await waitUntil("media connected") { self.engine.microphone != nil }
        self.engine.addRemote(self.peerDevice)
        self.scheduler.advance(by: 7)
        call.handle(.callEnded(Fixtures.call(state: .ended, startedBy: Fixtures.peer, invitees: [Fixtures.me: .accepted], endReason: .hangup)))
        XCTAssertEqual(call.state, .terminated(.remoteHangup, duration: 7))
    }

    func testTerminatedCallIgnoresLaterEvents() async {
        let call = self.incoming()
        call.start()
        call.decline()
        call.handle(.callEnded(Fixtures.call(state: .ended, startedBy: Fixtures.peer, endReason: .missed)))
        XCTAssertEqual(call.state, .terminated(.declinedLocally, duration: nil))
    }
}
