import XCTest
@testable import MattermostKit

final class RequestBuildingTests: StubbedClientTestCase {
    private let post = #"{"id":"pppppppppppppppppppppppppp"}"#
    private let channel = #"{"id":"cccccccccccccccccccccccccc"}"#

    /// Runs `call` against the stub and checks the request it produced.
    private func check(
        _ call: (MattermostClient) async throws -> Void,
        response: String = "{}",
        method: String,
        path: String,
        query: [String: String] = [:],
        body: JSONValue? = nil,
        authenticated: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        StubURLProtocol.reset()
        StubURLProtocol.respond(with: .json(response))
        let client = makeClient()
        do {
            try await call(client)
        } catch {
            XCTFail("Request failed: \(error)", file: file, line: line)
            return
        }
        guard let request = StubURLProtocol.lastRequest else {
            XCTFail("No request sent", file: file, line: line)
            return
        }
        XCTAssertEqual(request.method, method, file: file, line: line)
        XCTAssertEqual(request.path, path, file: file, line: line)
        XCTAssertEqual(request.query, query, file: file, line: line)
        XCTAssertEqual(request.jsonBody, body, file: file, line: line)
        XCTAssertEqual(request.header("Authorization"), authenticated ? "Bearer tok3n" : nil, file: file, line: line)
        XCTAssertEqual(request.header("X-Requested-With"), "XMLHttpRequest", file: file, line: line)
        if body != nil {
            XCTAssertEqual(request.header("Content-Type"), "application/json", file: file, line: line)
        }
    }

    // MARK: Server and auth

    func testServerEndpoints() async {
        await check({ _ = try await $0.ping() }, response: #"{"status":"OK"}"#, method: "GET", path: "/api/v4/system/ping", authenticated: false)
        await check({ _ = try await $0.ping(getServerStatus: true) }, response: #"{"status":"OK"}"#, method: "GET", path: "/api/v4/system/ping", query: ["get_server_status": "true"], authenticated: false)
        await check({ _ = try await $0.clientConfig() }, method: "GET", path: "/api/v4/config/client", query: ["format": "old"])
        await check({ _ = try await $0.clientLicense() }, method: "GET", path: "/api/v4/license/client", query: ["format": "old"])
    }

    func testDeviceAndLogout() async {
        await check({ try await $0.attachDevice(deviceId: "apple_rn-v2:abcdef") }, method: "PUT", path: "/api/v4/users/sessions/device", body: ["device_id": "apple_rn-v2:abcdef"])
        await check({ try await $0.logout() }, method: "POST", path: "/api/v4/users/logout")
    }

    // MARK: Me and teams

    func testMeAndTeams() async {
        await check({ _ = try await $0.me() }, response: Fixtures.user, method: "GET", path: "/api/v4/users/me")
        await check({ _ = try await $0.preferences() }, response: "[]", method: "GET", path: "/api/v4/users/me/preferences")
        await check({ _ = try await $0.teams() }, response: "[]", method: "GET", path: "/api/v4/users/me/teams")
        await check({ _ = try await $0.teamMembers() }, response: "[]", method: "GET", path: "/api/v4/users/me/teams/members")
        await check({ _ = try await $0.teamsUnread(includeCollapsedThreads: true) }, response: "[]", method: "GET", path: "/api/v4/users/me/teams/unread", query: ["include_collapsed_threads": "true"])
        await check({ _ = try await $0.teamsUnread(userId: "u1", excludeTeamId: "t1") }, response: "[]", method: "GET", path: "/api/v4/users/u1/teams/unread", query: ["exclude_team": "t1"])
    }

    func testPreferenceWrites() async {
        let preference = Preference(userId: "u1", category: "favorite_channel", name: "c1", value: "true")
        let expected: JSONValue = [["user_id": "u1", "category": "favorite_channel", "name": "c1", "value": "true"]]
        await check({ try await $0.savePreferences([preference]) }, method: "PUT", path: "/api/v4/users/me/preferences", body: expected)
        await check({ try await $0.deletePreferences([preference]) }, method: "POST", path: "/api/v4/users/me/preferences/delete", body: expected)
    }

    // MARK: Channels

    func testChannelReads() async {
        await check({ _ = try await $0.channels(teamId: "t1") }, response: "[]", method: "GET", path: "/api/v4/users/me/teams/t1/channels")
        await check({ _ = try await $0.channels(teamId: "t1", includeDeleted: true, lastDeleteAt: 0) }, response: "[]", method: "GET", path: "/api/v4/users/me/teams/t1/channels", query: ["include_deleted": "true", "last_delete_at": "0"])
        await check({ _ = try await $0.channelMembers(teamId: "t1") }, response: "[]", method: "GET", path: "/api/v4/users/me/teams/t1/channels/members")
        await check({ _ = try await $0.sidebarCategories(teamId: "t1") }, method: "GET", path: "/api/v4/users/me/teams/t1/channels/categories")
        await check({ _ = try await $0.publicChannels(teamId: "t1", page: 2, perPage: 50) }, response: "[]", method: "GET", path: "/api/v4/teams/t1/channels", query: ["page": "2", "per_page": "50"])
        await check({ _ = try await $0.channel(id: "c1") }, response: channel, method: "GET", path: "/api/v4/channels/c1")
        await check({ _ = try await $0.channelMember(channelId: "c1") }, method: "GET", path: "/api/v4/channels/c1/members/me")
        await check({ _ = try await $0.channelStats(channelId: "c1") }, method: "GET", path: "/api/v4/channels/c1/stats")
        await check({ _ = try await $0.pinnedPosts(channelId: "c1") }, method: "GET", path: "/api/v4/channels/c1/pinned")
    }

    func testChannelWrites() async {
        await check(
            { try await $0.viewChannel(channelId: "c1", previousChannelId: "c0") },
            response: #"{"status":"OK","last_viewed_at_times":{"c1":1700000000000}}"#,
            method: "POST",
            path: "/api/v4/channels/members/me/view",
            body: ["channel_id": "c1", "prev_channel_id": "c0", "collapsed_threads_supported": true]
        )
        await check(
            { _ = try await $0.createChannel(ChannelDraft(teamId: "t1", name: "ops", displayName: "Ops", type: .privateChannel, purpose: "p")) },
            response: channel,
            method: "POST",
            path: "/api/v4/channels",
            body: ["team_id": "t1", "name": "ops", "display_name": "Ops", "type": "P", "purpose": "p", "header": ""]
        )
        await check({ _ = try await $0.createDirectChannel(userId: "u1", otherUserId: "u2") }, response: channel, method: "POST", path: "/api/v4/channels/direct", body: ["u1", "u2"])
        await check({ _ = try await $0.createGroupChannel(userIds: ["u1", "u2", "u3"]) }, response: channel, method: "POST", path: "/api/v4/channels/group", body: ["u1", "u2", "u3"])
        await check({ try await $0.addChannelMember(channelId: "c1", userId: "u2") }, method: "POST", path: "/api/v4/channels/c1/members", body: ["user_id": "u2"])
        await check({ try await $0.removeChannelMember(channelId: "c1") }, method: "DELETE", path: "/api/v4/channels/c1/members/me")
        await check({ try await $0.updateChannelNotifyProps(channelId: "c1", props: ["mark_unread": "mention"]) }, response: #"{"status":"OK"}"#, method: "PUT", path: "/api/v4/channels/c1/members/me/notify_props", body: ["mark_unread": "mention"])
        await check(
            { try await $0.updateSidebarCategories([SidebarCategory(id: "cat1", userId: "u1", teamId: "t1", sortOrder: 0, sorting: "manual", type: .favorites, displayName: "Favorites", channelIds: ["c1", "c2"])], teamId: "t1") },
            response: "[]",
            method: "PUT",
            path: "/api/v4/users/me/teams/t1/channels/categories",
            body: [["id": "cat1", "user_id": "u1", "team_id": "t1", "sort_order": 0, "sorting": "manual", "type": "favorites", "display_name": "Favorites", "muted": false, "collapsed": false, "channel_ids": ["c1", "c2"]]]
        )
    }

    // MARK: Posts

    func testPostReads() async {
        await check({ _ = try await $0.posts(channelId: "c1", perPage: 60, before: "p9") }, method: "GET", path: "/api/v4/channels/c1/posts", query: ["before": "p9", "per_page": "60"])
        await check({ _ = try await $0.posts(channelId: "c1", perPage: 60, after: "p1") }, method: "GET", path: "/api/v4/channels/c1/posts", query: ["after": "p1", "per_page": "60"])
        await check({ _ = try await $0.posts(channelId: "c1", since: 1_700_000_000_000) }, method: "GET", path: "/api/v4/channels/c1/posts", query: ["since": "1700000000000"])
        await check(
            { _ = try await $0.posts(channelId: "c1", page: 0, perPage: 30, includeDeleted: true, collapsedThreads: true, collapsedThreadsExtended: true) },
            method: "GET",
            path: "/api/v4/channels/c1/posts",
            query: ["page": "0", "per_page": "30", "include_deleted": "true", "collapsedThreads": "true", "collapsedThreadsExtended": "true"]
        )
        await check({ _ = try await $0.post(id: "p1") }, response: post, method: "GET", path: "/api/v4/posts/p1")
        await check({ _ = try await $0.postThread(postId: "p1") }, method: "GET", path: "/api/v4/posts/p1/thread")
        await check(
            { _ = try await $0.postThread(postId: "p1", options: PostThreadOptions(perPage: 50, fromPost: "p5", fromCreateAt: 17, direction: .down, collapsedThreads: true)) },
            method: "GET",
            path: "/api/v4/posts/p1/thread",
            query: ["perPage": "50", "fromPost": "p5", "fromCreateAt": "17", "direction": "down", "collapsedThreads": "true"]
        )
    }

    func testPostWrites() async {
        await check(
            { _ = try await $0.createPost(PostDraft(channelId: "c1", message: "hi", rootId: "r1", fileIds: ["f1"], pendingPostId: "u1:1"), setOnline: false) },
            response: post,
            method: "POST",
            path: "/api/v4/posts",
            query: ["set_online": "false"],
            body: ["channel_id": "c1", "message": "hi", "root_id": "r1", "file_ids": ["f1"], "pending_post_id": "u1:1"]
        )
        await check({ _ = try await $0.patchPost(id: "p1", patch: PostPatch(message: "edited")) }, response: post, method: "PUT", path: "/api/v4/posts/p1/patch", body: ["message": "edited"])
        await check({ try await $0.deletePost(id: "p1") }, method: "DELETE", path: "/api/v4/posts/p1")
        await check({ try await $0.markPostUnread(postId: "p1") }, method: "POST", path: "/api/v4/users/me/posts/p1/set_unread", body: ["collapsed_threads_supported": true])
        await check(
            { _ = try await $0.searchPosts(teamId: "t1", options: PostSearchOptions(terms: "deploy from:bob", timeZoneOffset: 3600, perPage: 20)) },
            method: "POST",
            path: "/api/v4/teams/t1/posts/search",
            body: ["terms": "deploy from:bob", "is_or_search": false, "time_zone_offset": 3600, "include_deleted_channels": false, "page": 0, "per_page": 20]
        )
    }

    // MARK: Threads and reactions

    func testThreads() async {
        await check({ _ = try await $0.userThreads(teamId: "t1") }, method: "GET", path: "/api/v4/users/me/teams/t1/threads")
        await check(
            { _ = try await $0.userThreads(teamId: "t1", options: UserThreadsOptions(since: 5, before: "th1", perPage: 25, extended: true, unreadOnly: true)) },
            method: "GET",
            path: "/api/v4/users/me/teams/t1/threads",
            query: ["since": "5", "before": "th1", "per_page": "25", "extended": "true", "unread": "true"]
        )
        await check(
            { _ = try await $0.userThread(teamId: "t1", threadId: "th1", extended: true) },
            response: #"{"id":"th1","reply_count":3,"unread_replies":1}"#,
            method: "GET",
            path: "/api/v4/users/me/teams/t1/threads/th1",
            query: ["extended": "true"]
        )
        await check({ try await $0.markThreadRead(teamId: "t1", threadId: "th1", timestamp: 1_700_000_000_000) }, method: "PUT", path: "/api/v4/users/me/teams/t1/threads/th1/read/1700000000000")
        await check({ try await $0.followThread(teamId: "t1", threadId: "th1") }, method: "PUT", path: "/api/v4/users/me/teams/t1/threads/th1/following")
        await check({ try await $0.unfollowThread(teamId: "t1", threadId: "th1") }, method: "DELETE", path: "/api/v4/users/me/teams/t1/threads/th1/following")
    }

    func testReactions() async {
        await check(
            { try await $0.addReaction(userId: "u1", postId: "p1", emojiName: "+1") },
            response: #"{"user_id":"u1","post_id":"p1","emoji_name":"+1"}"#,
            method: "POST",
            path: "/api/v4/reactions",
            body: ["user_id": "u1", "post_id": "p1", "emoji_name": "+1", "create_at": 0, "update_at": 0, "delete_at": 0]
        )
        await check({ try await $0.removeReaction(postId: "p1", emojiName: "+1") }, method: "DELETE", path: "/api/v4/users/me/posts/p1/reactions/+1")
        // `+` must stay literal in the path so the server's route pattern matches.
        XCTAssertTrue(StubURLProtocol.lastRequest?.url.absoluteString.hasSuffix("/reactions/+1") == true)
    }

    // MARK: Users and emoji

    func testUsers() async {
        await check({ _ = try await $0.users(ids: ["u1", "u2"]) }, response: "[]", method: "POST", path: "/api/v4/users/ids", body: ["u1", "u2"])
        await check({ _ = try await $0.users(ids: ["u1"], since: 99) }, response: "[]", method: "POST", path: "/api/v4/users/ids", query: ["since": "99"], body: ["u1"])
        await check({ _ = try await $0.users(usernames: ["alice"]) }, response: "[]", method: "POST", path: "/api/v4/users/usernames", body: ["alice"])
        await check({ _ = try await $0.userStatuses(ids: ["u1"]) }, response: "[]", method: "POST", path: "/api/v4/users/status/ids", body: ["u1"])
        await check(
            { _ = try await $0.autocompleteUsers(name: "al", teamId: "t1", channelId: "c1", limit: 25) },
            method: "GET",
            path: "/api/v4/users/autocomplete",
            query: ["in_team": "t1", "in_channel": "c1", "name": "al", "limit": "25"]
        )
        await check(
            { _ = try await $0.searchUsers(UserSearchOptions(term: "ali", teamId: "t1", limit: 10)) },
            response: "[]",
            method: "POST",
            path: "/api/v4/users/search",
            body: ["term": "ali", "team_id": "t1", "limit": 10]
        )
        await check({ _ = try await $0.user(id: "u1") }, response: Fixtures.user, method: "GET", path: "/api/v4/users/u1")
    }

    func testMembersRolesAndAutocomplete() async {
        await check({ _ = try await $0.channelMembers(channelId: "c1", page: 2, perPage: 64) }, response: "[]", method: "GET", path: "/api/v4/channels/c1/members", query: ["page": "2", "per_page": "64"])
        await check({ _ = try await $0.channelMembers(channelId: "c1", userIds: ["u1", "u2"]) }, response: "[]", method: "POST", path: "/api/v4/channels/c1/members/ids", body: ["u1", "u2"])
        await check({ _ = try await $0.autocompleteChannels(teamId: "t1", name: "rel") }, response: "[]", method: "GET", path: "/api/v4/teams/t1/channels/autocomplete", query: ["name": "rel"])
        await check({ _ = try await $0.roles(names: ["system_user", "channel_user"]) }, response: "[]", method: "POST", path: "/api/v4/roles/names", body: ["system_user", "channel_user"])
        await check({ _ = try await $0.autocompleteCustomEmoji(name: "par") }, response: "[]", method: "GET", path: "/api/v4/emoji/autocomplete", query: ["name": "par"])
    }

    func testEmoji() async {
        await check({ _ = try await $0.customEmojis(page: 0, perPage: 200, sort: "name") }, response: "[]", method: "GET", path: "/api/v4/emoji", query: ["page": "0", "per_page": "200", "sort": "name"])
        await check({ _ = try await $0.customEmoji(name: "party_parrot") }, response: #"{"id":"e1","name":"party_parrot"}"#, method: "GET", path: "/api/v4/emoji/name/party_parrot")
    }

    // MARK: Integrations, push, misc

    func testIntegrations() async {
        await check(
            { _ = try await $0.commandAutocompleteSuggestions(teamId: "t1", userInput: "/giphy a+b&c", channelId: "c1", rootId: "r1") },
            response: "[]",
            method: "GET",
            path: "/api/v4/teams/t1/commands/autocomplete_suggestions",
            query: ["user_input": "/giphy a+b&c", "channel_id": "c1", "root_id": "r1"]
        )
        // Go decodes `+` in queries as a space, so it must be escaped.
        XCTAssertEqual(StubURLProtocol.lastRequest?.rawQuery, "user_input=%2Fgiphy%20a%2Bb%26c&channel_id=c1&root_id=r1")

        await check(
            { _ = try await $0.executeCommand("/echo hi", channelId: "c1", teamId: "t1") },
            response: #"{"response_type":"in_channel"}"#,
            method: "POST",
            path: "/api/v4/commands/execute",
            body: ["command": "/echo hi", "channel_id": "c1", "team_id": "t1"]
        )
        await check(
            { _ = try await $0.performPostAction(postId: "p1", actionId: "approve", selectedOption: "yes") },
            response: #"{"status":"OK"}"#,
            method: "POST",
            path: "/api/v4/posts/p1/actions/approve",
            body: ["selected_option": "yes"]
        )
        let submission = DialogSubmission(url: "https://hook", callbackId: "cb", state: "s", userId: "u1", channelId: "c1", teamId: "t1", submission: ["name": "x"])
        await check(
            { _ = try await $0.submitDialog(submission) },
            response: "",
            method: "POST",
            path: "/api/v4/actions/dialogs/submit",
            body: ["type": "dialog_submission", "url": "https://hook", "callback_id": "cb", "state": "s", "user_id": "u1", "channel_id": "c1", "team_id": "t1", "submission": ["name": "x"], "cancelled": false]
        )
    }

    func testPushAckAndOpenGraph() async {
        await check(
            { try await $0.acknowledgeNotification(PushNotificationAck(id: "ack1", type: "message", postId: "p1", receivedAt: 1_700_000_000_000)) },
            response: #"{"status":"OK"}"#,
            method: "POST",
            path: "/api/v4/notifications/ack",
            body: ["id": "ack1", "platform": "apple", "type": "message", "post_id": "p1", "is_id_loaded": false, "received_at": 1_700_000_000_000]
        )
        await check({ _ = try await $0.openGraph(url: "https://mattermost.com") }, response: Fixtures.openGraph, method: "POST", path: "/api/v4/opengraph", body: ["url": "https://mattermost.com"])
    }

    func testFileInfo() async {
        await check({ _ = try await $0.fileInfo(id: "f1") }, response: #"{"id":"f1"}"#, method: "GET", path: "/api/v4/files/f1/info")
    }

    // MARK: Headers and URLs

    func testCommonHeaders() async throws {
        StubURLProtocol.respond(with: .json("[]"))
        let client = makeClient(userAgent: "MattermostKitTests/1.0")
        _ = try await client.teams()
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.header("Authorization"), "Bearer tok3n")
        XCTAssertEqual(request.header("X-Requested-With"), "XMLHttpRequest")
        XCTAssertEqual(request.header("User-Agent"), "MattermostKitTests/1.0")
        XCTAssertEqual(request.header("Accept"), "application/json")
        XCTAssertNil(request.header("Content-Type"))
        XCTAssertFalse(request.request.httpShouldHandleCookies)
    }

    func testNoAuthorizationHeaderWithoutToken() async throws {
        StubURLProtocol.respond(with: .json("[]"))
        _ = try await makeClient(token: nil).teams()
        XCTAssertNil(StubURLProtocol.lastRequest?.header("Authorization"))
    }

    func testServerURLWithSubpath() async throws {
        StubURLProtocol.respond(with: .json("[]"))
        let client = makeClient(serverURL: URL(string: "https://example.com/mattermost/")!)
        _ = try await client.teams()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url.absoluteString, "https://example.com/mattermost/api/v4/users/me/teams")
        XCTAssertEqual(client.apiBaseURL.absoluteString, "https://example.com/mattermost/api/v4")
    }

    func testPathSegmentsAreEncoded() async throws {
        StubURLProtocol.respond(with: .json(#"{"id":"e"}"#))
        _ = try await makeClient().customEmoji(name: "a/b c")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url.absoluteString, "https://chat.example.com/api/v4/emoji/name/a%2Fb%20c")
    }

    func testTokenCanChange() async throws {
        StubURLProtocol.respond(with: .json("[]"))
        let client = makeClient(token: "first")
        client.setToken("second")
        _ = try await client.teams()
        XCTAssertEqual(StubURLProtocol.lastRequest?.header("Authorization"), "Bearer second")
        XCTAssertEqual(client.token, "second")
    }
}
