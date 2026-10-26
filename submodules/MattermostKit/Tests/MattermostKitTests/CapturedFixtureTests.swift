import XCTest
@testable import MattermostKit

/// Decodes real server responses recorded from the dev server (Mattermost
/// 11.7) by `infra/dev-server/capture-fixtures.py` and copied into
/// `Fixtures/Captured`. Set `MM_FIXTURES_DIR` to check a fresh capture instead
/// (e.g. `infra/dev-server/fixtures` after re-seeding or for another server
/// version).
///
/// Beyond "it decodes", these tests check that lenient decoding did not
/// silently drop anything: element counts must match the raw JSON.
final class CapturedFixtureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let override = ProcessInfo.processInfo.environment["MM_FIXTURES_DIR"] {
            directory = URL(fileURLWithPath: override)
        } else {
            directory = try XCTUnwrap(Bundle.module.url(forResource: "Captured", withExtension: nil), "Captured fixtures missing from the test bundle")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rest").path), "No captured fixtures at \(directory.path)")
    }

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func raw(_ name: String) throws -> JSONValue {
        try JSONValue.parse(data(name))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data(name))
        } catch {
            XCTFail("\(name) as \(T.self): \(error)", file: file, line: line)
            throw error
        }
    }

    /// Decodes a JSON array and checks no element was dropped.
    private func decodeArray<T: Decodable>(_ type: T.Type, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [T] {
        let values = try decode([T].self, name, file: file, line: line)
        XCTAssertEqual(values.count, try raw(name).arrayValue?.count, "\(name): element count", file: file, line: line)
        return values
    }

    private func decodePostList(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> PostList {
        let list = try decode(PostList.self, name, file: file, line: line)
        let raw = try raw(name)
        XCTAssertEqual(list.posts.count, raw["posts"]?.objectValue?.count ?? 0, "\(name): posts", file: file, line: line)
        XCTAssertEqual(list.orderedPosts.count, list.order.count, "\(name): every ordered ID resolves", file: file, line: line)
        for post in list.posts.values {
            let rawPost = raw["posts"]?[post.id]
            XCTAssertEqual(post.message, rawPost?["message"]?.stringValue ?? "", file: file, line: line)
            XCTAssertEqual(post.createAt, rawPost?["create_at"]?.int64Value ?? 0, file: file, line: line)
            XCTAssertEqual(post.metadata?.files.count ?? 0, rawPost?["metadata"]?["files"]?.arrayValue?.count ?? 0, "\(name): files of \(post.id)", file: file, line: line)
            XCTAssertEqual(post.metadata?.reactions.count ?? 0, rawPost?["metadata"]?["reactions"]?.arrayValue?.count ?? 0, "\(name): reactions of \(post.id)", file: file, line: line)
            XCTAssertEqual(post.metadata?.embeds.count ?? 0, rawPost?["metadata"]?["embeds"]?.arrayValue?.count ?? 0, "\(name): embeds of \(post.id)", file: file, line: line)
        }
        return list
    }

    // MARK: REST

    func testUsersAndStatuses() throws {
        let me = try decode(User.self, "rest/users_me.json")
        XCTAssertEqual(me.username, "alice")
        XCTAssertEqual(try decode(User.self, "rest/users_login.json").id, me.id)
        let users = try decodeArray(User.self, "rest/users_by_ids.json")
        XCTAssertTrue(users.contains { $0.id == me.id })
        let statuses = try decodeArray(UserStatus.self, "rest/users_status_ids.json")
        XCTAssertFalse(statuses.contains { if case .unknown = $0.status { return true } else { return false } })
        _ = try decodeArray(Preference.self, "rest/preferences.json")
    }

    func testTeamsAndChannels() throws {
        let teams = try decodeArray(Team.self, "rest/teams.json")
        XCTAssertFalse(teams.isEmpty)
        _ = try decodeArray(TeamMember.self, "rest/team_members.json")
        _ = try decodeArray(TeamUnread.self, "rest/teams_unread.json")

        for name in ["rest/channels_engineering.json", "rest/channels_all.json"] {
            let channels = try decodeArray(Channel.self, name)
            XCTAssertFalse(channels.contains { if case .unknown = $0.type { return true } else { return false } }, name)
            XCTAssertTrue(channels.contains { $0.type == .directMessage }, name)
            for dm in channels where dm.type == .directMessage {
                XCTAssertNotNil(dm.directMessageUserIds, dm.name)
            }
        }
        for name in ["rest/channel_members_engineering.json", "rest/channel_members_all.json"] {
            let members = try decodeArray(ChannelMember.self, name)
            XCTAssertTrue(members.allSatisfy { !$0.channelId.isEmpty && $0.lastViewedAt >= 0 }, name)
        }
        // off-topic is muted for alice in the seed data.
        XCTAssertTrue(try decodeArray(ChannelMember.self, "rest/channel_members_engineering.json").contains { $0.isMuted })

        _ = try decode(Channel.self, "rest/channel_by_id.json")
        let categories = try decode(OrderedSidebarCategories.self, "rest/sidebar_categories_engineering.json")
        XCTAssertEqual(categories.categories.count, try raw("rest/sidebar_categories_engineering.json")["categories"]?.arrayValue?.count)
        XCTAssertEqual(categories.orderedCategories.count, categories.categories.count)
        XCTAssertFalse(categories.categories.contains { if case .unknown = $0.type { return true } else { return false } })
    }

    func testPostPages() throws {
        for name in [
            "rest/posts_page_code_review.json",
            "rest/posts_page_firehose.json",
            "rest/posts_page_firehose_before.json",
            "rest/posts_around_unread_firehose.json",
            "rest/posts_page_integrations.json",
            "rest/posts_page_dm_bob.json",
            "rest/thread.json",
            "rest/thread_paged.json",
            "rest/pinned_posts_releases.json",
            "rest/flagged_posts.json",
        ] {
            _ = try decodePostList(name)
        }
        let integrations = try decodePostList("rest/posts_page_integrations.json")
        XCTAssertTrue(integrations.orderedPosts.contains { $0.props["attachments"]?.arrayValue?.isEmpty == false })
    }

    func testPostWithFilesAndReactions() throws {
        let post = try decode(Post.self, "rest/post_with_files_reactions.json")
        let metadata = try XCTUnwrap(post.metadata)
        XCTAssertEqual(metadata.files.count, 5)
        XCTAssertEqual(post.fileIds.count, 5)
        XCTAssertFalse(metadata.reactions.isEmpty)
        XCTAssertTrue(metadata.files.filter(\.isImage).allSatisfy { $0.width > 0 && $0.height > 0 })
        XCTAssertTrue(metadata.files.contains { $0.miniPreview != nil })
        _ = try decodeArray(FileInfo.self, "rest/post_files_info.json")
        _ = try decodeArray(Reaction.self, "rest/post_reactions.json")
        _ = try decodeArray(CustomEmoji.self, "rest/custom_emoji.json")
    }

    func testThreads() throws {
        let list = try decode(ThreadList.self, "rest/user_threads.json")
        XCTAssertEqual(list.threads.count, try raw("rest/user_threads.json")["threads"]?.arrayValue?.count)
        XCTAssertTrue(list.threads.allSatisfy { $0.post != nil })
        let thread = try decode(UserThread.self, "rest/user_thread.json")
        XCTAssertNotNil(thread.post)
    }

    func testServerInfo() throws {
        let config = try decode(ClientConfig.self, "rest/client_config.json")
        XCTAssertNotNil(config.serverVersion)
        XCTAssertNotNil(config.maxFileSize)
        XCTAssertTrue(config.collapsedThreads.isAvailable)
        _ = try decode(ClientLicense.self, "rest/client_license.json")
        XCTAssertTrue(try decode(PingResponse.self, "rest/system_ping.json").isOK)
        let error = try decode(AppError.self, "rest/error_post_not_found.json")
        XCTAssertEqual(error.statusCode, 404)
        XCTAssertFalse(error.id.isEmpty)
    }

    // MARK: WebSocket

    private func message(_ name: String) throws -> WebSocketMessage {
        try XCTUnwrap(WebSocketMessage(data: data(name)), name)
    }

    private func event(_ name: String) throws -> WebSocketEvent {
        guard case .event(let event) = try message(name) else {
            XCTFail("\(name) is not an event")
            throw URLError(.cannotParseResponse)
        }
        return event
    }

    func testWebSocketEvents() throws {
        XCTAssertNotNil(try event("ws/hello.json").hello)
        XCTAssertNotNil(try event("ws/typing.json").typing)
        XCTAssertNotNil(try event("ws/posted.json").posted)
        XCTAssertTrue(try XCTUnwrap(try event("ws/posted_reply.json").posted).post.isReply)
        XCTAssertNotNil(try event("ws/post_edited.json").editedPost)
        XCTAssertNotNil(try event("ws/post_deleted.json").deletedPost)
        XCTAssertNotNil(try event("ws/reaction_added.json").reaction)
        XCTAssertNotNil(try event("ws/reaction_removed.json").reaction)
        XCTAssertNotNil(try event("ws/thread_updated.json").updatedThread)
        XCTAssertNotNil(try event("ws/multiple_channels_viewed.json").multipleChannelsViewed)
        // 11.x sends multiple_channels_viewed even for one channel.
        XCTAssertEqual(try event("ws/multiple_channels_viewed.json").channelsViewed?.lastViewedAt.count, 1)

        guard case .response(let response) = try message("ws/response_seq_1.json") else {
            return XCTFail("Expected a response")
        }
        XCTAssertTrue(response.isOK)
        XCTAssertEqual(response.seqReply, 1)
    }

    func testRecordedEventSequence() throws {
        let frames = try XCTUnwrap(try raw("ws/events.json").arrayValue)
        var events: [WebSocketEvent] = []
        for frame in frames {
            let data = try JSONEncoder().encode(frame)
            switch WebSocketMessage(data: data) {
            case .event(let event)?: events.append(event)
            case .response?: break
            case nil: XCTFail("Unparseable frame: \(frame)")
            }
        }
        XCTAssertEqual(events.first?.type, .hello)
        // Server sequence numbers are contiguous from the hello event.
        let seqs = events.compactMap(\.seq)
        XCTAssertEqual(seqs, Array(0..<Int64(seqs.count)))
        XCTAssertFalse(events.contains { if case .unknown = $0.type { return true } else { return false } })
    }
}
