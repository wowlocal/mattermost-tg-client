import Foundation
import XCTest
@testable import MattermostKit

/// A canned HTTP response for `StubURLProtocol`.
struct StubResponse {
    var statusCode: Int = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data = Data()
    /// Seconds to wait before responding (for cancellation tests).
    var delay: TimeInterval = 0
    /// Fail at the transport level instead of responding.
    var error: URLError?

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        var allHeaders = ["Content-Type": "application/json"]
        allHeaders.merge(headers) { _, new in new }
        return StubResponse(statusCode: status, headers: allHeaders, body: Data(text.utf8))
    }

    static func failure(_ code: URLError.Code) -> StubResponse {
        StubResponse(error: URLError(code))
    }
}

/// A request as seen by the stub, with the body read from `httpBodyStream`.
struct RecordedRequest {
    var request: URLRequest
    var body: Data?

    var method: String { request.httpMethod ?? "" }
    var url: URL { request.url! }
    var path: String { url.path }
    /// Raw (percent-encoded) query string.
    var rawQuery: String { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "" }

    var query: [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    func header(_ name: String) -> String? {
        request.value(forHTTPHeaderField: name)
    }

    var jsonBody: JSONValue? {
        guard let body, !body.isEmpty else { return nil }
        return try? JSONValue.parse(body)
    }
}

/// Intercepts every request of sessions created with `StubURLProtocol.makeSession()`.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    private struct State {
        var handler: Handler = { _ in StubResponse.json("{}") }
        var requests: [RecordedRequest] = []
    }

    private static let state = Locked(State())
    private let stopped = Locked(false)

    static func reset() {
        state.set(State())
    }

    static func setHandler(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    static func respond(with response: StubResponse) {
        setHandler { _ in response }
    }

    static var requests: [RecordedRequest] {
        state.current.requests
    }

    static var lastRequest: RecordedRequest? {
        requests.last
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let handler = Self.state.withLock { state -> Handler in
            state.requests.append(RecordedRequest(request: request, body: body))
            return state.handler
        }
        let response = handler(request)
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
                guard !stopped.current else { return }
                finish(with: response)
            }
        } else {
            finish(with: response)
        }
    }

    override func stopLoading() {
        stopped.set(true)
    }

    private func finish(with response: StubResponse) {
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Base class for tests that talk to the stub.
class StubbedClientTestCase: XCTestCase {
    let serverURL = URL(string: "https://chat.example.com")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func makeClient(token: String? = "tok3n", serverURL: URL? = nil, userAgent: String? = nil) -> MattermostClient {
        MattermostClient(
            configuration: .init(serverURL: serverURL ?? self.serverURL, userAgent: userAgent),
            token: token,
            session: StubURLProtocol.makeSession()
        )
    }

    /// Asserts that `operation` throws a `MattermostError` and returns it.
    func expectMattermostError<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async -> MattermostError? {
        do {
            _ = try await operation()
            XCTFail("Expected an error", file: file, line: line)
            return nil
        } catch let error as MattermostError {
            return error
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
            return nil
        }
    }
}
