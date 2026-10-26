import XCTest
@testable import MattermostKit

/// Phase 2D endpoints: sessions (Settings → Devices), file search (media tabs), posts by id, and the
/// login's CSRF token.
final class SessionsAndFileSearchTests: StubbedClientTestCase {
    private let sessions = #"""
    [{"id":"s1","token":"","create_at":1793010644702,"expires_at":1795602644700,"last_activity_at":1793011206385,
      "user_id":"u1","device_id":"","roles":"system_user","is_oauth":false,"expired_notify":false,
      "props":{"browser":"Desktop App/0.0","csrf":"c5rf","isMobile":"true","os":"","platform":"Unknown"},
      "team_members":[{"team_id":"t1","user_id":"u1"}]},
     {"id":"s2","create_at":1,"last_activity_at":2,"user_id":"u1","device_id":"apple_rn-v2:abc",
      "props":{"type":"UserAccessToken"}}]
    """#

    func testSessions() async throws {
        StubURLProtocol.respond(with: .json(sessions))
        let result = try await makeClient().sessions()
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v4/users/me/sessions")
        XCTAssertEqual(result.map(\.id), ["s1", "s2"])
        XCTAssertEqual(result[0].lastActivityAt, 1793011206385)
        XCTAssertEqual(result[0].expiresAt, 1795602644700)
        XCTAssertEqual(result[0].csrfToken, "c5rf")
        XCTAssertEqual(result[0].props["browser"], "Desktop App/0.0")
        XCTAssertTrue(result[0].isMobile)
        XCTAssertFalse(result[0].isAccessToken)
        XCTAssertNil(result[1].csrfToken)
        XCTAssertTrue(result[1].isAccessToken)
        XCTAssertEqual(result[1].deviceId, "apple_rn-v2:abc")
    }

    func testRevokeSession() async throws {
        StubURLProtocol.respond(with: .json(#"{"status":"OK"}"#))
        try await makeClient().revokeSession(id: "s2")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/users/me/sessions/revoke")
        XCTAssertEqual(request.jsonBody, ["session_id": "s2"])
    }

    func testFileSearchInChannel() async throws {
        StubURLProtocol.respond(with: .json(#"""
        {"order":["f2","f1"],"file_infos":{
          "f1":{"id":"f1","post_id":"p1","channel_id":"c1","create_at":1,"name":"a.png","mime_type":"image/png"},
          "f2":{"id":"f2","post_id":"p2","channel_id":"c1","create_at":2,"name":"b.pdf","mime_type":"application/pdf"}},
         "next_file_info_id":"","prev_file_info_id":"","first_inaccessible_file_time":0}
        """#))
        let result = try await makeClient().searchFiles(FileSearchOptions(terms: "in:c1", timeZoneOffset: 3600, page: 2))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/files/search")
        XCTAssertEqual(request.jsonBody, [
            "terms": "in:c1",
            "is_or_search": false,
            "time_zone_offset": 3600,
            "include_deleted_channels": false,
            "page": 2,
            "per_page": 100
        ])
        XCTAssertEqual(result.orderedFiles.map(\.id), ["f2", "f1"])
        XCTAssertEqual(result.orderedFiles.map(\.postId), ["p2", "p1"])
        XCTAssertEqual(FileSearchOptions.channel("c9", page: 1).terms, "in:c9")
    }

    func testEmptyFileSearch() async throws {
        StubURLProtocol.respond(with: .json(#"{"order":[],"file_infos":{},"next_file_info_id":"","prev_file_info_id":""}"#))
        let empty = try await makeClient().searchFiles(.channel("c1"))
        XCTAssertTrue(empty.orderedFiles.isEmpty)
        StubURLProtocol.respond(with: .json(#"{"order":null,"file_infos":null}"#))
        let null = try await makeClient().searchFiles(.channel("c1"))
        XCTAssertTrue(null.orderedFiles.isEmpty)
    }

    func testPostsByIds() async throws {
        StubURLProtocol.respond(with: .json(#"[{"id":"p2","channel_id":"c1"},{"id":"p1","channel_id":"c1"}]"#))
        let posts = try await makeClient().posts(ids: ["p1", "p2", "missing"])
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/posts/ids")
        XCTAssertEqual(request.jsonBody, ["p1", "p2", "missing"])
        XCTAssertEqual(Set(posts.map(\.id)), ["p1", "p2"])
    }

    func testLoginReadsTheCSRFCookie() async throws {
        StubURLProtocol.respond(with: .json(Fixtures.user, headers: [
            "Token": "s3ss10n",
            "Set-Cookie": "MMAUTHTOKEN=s3ss10n; Path=/; Max-Age=2592000; HttpOnly, MMUSERID=u1; Path=/; Max-Age=2592000, MMCSRF=c5rf; Path=/; Max-Age=2592000"
        ]))
        let result = try await makeClient(token: nil).login(loginId: "alice", password: "pw")
        XCTAssertEqual(result.csrfToken, "c5rf")

        StubURLProtocol.respond(with: .json(Fixtures.user, headers: ["Token": "t"]))
        let withoutCookie = try await makeClient(token: nil).login(loginId: "alice", password: "pw")
        XCTAssertNil(withoutCookie.csrfToken)
    }
}
