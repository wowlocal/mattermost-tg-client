import XCTest
@testable import MattermostKit

final class UploadTimeoutTests: StubbedClientTestCase {
    func testStalledUploadCancelsTheRequest() async throws {
        var response = StubResponse.json("{}")
        response.delay = 10
        StubURLProtocol.respond(with: response)
        var configuration = MattermostClient.Configuration(serverURL: URL(string: "http://localhost")!)
        configuration.uploadInactivityTimeout = 0.05
        let client = MattermostClient(configuration: configuration, session: StubURLProtocol.makeSession())
        let started = Date()
        do {
            _ = try await client.uploadFiles([FileUpload(fileName: "stalled.txt", content: .data(Data([1])))], channelId: "channel")
            XCTFail("Expected timeout")
        } catch MattermostError.transport(let error) {
            XCTAssertEqual((error as NSError).code, URLError.timedOut.rawValue)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testActivityRequestCannotBeSatisfiedFromTheCache() async throws {
        StubURLProtocol.respond(with: .json("{}"))
        try await makeClient().recordUserActivity()
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.path, "/api/v4/users/me")
        XCTAssertEqual(request.request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.header("If-None-Match"))
    }

    func testActivityReportsARejectedSession() async throws {
        StubURLProtocol.respond(with: .json(#"{"id":"api.context.session_expired.app_error","message":"Session expired","status_code":401}"#, status: 401))
        let rejected = Locked(false)
        let configuration = MattermostClient.Configuration(serverURL: serverURL, onUnauthorized: { rejected.set(true) })
        let client = MattermostClient(configuration: configuration, token: "test-token", session: StubURLProtocol.makeSession())
        let error = await expectMattermostError { try await client.recordUserActivity() }
        XCTAssertTrue(error?.isSessionExpired == true)
        XCTAssertTrue(rejected.current)
    }
}
