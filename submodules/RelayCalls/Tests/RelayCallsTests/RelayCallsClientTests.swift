import Foundation
import XCTest
@testable import RelayCallsCore

private final class CallURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RelayCallsClientTests: XCTestCase {
    private let channel = "abcdefghijklmnopqrstuvwxyz"

    private func client() -> RelayCallsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallURLProtocol.self]
        return RelayCallsClient(serverURL: URL(string: "https://example.com/mattermost")!, token: "session-token", session: URLSession(configuration: configuration))
    }

    func testPluginRequestsPreserveServerPrefixAndAuthentication() async throws {
        CallURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/mattermost/plugins/org.relaychat.calls/channels/abcdefghijklmnopqrstuvwxyz")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            XCTAssertFalse(request.httpShouldHandleCookies)
            return (200, Data(#"{"call":null}"#.utf8))
        }
        let call = try await client().call(channelId: channel)
        XCTAssertNil(call)
    }

    func testForbiddenMembershipIsReportedToTheCaller() async {
        CallURLProtocol.handler = { _ in (403, Data(#"{"message":"Join this channel first."}"#.utf8)) }
        do {
            _ = try await client().join(channelId: channel)
            XCTFail("Forbidden call joined")
        } catch { XCTAssertEqual(error as? RelayCallsError, .server(403, "Join this channel first.")) }
    }

    func testJoinRejectsUntrustedMediaAddressAndWrongChannel() async throws {
        for (address, responseChannel) in [("http://calls.example.com", channel), ("wss://user:password@calls.example.com", channel), ("wss://calls.example.com", String(repeating: "a", count: 26))] {
            let data = try JSONSerialization.data(withJSONObject: ["url": address, "token": "room-token", "call": ["id": "call", "channel_id": responseChannel, "room": "room", "started_by": "user", "started_at": 1, "participants": 3, "can_end": false]])
            CallURLProtocol.handler = { _ in (200, data) }
            do { _ = try await client().join(channelId: channel); XCTFail("Invalid session accepted") }
            catch { XCTAssertEqual(error as? RelayCallsError, .invalidServer) }
        }
    }

    func testInvalidChannelDoesNotSendCredentials() async {
        CallURLProtocol.handler = { _ in XCTFail("Invalid channel reached the network"); return (500, Data()) }
        do { _ = try await client().call(channelId: "../config"); XCTFail("Invalid channel accepted") }
        catch { XCTAssertEqual(error as? RelayCallsError, .invalidChannel) }
    }

    func testEndingStaleCallPreservesConflict() async {
        CallURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/end"))
            return (409, Data(#"{"message":"This call has ended."}"#.utf8))
        }
        do { try await client().end(channelId: channel, callId: "old-call"); XCTFail("Stale call ended") }
        catch { XCTAssertEqual(error as? RelayCallsError, .server(409, "This call has ended.")) }
    }
}
