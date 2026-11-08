import Foundation
import XCTest
import RelayCallsCore

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

/// The JSON body of a request (URLProtocol sees it as a stream).
private func body(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        stream.close()
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

final class RelayCallsClientTests: XCTestCase {
    private let channel = "abcdefghijklmnopqrstuvwxyz"

    private func client(token: String = "session-token") -> RelayCallsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallURLProtocol.self]
        return RelayCallsClient(serverURL: URL(string: "https://example.com/mattermost")!, token: token, session: URLSession(configuration: configuration))
    }

    private func callJSON(id: String = "call1", channel: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var call: [String: Any] = ["id": id, "channel_id": channel ?? self.channel, "room": "relay_x", "kind": "direct", "state": "ringing", "video": true, "started_by": "caller", "started_at": 1, "ring_expires_at": 46_000, "participants": 1, "participant_ids": ["caller"], "invitees": ["callee": "received"], "post_id": "post1", "can_end": true]
        for (key, value) in extra { call[key] = value }
        return call
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
        for (address, responseChannel) in [("http://calls.example.com", channel), ("ws://calls.example.com", channel), ("wss://user:password@calls.example.com", channel), ("ftp://calls.example.com", channel), ("wss://calls.example.com", String(repeating: "a", count: 26))] {
            let data = try JSONSerialization.data(withJSONObject: ["url": address, "token": "room-token", "call": ["id": "call", "channel_id": responseChannel, "room": "room", "started_by": "user", "started_at": 1, "participants": 3, "can_end": false]])
            CallURLProtocol.handler = { _ in (200, data) }
            do { _ = try await client().join(channelId: channel); XCTFail("Invalid session accepted: \(address)") }
            catch { XCTAssertEqual(error as? RelayCallsError, .invalidServer) }
        }
    }

    func testLoopbackMediaAddressesMayBeUnencrypted() {
        for address in ["ws://localhost:7880", "http://127.0.0.1:7880", "ws://[::1]:7880", "wss://calls.example.com", "https://calls.example.com/rtc"] {
            XCTAssertTrue(RelayCallsClient.isAllowedMediaURL(address), address)
        }
        for address in ["ws://192.168.1.10:7880", "ws://localhost.example.com", "ws://127.0.0.1.example.com", "http://10.0.0.1", "wss://u@calls.example.com", "wss://calls.example.com#x", "livekit"] {
            XCTAssertFalse(RelayCallsClient.isAllowedMediaURL(address), address)
        }
    }

    func testInvalidChannelDoesNotSendCredentials() async {
        CallURLProtocol.handler = { _ in XCTFail("Invalid channel reached the network"); return (500, Data()) }
        do { _ = try await client().call(channelId: "../config"); XCTFail("Invalid channel accepted") }
        catch { XCTAssertEqual(error as? RelayCallsError, .invalidChannel) }
        do { _ = try await client().accept(callId: "../../users/me", deviceId: "d"); XCTFail("Invalid call accepted") }
        catch { XCTAssertEqual(error as? RelayCallsError, .invalidResponse) }
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

    func testEndAcceptsOkAndEmptyAnswers() async throws {
        CallURLProtocol.handler = { _ in (200, Data(#"{"ok":true}"#.utf8)) }
        try await client().end(channelId: channel, callId: "call1")
        CallURLProtocol.handler = { _ in (204, Data()) }
        try await client().end(channelId: channel, callId: "call1")
        CallURLProtocol.handler = { _ in (200, Data(#"{"ok":false}"#.utf8)) }
        do { try await client().end(channelId: channel, callId: "call1"); XCTFail("Refused end accepted") }
        catch { XCTAssertEqual(error as? RelayCallsError, .invalidResponse) }
    }

    func testConfigurationVersions() async throws {
        CallURLProtocol.handler = { _ in (200, Data(#"{"enabled":true,"version":1,"max_participants":25,"screen_sharing":true}"#.utf8)) }
        let old = try await client().configuration()
        XCTAssertEqual(old, RelayCallsConfiguration(enabled: true, version: 1, maxParticipants: 25, screenSharing: true))
        XCTAssertFalse(old.supportsRinging)
        CallURLProtocol.handler = { _ in (200, Data(#"{"enabled":true,"version":2,"max_participants":25,"screen_sharing":true,"camera":true,"ringing":true,"ring_timeout_seconds":30}"#.utf8)) }
        let current = try await client().configuration()
        XCTAssertTrue(current.camera)
        XCTAssertTrue(current.supportsRinging)
        XCTAssertEqual(current.ringTimeoutSeconds, 30)
    }

    func testRingSendsVideoAndDeviceAndDecodesTheCall() async throws {
        let call = callJSON()
        CallURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/mattermost/plugins/org.relaychat.calls/channels/abcdefghijklmnopqrstuvwxyz/ring")
            let sent = body(request)
            XCTAssertEqual(sent["video"] as? Bool, true)
            XCTAssertEqual(sent["device_id"] as? String, "device-1")
            return (200, try JSONSerialization.data(withJSONObject: ["url": "wss://lk.example.com", "token": "t", "call": call]))
        }
        let join = try await client().ring(channelId: channel, video: true, deviceId: "device-1")
        XCTAssertEqual(join.call.kind, .direct)
        XCTAssertEqual(join.call.state, .ringing)
        XCTAssertTrue(join.call.video)
        XCTAssertEqual(join.call.invitees, ["callee": .received])
        XCTAssertEqual(join.call.ringExpiresAt, 46_000)
        XCTAssertEqual(join.call.ringExpiryDate, Date(timeIntervalSince1970: 46))
        XCTAssertEqual(join.call.postId, "post1")
        XCTAssertTrue(join.call.isRinging(for: "callee"))
        XCTAssertFalse(join.call.isRinging(for: "caller"))
    }

    func testRingConflictCarriesTheRunningCall() async throws {
        let wrapped = try JSONSerialization.data(withJSONObject: ["message": "A call is running.", "call": callJSON(id: "running", extra: ["state": "active"])])
        CallURLProtocol.handler = { _ in (409, wrapped) }
        do { _ = try await client().ring(channelId: channel, video: false, deviceId: "d"); XCTFail("Conflict ignored") }
        catch { XCTAssertEqual((error as? RelayCallsError), .callInProgress(RelayCall(id: "running", channelId: channel, room: "relay_x", kind: .direct, state: .active, video: true, startedBy: "caller", startedAt: 1, ringExpiresAt: 46_000, participants: 1, participantIds: ["caller"], invitees: ["callee": .received], postId: "post1", canEnd: true))) }
        let raw = try JSONSerialization.data(withJSONObject: callJSON(id: "raw"))
        CallURLProtocol.handler = { _ in (409, raw) }
        do { _ = try await client().ring(channelId: channel, video: false, deviceId: "d"); XCTFail("Conflict ignored") }
        catch {
            guard case let .callInProgress(call)? = error as? RelayCallsError else { return XCTFail("\(error)") }
            XCTAssertEqual(call.id, "raw")
        }
        CallURLProtocol.handler = { _ in (409, Data(#"{"message":"Busy."}"#.utf8)) }
        do { _ = try await client().ring(channelId: channel, video: false, deviceId: "d"); XCTFail("Conflict ignored") }
        catch { XCTAssertEqual(error as? RelayCallsError, .server(409, "Busy.")) }
    }

    func testCallByIdForgottenIsNil() async throws {
        CallURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/mattermost/plugins/org.relaychat.calls/calls/call1")
            return (404, Data(#"{"message":"Not found."}"#.utf8))
        }
        let forgotten = try await client().call(id: "call1")
        XCTAssertNil(forgotten)
        let raw = try JSONSerialization.data(withJSONObject: callJSON())
        CallURLProtocol.handler = { _ in (200, raw) }
        let found = try await client().call(id: "call1")
        XCTAssertEqual(found?.id, "call1")
    }

    func testActiveCallsAcceptsAListOrAnObject() async throws {
        let list = try JSONSerialization.data(withJSONObject: [callJSON(id: "a"), callJSON(id: "b", extra: ["kind": "channel", "state": "active"])])
        CallURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/mattermost/plugins/org.relaychat.calls/calls/active")
            XCTAssertNotEqual(request.httpMethod, "POST")
            return (200, list)
        }
        let calls = try await client().activeCalls()
        XCTAssertEqual(calls.map(\.id), ["a", "b"])
        XCTAssertEqual(calls[1].kind, .channel)
        let object = try JSONSerialization.data(withJSONObject: ["calls": [callJSON(id: "c")]])
        CallURLProtocol.handler = { _ in (200, object) }
        let wrapped = try await client().activeCalls()
        XCTAssertEqual(wrapped.map(\.id), ["c"])
        CallURLProtocol.handler = { _ in (200, Data("null".utf8)) }
        let none = try await client().activeCalls()
        XCTAssertEqual(none, [])
    }

    func testRingAnswersSendTheDevice() async throws {
        var seen: [(String, [String: Any])] = []
        CallURLProtocol.handler = { request in
            seen.append((request.httpMethod! + " " + request.url!.path.replacingOccurrences(of: "/mattermost/plugins/org.relaychat.calls/", with: ""), body(request)))
            return (204, Data())
        }
        try await client().received(callId: "call1", deviceId: "dev")
        try await client().decline(callId: "call1", deviceId: "dev", reason: .busy)
        try await client().hangup(callId: "call1", deviceId: "dev")
        try await client().registerVoIPDevice(deviceId: "dev", token: "abcd", environment: .sandbox, bundleId: "chat.relay.app")
        try await client().unregisterVoIPDevice(deviceId: "dev")
        XCTAssertEqual(seen.map(\.0), ["POST calls/call1/received", "POST calls/call1/decline", "POST calls/call1/hangup", "POST devices/voip", "DELETE devices/voip/dev"])
        XCTAssertEqual(seen[0].1["device_id"] as? String, "dev")
        XCTAssertEqual(seen[1].1["reason"] as? String, "busy")
        XCTAssertEqual(seen[3].1["environment"] as? String, "sandbox")
        XCTAssertEqual(seen[3].1["bundle_id"] as? String, "chat.relay.app")
        XCTAssertEqual(seen[3].1["token"] as? String, "abcd")
    }

    func testAcceptMustAnswerForTheSameCall() async throws {
        let other = try JSONSerialization.data(withJSONObject: ["url": "wss://lk.example.com", "token": "t", "call": callJSON(id: "other")])
        CallURLProtocol.handler = { _ in (200, other) }
        do { _ = try await client().accept(callId: "call1", deviceId: "d"); XCTFail("Wrong call accepted") }
        catch { XCTAssertEqual(error as? RelayCallsError, .invalidServer) }
        CallURLProtocol.handler = { _ in (409, Data(#"{"message":"No longer ringing."}"#.utf8)) }
        do { _ = try await client().accept(callId: "call1", deviceId: "d"); XCTFail("Conflict ignored") }
        catch { XCTAssertEqual((error as? RelayCallsError)?.statusCode, 409) }
    }

    func testJoinSendsDeviceAndChecksTheCall() async throws {
        let call = try JSONSerialization.data(withJSONObject: ["url": "ws://localhost:7880", "token": "t", "call": callJSON(id: "call2")])
        CallURLProtocol.handler = { request in
            let sent = body(request)
            XCTAssertTrue(["call1", "call2"].contains(sent["call_id"] as? String))
            XCTAssertEqual(sent["device_id"] as? String, "dev")
            return (200, call)
        }
        do { _ = try await client().join(channelId: channel, callId: "call1", deviceId: "dev"); XCTFail("Another call joined") }
        catch { XCTAssertEqual(error as? RelayCallsError, .invalidServer) }
        let join = try await client().join(channelId: channel, callId: "call2", deviceId: "dev")
        XCTAssertEqual(join.url, "ws://localhost:7880")
    }

    func testTokenProviderIsReadPerRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokens = TokenBox()
        let client = RelayCallsClient(serverURL: URL(string: "https://example.com")!, token: { tokens.value }, session: { session })
        var seen: [String?] = []
        CallURLProtocol.handler = { request in
            seen.append(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data(#"{"call":null}"#.utf8))
        }
        _ = try await client.call(channelId: channel)
        tokens.value = "renewed"
        _ = try await client.call(channelId: channel)
        XCTAssertEqual(seen, ["Bearer first", "Bearer renewed"])
        tokens.value = nil
        do { _ = try await client.call(channelId: channel); XCTFail("No token sent") }
        catch { XCTAssertEqual((error as? RelayCallsError)?.statusCode, 401) }
    }
}

private final class TokenBox: @unchecked Sendable {
    var value: String? = "first"
}
