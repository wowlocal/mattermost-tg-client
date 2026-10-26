import XCTest
@testable import MattermostKit

/// Phase 3F endpoints: own status, custom status, profile patch, profile picture.
final class ProfileTests: StubbedClientTestCase {
    func testUserStatus() async throws {
        StubURLProtocol.respond(with: .json(#"{"user_id":"u1","status":"dnd","manual":true,"last_activity_at":5,"dnd_end_time":1793030400,"prev_status":"online"}"#))
        let status = try await makeClient().userStatus()
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v4/users/me/status")
        XCTAssertEqual(status.status, .dnd)
        XCTAssertTrue(status.manual)
        XCTAssertEqual(status.dndEndTime, 1793030400)
        XCTAssertEqual(status.prevStatus, "online")
    }

    func testUpdateStatusSendsTheRealUserIdAndDndEnd() async throws {
        StubURLProtocol.respond(with: .json(#"{"user_id":"u1","status":"dnd","manual":true,"dnd_end_time":1793030400}"#))
        let status = try await makeClient().updateStatus(.dnd, userId: "u1", dndEndTime: 1793030400)
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v4/users/u1/status")
        XCTAssertEqual(request.jsonBody, ["user_id": "u1", "status": "dnd", "dnd_end_time": 1793030400])
        XCTAssertEqual(status.dndEndTime, 1793030400)

        // No end for other statuses, and none for "don't clear".
        StubURLProtocol.respond(with: .json(#"{"user_id":"u1","status":"away"}"#))
        try await makeClient().updateStatus(.away, userId: "u1", dndEndTime: 1793030400)
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.jsonBody, ["user_id": "u1", "status": "away"])
        StubURLProtocol.respond(with: .json(#"{"user_id":"u1","status":"dnd"}"#))
        try await makeClient().updateStatus(.dnd, userId: "u1", dndEndTime: 0)
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.jsonBody, ["user_id": "u1", "status": "dnd"])
    }

    func testCustomStatus() async throws {
        StubURLProtocol.respond(with: .json(#"{"status":"OK"}"#))
        try await makeClient().updateCustomStatus(UserCustomStatus(emoji: "palm_tree", text: "On vacation", duration: "thirty_minutes", expiresAt: "2026-10-27T10:00:00Z"))
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v4/users/me/status/custom")
        XCTAssertEqual(request.jsonBody, ["emoji": "palm_tree", "text": "On vacation", "duration": "thirty_minutes", "expires_at": "2026-10-27T10:00:00Z"])

        // "Don't clear": no expires_at (the server can't parse an empty time).
        try await makeClient().updateCustomStatus(UserCustomStatus(emoji: "calendar", text: "In a meeting"))
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.jsonBody, ["emoji": "calendar", "text": "In a meeting", "duration": ""])

        try await makeClient().removeCustomStatus()
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/api/v4/users/me/status/custom")

        try await makeClient().removeRecentCustomStatus(UserCustomStatus(emoji: "calendar", text: "In a meeting"))
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/users/me/status/custom/recent/delete")
    }

    /// The preference value as the 11.7 server stores it (captured).
    func testRecentCustomStatuses() async throws {
        StubURLProtocol.respond(with: .json(#"[{"category":"custom_status","name":"recent_custom_statuses","user_id":"u1","value":"[{\"emoji\":\"palm_tree\",\"text\":\"On vacation\",\"duration\":\"thirty_minutes\",\"expires_at\":\"2026-10-27T10:00:00Z\"},{\"emoji\":\"palm_tree\",\"text\":\"OOO until Monday\",\"duration\":\"\",\"expires_at\":\"0001-01-01T00:00:00Z\"}]"}]"#))
        let recent = try await makeClient().recentCustomStatuses()
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.path, "/api/v4/users/me/preferences/custom_status")
        XCTAssertEqual(recent.map(\.text), ["On vacation", "OOO until Monday"])
        XCTAssertNotNil(recent[0].expiryDate)
        XCTAssertNil(recent[1].expiryDate, "Go's zero time means no expiry")
        XCTAssertFalse(recent[1].isExpired(at: Date()))
        XCTAssertTrue(recent[0].isExpired(at: Date(timeIntervalSince1970: 1_893_456_000)))

        StubURLProtocol.respond(with: .json(#"{"id":"api.preference.preferences_category.get.app_error","message":"Unable to get user preferences.","status_code":404}"#, status: 404))
        let none = try await makeClient().recentCustomStatuses()
        XCTAssertTrue(none.isEmpty)
    }

    func testPatchUserSendsOnlyChangedFields() async throws {
        StubURLProtocol.respond(with: .json(#"{"id":"u1","username":"alice2","nickname":"Al","first_name":"Alice","last_name":"A","position":"Lead","notify_props":{"push":"all"}}"#))
        let user = try await makeClient().patchUser(UserPatch(nickname: "Al", lastName: "A", position: "Lead"))
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v4/users/me/patch")
        XCTAssertEqual(request.jsonBody, ["nickname": "Al", "last_name": "A", "position": "Lead"])
        XCTAssertEqual(user.position, "Lead")

        try await makeClient().patchUser(UserPatch(notifyProps: ["push": "all", "mention_keys": "deploy,release"]))
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.jsonBody, ["notify_props": ["push": "all", "mention_keys": "deploy,release"]])
        XCTAssertTrue(UserPatch().isEmpty)
    }

    func testUsernameTakenError() async throws {
        StubURLProtocol.respond(with: .json(#"{"id":"app.user.save.username_exists.app_error","message":"An account with that username already exists.","status_code":400}"#, status: 400))
        let error = await expectMattermostError { try await self.makeClient().patchUser(UserPatch(username: "bob")) }
        XCTAssertEqual(error?.statusCode, 400)
        XCTAssertEqual(error?.appError?.id, "app.user.save.username_exists.app_error")
    }

    func testProfileImageUploadAndDelete() async throws {
        StubURLProtocol.respond(with: .json(#"{"status":"OK"}"#))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        try await makeClient().uploadProfileImage(jpeg)
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/users/me/image")
        let contentType = try XCTUnwrap(request.header("Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try XCTUnwrap(request.body)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#"name="image"; filename="profile.jpg""#))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertNotNil(body.range(of: jpeg))

        try await makeClient().deleteProfileImage()
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/api/v4/users/me/image")
    }

    func testCustomPictureFlag() {
        XCTAssertFalse(User(id: "u", lastPictureUpdate: 0).hasCustomPicture)
        XCTAssertFalse(User(id: "u", lastPictureUpdate: -1793024984585).hasCustomPicture, "11.x after DELETE /users/me/image")
        XCTAssertTrue(User(id: "u", lastPictureUpdate: 1793003343585).hasCustomPicture)
    }
}
