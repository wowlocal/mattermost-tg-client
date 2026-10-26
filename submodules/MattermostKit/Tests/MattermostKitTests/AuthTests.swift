import XCTest
@testable import MattermostKit

final class AuthTests: StubbedClientTestCase {
    func testLoginExtractsTokenAndUsesItAfterwards() async throws {
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/api/v4/users/login" {
                return .json(Fixtures.user, headers: ["Token": "s3ss10n", "Set-Cookie": "MMAUTHTOKEN=s3ss10n; Path=/; HttpOnly"])
            }
            return .json("[]")
        }
        let client = makeClient(token: "stale")
        let result = try await client.login(loginId: "alice", password: "pa55", mfaToken: "123456")
        XCTAssertEqual(result.token, "s3ss10n")
        XCTAssertEqual(result.user.username, "alice")
        XCTAssertEqual(client.token, "s3ss10n")

        let login = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(login.method, "POST")
        XCTAssertEqual(login.path, "/api/v4/users/login")
        XCTAssertEqual(login.jsonBody, ["login_id": "alice", "password": "pa55", "token": "123456"])
        // A stale token must not be sent with the login request.
        XCTAssertNil(login.header("Authorization"))

        _ = try await client.teams()
        XCTAssertEqual(StubURLProtocol.lastRequest?.header("Authorization"), "Bearer s3ss10n")
        XCTAssertNil(StubURLProtocol.lastRequest?.header("Cookie"))
    }

    func testLoginWithoutMFAOmitsToken() async throws {
        StubURLProtocol.respond(with: .json(Fixtures.user, headers: ["Token": "t"]))
        try await makeClient(token: nil).login(loginId: "alice@example.com", password: "pw", deviceId: "apple:abc")
        XCTAssertEqual(StubURLProtocol.lastRequest?.jsonBody, ["login_id": "alice@example.com", "password": "pw", "device_id": "apple:abc"])
    }

    func testLoginWithoutTokenHeaderFails() async {
        StubURLProtocol.respond(with: .json(Fixtures.user))
        let client = makeClient(token: "previous")
        let error = await expectMattermostError { try await client.login(loginId: "alice", password: "pw") }
        guard case .decoding? = error else {
            return XCTFail("Expected .decoding, got \(String(describing: error))")
        }
        XCTAssertEqual(client.token, "previous")
    }

    func testLoginRejected() async {
        StubURLProtocol.respond(with: .json(Fixtures.appError, status: 401))
        let client = makeClient(token: nil)
        let error = await expectMattermostError { try await client.login(loginId: "alice", password: "wrong") }
        XCTAssertEqual(error?.appError?.id, "api.user.login.invalid_credentials_email_username")
        XCTAssertFalse(error?.isMFARequired == true)
        XCTAssertNil(client.token)
    }

    func testLoginNeedsMFA() async {
        StubURLProtocol.respond(with: .json(#"{"id":"mfa.validate_token.authenticate.app_error","message":"Invalid MFA token.","status_code":401}"#, status: 401))
        let error = await expectMattermostError { try await self.makeClient(token: nil).login(loginId: "alice", password: "pw") }
        XCTAssertTrue(error?.isMFARequired == true)
        XCTAssertFalse(error?.isInvalidMFAToken == true)
    }

    func testLoginWithWrongMFACode() async {
        // As recorded from the 11.7 dev server.
        StubURLProtocol.respond(with: .json(#"{"id":"api.user.check_user_mfa.bad_code.app_error","message":"Invalid MFA token.","detailed_error":"","request_id":"wkcouno6fffx5j744fy7kwkbsw","status_code":401}"#, status: 401))
        let error = await expectMattermostError { try await self.makeClient(token: nil).login(loginId: "carol", password: "pw", mfaToken: "000000") }
        XCTAssertTrue(error?.isInvalidMFAToken == true)
        XCTAssertFalse(error?.isMFARequired == true)
    }

    func testLogoutClearsTokenEvenOnFailure() async {
        StubURLProtocol.respond(with: .json(Fixtures.appError, status: 401))
        let client = makeClient(token: "t")
        _ = await expectMattermostError { try await client.logout() }
        XCTAssertNil(client.token)
    }

    func testPersonalAccessToken() async throws {
        StubURLProtocol.respond(with: .json(Fixtures.user))
        let client = MattermostClient(serverURL: serverURL, token: "pat-123", session: StubURLProtocol.makeSession())
        _ = try await client.me()
        XCTAssertEqual(StubURLProtocol.lastRequest?.header("Authorization"), "Bearer pat-123")
    }

    // MARK: SSO

    func testSSOLoginURLs() {
        let redirect = URL(string: "mmclient://sso/callback")!
        XCTAssertEqual(
            MobileSSO.loginURL(serverURL: URL(string: "https://chat.example.com/")!, provider: .gitlab, redirectURL: redirect)?.absoluteString,
            "https://chat.example.com/oauth/gitlab/mobile_login?redirect_to=mmclient%3A%2F%2Fsso%2Fcallback"
        )
        XCTAssertEqual(
            MobileSSO.loginURL(serverURL: URL(string: "https://example.com/mm")!, provider: .openid, redirectURL: redirect)?.absoluteString,
            "https://example.com/mm/oauth/openid/mobile_login?redirect_to=mmclient%3A%2F%2Fsso%2Fcallback"
        )
        XCTAssertEqual(
            MobileSSO.loginURL(serverURL: URL(string: "https://chat.example.com")!, provider: .saml, redirectURL: redirect)?.absoluteString,
            "https://chat.example.com/login/sso/saml?action=mobile&redirect_to=mmclient%3A%2F%2Fsso%2Fcallback"
        )
    }

    func testSSOCallbackParsing() throws {
        let redirect = URL(string: "mmclient://sso/callback")!
        let credentials = try MobileSSO.credentials(
            fromCallback: URL(string: "mmclient://sso/callback?MMAUTHTOKEN=abc123&MMCSRF=csrf9")!,
            redirectURL: redirect
        )
        XCTAssertEqual(credentials, MobileSSO.Credentials(token: "abc123", csrfToken: "csrf9"))

        XCTAssertThrowsError(try MobileSSO.credentials(fromCallback: URL(string: "mmclient://sso/callback?error=access_denied")!, redirectURL: redirect)) { error in
            XCTAssertEqual(error as? MobileSSO.CallbackError, .missingToken(message: "access_denied"))
        }
        XCTAssertThrowsError(try MobileSSO.credentials(fromCallback: URL(string: "evil://sso/callback?MMAUTHTOKEN=x")!, redirectURL: redirect)) { error in
            XCTAssertEqual(error as? MobileSSO.CallbackError, .unexpectedCallback)
        }
        XCTAssertEqual(try MobileSSO.credentials(fromCallback: URL(string: "x://y?MMAUTHTOKEN=t")!).token, "t")
    }
}
