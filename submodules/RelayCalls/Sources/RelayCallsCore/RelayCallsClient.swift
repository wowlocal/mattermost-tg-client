import Foundation

public enum RelayCallsError: LocalizedError, Equatable {
    case invalidChannel
    case invalidServer
    case invalidResponse
    case server(Int, String)
    /// `ring` found a call already running in the channel (`409` with that call).
    case callInProgress(RelayCall)

    public var errorDescription: String? {
        switch self {
        case .invalidChannel: return "This conversation is not ready for calls."
        case .invalidServer: return "The server returned an invalid calling address."
        case .invalidResponse: return "The calling service returned an invalid response."
        case let .server(_, message): return message
        case .callInProgress: return "A call is already in progress in this conversation."
        }
    }

    /// The HTTP status of a server error.
    public var statusCode: Int? {
        switch self {
        case let .server(status, _): return status
        case .callInProgress: return 409
        default: return nil
        }
    }
}

/// The plugin routes the call controllers use (`RelayDirectCall`, `RelayGroupCall`); `RelayCallsClient` implements
/// them over HTTP, tests with a fake.
public protocol RelayCallsAPI: AnyObject, Sendable {
    func call(id: String) async throws -> RelayCall?
    func join(channelId: String, callId: String?, deviceId: String?) async throws -> RelayCallJoin
    func ring(channelId: String, video: Bool, deviceId: String) async throws -> RelayCallJoin
    func end(channelId: String, callId: String) async throws
    func received(callId: String, deviceId: String) async throws
    func accept(callId: String, deviceId: String) async throws -> RelayCallJoin
    func decline(callId: String, deviceId: String, reason: RelayDeclineReason) async throws
    func hangup(callId: String, deviceId: String) async throws
}

/// The REST client of the Relay calls plugin (`/plugins/org.relaychat.calls`), authenticated with the account's
/// Mattermost session (Bearer token, no cookies) over the account's pinned `URLSession`.
public final class RelayCallsClient: RelayCallsAPI, @unchecked Sendable {
    private struct Failure: Decodable { let message: String }
    public let serverURL: URL
    private let tokenProvider: @Sendable () -> String?
    private let sessionProvider: @Sendable () -> URLSession

    public init(serverURL: URL, token: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.tokenProvider = { token }
        self.sessionProvider = { session }
    }

    /// The token and session are looked up per request: Mattermost renews its pinned session when the certificate pins
    /// change, and a re-login replaces the token.
    public init(serverURL: URL, token: @escaping @Sendable () -> String?, session: @escaping @Sendable () -> URLSession) {
        self.serverURL = serverURL
        self.tokenProvider = token
        self.sessionProvider = session
    }

    // MARK: Routes

    public func configuration() async throws -> RelayCallsConfiguration {
        return try await self.request("config")
    }

    /// The channel's current call, or nil.
    public func call(channelId: String) async throws -> RelayCall? {
        try Self.validate(channelId: channelId)
        struct Response: Decodable { let call: RelayCall? }
        let response: Response = try await self.request("channels/" + channelId)
        return response.call
    }

    /// Joins the channel's active call (any kind) or starts a channel call. `callId` makes the join fail (`409`) when
    /// the channel's call is another one.
    public func join(channelId: String, callId: String? = nil, deviceId: String? = nil) async throws -> RelayCallJoin {
        try Self.validate(channelId: channelId)
        var body: [String: Any] = ["call_id": callId ?? ""]
        if let deviceId {
            body["device_id"] = deviceId
        }
        let result: RelayCallJoin = try await self.request("channels/" + channelId + "/join", body: body)
        try Self.validate(join: result)
        guard result.call.channelId == channelId, callId == nil || callId == "" || result.call.id == callId else {
            throw RelayCallsError.invalidServer
        }
        return result
    }

    /// Rings a DM or group message (`400` for other channels). A call already running there fails with
    /// `RelayCallsError.callInProgress`.
    public func ring(channelId: String, video: Bool, deviceId: String) async throws -> RelayCallJoin {
        try Self.validate(channelId: channelId)
        let result: RelayCallJoin = try await self.request("channels/" + channelId + "/ring", body: ["video": video, "device_id": deviceId], conflictCall: true)
        try Self.validate(join: result)
        guard result.call.channelId == channelId else {
            throw RelayCallsError.invalidServer
        }
        return result
    }

    /// Ends the call for everyone (callers with `can_end`).
    public func end(channelId: String, callId: String) async throws {
        try Self.validate(channelId: channelId)
        struct Response: Decodable { let ok: Bool? }
        let data = try await self.requestData("channels/" + channelId + "/end", body: ["call_id": callId])
        if !data.isEmpty, let response = try? JSONDecoder().decode(Response.self, from: data), response.ok == false {
            throw RelayCallsError.invalidResponse
        }
    }

    /// A call by id; nil once the plugin forgot it (`404`).
    public func call(id: String) async throws -> RelayCall? {
        try Self.validate(callId: id)
        do {
            let data = try await self.requestData("calls/" + id)
            return try Self.decodeCall(data)
        } catch RelayCallsError.server(404, _) {
            return nil
        }
    }

    /// Every ringing or active call in the user's channels. The user's own rings have `invitees[me]` `ringing` or
    /// `received`; the rest feed the join panel.
    public func activeCalls() async throws -> [RelayCall] {
        let data = try await self.requestData("calls/active")
        struct Wrapped: Decodable { let calls: [RelayCall]? }
        if let calls = try? JSONDecoder().decode([RelayCall].self, from: data) {
            return calls
        }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: data) {
            return wrapped.calls ?? []
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), text == "null" || text.isEmpty {
            return []
        }
        throw RelayCallsError.invalidResponse
    }

    /// An invitee device shows the call (the caller sees "Ringing…").
    public func received(callId: String, deviceId: String) async throws {
        try Self.validate(callId: callId)
        _ = try await self.requestData("calls/" + callId + "/received", body: ["device_id": deviceId])
    }

    /// Answers a ring. The first device wins; `409` when the call no longer rings for this user.
    public func accept(callId: String, deviceId: String) async throws -> RelayCallJoin {
        try Self.validate(callId: callId)
        let result: RelayCallJoin = try await self.request("calls/" + callId + "/accept", body: ["device_id": deviceId])
        try Self.validate(join: result)
        guard result.call.id == callId else {
            throw RelayCallsError.invalidServer
        }
        return result
    }

    public func decline(callId: String, deviceId: String, reason: RelayDeclineReason = .declined) async throws {
        try Self.validate(callId: callId)
        _ = try await self.requestData("calls/" + callId + "/decline", body: ["device_id": deviceId, "reason": reason.rawValue])
    }

    /// Leaves or ends the call: the caller of a ringing call cancels it, a `direct` call that was answered ends for
    /// both, a `group` call is left.
    public func hangup(callId: String, deviceId: String) async throws {
        try Self.validate(callId: callId)
        _ = try await self.requestData("calls/" + callId + "/hangup", body: ["device_id": deviceId])
    }

    /// Registers this device's PushKit token (hexadecimal) for rings.
    public func registerVoIPDevice(deviceId: String, token: String, environment: RelayVoIPEnvironment, bundleId: String) async throws {
        try Self.validate(callId: deviceId)
        _ = try await self.requestData("devices/voip", body: ["device_id": deviceId, "token": token, "environment": environment.rawValue, "bundle_id": bundleId])
    }

    public func unregisterVoIPDevice(deviceId: String) async throws {
        try Self.validate(callId: deviceId)
        _ = try await self.requestData("devices/voip/" + deviceId, method: "DELETE")
    }

    // MARK: Validation

    /// Mattermost ids: 26 lowercase letters and digits.
    static func validate(channelId id: String) throws {
        guard id.count == 26, id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            throw RelayCallsError.invalidChannel
        }
    }

    /// Call and device ids become path components: letters, digits, `-` and `_` only.
    static func validate(callId id: String) throws {
        guard (1...64).contains(id.utf8.count), id.utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw RelayCallsError.invalidResponse
        }
    }

    /// A media address the client may connect to: `wss`/`https` anywhere, `ws`/`http` only on this machine (a local
    /// development LiveKit), never with credentials or a fragment; and a room token.
    static func validate(join result: RelayCallJoin) throws {
        guard Self.isAllowedMediaURL(result.url), !result.token.isEmpty, !result.call.id.isEmpty else {
            throw RelayCallsError.invalidServer
        }
    }

    public static func isAllowedMediaURL(_ string: String) -> Bool {
        guard let url = URLComponents(string: string), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            return false
        }
        switch scheme {
        case "https", "wss":
            return true
        case "http", "ws":
            return Self.isLoopbackHost(host)
        default:
            return false
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "127", parts.allSatisfy({ part in UInt8(part) != nil }) {
            return true
        }
        return false
    }

    static func decodeCall(_ data: Data) throws -> RelayCall? {
        struct Wrapped: Decodable { let call: RelayCall? }
        if let call = try? JSONDecoder().decode(RelayCall.self, from: data) {
            return call
        }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: data) {
            return wrapped.call
        }
        throw RelayCallsError.invalidResponse
    }

    // MARK: Requests

    private func request<T: Decodable>(_ path: String, body: [String: Any]? = nil, conflictCall: Bool = false) async throws -> T {
        let data = try await self.requestData(path, body: body, conflictCall: conflictCall)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RelayCallsError.invalidResponse
        }
    }

    private func requestData(_ path: String, body: [String: Any]? = nil, method: String? = nil, conflictCall: Bool = false) async throws -> Data {
        guard ["https", "http"].contains(self.serverURL.scheme?.lowercased() ?? ""), self.serverURL.host != nil,
              self.serverURL.user == nil, self.serverURL.password == nil else {
            throw RelayCallsError.invalidServer
        }
        guard let token = self.tokenProvider(), !token.isEmpty else {
            throw RelayCallsError.server(401, "Sign in again to make calls.")
        }
        let url = self.serverURL.appendingPathComponent("plugins/org.relaychat.calls/" + path)
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let body {
            request.httpMethod = method ?? "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let method {
            request.httpMethod = method
        }
        let (data, response) = try await self.sessionProvider().data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RelayCallsError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if conflictCall, response.statusCode == 409, let call = try? Self.decodeCall(data) {
                throw RelayCallsError.callInProgress(call)
            }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            let fallback = response.statusCode == 404 ? "Calling is not installed on this Mattermost server." : "The calling service is temporarily unavailable."
            throw RelayCallsError.server(response.statusCode, message ?? fallback)
        }
        return data
    }
}
