import XCTest
@testable import MattermostSyncCore

/// Phase 3F: status durations, custom status expiry, username rules, field access, notification preferences.
final class StatusOptionsTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 1 // Sunday, as Mattermost's clients (moment's default locale)
        return calendar
    }

    /// 2026-10-26 15:20:10 in Berlin (CET, UTC+1), a Monday.
    private let now = Date(timeIntervalSince1970: 1_793_024_410)

    func testDoNotDisturbEnds() {
        XCTAssertNil(DoNotDisturbDuration.indefinitely.endTime(now: now, calendar: berlin))
        XCTAssertEqual(DoNotDisturbDuration.thirtyMinutes.endTime(now: now, calendar: berlin), 1_793_024_410 + 1800)
        XCTAssertEqual(DoNotDisturbDuration.oneHour.endTime(now: now, calendar: berlin), 1_793_024_410 + 3600)
        XCTAssertEqual(DoNotDisturbDuration.twoHours.endTime(now: now, calendar: berlin), 1_793_024_410 + 7200)
        // Tomorrow 09:00 Berlin = 08:00 UTC on 2026-10-27.
        XCTAssertEqual(DoNotDisturbDuration.tomorrow.endTime(now: now, calendar: berlin), 1_793_088_000)
        XCTAssertEqual(DoNotDisturbDuration.until(Date(timeIntervalSince1970: 1_793_100_000.7)).endTime(now: now, calendar: berlin), 1_793_100_000)
    }

    func testTomorrowAcrossTheDaylightSavingSwitch() {
        // 2026-10-24 22:00 Berlin (CEST): tomorrow 09:00 is after the switch to CET (UTC+1) → 08:00 UTC.
        let saturdayEvening = Date(timeIntervalSince1970: 1_792_872_000)
        XCTAssertEqual(DoNotDisturbDuration.tomorrow.endTime(now: saturdayEvening, calendar: berlin), 1_792_915_200)
    }

    func testCustomStatusExpiry() {
        XCTAssertNil(CustomStatusDuration.dontClear.expiry(now: now, calendar: berlin))
        XCTAssertEqual(CustomStatusDuration.dontClear.expiresAtString(now: now, calendar: berlin), "")
        XCTAssertEqual(CustomStatusDuration.thirtyMinutes.expiry(now: now, calendar: berlin), now.addingTimeInterval(1800))
        XCTAssertEqual(CustomStatusDuration.fourHours.expiry(now: now, calendar: berlin), now.addingTimeInterval(4 * 3600))
        // End of today: 23:59:59 Berlin = 22:59:59 UTC.
        XCTAssertEqual(CustomStatusDuration.today.expiresAtString(now: now, calendar: berlin), "2026-10-26T22:59:59Z")
        // End of the week (Sunday-first): Saturday 2026-10-31 23:59:59 Berlin.
        XCTAssertEqual(CustomStatusDuration.thisWeek.expiresAtString(now: now, calendar: berlin), "2026-10-31T22:59:59Z")
        let chosen = Date(timeIntervalSince1970: 1_793_200_000)
        XCTAssertEqual(CustomStatusDuration.dateAndTime(chosen).expiry(now: now, calendar: berlin), chosen)
    }

    func testDurationAPIValuesRoundTrip() {
        for preset in CustomStatusDuration.presets {
            XCTAssertEqual(CustomStatusDuration(apiValue: preset.apiValue), preset)
        }
        XCTAssertEqual(CustomStatusDuration.dateAndTime(now).apiValue, "date_and_time")
        XCTAssertNil(CustomStatusDuration(apiValue: "date_and_time"))
        XCTAssertNil(CustomStatusDuration(apiValue: "fortnight"))
    }

    func testSuggestionsUseKnownEmoji() {
        for suggestion in CustomStatusSuggestion.defaults {
            XCTAssertNotNil(EmojiTable.unicode(forName: suggestion.emoji), suggestion.emoji)
        }
        XCTAssertNotNil(EmojiTable.unicode(forName: CustomStatusRules.defaultEmoji))
    }

    func testUsernameRules() {
        XCTAssertNil(UsernameRules.validate("alice"))
        XCTAssertNil(UsernameRules.validate("a.b-c_9"))
        XCTAssertEqual(UsernameRules.validate("al"), .tooShort)
        XCTAssertEqual(UsernameRules.validate(String(repeating: "a", count: 23)), .tooLong)
        XCTAssertNil(UsernameRules.validate(String(repeating: "a", count: 22)))
        XCTAssertEqual(UsernameRules.validate("9lives"), .mustStartWithLetter)
        XCTAssertEqual(UsernameRules.validate("_alice"), .mustStartWithLetter)
        XCTAssertEqual(UsernameRules.validate("Alice"), .invalidCharacters)
        XCTAssertEqual(UsernameRules.validate("al ice"), .invalidCharacters)
        XCTAssertEqual(UsernameRules.validate("alïce"), .invalidCharacters)
        XCTAssertEqual(UsernameRules.validate("channel"), .reserved)
        XCTAssertEqual(UsernameRules.validate("system"), .reserved)
    }

    func testProfileFieldAccess() {
        XCTAssertEqual(ProfileFieldAccess.resolve(authService: "", config: ["LdapFirstNameAttributeSet": "true"]), ProfileFieldAccess())
        let ldap = ProfileFieldAccess.resolve(authService: "ldap", config: ["LdapFirstNameAttributeSet": "true", "LdapPositionAttributeSet": "true", "LdapPictureAttributeSet": "true", "SamlLastNameAttributeSet": "true"])
        XCTAssertFalse(ldap.firstName)
        XCTAssertTrue(ldap.lastName)
        XCTAssertTrue(ldap.nickname)
        XCTAssertFalse(ldap.position)
        XCTAssertFalse(ldap.username)
        XCTAssertFalse(ldap.email)
        XCTAssertFalse(ldap.picture)
        let saml = ProfileFieldAccess.resolve(authService: "saml", config: ["SamlLastNameAttributeSet": "true"])
        XCTAssertTrue(saml.firstName)
        XCTAssertFalse(saml.lastName)
        XCTAssertTrue(saml.picture)
        let gitlab = ProfileFieldAccess.resolve(authService: "gitlab", config: [:])
        XCTAssertEqual(gitlab, ProfileFieldAccess(username: false, email: false))
    }
}

final class NotificationPreferencesTests: XCTestCase {
    /// alice's props on the 11.7 dev server (captured).
    private let aliceProps: [String: String] = [
        "channel": "true", "comments": "never", "desktop": "mention", "desktop_sound": "true", "desktop_threads": "all",
        "email": "true", "email_threads": "all", "first_name": "false", "mention_keys": "", "push": "mention",
        "push_status": "online", "push_threads": "all"
    ]

    func testUserPreferencesRoundTrip() {
        var preferences = UserNotificationPreferences(props: aliceProps)
        XCTAssertEqual(preferences.push, .mention)
        XCTAssertEqual(preferences.pushStatus, .online)
        XCTAssertEqual(preferences.pushThreads, .all)
        XCTAssertEqual(preferences.mentionKeys, [])
        XCTAssertFalse(preferences.firstNameMentions)
        XCTAssertTrue(preferences.channelMentions)
        XCTAssertEqual(preferences.props(updating: aliceProps), aliceProps, "unchanged values write the same map")

        preferences.push = .all
        preferences.pushStatus = .away
        preferences.pushThreads = .mention
        preferences.mentionKeys = ["deploy", " Release ", "", "deploy"]
        preferences.firstNameMentions = true
        preferences.channelMentions = false
        let props = preferences.props(updating: aliceProps)
        XCTAssertEqual(props["push"], "all")
        XCTAssertEqual(props["push_status"], "away")
        XCTAssertEqual(props["push_threads"], "mention")
        XCTAssertEqual(props["mention_keys"], "deploy,Release")
        XCTAssertEqual(props["first_name"], "true")
        XCTAssertEqual(props["channel"], "false")
        XCTAssertEqual(props["desktop"], "mention", "other keys are kept")
        XCTAssertEqual(props["comments"], "never")
    }

    func testUserPreferencesDefaultsForMissingKeys() {
        let preferences = UserNotificationPreferences(props: [:])
        XCTAssertEqual(preferences, UserNotificationPreferences())
        XCTAssertEqual(UserNotificationPreferences(props: ["push": "bogus", "channel": "false"]).push, .mention)
        XCTAssertFalse(UserNotificationPreferences(props: ["channel": "false"]).channelMentions)
    }

    func testMentionKeysParsing() {
        XCTAssertEqual(UserNotificationPreferences.parseMentionKeys(" a, b ,,A,c "), ["a", "b", "c"])
        XCTAssertEqual(UserNotificationPreferences.joinMentionKeys(["x", "X", " y "]), "x,y")
    }

    /// A channel member's props on the 11.7 dev server (captured, a muted channel).
    func testChannelPreferences() {
        let props = ["channel_auto_follow_threads": "off", "desktop": "default", "email": "default", "ignore_channel_mentions": "default", "mark_unread": "mention", "push": "default"]
        var preferences = ChannelNotificationPreferences(props: props)
        XCTAssertNil(preferences.push)
        XCTAssertNil(preferences.pushThreads)
        XCTAssertNil(preferences.ignoreChannelMentions)
        XCTAssertTrue(preferences.muted)
        XCTAssertFalse(preferences.autoFollowThreads)
        XCTAssertEqual(preferences.effectivePush(user: UserNotificationPreferences(push: .all)), .all)

        preferences.push = PushLevel.none
        preferences.pushThreads = .mention
        preferences.ignoreChannelMentions = true
        preferences.muted = false
        preferences.autoFollowThreads = true
        XCTAssertEqual(preferences.props, ["push": "none", "push_threads": "mention", "ignore_channel_mentions": "on", "mark_unread": "all", "channel_auto_follow_threads": "on"])
        XCTAssertEqual(ChannelNotificationPreferences(props: preferences.props), preferences)
        XCTAssertEqual(preferences.effectivePush(user: UserNotificationPreferences(push: .all)), PushLevel.none)

        preferences.ignoreChannelMentions = false
        XCTAssertEqual(preferences.props["ignore_channel_mentions"], "off")
        XCTAssertEqual(ChannelNotificationPreferences(props: ["ignore_channel_mentions": "off"]).ignoreChannelMentions, false)
    }
}
