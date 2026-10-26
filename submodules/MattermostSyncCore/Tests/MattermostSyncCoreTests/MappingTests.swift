import XCTest
@testable import MattermostSyncCore

final class ReadStateTests: XCTestCase {
    private let posts: [ReadStateMapper.KnownPost] = [
        .init(localId: 100, createAt: 1000),
        .init(localId: 116, createAt: 2000),
        .init(localId: 132, createAt: 3000),
        .init(localId: 148, createAt: 4000),
    ]

    func testUnreadChannel() {
        let counters = ChannelReadCounters(lastViewedAt: 2500, totalMessageCount: 40, memberMessageCount: 38, mentionCount: 1)
        let state = ReadStateMapper.readState(knownPosts: posts.shuffled(), counters: counters)
        XCTAssertEqual(state, ChannelReadState(maxIncomingReadId: 116, maxKnownId: 148, unreadCount: 2, mentionCount: 1))
        XCTAssertTrue(state.isUnread)
        XCTAssertEqual(state.maxOutgoingReadId, 0)
    }

    func testBoundaryIsInclusive() {
        let counters = ChannelReadCounters(lastViewedAt: 3000, totalMessageCount: 10, memberMessageCount: 10, mentionCount: 0)
        let state = ReadStateMapper.readState(knownPosts: posts, counters: counters)
        XCTAssertEqual(state.maxIncomingReadId, 132)
        XCTAssertFalse(state.isUnread)
    }

    func testNothingReadAmongKnownPosts() {
        let counters = ChannelReadCounters(lastViewedAt: 10, totalMessageCount: 4, memberMessageCount: 0, mentionCount: 0)
        XCTAssertEqual(ReadStateMapper.readState(knownPosts: posts, counters: counters).maxIncomingReadId, 0)
        XCTAssertEqual(ReadStateMapper.readState(knownPosts: [], counters: counters), ChannelReadState(maxIncomingReadId: 0, maxKnownId: 0, unreadCount: 4, mentionCount: 0))
    }

    func testCollapsedThreadsUseRootCounters() {
        let counters = ChannelReadCounters(
            lastViewedAt: 4000,
            totalMessageCount: 100, totalMessageCountRoot: 30,
            memberMessageCount: 90, memberMessageCountRoot: 29,
            mentionCount: 5, mentionCountRoot: 2,
            collapsedThreads: true
        )
        let state = ReadStateMapper.readState(knownPosts: posts, counters: counters)
        XCTAssertEqual(state.unreadCount, 1)
        XCTAssertEqual(state.mentionCount, 2)
        var off = counters
        off.collapsedThreads = false
        XCTAssertEqual(ReadStateMapper.readState(knownPosts: posts, counters: off).unreadCount, 10)
        XCTAssertEqual(ReadStateMapper.readState(knownPosts: posts, counters: off).mentionCount, 5)
    }

    func testCountersNeverGoNegative() {
        // The member count can be ahead of the channel count briefly (events racing).
        let counters = ChannelReadCounters(lastViewedAt: 0, totalMessageCount: 5, memberMessageCount: 7, mentionCount: -1)
        let state = ReadStateMapper.readState(knownPosts: posts, counters: counters)
        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertEqual(state.mentionCount, 0)
    }
}

final class PresenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testOnline() {
        let presence = PresenceMapper.presence(status: .online, lastActivityAt: 1_789_999_990_000, now: now)
        XCTAssertEqual(presence, MappedPresence(state: .online(until: 1_790_000_060)))
    }

    func testAwayPresentations() {
        let lastActivity: Int64 = 1_789_990_000_000
        XCTAssertEqual(PresenceMapper.presence(status: .away, lastActivityAt: lastActivity, now: now), MappedPresence(state: .recently, isAway: true))
        XCTAssertEqual(
            PresenceMapper.presence(status: .away, lastActivityAt: lastActivity, now: now, configuration: .init(awayPresentation: .online)),
            MappedPresence(state: .online(until: 1_790_000_060), isAway: true)
        )
        XCTAssertEqual(
            PresenceMapper.presence(status: .away, lastActivityAt: lastActivity, now: now, configuration: .init(awayPresentation: .lastSeen)),
            MappedPresence(state: .lastSeen(at: 1_789_990_000), isAway: true)
        )
        XCTAssertEqual(
            PresenceMapper.presence(status: .away, lastActivityAt: 0, now: now, configuration: .init(awayPresentation: .lastSeen)),
            MappedPresence(state: .recently, isAway: true)
        )
    }

    func testDoNotDisturb() {
        XCTAssertEqual(
            PresenceMapper.presence(status: .dnd, lastActivityAt: 0, dndEndTime: 1_790_003_600, now: now),
            MappedPresence(state: .online(until: 1_790_000_060), isDoNotDisturb: true, doNotDisturbUntil: 1_790_003_600)
        )
        // Milliseconds are normalised; 0 means "until turned off".
        XCTAssertEqual(PresenceMapper.presence(status: .dnd, lastActivityAt: 0, dndEndTime: 1_790_003_600_000, now: now).doNotDisturbUntil, 1_790_003_600)
        XCTAssertNil(PresenceMapper.presence(status: .dnd, lastActivityAt: 0, dndEndTime: 0, now: now).doNotDisturbUntil)
    }

    func testOffline() {
        XCTAssertEqual(PresenceMapper.presence(status: .offline, lastActivityAt: 1_789_000_000_123, now: now), MappedPresence(state: .lastSeen(at: 1_789_000_000)))
        XCTAssertEqual(PresenceMapper.presence(status: .offline, lastActivityAt: 0, now: now), MappedPresence(state: .unknown))
        // A clock-skewed activity time in the future is clamped to now.
        XCTAssertEqual(PresenceMapper.presence(status: .offline, lastActivityAt: 1_800_000_000_000, now: now).state, .lastSeen(at: 1_790_000_000))
    }

    func testStatusParsing() {
        XCTAssertEqual(MattermostUserStatus(apiValue: "online"), .online)
        XCTAssertEqual(MattermostUserStatus(apiValue: "DND"), .dnd)
        XCTAssertEqual(MattermostUserStatus(apiValue: "away"), .away)
        XCTAssertEqual(MattermostUserStatus(apiValue: "out_of_office"), .offline)
        XCTAssertEqual(MattermostUserStatus(apiValue: ""), .offline)
    }
}

final class ServiceActionTests: XCTestCase {
    private let actor = "actor-id"

    private func map(_ type: String, message: String = "", props: [String: String] = [:]) -> ServiceAction? {
        return ServiceAction.from(type: type, userId: actor, message: message, props: props)
    }

    func testMembership() {
        XCTAssertEqual(map("system_join_channel", props: ["username": "alice"]), .joinedChannel(user: ServiceUserRef(userId: actor, username: "alice"), isGuest: false))
        XCTAssertEqual(map("system_guest_join_channel", props: ["username": "gus"]), .joinedChannel(user: ServiceUserRef(userId: actor, username: "gus"), isGuest: true))
        XCTAssertEqual(map("system_leave_channel", props: ["username": "alice"]), .leftChannel(user: ServiceUserRef(userId: actor, username: "alice")))
        XCTAssertEqual(
            map("system_add_to_channel", props: ["userId": "adder", "username": "bob", "addedUserId": "new", "addedUsername": "carol"]),
            .addedToChannel(actor: ServiceUserRef(userId: "adder", username: "bob"), added: ServiceUserRef(userId: "new", username: "carol"), isGuest: false)
        )
        XCTAssertEqual(
            map("system_add_guest_to_chan", props: ["username": "bob", "addedUserId": "g", "addedUsername": "guest"]),
            .addedToChannel(actor: ServiceUserRef(userId: actor, username: "bob"), added: ServiceUserRef(userId: "g", username: "guest"), isGuest: true)
        )
        XCTAssertEqual(
            map("system_remove_from_channel", props: ["removedUserId": "gone", "removedUsername": "dave"]),
            .removedFromChannel(actor: ServiceUserRef(userId: actor, username: nil), removed: ServiceUserRef(userId: "gone", username: "dave"))
        )
        XCTAssertEqual(map("system_join_team", props: ["username": "alice"]), .joinedTeam(user: ServiceUserRef(userId: actor, username: "alice")))
        XCTAssertEqual(map("system_leave_team", props: ["username": "alice"]), .leftTeam(user: ServiceUserRef(userId: actor, username: "alice")))
        XCTAssertEqual(
            map("system_add_to_team", props: ["userId": "adder", "username": "bob", "addedUserId": "new", "addedUsername": "carol"]),
            .addedToTeam(actor: ServiceUserRef(userId: "adder", username: "bob"), added: ServiceUserRef(userId: "new", username: "carol"))
        )
        XCTAssertEqual(
            map("system_remove_from_team", props: ["username": "erin"]),
            .removedFromTeam(actor: ServiceUserRef(userId: nil, username: nil), removed: ServiceUserRef(userId: actor, username: "erin"))
        )
    }

    func testChannelChanges() {
        XCTAssertEqual(
            map("system_header_change", props: ["username": "alice", "old_header": "old", "new_header": "new"]),
            .headerChanged(actor: ServiceUserRef(userId: actor, username: "alice"), oldHeader: "old", newHeader: "new")
        )
        XCTAssertEqual(
            map("system_purpose_change", props: ["username": "alice", "new_purpose": "why"]),
            .purposeChanged(actor: ServiceUserRef(userId: actor, username: "alice"), oldPurpose: "", newPurpose: "why")
        )
        XCTAssertEqual(
            map("system_displayname_change", props: ["username": "alice", "old_displayname": "A", "new_displayname": "B"]),
            .displayNameChanged(actor: ServiceUserRef(userId: actor, username: "alice"), oldName: "A", newName: "B")
        )
        XCTAssertEqual(map("system_channel_deleted", props: ["username": "alice"]), .channelArchived(actor: ServiceUserRef(userId: actor, username: "alice")))
        XCTAssertEqual(map("system_channel_restored"), .channelRestored(actor: ServiceUserRef(userId: actor, username: nil)))
        XCTAssertEqual(map("system_convert_channel"), .convertedToPrivate(actor: ServiceUserRef(userId: actor, username: nil)))
        XCTAssertEqual(map("system_change_chan_privacy", message: "made private"), .privacyChanged(actor: ServiceUserRef(userId: actor, username: nil), message: "made private"))
        XCTAssertEqual(map("system_move_channel", message: "moved"), .channelMoved(actor: ServiceUserRef(userId: actor, username: nil), message: "moved"))
        XCTAssertEqual(map("system_gm_to_channel", message: "converted"), .convertedFromGroupMessage(actor: ServiceUserRef(userId: actor, username: nil), message: "converted"))
    }

    func testOrdinaryAndUnknownTypes() {
        XCTAssertNil(map(""))
        XCTAssertNil(map("me"))
        XCTAssertNil(map("system_auto_responder"))
        XCTAssertNil(map("reminder"))
        XCTAssertEqual(map("system_generic", message: "Something happened"), .generic(text: "Something happened"))
        XCTAssertEqual(map("system_something_new", message: "future"), .generic(text: "future"))
        XCTAssertEqual(map("custom_poll", message: "Poll"), .unsupported(type: "custom_poll", text: "Poll"))
        XCTAssertTrue(ServiceAction.isSystemPostType("system_join_channel"))
        XCTAssertFalse(ServiceAction.isSystemPostType("system_auto_responder"))
        XCTAssertFalse(ServiceAction.isSystemPostType("custom_poll"))
    }

    func testEmptyPropsBecomeNil() {
        XCTAssertEqual(ServiceUserRef(userId: "", username: ""), ServiceUserRef(userId: nil, username: nil))
    }

    func testFallbackText() {
        let name: (ServiceUserRef) -> String = { "@" + ($0.username ?? "someone") }
        XCTAssertEqual(map("system_join_channel", props: ["username": "alice"])?.fallbackText(name: name), "@alice joined the channel.")
        XCTAssertEqual(
            map("system_add_to_channel", props: ["username": "bob", "addedUsername": "carol"])?.fallbackText(name: name),
            "@carol was added to the channel by @bob."
        )
        XCTAssertEqual(
            map("system_header_change", props: ["username": "alice", "old_header": "", "new_header": "Welcome"])?.fallbackText(name: name),
            "@alice updated the channel header to: Welcome"
        )
        XCTAssertEqual(map("system_channel_deleted", props: ["username": "alice"])?.fallbackText(name: name), "@alice archived the channel.")
    }

    func testFormattedTextMarksUsersAndQuotedValues() {
        let name: (ServiceUserRef) -> String = { $0.username.map { "@" + $0 } ?? "Someone" }
        func substring(_ text: String, _ range: Range<Int>) -> String {
            let utf16 = Array(text.utf16)
            return String(decoding: utf16[range], as: UTF16.self)
        }
        let added = map("system_add_to_channel", props: ["userId": "u1", "username": "bob", "addedUserId": "u2", "addedUsername": "carol"])!.formattedText(name: name)
        XCTAssertEqual(added.text, "@carol was added to the channel by @bob.")
        XCTAssertEqual(added.mentions.map { substring(added.text, $0.range) }, ["@carol", "@bob"])
        XCTAssertEqual(added.mentions.map { $0.user.userId }, ["u2", "u1"])
        XCTAssertEqual(added.emphasized, [])

        // Ranges are UTF-16 offsets: names and values with emoji and other scripts.
        let header = map("system_header_change", props: ["username": "zoë", "old_header": "Old 🐈‍⬛", "new_header": "Новый 🌍"])!.formattedText(name: name)
        XCTAssertEqual(header.text, "@zoë updated the channel header from: Old 🐈‍⬛ to: Новый 🌍")
        XCTAssertEqual(header.mentions.map { substring(header.text, $0.range) }, ["@zoë"])
        XCTAssertEqual(header.emphasized.map { substring(header.text, $0) }, ["Old 🐈‍⬛", "Новый 🌍"])

        let removed = map("system_purpose_change", props: ["username": "a", "old_purpose": "x", "new_purpose": ""])!.formattedText(name: name)
        XCTAssertEqual(removed.text, "@a removed the channel purpose (was: x)")
        XCTAssertEqual(removed.emphasized.map { substring(removed.text, $0) }, ["x"])

        // Markdown in a header is rendered, not shown raw.
        let markdown = map("system_header_change", props: ["username": "bob", "old_header": "", "new_header": "**Deploys** in [the runbook](https://example.com/run) by @alice :rocket:\nsecond line"])!.formattedText(name: name)
        XCTAssertEqual(markdown.text, "@bob updated the channel header to: Deploys in the runbook by @alice 🚀 second line")
        XCTAssertEqual(markdown.emphasized.map { substring(markdown.text, $0) }, ["Deploys in the runbook by @alice 🚀 second line"])
        XCTAssertEqual(markdown.entities.map { $0.type }, [.bold, .textUrl(url: "https://example.com/run"), .mention(username: "alice")])
        XCTAssertEqual(markdown.entities.map { substring(markdown.text, $0.range) }, ["Deploys", "the runbook", "@alice"])
        let quote = map("system_purpose_change", props: ["username": "a", "old_purpose": "> quoted `code`", "new_purpose": ""])!.formattedText(name: name)
        XCTAssertEqual(quote.text, "@a removed the channel purpose (was: quoted code)")
        XCTAssertEqual(quote.entities.map { $0.type }, [.code])

        let generic = map("system_generic", message: "Server text")!.formattedText(name: name)
        XCTAssertEqual(generic.text, "Server text")
        XCTAssertEqual(generic.mentions, [])
    }
}

final class SlashCommandTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(SlashCommand.parse("/away"), SlashCommand.Parsed(trigger: "away", arguments: ""))
        XCTAssertEqual(SlashCommand.parse("/Echo  hello world "), SlashCommand.Parsed(trigger: "echo", arguments: "hello world "))
        XCTAssertEqual(SlashCommand.parse("/header **new**\nsecond line"), SlashCommand.Parsed(trigger: "header", arguments: "**new**\nsecond line"))
        XCTAssertEqual(SlashCommand.parse("/me waves"), SlashCommand.Parsed(trigger: "me", arguments: "waves"))
    }

    func testFalsePositivesArePosted() {
        XCTAssertNil(SlashCommand.parse("/usr/bin/env python"))
        XCTAssertNil(SlashCommand.parse("/path/to/file"))
        XCTAssertNil(SlashCommand.parse("//not a command"))
        XCTAssertNil(SlashCommand.parse("/"))
        XCTAssertNil(SlashCommand.parse("/ hello"))
        XCTAssertNil(SlashCommand.parse(" /away"))
        XCTAssertNil(SlashCommand.parse("hello /away"))
    }
}
