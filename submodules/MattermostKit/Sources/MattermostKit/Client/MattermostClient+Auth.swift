import Foundation

// MARK: - Server

extension MattermostClient {
    /// `GET /system/ping`. Use on the server-URL screen to check that the URL
    /// points at a Mattermost server. Does not need a token.
    public func ping(getServerStatus: Bool = false) async throws -> PingResponse {
        var query = QueryBuilder()
        query.addFlag("get_server_status", getServerStatus)
        return try await send(APIRequest(.get, "/system/ping", query: query.items, authenticated: false))
    }

    /// `GET /config/client?format=old`. Logged-out callers get a limited subset.
    public func clientConfig() async throws -> ClientConfig {
        try await send(APIRequest(.get, "/config/client", query: [URLQueryItem(name: "format", value: "old")]))
    }

    /// `GET /license/client?format=old`.
    public func clientLicense() async throws -> ClientLicense {
        try await send(APIRequest(.get, "/license/client", query: [URLQueryItem(name: "format", value: "old")]))
    }
}

// MARK: - Auth

extension MattermostClient {
    private struct LoginBody: Encodable {
        var loginId: String
        var password: String
        var token: String?
        var deviceId: String?

        enum CodingKeys: String, CodingKey {
            case loginId = "login_id"
            case password
            case token
            case deviceId = "device_id"
        }
    }

    /// `POST /users/login`. On success the client adopts the session token from
    /// the `Token` response header.
    ///
    /// - Parameters:
    ///   - loginId: Email or username (or LDAP ID when LDAP is enabled).
    ///   - mfaToken: The current MFA code, if the account uses MFA. Check
    ///     `MattermostError.isMFARequired` to learn when one is needed.
    ///   - deviceId: Optionally attach the push device in the same request
    ///     (`"<platform>:<token>"`, see `attachDevice(deviceId:)`).
    @discardableResult
    public func login(loginId: String, password: String, mfaToken: String? = nil, deviceId: String? = nil) async throws -> LoginResult {
        let body = LoginBody(
            loginId: loginId,
            password: password,
            token: mfaToken.flatMap { $0.isEmpty ? nil : $0 },
            deviceId: deviceId
        )
        let request = try APIRequest.json(.post, "/users/login", body: body, authenticated: false)
        let (data, response) = try await perform(request)
        guard let token = response.value(forHTTPHeaderField: "Token"), !token.isEmpty else {
            throw MattermostError.decoding("Login response has no Token header")
        }
        let user = try decode(User.self, from: data)
        setToken(token)
        return LoginResult(user: user, token: token, csrfToken: Self.cookie(named: "MMCSRF", in: response))
    }

    /// A cookie the response sets (the client never stores cookies; the token goes in a header).
    static func cookie(named name: String, in response: HTTPURLResponse) -> String? {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                fields[key] = value
            }
        }
        guard let url = response.url else {
            return nil
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first(where: { $0.name == name })?.value
    }

    /// `POST /users/logout`. Ends the session server-side (which also removes
    /// the attached push device) and clears the token locally, even if the
    /// request fails.
    public func logout() async throws {
        defer { setToken(nil) }
        try await sendIgnoringResponse(APIRequest(.post, "/users/logout"))
    }

    /// `PUT /users/sessions/device`. Attaches a push device to the session.
    ///
    /// - Parameter deviceId: `"<platform>:<apns token>"`. The platform prefix
    ///   must match an entry in the push proxy configuration (needs
    ///   verification against our deployed proxy, see docs/plan/04).
    public func attachDevice(deviceId: String) async throws {
        try await sendIgnoringResponse(APIRequest.json(.put, "/users/sessions/device", body: ["device_id": deviceId]))
    }
}

// MARK: - Session check and WebSocket

extension MattermostClient {
    /// False only when the server definitely rejects the current token
    /// (`GET /users/me` answers 401). Network errors and other failures count
    /// as "not rejected".
    public func isTokenAccepted() async -> Bool {
        do {
            _ = try await me()
            return true
        } catch MattermostError.unauthorized {
            return false
        } catch {
            return true
        }
    }

    /// A WebSocket for this server with the client's current token and user
    /// agent, using `isTokenAccepted()` to recognise a rejected token.
    public func makeWebSocket(
        configuration: MattermostWebSocket.Configuration = MattermostWebSocket.Configuration(),
        transport: any WebSocketTransport = URLSessionWebSocketTransport()
    ) -> MattermostWebSocket {
        var configuration = configuration
        if configuration.userAgent == nil {
            configuration.userAgent = self.configuration.userAgent
        }
        return MattermostWebSocket(
            serverURL: serverURL,
            token: token,
            configuration: configuration,
            transport: transport,
            tokenVerifier: { [weak self] in
                await self?.isTokenAccepted() ?? true
            }
        )
    }
}
