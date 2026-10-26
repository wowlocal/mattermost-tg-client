import XCTest
@testable import MattermostKit

final class ErrorMappingTests: StubbedClientTestCase {
    private func error(for response: StubResponse) async -> MattermostError? {
        StubURLProtocol.respond(with: response)
        return await expectMattermostError { try await self.makeClient().teams() }
    }

    func testUnauthorizedCarriesAppError() async {
        let result = await error(for: .json(Fixtures.appError, status: 401))
        guard case .unauthorized(let appError)? = result else {
            return XCTFail("Expected .unauthorized, got \(String(describing: result))")
        }
        XCTAssertEqual(appError?.id, "api.user.login.invalid_credentials_email_username")
        XCTAssertEqual(result?.statusCode, 401)
        XCTAssertTrue(result?.isSessionExpired == true)
        XCTAssertFalse(result?.isTransient == true)
        XCTAssertEqual(result?.errorDescription, "Enter a valid email or username and/or password.")
    }

    func testForbiddenAndNotFound() async {
        let forbidden = await error(for: .json(#"{"id":"api.context.permissions.app_error","message":"You do not have the appropriate permissions.","status_code":403}"#, status: 403))
        XCTAssertEqual(forbidden, .forbidden(AppError(id: "api.context.permissions.app_error", message: "You do not have the appropriate permissions.", statusCode: 403)))

        let notFound = await error(for: StubResponse(statusCode: 404, headers: [:], body: Data()))
        XCTAssertEqual(notFound, .notFound(nil))
    }

    func testRateLimitedWithRetryAfterSeconds() async {
        let result = await error(for: .json(#"{"message":"rate limited"}"#, status: 429, headers: ["Retry-After": "7"]))
        XCTAssertEqual(result, .rateLimited(retryAfter: 7))
        XCTAssertTrue(result?.isTransient == true)
    }

    func testRateLimitedWithHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let response = HTTPURLResponse(
            url: serverURL,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "Tue, 14 Nov 2023 22:13:50 GMT"]
        )!
        XCTAssertEqual(MattermostError.from(response: response, body: Data(), now: now), .rateLimited(retryAfter: 30))
    }

    func testRateLimitedFallsBackToRateLimitReset() async {
        let result = await error(for: StubResponse(statusCode: 429, headers: ["X-RateLimit-Reset": "3"], body: Data()))
        XCTAssertEqual(result, .rateLimited(retryAfter: 3))
        let unknown = await error(for: StubResponse(statusCode: 429, headers: [:], body: Data()))
        XCTAssertEqual(unknown, .rateLimited(retryAfter: nil))
    }

    func testServerErrorWithAppError() async {
        let result = await error(for: .json(#"{"id":"app.post.save.app_error","message":"Unable to save the post.","request_id":"r1"}"#, status: 500))
        guard case .server(let appError)? = result else {
            return XCTFail("Expected .server, got \(String(describing: result))")
        }
        XCTAssertEqual(appError.id, "app.post.save.app_error")
        // The HTTP status fills in a missing status_code.
        XCTAssertEqual(appError.statusCode, 500)
        XCTAssertTrue(result?.isTransient == true)
    }

    func testNonJSONErrorBodyIsSynthesised() async {
        let html = "<html><body>502 Bad Gateway</body></html>"
        let result = await error(for: StubResponse(statusCode: 502, headers: ["Content-Type": "text/html"], body: Data(html.utf8)))
        guard case .server(let appError)? = result else {
            return XCTFail("Expected .server, got \(String(describing: result))")
        }
        XCTAssertEqual(appError.statusCode, 502)
        XCTAssertEqual(appError.id, "")
        XCTAssertEqual(appError.detailedError, html)
        XCTAssertTrue(result?.isTransient == true)
    }

    func testClientErrorIsNotTransient() async {
        let result = await error(for: .json(#"{"id":"api.post.create_post.root_id.app_error","message":"Invalid root","status_code":400}"#, status: 400))
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertFalse(result?.isTransient == true)
    }

    func testTransportError() async {
        let result = await error(for: .failure(.notConnectedToInternet))
        XCTAssertEqual(result, .transport(URLError(.notConnectedToInternet)))
        XCTAssertTrue(result?.isTransient == true)
        XCTAssertNil(result?.statusCode)
    }

    func testDecodingError() async {
        let result = await error(for: .json(#"{"not":"an array"}"#))
        guard case .decoding? = result else {
            return XCTFail("Expected .decoding, got \(String(describing: result))")
        }
    }

    func testMFARequiredDetection() {
        let mfa = MattermostError.unauthorized(AppError(id: "mfa.validate_token.authenticate.app_error", statusCode: 401))
        XCTAssertTrue(mfa.isMFARequired)
        XCTAssertFalse(MattermostError.unauthorized(nil).isMFARequired)
        XCTAssertFalse(MattermostError.unauthorized(AppError(id: "api.user.login.invalid_credentials_email_username")).isMFARequired)
    }

    func testWrapMapsCancellation() {
        XCTAssertEqual(MattermostError.wrap(CancellationError()), .cancelled)
        XCTAssertEqual(MattermostError.wrap(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(MattermostError.wrap(URLError(.timedOut)), .transport(URLError(.timedOut)))
    }
}
