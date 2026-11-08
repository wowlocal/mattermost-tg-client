import Foundation
import XCTest
@testable import RelayCallsCore

final class RelayCallsEventTests: XCTestCase {
    private let call: [String: Any] = [
        "id": "call1", "channel_id": "abcdefghijklmnopqrstuvwxyz", "room": "relay_1", "kind": "direct", "state": "ringing",
        "video": false, "started_by": "caller", "started_at": 1_700_000_000_000, "ring_expires_at": 1_700_000_045_000,
        "participants": 1, "participant_ids": ["caller"], "invitees": ["callee": "ringing"], "post_id": "post1", "can_end": false,
    ]

    private func decode(_ name: String, _ data: [String: Any]) -> RelayCallsEvent? {
        let json = try! JSONSerialization.data(withJSONObject: data)
        return RelayCallsEvent.decode(eventName: "custom_org.relaychat.calls_" + name, data: json)
    }

    func testIncoming() throws {
        let event = decode("incoming", ["call": call, "caller": ["id": "caller", "username": "alex", "display_name": "Alex Rivera"]])
        guard case let .incoming(decoded, caller)? = event else { return XCTFail("\(String(describing: event))") }
        XCTAssertEqual(decoded.id, "call1")
        XCTAssertEqual(decoded.kind, .direct)
        XCTAssertEqual(decoded.invitees, ["callee": .ringing])
        XCTAssertEqual(decoded.startedAt, 1_700_000_000_000)
        XCTAssertEqual(caller, RelayCaller(id: "caller", username: "alex", displayName: "Alex Rivera"))
        XCTAssertEqual(event?.call?.id, "call1")
    }

    func testIncomingWithoutCallerUsesTheStarter() {
        guard case let .incoming(_, caller)? = decode("incoming", ["call": call]) else { return XCTFail() }
        XCTAssertEqual(caller.id, "caller")
    }

    func testCallState() {
        let event = decode("call_state", ["call": call, "user_id": "callee", "device_id": "dev", "action": "received"])
        guard case let .callState(decoded, userId, deviceId, action)? = event else { return XCTFail() }
        XCTAssertEqual(decoded.id, "call1")
        XCTAssertEqual(userId, "callee")
        XCTAssertEqual(deviceId, "dev")
        XCTAssertEqual(action, .received)
        for action in ["received", "accepted", "declined", "busy", "missed", "cancelled", "hangup", "joined", "left"] {
            XCTAssertNotNil(decode("call_state", ["call": call, "user_id": "u", "device_id": "d", "action": action]), action)
        }
        XCTAssertNil(decode("call_state", ["call": call, "user_id": "u", "action": "teleported"]))
    }

    func testCallUpdatedAndEnded() {
        var active = call
        active["state"] = "active"
        active["kind"] = "channel"
        guard case let .callUpdated(updated)? = decode("call_updated", ["call": active]) else { return XCTFail() }
        XCTAssertEqual(updated.state, .active)
        XCTAssertEqual(updated.kind, .channel)

        var ended = call
        ended["state"] = "ended"
        ended["end_reason"] = "declined"
        ended["end_at"] = 1_700_000_010_000
        ended["duration_ms"] = 0
        ended.removeValue(forKey: "ring_expires_at")
        guard case let .callEnded(decoded)? = decode("call_ended", ["call": ended]) else { return XCTFail() }
        XCTAssertEqual(decoded.state, .ended)
        XCTAssertEqual(decoded.endReason, .declined)
        XCTAssertEqual(decoded.endAt, 1_700_000_010_000)
        XCTAssertEqual(decoded.durationMs, 0)
        XCTAssertNil(decoded.ringExpiresAt)
        XCTAssertFalse(decoded.isLive)
    }

    func testVersionOneEvents() {
        // Version 1 sent `call_updated` with a call without kind/state and `call_ended` without the call.
        let old: [String: Any] = ["id": "call1", "channel_id": "abcdefghijklmnopqrstuvwxyz", "room": "relay_1", "started_by": "u", "started_at": 1, "post_id": "", "participants": 2, "can_end": false]
        guard case let .callUpdated(updated)? = decode("call_updated", ["channel_id": "abcdefghijklmnopqrstuvwxyz", "call": old]) else { return XCTFail() }
        XCTAssertEqual(updated.kind, .channel)
        XCTAssertEqual(updated.state, .active)
        XCTAssertNil(updated.postId)
        XCTAssertNil(updated.invitees)
        XCTAssertEqual(updated.participants, 2)
        guard case let .callEnded(ended)? = decode("call_ended", ["channel_id": "abcdefghijklmnopqrstuvwxyz", "call_id": "call1"]) else { return XCTFail() }
        XCTAssertEqual(ended.id, "call1")
        XCTAssertEqual(ended.state, .ended)
        XCTAssertEqual(ended.endReason, .ended)
    }

    func testNestedObjectsMayBeJSONStrings() throws {
        let encoded = String(data: try JSONSerialization.data(withJSONObject: call), encoding: .utf8)!
        guard case let .callUpdated(decoded)? = decode("call_updated", ["call": encoded]) else { return XCTFail() }
        XCTAssertEqual(decoded.id, "call1")
    }

    func testUnknownValuesDecodeLeniently() {
        var future = call
        future["kind"] = "webinar"
        future["state"] = "ended"
        future["end_reason"] = "solar_flare"
        future["invitees"] = ["callee": "teleported"]
        guard case let .callEnded(decoded)? = decode("call_ended", ["call": future]) else { return XCTFail() }
        XCTAssertEqual(decoded.kind, .channel)
        XCTAssertEqual(decoded.endReason, .ended)
        XCTAssertEqual(decoded.invitees, ["callee": .missed])
    }

    func testOtherEventsAndMalformedDataAreIgnored() {
        XCTAssertNil(RelayCallsEvent.decode(eventName: "posted", data: Data("{}".utf8)))
        XCTAssertNil(RelayCallsEvent.decode(eventName: "custom_org.relaychat.calls_recording", data: Data("{}".utf8)))
        XCTAssertNil(RelayCallsEvent.decode(eventName: "custom_org.relaychat.calls_incoming", data: Data("[1]".utf8)))
        XCTAssertNil(RelayCallsEvent.decode(eventName: "custom_org.relaychat.calls_incoming", data: Data("not json".utf8)))
        XCTAssertNil(decode("incoming", ["call": ["id": "missing channel"]]))
        XCTAssertTrue(RelayCallsEvent.isRelayCallsEvent("custom_org.relaychat.calls_call_state"))
        XCTAssertFalse(RelayCallsEvent.isRelayCallsEvent("custom_com.mattermost.calls_call_state"))
    }

    func testCallRoundTripsThroughJSON() throws {
        let original = RelayCall(id: "c", channelId: "abcdefghijklmnopqrstuvwxyz", room: "r", kind: .group, state: .ended, video: true, startedBy: "u", startedAt: 5, endReason: .missed, endAt: 9, durationMs: 0, participants: 0, participantIds: [], invitees: ["v": .missed], postId: "p", canEnd: true)
        let decoded = try JSONDecoder().decode(RelayCall.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testVoIPPushPayload() {
        let payload: [AnyHashable: Any] = ["relay_call": ["v": 2, "call_id": "call1", "channel_id": "abcdefghijklmnopqrstuvwxyz", "caller_id": "caller", "caller_name": "Alex Rivera", "video": true, "ring_expires_at": 1_700_000_045_000, "server_url": "https://chat.example.com", "recipient_id": "callee"], "aps": [:]]
        let push = RelayCallPush(payload: payload)
        XCTAssertEqual(push, RelayCallPush(version: 2, callId: "call1", channelId: "abcdefghijklmnopqrstuvwxyz", callerId: "caller", callerName: "Alex Rivera", video: true, ringExpiresAt: 1_700_000_045_000, serverURL: "https://chat.example.com", recipientId: "callee"))
        XCTAssertEqual(push?.ringExpiryDate, Date(timeIntervalSince1970: 1_700_000_045))
        XCTAssertNil(RelayCallPush(payload: ["aps": ["alert": "hi"]]))
        XCTAssertNil(RelayCallPush(payload: ["relay_call": ["call_id": "", "channel_id": "x"]]))
        XCTAssertNotNil(RelayCallPush(payload: ["relay_call": #"{"call_id":"c","channel_id":"x"}"#]))
    }

    func testParticipantIdentity() {
        let identity = RelayParticipantIdentity("abcdefghijklmnopqrstuvwxyz:3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertEqual(identity?.userId, "abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(identity?.deviceId, "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertEqual(identity?.stringValue, "abcdefghijklmnopqrstuvwxyz:3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertEqual(RelayParticipantIdentity("user:dev:extra")?.deviceId, "dev:extra")
        XCTAssertNil(RelayParticipantIdentity("no-device"))
        XCTAssertNil(RelayParticipantIdentity(":dev"))
        XCTAssertEqual(RelayParticipantIdentity(userId: "u", deviceId: "d").description, "u:d")
        XCTAssertEqual(RelayMediaParticipant(identity: "u:d").userId, "u")
    }
}
