import XCTest
@testable import MattermostKit

final class ModelDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            XCTFail("Decoding \(T.self) failed: \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: Users

    func testUser() throws {
        let user = try decode(User.self, Fixtures.user)
        XCTAssertEqual(user.id, Fixtures.userId)
        XCTAssertEqual(user.username, "alice")
        XCTAssertEqual(user.fullName, "Alice Liddell")
        XCTAssertEqual(user.displayName(.nicknameOrFullName), "Al")
        XCTAssertEqual(user.displayName(.fullName), "Alice Liddell")
        XCTAssertEqual(user.displayName(), "alice")
        XCTAssertTrue(user.isSystemAdmin)
        XCTAssertFalse(user.isGuest)
        XCTAssertFalse(user.isBot)
        XCTAssertEqual(user.lastPictureUpdate, 1_700_000_600_000)
        XCTAssertEqual(user.lastActivityAt, 1_700_000_700_000)
        XCTAssertEqual(user.notifyProps["push"], "mention")
        XCTAssertEqual(user.timezone["automaticTimezone"], "Europe/Berlin")
        XCTAssertEqual(user.customStatus, UserCustomStatus(emoji: "calendar", text: "In a meeting", duration: "one_hour", expiresAt: "2026-10-26T15:00:00Z"))
    }

    func testBotUserWithNullAndMissingFields() throws {
        let user = try decode(User.self, Fixtures.botUser)
        XCTAssertTrue(user.isBot)
        XCTAssertEqual(user.botDescription, "Posts RSS items")
        XCTAssertEqual(user.notifyProps, [:])
        XCTAssertEqual(user.email, "")
        XCTAssertNil(user.lastActivityAt)
        XCTAssertNil(user.customStatus)
        XCTAssertEqual(user.displayName(.fullName), "Feed")
    }

    func testUserRequiresId() {
        XCTAssertThrowsError(try JSONDecoder().decode(User.self, from: Data(#"{"username":"x"}"#.utf8)))
    }

    func testUserStatuses() throws {
        let statuses = try decode([UserStatus].self, Fixtures.statuses)
        XCTAssertEqual(statuses.map(\.status), [.online, .dnd, .unknown("on_vacation")])
        XCTAssertTrue(statuses[1].manual)
        XCTAssertEqual(statuses[1].dndEndTime, 1_700_003_600)
        XCTAssertEqual(statuses[2].lastActivityAt, 0)
    }

    func testPreferences() throws {
        let preferences = try decode([Preference].self, Fixtures.preferences)
        XCTAssertEqual(preferences.count, 2)
        XCTAssertEqual(preferences[1].category, PreferenceCategory.flaggedPost)
        XCTAssertEqual(preferences[1].name, "8d9dmwzmrinfmxsfr4cqnz3d6e")
    }

    // MARK: Teams

    func testTeamsAndMembers() throws {
        let teams = try decode([Team].self, Fixtures.teams)
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams[0].displayName, "Engineering")
        XCTAssertEqual(teams[0].type, "O")
        XCTAssertTrue(teams[0].allowOpenInvite)
        XCTAssertNil(teams[0].schemeId)
        XCTAssertNil(teams[0].groupConstrained)

        let members = try decode([TeamMember].self, Fixtures.teamMembers)
        XCTAssertEqual(members[0].teamId, Fixtures.teamId)
        XCTAssertTrue(members[0].schemeAdmin)
        XCTAssertEqual(members[0].createAt, 1_690_000_000_000)

        let unread = try decode([TeamUnread].self, Fixtures.teamsUnread)
        XCTAssertEqual(unread[0].msgCount, 12)
        XCTAssertEqual(unread[0].mentionCountRoot, 1)
        XCTAssertEqual(unread[0].threadMentionCount, 1)
    }

    // MARK: Channels

    func testChannels() throws {
        let channels = try decode([Channel].self, Fixtures.channels)
        XCTAssertEqual(channels.map(\.type), [.publicChannel, .privateChannel, .directMessage, .groupMessage, .unknown("X")])

        let townSquare = channels[0]
        XCTAssertEqual(townSquare.displayName, "Town Square")
        XCTAssertEqual(townSquare.lastPostAt, 1_700_000_900_000)
        XCTAssertEqual(townSquare.totalMsgCount, 120)
        XCTAssertEqual(townSquare.totalMsgCountRoot, 100)
        XCTAssertEqual(townSquare.props, [:])
        XCTAssertFalse(townSquare.isArchived)

        XCTAssertTrue(channels[1].isArchived)
        XCTAssertEqual(channels[1].totalMsgCountRoot, 0)

        let dm = channels[2]
        XCTAssertEqual(dm.directMessagePartnerId(myUserId: Fixtures.userId), Fixtures.otherUserId)
        XCTAssertEqual(dm.directMessagePartnerId(myUserId: Fixtures.otherUserId), Fixtures.userId)
        XCTAssertNil(dm.directMessagePartnerId(myUserId: "someone-else"))
        XCTAssertNil(townSquare.directMessageUserIds)

        // Minimal objects still decode.
        XCTAssertEqual(channels[3].createAt, 0)
        XCTAssertEqual(channels[4].type.rawValue, "X")
    }

    func testChannelStats() throws {
        let stats = try decode(ChannelStats.self, #"{"channel_id":"c1","member_count":5,"guest_count":0,"pinnedpost_count":2,"files_count":7}"#)
        XCTAssertEqual(stats, ChannelStats(channelId: "c1", memberCount: 5, guestCount: 0, pinnedPostCount: 2, filesCount: 7))
        XCTAssertEqual(try decode(ChannelStats.self, #"{"channel_id":"c1","member_count":3}"#).memberCount, 3)
    }

    func testChannelTypeRoundTrip() throws {
        let data = try JSONEncoder().encode([ChannelType.privateChannel, .unknown("Z")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["P","Z"]"#)
    }

    func testChannelMembers() throws {
        let members = try decode([ChannelMember].self, Fixtures.channelMembers)
        XCTAssertEqual(members[0].lastViewedAt, 1_700_000_850_000)
        XCTAssertEqual(members[0].msgCount, 110)
        XCTAssertEqual(members[0].msgCountRoot, 95)
        XCTAssertEqual(members[0].mentionCount, 1)
        XCTAssertEqual(members[0].mentionCountRoot, 1)
        XCTAssertEqual(members[0].roles, "channel_user")
        XCTAssertTrue(members[0].isMuted)
        XCTAssertFalse(members[1].isMuted)
        XCTAssertEqual(members[1].notifyProps, [:])
        XCTAssertEqual(members[1].mentionCountRoot, 0)
    }

    func testSidebarCategories() throws {
        let result = try decode(OrderedSidebarCategories.self, Fixtures.sidebarCategories)
        XCTAssertEqual(result.categories.count, 3)
        XCTAssertEqual(result.orderedCategories.map(\.type), [.favorites, .directMessages, .channels])
        XCTAssertEqual(result.categories[0].channelIds, ["pb1bt4wqepdj8xg6ymbiec1ydh"])
        XCTAssertEqual(result.categories[2].channelIds, [])
        XCTAssertTrue(result.categories[2].collapsed)
        XCTAssertEqual(result.categories[1].sorting, "alpha")
    }

    // MARK: Posts

    func testPostWithMetadata() throws {
        let post = try decode(Post.self, Fixtures.post)
        XCTAssertEqual(post.id, "8d9dmwzmrinfmxsfr4cqnz3d6e")
        XCTAssertTrue(post.isEdited)
        XCTAssertTrue(post.isPinned)
        XCTAssertFalse(post.isReply)
        XCTAssertEqual(post.replyCount, 3)
        XCTAssertEqual(post.isFollowing, true)
        XCTAssertNil(post.participants)
        XCTAssertEqual(post.fileIds, ["a1b2c3d4e5f6g7h8i9j0k1l2m3"])
        XCTAssertEqual(post.pendingPostId, "9fsrebgu3jdq9xf5t1rf6khtmo:1700000899000")
        XCTAssertEqual(post.props["disable_group_highlight"], .bool(true))
        XCTAssertEqual(post.props["attachments"]?[0]?["fields"]?[0]?["value"]?.stringValue, "main")

        let metadata = try XCTUnwrap(post.metadata)
        XCTAssertEqual(metadata.embeds.count, 2)
        let openGraph = try XCTUnwrap(metadata.embeds[0].openGraph)
        XCTAssertEqual(openGraph.title, "Release 2.0")
        XCTAssertEqual(openGraph.images.first?.bestURL, "https://example.com/og.png")
        XCTAssertNil(metadata.embeds[1].openGraph)
        XCTAssertEqual(metadata.embeds[1].url, "")

        XCTAssertEqual(metadata.emojis.map(\.name), ["party_parrot"])
        XCTAssertEqual(metadata.files.count, 1)
        let file = metadata.files[0]
        XCTAssertEqual(file.mimeType, "image/png")
        XCTAssertTrue(file.isImage)
        XCTAssertEqual(file.width, 1280)
        XCTAssertEqual(file.size, 48213)
        XCTAssertNotNil(file.miniPreview)
        XCTAssertEqual(metadata.images["https://example.com/og.png"], PostImage(width: 1200, height: 630, format: "png", frameCount: 0))
        XCTAssertEqual(metadata.reactions.map(\.emojiName), ["+1", "party_parrot"])
        XCTAssertEqual(metadata.reactions[1].channelId, nil)
        XCTAssertEqual(metadata.priority, PostPriority(priority: "important", requestedAck: true, persistentNotifications: false))
    }

    func testMinimalPostUsesDefaults() throws {
        let post = try decode(Post.self, #"{"id":"abc"}"#)
        XCTAssertEqual(post, Post(id: "abc"))
        XCTAssertNil(post.metadata)
        XCTAssertNil(post.isFollowing)
    }

    func testPostToleratesMistypedFields() throws {
        let json = #"""
        {"id":"abc","create_at":"1700000000000","reply_count":2.0,"is_pinned":"true","file_ids":null,"props":null,
         "metadata":{"files":[{"name":"no id"},{"id":"f1","size":"12"}],"reactions":null,"images":{"u":{"width":"10"}, "bad": 5}}}
        """#
        let post = try decode(Post.self, json)
        XCTAssertEqual(post.createAt, 1_700_000_000_000)
        XCTAssertEqual(post.replyCount, 2)
        XCTAssertTrue(post.isPinned)
        XCTAssertEqual(post.fileIds, [])
        XCTAssertEqual(post.props, [:])
        // The file without an ID is skipped instead of failing the post.
        XCTAssertEqual(post.metadata?.files.map(\.id), ["f1"])
        XCTAssertEqual(post.metadata?.files.first?.size, 12)
        XCTAssertEqual(post.metadata?.reactions, [])
        XCTAssertEqual(post.metadata?.images["u"]?.width, 10)
        XCTAssertNil(post.metadata?.images["bad"])
    }

    func testPostList() throws {
        let list = try decode(PostList.self, Fixtures.postList)
        XCTAssertEqual(list.order.count, 4)
        // The entry without an ID was dropped; the missing ID is skipped.
        XCTAssertEqual(list.posts.count, 3)
        XCTAssertEqual(list.orderedPosts.map(\.message), ["bob joined the channel.", "reply", "first"])
        XCTAssertEqual(list.prevPostId, "p0xxxxxxxxxxxxxxxxxxxxxxxx")
        XCTAssertEqual(list.nextPostId, "")
        XCTAssertEqual(list.hasNext, false)

        let reply = try XCTUnwrap(list.posts["p2xxxxxxxxxxxxxxxxxxxxxxxx"])
        XCTAssertTrue(reply.isReply)
        XCTAssertTrue(reply.isFromWebhook)
        let system = try XCTUnwrap(list.posts["p3xxxxxxxxxxxxxxxxxxxxxxxx"])
        XCTAssertTrue(system.isSystemMessage)
        XCTAssertFalse(system.isEphemeral)
    }

    func testEmptyPostList() throws {
        let list = try decode(PostList.self, #"{"order":[],"posts":{},"next_post_id":"","prev_post_id":""}"#)
        XCTAssertTrue(list.orderedPosts.isEmpty)
        XCTAssertNil(list.hasNext)
        let legacy = try decode(PostList.self, #"{"order":null,"posts":null}"#)
        XCTAssertEqual(legacy, PostList())
    }

    func testSearchResults() throws {
        let json = #"{"order":["a"],"posts":{"a":{"id":"a","message":"deploy"}},"matches":{"a":["deploy"]}}"#
        let results = try decode(PostSearchResults.self, json)
        XCTAssertEqual(results.orderedPosts.map(\.id), ["a"])
        XCTAssertEqual(results.matches["a"], ["deploy"])
    }

    func testPostDraftEncoding() throws {
        let draft = PostDraft(channelId: "c", message: "hi", rootId: "r", fileIds: ["f"], pendingPostId: "u:1", priority: PostPriority(priority: "urgent"))
        let json = try JSONValue(encoding: draft)
        XCTAssertEqual(json, [
            "channel_id": "c",
            "message": "hi",
            "root_id": "r",
            "file_ids": ["f"],
            "pending_post_id": "u:1",
            "metadata": ["priority": ["priority": "urgent", "requested_ack": false, "persistent_notifications": false]],
        ])
        let minimal = try JSONValue(encoding: PostDraft(channelId: "c", message: "hi"))
        XCTAssertEqual(minimal, ["channel_id": "c", "message": "hi"])
    }

    func testPendingPostId() {
        XCTAssertEqual(Post.makePendingPostId(userId: "u", date: Date(timeIntervalSince1970: 1_700_000_000.123)), "u:1700000000123")
    }

    func testThreads() throws {
        let list = try decode(ThreadList.self, Fixtures.threads)
        XCTAssertEqual(list.total, 2)
        XCTAssertEqual(list.totalUnreadThreads, 1)
        XCTAssertEqual(list.threads.count, 2)
        XCTAssertEqual(list.threads[0].participants.map(\.id), [Fixtures.userId, Fixtures.otherUserId])
        XCTAssertEqual(list.threads[0].post?.message, "first")
        XCTAssertEqual(list.threads[0].unreadReplies, 2)
        XCTAssertEqual(list.threads[1].participants, [])
        XCTAssertNil(list.threads[1].post)
    }

    // MARK: Files, reactions, emoji

    func testFileUploadResponse() throws {
        let response = try decode(FileUploadResponse.self, Fixtures.fileUploadResponse)
        XCTAssertEqual(response.fileInfos.map(\.id), ["f1xxxxxxxxxxxxxxxxxxxxxxxx", "f2xxxxxxxxxxxxxxxxxxxxxxxx"])
        XCTAssertEqual(response.fileInfo(forClientId: "client-2")?.name, "photo.jpg")
        XCTAssertNil(response.fileInfo(forClientId: "nope"))
        XCTAssertEqual(response.fileInfos[1].postId, "")
    }

    func testReactionEncodingUsesSnakeCase() throws {
        let json = try JSONValue(encoding: Reaction(userId: "u", postId: "p", emojiName: "+1"))
        XCTAssertEqual(json["user_id"], "u")
        XCTAssertEqual(json["post_id"], "p")
        XCTAssertEqual(json["emoji_name"], "+1")
        XCTAssertNil(json["channel_id"])
    }

    // MARK: Server

    func testClientConfig() throws {
        let config = try decode(ClientConfig.self, Fixtures.clientConfig)
        XCTAssertEqual(config.version, "9.11.1")
        XCTAssertEqual(config.serverVersion, ServerVersion(major: 9, minor: 11, patch: 1))
        XCTAssertEqual(config.buildNumber, "10234567")
        XCTAssertEqual(config.siteName, "Example Chat")
        XCTAssertTrue(config.enableCustomEmoji)
        XCTAssertEqual(config.maxFileSize, 104_857_600)
        XCTAssertEqual(config.collapsedThreads, .defaultOn)
        XCTAssertTrue(config.collapsedThreads.isAvailable)
        XCTAssertEqual(config.teammateNameDisplay, .fullName)
        XCTAssertTrue(config.enableSignUpWithGitLab)
        XCTAssertFalse(config.enableSignUpWithGoogle)
        XCTAssertTrue(config.enableSaml)
        XCTAssertTrue(config.enableMultifactorAuthentication)
        XCTAssertFalse(config.enforceMultifactorAuthentication)
        XCTAssertEqual(config.enabledSSOProviders, [.gitlab, .openid, .saml])
        // Non-string values are tolerated and converted.
        XCTAssertEqual(config["ExperimentalNumber"], "3")
    }

    func testLimitedClientConfig() throws {
        let config = try decode(ClientConfig.self, #"{"Version":"7.8.0","SiteName":"Old"}"#)
        XCTAssertEqual(config.collapsedThreads, .disabled)
        XCTAssertNil(config.maxFileSize)
        XCTAssertFalse(config.enableCustomEmoji)
        XCTAssertEqual(config.enabledSSOProviders, [])
    }

    func testClientLicense() throws {
        let license = try decode(ClientLicense.self, Fixtures.clientLicense)
        XCTAssertTrue(license.isLicensed)
        XCTAssertEqual(license.skuShortName, "professional")
        XCTAssertFalse(license.isCloud)
        XCTAssertFalse(try decode(ClientLicense.self, #"{"IsLicensed":"false"}"#).isLicensed)
    }

    func testServerVersionParsing() {
        XCTAssertEqual(ServerVersion("9.11.1.10234567.abc.true"), ServerVersion(major: 9, minor: 11, patch: 1))
        XCTAssertEqual(ServerVersion("10.0.0-rc2"), ServerVersion(major: 10))
        XCTAssertEqual(ServerVersion("8"), ServerVersion(major: 8))
        XCTAssertNil(ServerVersion("dev"))
        XCTAssertLessThan(ServerVersion(major: 9, minor: 2), ServerVersion(major: 9, minor: 11))
    }

    func testAppError() throws {
        let error = try decode(AppError.self, Fixtures.appError)
        XCTAssertEqual(error.id, "api.user.login.invalid_credentials_email_username")
        XCTAssertEqual(error.statusCode, 401)
        XCTAssertEqual(error.requestId, "zq8s8bxfb7gc8b5xzmq9jhqiwy")
        XCTAssertEqual(error.errorDescription, "Enter a valid email or username and/or password.")
    }

    func testPingResponse() throws {
        let ping = try decode(PingResponse.self, #"{"status":"OK","ActiveSearchBackend":"database","database_status":"OK"}"#)
        XCTAssertTrue(ping.isOK)
        XCTAssertEqual(ping.fields["ActiveSearchBackend"], "database")
    }

    // MARK: Integrations

    func testAutocompleteSuggestionsAcceptBothKeyStyles() throws {
        let suggestions = try decode([AutocompleteSuggestion].self, Fixtures.autocompleteSuggestions)
        XCTAssertEqual(suggestions, [
            AutocompleteSuggestion(complete: "giphy", suggestion: "/giphy", hint: "[text]", description: "Post a GIF"),
            AutocompleteSuggestion(complete: "away", suggestion: "/away", description: "Set your status away"),
        ])
    }

    func testCommandResponse() throws {
        let json = #"{"response_type":"ephemeral","text":"Done","goto_location":"","trigger_id":"t1","skip_slack_parsing":false,"attachments":null}"#
        let response = try decode(CommandResponse.self, json)
        XCTAssertEqual(response.responseType, "ephemeral")
        XCTAssertEqual(response.triggerId, "t1")
        XCTAssertEqual(response.attachments, [])
    }

    func testOpenGraph() throws {
        let graph = try decode(OpenGraph.self, Fixtures.openGraph)
        XCTAssertEqual(graph.siteName, "Mattermost")
        XCTAssertEqual(graph.images.first?.bestURL, "https://mattermost.com/og.png")
        XCTAssertEqual(graph.videos, [])
    }

    func testDialogSubmissionResponse() throws {
        let response = try decode(DialogSubmissionResponse.self, #"{"errors":{"name":"Required"}}"#)
        XCTAssertEqual(response.errors, ["name": "Required"])
        XCTAssertEqual(response.error, "")
    }

    // MARK: Round trips

    func testModelsRoundTripThroughEncoding() throws {
        let post = try decode(Post.self, Fixtures.post)
        XCTAssertEqual(try JSONDecoder().decode(Post.self, from: JSONEncoder().encode(post)), post)
        let user = try decode(User.self, Fixtures.user)
        XCTAssertEqual(try JSONDecoder().decode(User.self, from: JSONEncoder().encode(user)), user)
        let channels = try decode([Channel].self, Fixtures.channels)
        XCTAssertEqual(try JSONDecoder().decode([Channel].self, from: JSONEncoder().encode(channels)), channels)
        let config = try decode(ClientConfig.self, Fixtures.clientConfig)
        XCTAssertEqual(try JSONDecoder().decode(ClientConfig.self, from: JSONEncoder().encode(config)), config)
    }
}

final class DialogValidationTests: XCTestCase {
    func testRequiredAndOptional() {
        let required = DialogElement(name: "a", type: "text")
        XCTAssertEqual(required.validate(nil), .required)
        XCTAssertEqual(required.validate(.string("  ")), .required)
        XCTAssertNil(required.validate(.string("x")))
        XCTAssertNil(DialogElement(name: "b", type: "text", optional: true).validate(nil))
        XCTAssertEqual(DialogElement(name: "c", type: "select").validate(nil), .required)
        XCTAssertNil(DialogElement(name: "d", type: "bool").validate(nil))
    }

    func testLengthsAndSubtypes() {
        let text = DialogElement(name: "a", type: "text", minLength: 3, maxLength: 5)
        XCTAssertEqual(text.validate(.string("ab")), .tooShort(minLength: 3))
        XCTAssertEqual(text.validate(.string("abcdef")), .tooLong(maxLength: 5))
        XCTAssertNil(text.validate(.string("abcd")))
        XCTAssertEqual(DialogElement(name: "e", type: "text", subtype: "email").validate(.string("nope")), .invalidEmail)
        XCTAssertNil(DialogElement(name: "e", type: "text", subtype: "email").validate(.string("a@b.c")))
        XCTAssertEqual(DialogElement(name: "n", type: "text", subtype: "number").validate(.string("12a")), .invalidNumber)
        XCTAssertEqual(DialogElement(name: "u", type: "text", subtype: "url").validate(.string("example.com")), .invalidURL)
        XCTAssertNil(DialogElement(name: "u", type: "text", subtype: "url").validate(.string("https://example.com")))
    }

    func testSubmissionValues() {
        let number = DialogElement(name: "n", type: "text", subtype: "number")
        XCTAssertEqual(number.submissionValue(text: "42"), .int(42))
        XCTAssertEqual(number.submissionValue(text: "4.5"), .double(4.5))
        XCTAssertEqual(DialogElement(name: "t", type: "text").submissionValue(text: "42"), .string("42"))
        XCTAssertEqual(DialogElement(name: "b", type: "bool", defaultValue: "true").defaultSubmissionValue, .bool(true))
        XCTAssertEqual(DialogElement(name: "b", type: "bool").defaultSubmissionValue, .bool(false))
        XCTAssertEqual(DialogElement(name: "s", type: "select", defaultValue: "prod").defaultSubmissionValue, .string("prod"))
        XCTAssertNil(DialogElement(name: "s", type: "select").defaultSubmissionValue)
    }
}
