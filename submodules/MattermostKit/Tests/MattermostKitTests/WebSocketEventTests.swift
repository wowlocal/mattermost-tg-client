import XCTest
@testable import MattermostKit

final class WebSocketEventTests: XCTestCase {
    private func event(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> WebSocketEvent {
        guard case .event(let event)? = WebSocketMessage(text: text) else {
            XCTFail("Not an event: \(text)", file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        return event
    }

    func testHello() throws {
        let event = try event(Fixtures.hello(connectionId: "rtz3bpu8wtgu7q8nskpqzfo4pc"))
        XCTAssertEqual(event.type, .hello)
        XCTAssertEqual(event.seq, 0)
        XCTAssertEqual(event.broadcast.userId, Fixtures.userId)
        XCTAssertEqual(event.hello, HelloEvent(connectionId: "rtz3bpu8wtgu7q8nskpqzfo4pc", serverVersion: "9.11.1.10234567.f4b4f3a6b0b84d7e.true"))
        XCTAssertEqual(event.hello?.serverVersion.flatMap(ServerVersion.init), ServerVersion(major: 9, minor: 11, patch: 1))
        XCTAssertNil(event.posted)
    }

    func testPosted() throws {
        let event = try event(Fixtures.posted)
        XCTAssertEqual(event.type, .posted)
        XCTAssertEqual(event.seq, 1)
        XCTAssertEqual(event.broadcast.channelId, Fixtures.channelId)
        let posted = try XCTUnwrap(event.posted)
        XCTAssertEqual(posted.post.id, "n3wp0stxxxxxxxxxxxxxxxxxxx")
        XCTAssertEqual(posted.post.message, "hello @alice")
        XCTAssertEqual(posted.post.pendingPostId, "kq7xqbs6ofbbpmcs9ycw1mn1yc:1700001099000")
        XCTAssertEqual(posted.channelType, .publicChannel)
        XCTAssertEqual(posted.channelName, "town-square")
        XCTAssertEqual(posted.channelDisplayName, "Town Square")
        XCTAssertEqual(posted.senderName, "@bob")
        XCTAssertEqual(posted.teamId, Fixtures.teamId)
        XCTAssertEqual(posted.mentions, [Fixtures.userId])
        XCTAssertEqual(posted.followers, [Fixtures.otherUserId])
        XCTAssertEqual(posted.setOnline, true)
    }

    func testOpenDialog() throws {
        // As 11.7 sends it: `data.dialog` is the JSON-encoded `OpenDialogRequest`.
        let dialog = #"{"trigger_id":"tr1","url":"http://localhost:8099/dialog","dialog":{"callback_id":"cb","title":"Deploy","introduction_text":"**Pick** a target","icon_url":"","elements":[{"display_name":"Name","name":"name","type":"text","subtype":"","default":"web","placeholder":"","help_text":"The service","optional":false,"min_length":2,"max_length":20,"data_source":"","options":null},{"display_name":"Env","name":"env","type":"select","default":"","optional":true,"options":[{"text":"Production","value":"prod"}]},{"display_name":"Notify","name":"notify","type":"bool","default":"true"}],"submit_label":"Go","notify_on_cancel":true,"state":"s1"}}"#
        let data = try JSONEncoder().encode(["dialog": dialog])
        let text = #"{"event":"open_dialog","data":"# + String(decoding: data, as: UTF8.self) + #","broadcast":{"user_id":"u1"},"seq":7}"#
        let event = try event(text)
        XCTAssertEqual(event.type, .openDialog)
        let request = try XCTUnwrap(event.openDialog)
        XCTAssertEqual(request.triggerId, "tr1")
        XCTAssertEqual(request.url, "http://localhost:8099/dialog")
        XCTAssertEqual(request.dialog.title, "Deploy")
        XCTAssertEqual(request.dialog.submitLabel, "Go")
        XCTAssertTrue(request.dialog.notifyOnCancel)
        XCTAssertEqual(request.dialog.elements.map(\.kind), [.text, .select, .bool])
        XCTAssertEqual(request.dialog.elements[0].defaultValue, "web")
        XCTAssertEqual(request.dialog.elements[0].minLength, 2)
        XCTAssertEqual(request.dialog.elements[0].helpText, "The service")
        XCTAssertEqual(request.dialog.elements[1].options, [DialogOption(text: "Production", value: "prod")])
        XCTAssertTrue(request.dialog.elements[1].optional)
        XCTAssertEqual(request.dialog.elements[2].defaultValue, "true")
        XCTAssertNil(event.posted)
    }

    func testPostedWithoutOptionalFields() throws {
        let text = #"{"event":"posted","data":{"post":"{\"id\":\"p1\",\"message\":\"m\"}"},"broadcast":{},"seq":3}"#
        let posted = try XCTUnwrap(try event(text).posted)
        XCTAssertEqual(posted.mentions, [])
        XCTAssertNil(posted.channelType)
        XCTAssertNil(posted.setOnline)
    }

    func testPostEditedAndDeleted() throws {
        let edited = try XCTUnwrap(try event(Fixtures.postEdited).editedPost)
        XCTAssertEqual(edited.message, "hello @alice (edited)")
        XCTAssertTrue(edited.isEdited)

        let deleted = try XCTUnwrap(try event(Fixtures.postDeleted).deletedPost)
        XCTAssertEqual(deleted.id, "n3wp0stxxxxxxxxxxxxxxxxxxx")
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertNil(try event(Fixtures.postDeleted).editedPost)
    }

    func testReactions() throws {
        let added = try event(Fixtures.reactionAdded)
        XCTAssertEqual(added.type, .reactionAdded)
        XCTAssertEqual(added.reaction, Reaction(userId: Fixtures.otherUserId, postId: "n3wp0stxxxxxxxxxxxxxxxxxxx", emojiName: "+1", createAt: 1_700_001_400_000, updateAt: 1_700_001_400_000, remoteId: "", channelId: Fixtures.channelId))

        let removed = try event(Fixtures.reactionRemoved)
        XCTAssertEqual(removed.type, .reactionRemoved)
        XCTAssertEqual(removed.reaction?.emojiName, "+1")
        // Broadcast fields missing from the frame default to empty.
        XCTAssertEqual(removed.broadcast.userId, "")
    }

    func testChannelViewed() throws {
        XCTAssertEqual(try event(Fixtures.channelViewed).channelViewed, ChannelViewedEvent(channelId: Fixtures.channelId, userId: Fixtures.userId))
        XCTAssertEqual(try event(Fixtures.multipleChannelsViewed).multipleChannelsViewed, [
            Fixtures.channelId: 1_700_001_500_000,
            "pb1bt4wqepdj8xg6ymbiec1ydh": 1_700_001_500_001,
        ])
    }

    func testChannelsViewedCoversBothServerVariants() throws {
        // Older servers: channel_viewed, no timestamp.
        XCTAssertEqual(try event(Fixtures.channelViewed).channelsViewed, ChannelsViewedEvent(channelIds: [Fixtures.channelId], lastViewedAt: [:]))
        // Mattermost 11.x: only multiple_channels_viewed.
        XCTAssertEqual(try event(Fixtures.multipleChannelsViewed).channelsViewed, ChannelsViewedEvent(
            channelIds: [Fixtures.channelId, "pb1bt4wqepdj8xg6ymbiec1ydh"],
            lastViewedAt: [Fixtures.channelId: 1_700_001_500_000, "pb1bt4wqepdj8xg6ymbiec1ydh": 1_700_001_500_001]
        ))
        XCTAssertNil(try event(Fixtures.statusChange).channelsViewed)
    }

    func testTypingAndStatus() throws {
        let typing = try event(Fixtures.typing(seq: 4))
        XCTAssertEqual(typing.typing, TypingEvent(userId: Fixtures.otherUserId, channelId: Fixtures.channelId, parentId: ""))
        XCTAssertEqual(typing.broadcast.omitUsers, [Fixtures.otherUserId: true])

        XCTAssertEqual(try event(Fixtures.statusChange).statusChange, StatusChangeEvent(userId: Fixtures.otherUserId, status: .away))
    }

    func testThreadUpdated() throws {
        let thread = try XCTUnwrap(try event(Fixtures.threadUpdated).updatedThread)
        XCTAssertEqual(thread.id, "p1xxxxxxxxxxxxxxxxxxxxxxxx")
        XCTAssertEqual(thread.replyCount, 5)
        XCTAssertEqual(thread.unreadReplies, 2)
        XCTAssertEqual(thread.post?.message, "first")
    }

    func testUnknownEventIsPreserved() throws {
        let event = try event(#"{"event":"custom_com.mattermost.calls_call_start","data":{"id":"x"},"broadcast":{"channel_id":"c"},"seq":11}"#)
        XCTAssertEqual(event.type, .unknown("custom_com.mattermost.calls_call_start"))
        XCTAssertEqual(event.data["id"], "x")
    }

    func testEventTypeRawValues() {
        XCTAssertEqual(WebSocketEventType(rawValue: "sidebar_category_order_updated"), .sidebarCategoryOrderUpdated)
        XCTAssertEqual(WebSocketEventType.threadReadChanged.rawValue, "thread_read_changed")
        XCTAssertEqual(WebSocketEventType.unknown("x").rawValue, "x")
    }

    func testReplies() {
        guard case .response(let pong)? = WebSocketMessage(text: Fixtures.pongReply) else {
            return XCTFail("Expected a response")
        }
        XCTAssertTrue(pong.isOK)
        XCTAssertEqual(pong.seqReply, 5)
        XCTAssertEqual(pong.data["text"], "pong")

        guard case .response(let failed)? = WebSocketMessage(text: Fixtures.failedReply) else {
            return XCTFail("Expected a response")
        }
        XCTAssertFalse(failed.isOK)
        XCTAssertEqual(failed.error?.id, "api.web_socket_router.bad_action.app_error")
    }

    func testMalformedFrames() {
        XCTAssertNil(WebSocketMessage(text: "not json"))
        XCTAssertNil(WebSocketMessage(text: "[1,2]"))
        XCTAssertNil(WebSocketMessage(text: #"{"data":{}}"#))
        XCTAssertNil(WebSocketMessage(text: #"{"event":5}"#))
    }

    func testActionEncoding() throws {
        let text = MattermostWebSocket.encodeAction("user_typing", sequence: 3, data: ["channel_id": "c1", "parent_id": ""])
        XCTAssertEqual(try JSONValue.parse(Data(text.utf8)), ["action": "user_typing", "seq": 3, "data": ["channel_id": "c1", "parent_id": ""]])
    }
}
