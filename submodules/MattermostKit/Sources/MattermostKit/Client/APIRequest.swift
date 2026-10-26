import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}

/// A request relative to `/api/v4`.
struct APIRequest: Sendable {
    var method: HTTPMethod
    /// Percent-encoded path starting with `/`, relative to `/api/v4`.
    var path: String
    var query: [URLQueryItem]
    var body: Data?
    var contentType: String?
    /// Whether to send the session token.
    var authenticated: Bool
    /// Whether the response is JSON (sets `Accept`).
    var expectsJSON: Bool

    init(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        authenticated: Bool = true,
        expectsJSON: Bool = true
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType
        self.authenticated = authenticated
        self.expectsJSON = expectsJSON
    }

    /// A request with a JSON body.
    static func json<Body: Encodable>(_ method: HTTPMethod, _ path: String, body: Body, query: [URLQueryItem] = [], authenticated: Bool = true) throws -> APIRequest {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw MattermostError.decoding("Could not encode request body: \(error)")
        }
        return APIRequest(method, path, query: query, body: data, contentType: "application/json", authenticated: authenticated)
    }
}

/// Builds `/a/b/c` from raw segments, percent-encoding each one.
func apiPath(_ segments: String...) -> String {
    "/" + segments.map(percentEncodePathSegment).joined(separator: "/")
}

private let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
// RFC 3986 `pchar` minus `/`. `+` stays literal so emoji names like `+1` match
// the server's route patterns.
private let pathSegmentCharacters = unreservedCharacters.union(CharacterSet(charactersIn: "!$&'()*+,;=:@"))

func percentEncodePathSegment(_ segment: String) -> String {
    segment.addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) ?? segment
}

/// Encodes a query component strictly: Go decodes `+` in queries as a space,
/// so everything but unreserved characters is escaped.
func percentEncodeQueryComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
}

/// Collects query items, skipping nil values.
struct QueryBuilder {
    private(set) var items: [URLQueryItem] = []

    mutating func add(_ name: String, _ value: String?) {
        guard let value else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    mutating func add(_ name: String, _ value: Int?) {
        add(name, value.map { String($0) })
    }

    mutating func add(_ name: String, _ value: Int64?) {
        add(name, value.map { String($0) })
    }

    /// Adds `name=true` only when `value` is true.
    mutating func addFlag(_ name: String, _ value: Bool) {
        if value {
            add(name, "true")
        }
    }

    /// Adds `name=true|false` when `value` is non-nil.
    mutating func add(_ name: String, _ value: Bool?) {
        add(name, value.map { $0 ? "true" : "false" })
    }
}
