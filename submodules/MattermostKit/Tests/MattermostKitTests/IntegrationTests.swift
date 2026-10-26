import XCTest
@testable import MattermostKit

/// Runs against a live server. Skipped unless `MM_INTEGRATION=1`.
///
/// Environment:
/// - `MM_URL` (default `http://localhost:8065`)
/// - `MM_LOGIN_ID` (default `alice`)
/// - `MM_PASSWORD`; if unset, `SEED_USER_PASSWORD` is read from
///   `infra/dev-server/.env` (the local dev server's seed password).
///
/// Writes only to the seeded `sandbox` scratch channel and cleans up.
final class IntegrationTests: XCTestCase {
    private var serverURL: URL!
    private var loginId = "alice"
    private var password = ""
    private var diagnostics: () -> String = { "" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MM_INTEGRATION"] == "1", "Set MM_INTEGRATION=1 to run against a live server")
        serverURL = URL(string: environment["MM_URL"] ?? "http://localhost:8065")
        loginId = environment["MM_LOGIN_ID"] ?? "alice"
        password = try environment["MM_PASSWORD"] ?? Self.devServerPassword()
    }

    /// Reads `SEED_USER_PASSWORD` from the dev server's `.env` without logging it.
    private static func devServerPassword() throws -> String {
        let envFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("infra/dev-server/.env")
        let contents = try String(contentsOf: envFile, encoding: .utf8)
        for line in contents.split(separator: "\n") where line.hasPrefix("SEED_USER_PASSWORD=") {
            return String(line.dropFirst("SEED_USER_PASSWORD=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        throw XCTSkip("No MM_PASSWORD and no SEED_USER_PASSWORD in \(envFile.path)")
    }

    private func loggedInClient() async throws -> (MattermostClient, User) {
        let client = MattermostClient(serverURL: serverURL, userAgent: "MattermostKitTests")
        let result = try await client.login(loginId: loginId, password: password)
        return (client, result.user)
    }

    func testServerDiscovery() async throws {
        let client = MattermostClient(serverURL: serverURL)
        let ping = try await client.ping()
        XCTAssertTrue(ping.isOK)
        let config = try await client.clientConfig()
        XCTAssertNotNil(config.serverVersion)
        _ = try await client.clientLicense()

        let error = await capture { try await client.me() }
        XCTAssertEqual(error?.isSessionExpired, true)
    }

    func testBootstrapReads() async throws {
        let (client, me) = try await loggedInClient()
        defer { Task { try? await client.logout() } }

        let fetchedMe = try await client.me()
        XCTAssertEqual(fetchedMe.id, me.id)
        let config = try await client.clientConfig()
        XCTAssertNotNil(config.maxFileSize, "logged-in config should include MaxFileSize")
        _ = try await client.preferences()
        let teams = try await client.teams()
        XCTAssertFalse(teams.isEmpty)
        _ = try await client.teamMembers()
        _ = try await client.teamsUnread(includeCollapsedThreads: true)

        let team = try XCTUnwrap(teams.first { $0.name == "engineering" } ?? teams.first)
        let channels = try await client.channels(teamId: team.id)
        XCTAssertFalse(channels.isEmpty)
        let members = try await client.channelMembers(teamId: team.id)
        XCTAssertFalse(members.isEmpty)
        let categories = try await client.sidebarCategories(teamId: team.id)
        XCTAssertFalse(categories.orderedCategories.isEmpty)

        let partnerIds = channels.compactMap { $0.directMessagePartnerId(myUserId: me.id) }
        if !partnerIds.isEmpty {
            let users = try await client.users(ids: partnerIds)
            XCTAssertFalse(users.isEmpty)
            _ = try await client.userStatuses(ids: partnerIds)
        }

        let busiest = try XCTUnwrap(channels.max { $0.totalMsgCount < $1.totalMsgCount })
        let page = try await client.posts(channelId: busiest.id, page: 0, perPage: 30, collapsedThreads: true)
        XCTAssertEqual(page.orderedPosts.count, page.order.count)
        if let oldest = page.order.last {
            let older = try await client.posts(channelId: busiest.id, perPage: 30, before: oldest)
            XCTAssertFalse(older.order.contains(oldest))
        }
        if let root = page.orderedPosts.first(where: { $0.replyCount > 0 }) {
            let thread = try await client.postThread(postId: root.id, options: PostThreadOptions(perPage: 10, direction: .down, collapsedThreads: true))
            XCTAssertNotNil(thread.posts[root.id])
        }
        _ = try await client.userThreads(teamId: team.id, options: UserThreadsOptions(perPage: 10))
        _ = try await client.customEmojis(page: 0, perPage: 50, sort: "name")
        _ = try await client.autocompleteUsers(name: "b", teamId: team.id)
        _ = try await client.commandAutocompleteSuggestions(teamId: team.id, userInput: "/", channelId: busiest.id)

        if let avatarOwner = try await client.users(ids: [me.id]).first {
            let image = try await client.data(for: .userImage(userId: avatarOwner.id, lastPictureUpdate: avatarOwner.lastPictureUpdate))
            XCTAssertFalse(image.isEmpty)
        }
    }

    func testPostLifecycleInSandbox() async throws {
        let (client, me) = try await loggedInClient()
        defer { Task { try? await client.logout() } }
        let teams = try await client.teams()
        let team = try XCTUnwrap(teams.first { $0.name == "engineering" })
        let channels = try await client.channels(teamId: team.id)
        let sandbox = try XCTUnwrap(channels.first { $0.name == "sandbox" }, "seeded sandbox channel")

        let upload = try await client.uploadFiles(
            [FileUpload(clientId: "it-1", fileName: "integration.txt", mimeType: "text/plain", content: .data(Data("MattermostKit integration test".utf8)))],
            channelId: sandbox.id
        )
        XCTAssertEqual(upload.clientIds, ["it-1"])
        let file = try XCTUnwrap(upload.fileInfos.first)

        let pendingId = Post.makePendingPostId(userId: me.id)
        let post = try await client.createPost(PostDraft(channelId: sandbox.id, message: "MattermostKit integration test", fileIds: [file.id], pendingPostId: pendingId))
        XCTAssertEqual(post.pendingPostId, pendingId)

        let reaction = try await client.addReaction(userId: me.id, postId: post.id, emojiName: "+1")
        XCTAssertEqual(reaction.emojiName, "+1")
        try await client.removeReaction(postId: post.id, emojiName: "+1")

        let edited = try await client.patchPost(id: post.id, patch: PostPatch(message: "MattermostKit integration test (edited)"))
        XCTAssertTrue(edited.isEdited)

        let fetched = try await client.post(id: post.id)
        XCTAssertEqual(fetched.metadata?.files.first?.id, file.id)
        let downloaded = try await client.data(for: .file(id: file.id))
        XCTAssertEqual(String(decoding: downloaded, as: UTF8.self), "MattermostKit integration test")

        try await client.deletePost(id: post.id)
        let error = await capture { try await client.post(id: post.id) }
        XCTAssertNotNil(error)
    }

    func testWebSocketHelloActionsAndResume() async throws {
        let (client, _) = try await loggedInClient()
        defer { Task { try? await client.logout() } }
        let token = try XCTUnwrap(client.token)

        XCTAssertFalse(token.isEmpty)
        let socket = client.makeWebSocket(configuration: .init(pingInterval: nil))
        let stateLog = StreamRecorder(socket.connectionStates())
        let eventLog = StreamRecorder(socket.events())
        diagnostics = { "states: \(stateLog.values)\nevents: \(eventLog.values.map { "\($0.event)#\($0.seq ?? -1) \($0.data)" })" }
        await socket.connect()

        let first = try await connected(socket)
        XCTAssertFalse(first.resumed)
        XCTAssertNotNil(first.serverVersion.flatMap(ServerVersion.init))

        let statuses = try await socket.sendAction("get_statuses")
        XCTAssertTrue(statuses.isOK)
        let pong = try await socket.ping()
        XCTAssertNotNil(pong.data["server_time"]?.int64Value)

        let teams = try await client.teams()
        let team = try XCTUnwrap(teams.first { $0.name == "engineering" })
        let channels = try await client.channels(teamId: team.id)
        let sandbox = try XCTUnwrap(channels.first { $0.name == "sandbox" }, "seeded sandbox channel")
        try await socket.userTyping(channelId: sandbox.id)

        // Reconnecting right away should resume the same server connection.
        await socket.reconnectNow()
        let second = try await connected(socket) { $0.resumed || $0.connectionId != first.connectionId }
        assertConsistent(second, previous: first)

        // An event that happens while disconnected is replayed after resuming.
        await socket.disconnect()
        try await Task.sleep(nanoseconds: 500_000_000)
        let missed = try await client.createPost(PostDraft(channelId: sandbox.id, message: "MattermostKit resume test"))
        await socket.connect()
        let third = try await connected(socket)
        assertConsistent(third, previous: second)
        if third.resumed {
            await waitUntil(timeout: 5) { eventLog.values.contains { $0.posted?.post.id == missed.id } }
            let seqs = eventLog.values.compactMap(\.seq)
            if second.resumed {
                XCTAssertEqual(seqs, Array(0..<Int64(seqs.count)), "event sequence should be contiguous across resumes\n\(diagnostics())")
            }
        } else {
            // The server is free not to resume; the sync layer then catches up.
            print("IntegrationTests: server did not resume after disconnect\n\(diagnostics())")
        }

        try await client.deletePost(id: missed.id)
        await socket.disconnect()
    }

    func testWebSocketRejectsInvalidToken() async throws {
        // Mattermost upgrades the connection anyway and then stays silent; the
        // token verifier (GET /users/me → 401) turns that into .unauthorized.
        let client = MattermostClient(serverURL: serverURL, token: "not-a-valid-token")
        let socket = client.makeWebSocket(configuration: .init(pingInterval: nil, handshakeTimeout: 2))
        let stateLog = StreamRecorder(socket.connectionStates())
        await socket.connect()
        await waitUntil(timeout: 8) { stateLog.values.contains(.unauthorized) }
        if !stateLog.values.contains(.unauthorized) {
            XCTFail("expected .unauthorized; states: \(stateLog.values)")
        }
        await socket.disconnect()
    }

    // MARK: Helpers

    /// A reconnect either resumed the same connection or reports a new one.
    /// Mattermost does not guarantee a resume, so either outcome is valid; the
    /// client must just report it truthfully.
    private func assertConsistent(_ info: WebSocketConnectionInfo, previous: WebSocketConnectionInfo, file: StaticString = #filePath, line: UInt = #line) {
        if info.resumed {
            XCTAssertEqual(info.connectionId, previous.connectionId, "resumed with a different ID\n\(diagnostics())", file: file, line: line)
        } else {
            XCTAssertNotEqual(info.connectionId, previous.connectionId, "same ID but not reported as resumed\n\(diagnostics())", file: file, line: line)
            print("IntegrationTests: server did not resume (new connection \(info.connectionId))")
        }
    }

    /// Waits for a `.connected` state matching `predicate` on a fresh state stream.
    private func connected(
        _ socket: MattermostWebSocket,
        timeout: TimeInterval = 10,
        where predicate: @escaping @Sendable (WebSocketConnectionInfo) -> Bool = { _ in true }
    ) async throws -> WebSocketConnectionInfo {
        let states = socket.connectionStates()
        return try await withThrowingTaskGroup(of: WebSocketConnectionInfo?.self) { group in
            group.addTask {
                for await state in states {
                    if case .connected(let info) = state, predicate(info) { return info }
                    if state == .unauthorized { return nil }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let info = try await group.next() ?? nil else {
                XCTFail("WebSocket did not reach the expected state within \(timeout) s\n\(diagnostics())")
                throw MattermostWebSocketError.timeout
            }
            return info
        }
    }

    private func capture<T>(_ operation: () async throws -> T) async -> MattermostError? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error as? MattermostError
        }
    }
}
