import XCTest
@testable import MattermostSyncCore

final class UserDisplayNameTests: XCTestCase {
    private func names(_ format: String, first: String = "Bob", last: String = "Brennan", nickname: String = "", username: String = "bob") -> (String, String?) {
        let names = UserDisplayName.peerNames(username: username, firstName: first, lastName: last, nickname: nickname, format: format)
        return (names.first, names.last)
    }

    func testUsernameFormat() {
        XCTAssertTrue(names("username") == ("bob", nil))
        XCTAssertTrue(names("username", nickname: "Bobby") == ("bob", nil))
        // Unknown values (a newer server) name users as the server's default does: by username.
        XCTAssertTrue(names("something_new") == ("bob", nil))
    }

    func testFullNameFormat() {
        XCTAssertTrue(names("full_name") == ("Bob", "Brennan"))
        XCTAssertTrue(names("full_name", nickname: "Bobby") == ("Bob", "Brennan"))
        XCTAssertTrue(names("full_name", first: " Bob ", last: "") == ("Bob", nil))
        XCTAssertTrue(names("full_name", first: "", last: "Brennan") == ("Brennan", nil))
        XCTAssertTrue(names("full_name", first: "", last: "") == ("bob", nil))
    }

    func testNicknameFormat() {
        XCTAssertTrue(names("nickname_full_name", nickname: "Bobby") == ("Bobby", nil))
        XCTAssertTrue(names("nickname_full_name", nickname: "  ") == ("Bob", "Brennan"))
        XCTAssertTrue(names("nickname_full_name", first: "", last: "", nickname: "") == ("bob", nil))
    }

    func testDisplayNameMatchesPushSenderNames() {
        // The same rules the notification extension uses (MattermostPushSenderName, 4F).
        XCTAssertEqual(UserDisplayName.displayName(username: "bob", firstName: "Bob", lastName: "Brennan", nickname: "Bobby", format: "full_name"), "Bob Brennan")
        XCTAssertEqual(UserDisplayName.displayName(username: "bob", firstName: "Bob", lastName: "Brennan", nickname: "Bobby", format: "nickname_full_name"), "Bobby")
        XCTAssertEqual(UserDisplayName.displayName(username: "bob", firstName: "Bob", lastName: "Brennan", nickname: "Bobby", format: "username"), "bob")
    }

    func testGroupTitle() {
        XCTAssertEqual(UserDisplayName.groupUsernames(displayName: "alice, bob, carol"), ["alice", "bob", "carol"])
        XCTAssertEqual(UserDisplayName.groupUsernames(displayName: ""), [])
        XCTAssertEqual(UserDisplayName.groupTitle(["dave", "Carol Chen", "bob"]), "bob, Carol Chen, dave")
        XCTAssertEqual(UserDisplayName.groupTitle(["user10", "user9"]), "user9, user10")
    }
}

final class ChannelWideMentionTests: XCTestCase {
    func testMentions() {
        XCTAssertEqual(ChannelWideMention.mentions(in: "hello @channel"), [.channel])
        XCTAssertEqual(ChannelWideMention.mentions(in: "@here and @all, @HERE again"), [.here, .all])
        XCTAssertEqual(ChannelWideMention.mentions(in: "@channel."), [.channel])
        XCTAssertEqual(ChannelWideMention.mentions(in: "no mentions"), [])
        XCTAssertEqual(ChannelWideMention.mentions(in: "@channels @allison @hereford"), [])
        XCTAssertEqual(ChannelWideMention.mentions(in: "mail me at bob@channel.com"), [])
    }

    func testCodeDoesNotCount() {
        XCTAssertEqual(ChannelWideMention.mentions(in: "`@channel`"), [])
        XCTAssertEqual(ChannelWideMention.mentions(in: "```\n@all\n```"), [])
    }

    func testNeedsConfirmation() {
        XCTAssertTrue(ChannelWideMention.needsConfirmation(mentions: [.channel], memberCount: 6, confirmationEnabled: true, canUseChannelMentions: true))
        XCTAssertFalse(ChannelWideMention.needsConfirmation(mentions: [.channel], memberCount: 5, confirmationEnabled: true, canUseChannelMentions: true))
        XCTAssertFalse(ChannelWideMention.needsConfirmation(mentions: [.here], memberCount: 50, confirmationEnabled: false, canUseChannelMentions: true))
        XCTAssertFalse(ChannelWideMention.needsConfirmation(mentions: [.all], memberCount: 50, confirmationEnabled: true, canUseChannelMentions: false))
        XCTAssertFalse(ChannelWideMention.needsConfirmation(mentions: [], memberCount: 50, confirmationEnabled: true, canUseChannelMentions: true))
    }
}

final class PermalinkForwardTests: XCTestCase {
    private let postId = "5tsc8rfigp8m5f7kteuj7aa9dy"

    func testPlainForward() {
        let message = PermalinkForward.message(permalink: "http://localhost:8065/engineering/pl/\(postId)")
        XCTAssertEqual(message, "http://localhost:8065/engineering/pl/\(postId)")
        XCTAssertEqual(PermalinkForward.parse(message), PermalinkForward.Message(comment: "", url: message, postId: postId))
    }

    func testForwardWithComment() {
        let message = PermalinkForward.message(permalink: "https://chat.example.com/sub/eng/pl/\(postId)", comment: "look at this\n")
        XCTAssertEqual(message, "look at this\nhttps://chat.example.com/sub/eng/pl/\(postId)")
        XCTAssertEqual(PermalinkForward.parse(message)?.comment, "look at this")
        XCTAssertEqual(PermalinkForward.parse(message)?.postId, postId)
    }

    func testNotForwards() {
        XCTAssertNil(PermalinkForward.parse("http://localhost:8065/engineering/pl/\(postId) is the one"))
        XCTAssertNil(PermalinkForward.parse("http://localhost:8065/engineering/channels/town-square"))
        XCTAssertNil(PermalinkForward.parse("http://localhost:8065/engineering/pl/short"))
        XCTAssertNil(PermalinkForward.parse("see engineering/pl/\(postId)"))
        XCTAssertNil(PermalinkForward.parse(""))
    }

    func testWhereForwardsMayGo() {
        XCTAssertTrue(PermalinkForward.canForward(sourceChannelType: "O", sourceChannelId: "a", targetChannelId: "b"))
        XCTAssertFalse(PermalinkForward.canForward(sourceChannelType: "P", sourceChannelId: "a", targetChannelId: "b"))
        XCTAssertFalse(PermalinkForward.canForward(sourceChannelType: "D", sourceChannelId: "a", targetChannelId: "b"))
        XCTAssertTrue(PermalinkForward.canForward(sourceChannelType: "G", sourceChannelId: "a", targetChannelId: "a"))
    }
}
