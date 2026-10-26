import XCTest
@testable import MattermostKit

/// Phase 3C endpoints: channel search, saved posts, pin/unpin, team file search, post search results.
final class FindingTests: StubbedClientTestCase {
    func testSearchChannels() async throws {
        StubURLProtocol.respond(with: .json(#"[{"id":"c1","team_id":"t1","type":"O","name":"releases","display_name":"Releases","delete_at":0},{"id":"c2","team_id":"t1","type":"O","name":"old","display_name":"Old","delete_at":5}]"#))
        let channels = try await makeClient().searchChannels(teamId: "t1", term: "re")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/teams/t1/channels/search")
        XCTAssertEqual(request.jsonBody, ["term": "re"])
        XCTAssertEqual(channels.map(\.id), ["c1", "c2"])
        XCTAssertEqual(channels[1].deleteAt, 5)
    }

    func testFlaggedPosts() async throws {
        StubURLProtocol.respond(with: .json(#"{"order":["p2","p1"],"posts":{"p1":{"id":"p1","channel_id":"c1","create_at":1},"p2":{"id":"p2","channel_id":"c2","create_at":2}},"next_post_id":"","prev_post_id":""}"#))
        let list = try await makeClient().flaggedPosts(page: 1, perPage: 60)
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v4/users/me/posts/flagged")
        XCTAssertEqual(request.query, ["page": "1", "per_page": "60"])
        XCTAssertEqual(list.orderedPosts.map(\.id), ["p2", "p1"])

        StubURLProtocol.respond(with: .json(#"{"order":[],"posts":{}}"#))
        let empty = try await makeClient().flaggedPosts(userId: "u1", teamId: "t1", channelId: "c1")
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.path, "/api/v4/users/u1/posts/flagged")
        XCTAssertEqual(request.query, ["team_id": "t1", "channel_id": "c1"])
        XCTAssertTrue(empty.orderedPosts.isEmpty)
    }

    func testPinAndUnpin() async throws {
        StubURLProtocol.respond(with: .json(#"{"status":"OK"}"#))
        try await makeClient().pinPost(id: "p1")
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/posts/p1/pin")
        try await makeClient().unpinPost(id: "p1")
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/posts/p1/unpin")
    }

    func testPinOfAnotherUsersPostIsRefused() async throws {
        StubURLProtocol.respond(with: .json(#"{"id":"api.context.permissions.app_error","message":"You do not have the appropriate permissions.","status_code":403}"#, status: 403))
        let error = await expectMattermostError { try await self.makeClient().pinPost(id: "p1") }
        XCTAssertEqual(error?.statusCode, 403)
    }

    func testSaveAndUnsavePost() async throws {
        StubURLProtocol.respond(with: .json(#"{"status":"OK"}"#))
        try await makeClient().savePost(id: "p1", userId: "u1")
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v4/users/me/preferences")
        XCTAssertEqual(request.jsonBody, [["user_id": "u1", "category": "flagged_post", "name": "p1", "value": "true"]])
        try await makeClient().unsavePost(id: "p1", userId: "u1")
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/users/me/preferences/delete")
        XCTAssertEqual(request.jsonBody, [["user_id": "u1", "category": "flagged_post", "name": "p1", "value": "true"]])
    }

    func testTeamFileSearch() async throws {
        StubURLProtocol.respond(with: .json(#"{"order":["f1"],"file_infos":{"f1":{"id":"f1","post_id":"p1","channel_id":"c1","name":"report.pdf"}}}"#))
        let list = try await makeClient().searchFiles(teamId: "t1", options: FileSearchOptions(terms: "report in:c1", timeZoneOffset: 0))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/teams/t1/files/search")
        XCTAssertEqual(request.jsonBody?["terms"], "report in:c1")
        XCTAssertEqual(list.orderedFiles.map(\.postId), ["p1"])
    }

    /// The 11.7 database search answer (captured): `matches` is empty, `order` newest first.
    func testPostSearchResults() async throws {
        StubURLProtocol.respond(with: .json(#"{"order":["p2","p1"],"posts":{"p1":{"id":"p1","channel_id":"c1","create_at":1,"message":"Deploy"},"p2":{"id":"p2","channel_id":"c2","create_at":2,"message":"deploy again","root_id":"p0"}},"matches":null,"next_post_id":"","prev_post_id":"","first_inaccessible_post_time":0}"#))
        let results = try await makeClient().searchPosts(teamId: "t1", options: PostSearchOptions(terms: "deploy", perPage: PostSearchOptions.maxPerPage))
        XCTAssertEqual(results.orderedPosts.map(\.id), ["p2", "p1"])
        XCTAssertEqual(results.orderedPosts[0].rootId, "p0")
        XCTAssertTrue(results.matches.isEmpty)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.jsonBody?["per_page"], 100)
    }
}
