import XCTest
@testable import MattermostSyncCore

final class RelayCallRecordTests: XCTestCase {
    private func record(_ props: [String: Any], type: String = RelayCallRecord.postType) -> RelayCallRecord? {
        return RelayCallRecord(postType: type, propsValue: props)
    }

    func testEndedDirectCall() {
        let record = self.record(["v": 2, "call_id": "call1", "kind": "direct", "video": true, "state": "ended", "started_by": "u1", "end_reason": "hangup", "duration_ms": 83_400, "started_at": 1_000, "end_at": 90_000])
        XCTAssertEqual(record, RelayCallRecord(version: 2, callId: "call1", kind: .direct, video: true, state: .ended, startedBy: "u1", endReason: "hangup", durationMs: 83_400, startedAt: 1_000, endAt: 90_000))
        XCTAssertEqual(record?.discardReason, .hangup)
        XCTAssertEqual(record?.durationSeconds, 83)
        XCTAssertTrue(record?.isDirect == true)
        XCTAssertEqual(record?.fallbackText(isOutgoing: true), "Outgoing video call (1:23)")
    }

    func testEndReasonsMapOntoTelegramDiscardReasons() {
        let expected: [String: RelayCallRecord.DiscardReason] = ["missed": .missed, "cancelled": .missed, "declined": .busy, "busy": .busy, "hangup": .hangup, "ended": .hangup, "failed": .disconnect, "future": .hangup]
        for (reason, discard) in expected {
            let record = self.record(["call_id": "c", "kind": "direct", "state": "ended", "end_reason": reason, "duration_ms": 0])
            XCTAssertEqual(record?.discardReason, discard, reason)
            XCTAssertNil(record?.durationSeconds, reason)
        }
        XCTAssertEqual(self.record(["call_id": "c", "kind": "direct", "state": "ended", "end_reason": "missed"])?.fallbackText(isOutgoing: false), "Missed call")
        XCTAssertEqual(self.record(["call_id": "c", "kind": "direct", "state": "ended", "end_reason": "declined"])?.fallbackText(isOutgoing: true), "Cancelled call")
    }

    func testRunningCallsHaveNoOutcome() {
        let record = self.record(["call_id": "c", "kind": "group", "state": "active", "duration_ms": 5_000])
        XCTAssertNil(record?.discardReason)
        XCTAssertNil(record?.durationSeconds)
        XCTAssertFalse(record?.isDirect == true)
        XCTAssertEqual(record?.fallbackText(isOutgoing: false), "Call started")
        let ended = self.record(["call_id": "c", "kind": "channel", "state": "ended", "end_reason": "ended", "duration_ms": 3_725_000, "video": true])
        XCTAssertEqual(ended?.fallbackText(isOutgoing: false), "Video call ended (1:02:05)")
    }

    func testLenientDecoding() {
        // A JSON string, numeric strings, a missing state with an end reason, an unknown kind.
        let string = #"{"call_id":"c","kind":"webinar","end_reason":"missed","duration_ms":"0","started_at":"7"}"#
        let record = RelayCallRecord(postType: RelayCallRecord.postType, propsValue: string)
        XCTAssertEqual(record?.kind, .channel)
        XCTAssertEqual(record?.state, .ended)
        XCTAssertEqual(record?.startedAt, 7)
        XCTAssertEqual(record?.version, 2)
        XCTAssertNil(self.record(["kind": "direct"]))
        XCTAssertNil(self.record(["call_id": ""]))
        XCTAssertNil(self.record(["call_id": "c"], type: "custom_poll"))
        XCTAssertNil(RelayCallRecord(postType: RelayCallRecord.postType, propsValue: 5))
    }

    func testTelegramCallIdIsStablePositiveAndDistinct() {
        let a = RelayCallRecord.telegramCallId("4xz9q1call0000000000000000")
        XCTAssertEqual(a, RelayCallRecord.telegramCallId("4xz9q1call0000000000000000"))
        XCTAssertGreaterThan(a, 0)
        XCTAssertNotEqual(a, RelayCallRecord.telegramCallId("4xz9q1call0000000000000001"))
        XCTAssertGreaterThan(RelayCallRecord.telegramCallId(""), 0)
        // Pinned: the value is persisted in Postbox (call messages, active calls).
        XCTAssertEqual(RelayCallRecord.telegramCallId("call1"), 8_130_928_321_570_057_800)
    }

    func testRecordsWithoutPropsShowThePluginText() {
        XCTAssertEqual(ServiceAction.from(type: RelayCallRecord.postType, userId: "u", message: "Call ended", props: [:]), .generic(text: "Call ended"))
    }
}
