import Foundation

public struct RelayCall: Codable, Equatable, Sendable {
    public let id: String
    public let channelId: String
    public let room: String
    public let startedBy: String
    public let startedAt: Int64
    public let participants: Int
    public let canEnd: Bool

    enum CodingKeys: String, CodingKey {
        case id, room, participants
        case channelId = "channel_id"
        case startedBy = "started_by"
        case startedAt = "started_at"
        case canEnd = "can_end"
    }
}

public struct RelayCallJoin: Decodable, Sendable {
    public let url: String
    public let token: String
    public let call: RelayCall
}

public struct RelayCallsConfiguration: Decodable, Sendable {
    public let enabled: Bool
    public let version: Int
    public let maxParticipants: Int
    public let screenSharing: Bool

    enum CodingKeys: String, CodingKey {
        case enabled, version
        case maxParticipants = "max_participants"
        case screenSharing = "screen_sharing"
    }
}

public enum RelayCallsError: LocalizedError, Equatable {
    case invalidChannel
    case invalidServer
    case invalidResponse
    case server(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidChannel: return "This conversation is not ready for calls."
        case .invalidServer: return "The server returned an invalid calling address."
        case .invalidResponse: return "The calling service returned an invalid response."
        case let .server(_, message): return message
        }
    }
}

public final class RelayCallsClient: @unchecked Sendable {
    private struct Failure: Decodable { let message: String }
    public let serverURL: URL
    private let token: String
    private let session: URLSession

    public init(serverURL: URL, token: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.token = token
        self.session = session
    }

    public func configuration() async throws -> RelayCallsConfiguration {
        try await request("config")
    }

    public func call(channelId: String) async throws -> RelayCall? {
        try validate(channelId)
        struct Response: Decodable { let call: RelayCall? }
        let response: Response = try await request("channels/" + channelId)
        return response.call
    }

    public func join(channelId: String, callId: String? = nil) async throws -> RelayCallJoin {
        try validate(channelId)
        let result: RelayCallJoin = try await request("channels/" + channelId + "/join", body: ["call_id": callId ?? ""])
        guard let url = URLComponents(string: result.url), ["https", "wss"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.fragment == nil,
              !result.token.isEmpty, result.call.channelId == channelId else {
            throw RelayCallsError.invalidServer
        }
        return result
    }

    public func end(channelId: String, callId: String) async throws {
        try validate(channelId)
        struct Response: Decodable { let ok: Bool }
        let response: Response = try await request("channels/" + channelId + "/end", body: ["call_id": callId])
        guard response.ok else { throw RelayCallsError.invalidResponse }
    }

    private func validate(_ id: String) throws {
        guard id.count == 26, id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            throw RelayCallsError.invalidChannel
        }
    }

    private func request<T: Decodable>(_ path: String, body: [String: String]? = nil) async throws -> T {
        guard ["https", "http"].contains(serverURL.scheme?.lowercased() ?? ""), serverURL.host != nil,
              serverURL.user == nil, serverURL.password == nil else { throw RelayCallsError.invalidServer }
        let url = serverURL.appendingPathComponent("plugins/org.relaychat.calls/" + path)
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RelayCallsError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            let fallback = response.statusCode == 404 ? "Calling is not installed on this Mattermost server." : "The calling service is temporarily unavailable."
            throw RelayCallsError.server(response.statusCode, message ?? fallback)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RelayCallsError.invalidResponse }
    }
}
