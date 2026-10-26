import Foundation

/// Mattermost REST API v4 client.
///
/// Thread-safe. The session token can be changed at any time (login, logout,
/// SSO); requests read it when they are built.
public final class MattermostClient: Sendable {
    public struct Configuration: Sendable {
        /// The server's site URL, e.g. `https://chat.example.com` or
        /// `https://example.com/mattermost`. `/api/v4` is appended.
        public var serverURL: URL
        public var userAgent: String?
        public var timeoutInterval: TimeInterval
        /// Extra headers sent with every request.
        public var additionalHeaders: [String: String]
        /// Called when the server answers 401 to a request sent with a token, the usual sign of an expired
        /// or revoked session. Requests sent without a token (login) never call it. A few endpoints use 401
        /// for other errors, so confirm with `isTokenAccepted()` before acting.
        public var onUnauthorized: (@Sendable () -> Void)?
        /// Called whenever the server answered a request (any status), e.g. to reconnect a WebSocket that is
        /// waiting out its backoff after the server was unreachable.
        public var onServerReached: (@Sendable () -> Void)?

        public init(serverURL: URL, userAgent: String? = nil, timeoutInterval: TimeInterval = 30, additionalHeaders: [String: String] = [:], onUnauthorized: (@Sendable () -> Void)? = nil) {
            self.serverURL = serverURL
            self.userAgent = userAgent
            self.timeoutInterval = timeoutInterval
            self.additionalHeaders = additionalHeaders
            self.onUnauthorized = onUnauthorized
        }
    }

    public let configuration: Configuration
    private let injectedSession: URLSession?
    private let tokenStorage: Locked<String?>

    /// - Parameters:
    ///   - token: A session token or personal access token.
    ///   - session: Inject a custom session (tests use a `URLProtocol` stub). Without one, every request goes
    ///     through `MattermostURLSession.current`, which applies the certificate pins of `MattermostServerTrust.shared`
    ///     and is renewed when they change (Phase 4G).
    public init(configuration: Configuration, token: String? = nil, session: URLSession? = nil) {
        self.configuration = configuration
        self.injectedSession = session
        self.tokenStorage = Locked(token)
    }

    /// The session requests go through (looked up per request: `MattermostURLSession` renews its session when the
    /// certificate pins change).
    public var session: URLSession {
        return self.injectedSession ?? MattermostURLSession.current
    }

    public convenience init(serverURL: URL, token: String? = nil, userAgent: String? = nil, session: URLSession? = nil) {
        self.init(configuration: Configuration(serverURL: serverURL, userAgent: userAgent), token: token, session: session)
    }

    public var serverURL: URL { configuration.serverURL }

    /// The current session token or personal access token.
    public var token: String? { tokenStorage.current }

    public func setToken(_ token: String?) {
        tokenStorage.set(token)
    }

    /// `<serverURL>/api/v4`.
    public var apiBaseURL: URL {
        serverURL.appendingPathComponent("api").appendingPathComponent("v4")
    }

    // MARK: - Request building

    func urlRequest(for request: APIRequest) throws -> URLRequest {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw MattermostError.transport(URLError(.badURL))
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.percentEncodedPath = basePath + "/api/v4" + request.path
        components.fragment = nil
        components.percentEncodedQuery = request.query.isEmpty ? nil : request.query.map { item in
            percentEncodeQueryComponent(item.name) + "=" + percentEncodeQueryComponent(item.value ?? "")
        }.joined(separator: "&")
        guard let url = components.url else {
            throw MattermostError.transport(URLError(.badURL))
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: configuration.timeoutInterval)
        urlRequest.httpMethod = request.method.rawValue
        // Authenticate with the bearer token only; cookies from the login
        // response would otherwise trigger CSRF checks and outlive logout.
        urlRequest.httpShouldHandleCookies = false
        applyCommonHeaders(to: &urlRequest, authenticated: request.authenticated)
        if request.expectsJSON {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue(request.contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    func applyCommonHeaders(to request: inout URLRequest, authenticated: Bool = true) {
        for (name, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let userAgent = configuration.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if authenticated, let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Sending

    /// Sends a request and returns the body of a 2xx response.
    func perform(_ request: APIRequest) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try urlRequest(for: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw MattermostError.wrap(error, url: urlRequest.url)
        }
        configuration.onServerReached?()
        let http: HTTPURLResponse
        do {
            http = try validate(response: response, body: data)
        } catch MattermostError.unauthorized(let appError) {
            if urlRequest.value(forHTTPHeaderField: "Authorization") != nil {
                configuration.onUnauthorized?()
            }
            throw MattermostError.unauthorized(appError)
        }
        return (data, http)
    }

    func send<T: Decodable>(_ request: APIRequest, as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await perform(request)
        return try decode(T.self, from: data)
    }

    /// Sends a request whose response body (usually `{"status":"OK"}`) is not needed.
    func sendIgnoringResponse(_ request: APIRequest) async throws {
        _ = try await perform(request)
    }

    func validate(response: URLResponse, body: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw MattermostError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MattermostError.from(response: http, body: body)
        }
        return http
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MattermostError.decoding(String(describing: error))
        }
    }
}
