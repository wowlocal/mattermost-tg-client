import XCTest
@testable import MattermostSyncCore

final class ChannelNamingTests: XCTestCase {
    private func name(_ displayName: String) -> String {
        return ChannelNaming.urlName(fromDisplayName: displayName, fallback: { "generated" })
    }

    func testURLNameFromDisplayName() {
        XCTAssertEqual(name("Release Train"), "release-train")
        XCTAssertEqual(name("  iOS -- Team  "), "ios-team")
        XCTAssertEqual(name("Q3 Planning: Q&A!"), "q3-planning-qa")
        XCTAssertEqual(name("snake_case name"), "snake_case-name")
        XCTAssertEqual(name("Café Crème"), "caf-crme")
        XCTAssertEqual(name("a-b"), "a-b")
    }

    func testFallbackWhenNothingUsable() {
        XCTAssertEqual(name("Проект"), "generated")
        XCTAssertEqual(name("🚀"), "generated")
        XCTAssertEqual(name("x"), "generated")
        XCTAssertEqual(name("_lead"), "generated")
        XCTAssertEqual(name("a__b"), "generated")
    }

    func testLongDisplayNameIsCut() {
        let long = String(repeating: "word ", count: 30)
        let result = name(long)
        XCTAssertLessThanOrEqual(result.count, 64)
        XCTAssertNil(ChannelNaming.validate(urlName: result))
    }

    func testURLNameValidation() {
        XCTAssertNil(ChannelNaming.validate(urlName: "release-train"))
        XCTAssertNil(ChannelNaming.validate(urlName: "a1"))
        XCTAssertNil(ChannelNaming.validate(urlName: "a_b-c"))
        XCTAssertEqual(ChannelNaming.validate(urlName: "a"), .tooShort)
        XCTAssertEqual(ChannelNaming.validate(urlName: String(repeating: "a", count: 65)), .tooLong)
        XCTAssertEqual(ChannelNaming.validate(urlName: "Release"), .invalidCharacters)
        XCTAssertEqual(ChannelNaming.validate(urlName: "rel ease"), .invalidCharacters)
        XCTAssertEqual(ChannelNaming.validate(urlName: "-release"), .badEdges)
        XCTAssertEqual(ChannelNaming.validate(urlName: "release_"), .badEdges)
        XCTAssertEqual(ChannelNaming.validate(urlName: "a__b"), .doubleUnderscore)
    }

    func testDisplayNameValidation() {
        XCTAssertNil(ChannelNaming.validate(displayName: "Ops"))
        XCTAssertEqual(ChannelNaming.validate(displayName: "   "), .empty)
        XCTAssertEqual(ChannelNaming.validate(displayName: String(repeating: "x", count: 65)), .tooLong)
    }

    func testGeneratedName() {
        let generated = ChannelNaming.generatedName()
        XCTAssertEqual(generated.count, 26)
        XCTAssertNil(ChannelNaming.validate(urlName: generated))
    }
}

final class ChannelAccessRulesTests: XCTestCase {
    private let channelUser: Set<String> = ["manage_public_channel_members", "manage_private_channel_members", "manage_public_channel_properties", "manage_private_channel_properties", "delete_public_channel", "delete_private_channel"]

    func testDefaultMemberOfPublicChannel() {
        let result = ChannelAccessRules.evaluate(permissions: channelUser, channelType: "O", channelName: "releases", isArchived: false)
        XCTAssertTrue(result.canEditProperties)
        XCTAssertTrue(result.canManageMembers)
        XCTAssertTrue(result.canArchive)
        XCTAssertTrue(result.canLeave)
        XCTAssertFalse(result.canManageRoles)
        XCTAssertFalse(result.canConvertToPrivate)
        XCTAssertFalse(result.canUnarchive)
    }

    func testPrivateChannelUsesPrivatePermissions() {
        let result = ChannelAccessRules.evaluate(permissions: ["manage_public_channel_members", "manage_public_channel_properties"], channelType: "P", channelName: "leads", isArchived: false)
        XCTAssertFalse(result.canManageMembers)
        XCTAssertFalse(result.canEditProperties)
        XCTAssertFalse(result.canConvertToPrivate)
        XCTAssertTrue(result.canLeave)
    }

    func testTownSquare() {
        let result = ChannelAccessRules.evaluate(permissions: channelUser.union(["convert_public_channel_to_private"]), channelType: "O", channelName: "town-square", isArchived: false)
        XCTAssertTrue(result.isDefaultChannel)
        XCTAssertFalse(result.canLeave)
        XCTAssertFalse(result.canArchive)
        XCTAssertFalse(result.canConvertToPrivate)
        XCTAssertTrue(result.canEditProperties)
        // 4H: nobody is added to or removed from the default channel.
        XCTAssertFalse(result.canManageMembers)
    }

    func testAdminsAndSystemAdmin() {
        let teamAdmin = ChannelAccessRules.evaluate(permissions: channelUser.union(["manage_channel_roles", "convert_public_channel_to_private", "manage_team"]), channelType: "O", channelName: "ops", isArchived: false)
        XCTAssertTrue(teamAdmin.canManageRoles)
        XCTAssertTrue(teamAdmin.canConvertToPrivate)
        let systemAdmin = ChannelAccessRules.evaluate(permissions: ["manage_system"], channelType: "P", channelName: "ops", isArchived: false)
        XCTAssertTrue(systemAdmin.canManageMembers)
        XCTAssertTrue(systemAdmin.canArchive)
        XCTAssertFalse(systemAdmin.canConvertToPrivate)
    }

    func testDeleteOthersPosts() {
        XCTAssertFalse(ChannelAccessRules.evaluate(permissions: channelUser, channelType: "O", channelName: "ops", isArchived: false).canDeleteOthersPosts)
        // Channel admins (`channel_admin` has `delete_others_posts` by default), in channels and group messages.
        XCTAssertTrue(ChannelAccessRules.evaluate(permissions: channelUser.union(["delete_others_posts"]), channelType: "P", channelName: "ops", isArchived: false).canDeleteOthersPosts)
        XCTAssertTrue(ChannelAccessRules.evaluate(permissions: ["delete_others_posts"], channelType: "G", channelName: "gm", isArchived: false).canDeleteOthersPosts)
        XCTAssertTrue(ChannelAccessRules.evaluate(permissions: ["manage_system"], channelType: "O", channelName: "ops", isArchived: false).canDeleteOthersPosts)
        // Not in an archived channel.
        XCTAssertFalse(ChannelAccessRules.evaluate(permissions: ["delete_others_posts"], channelType: "O", channelName: "ops", isArchived: true).canDeleteOthersPosts)
    }

    func testArchivedChannel() {
        let member = ChannelAccessRules.evaluate(permissions: channelUser, channelType: "O", channelName: "old", isArchived: true)
        XCTAssertFalse(member.canEditProperties)
        XCTAssertFalse(member.canManageMembers)
        XCTAssertFalse(member.canArchive)
        XCTAssertFalse(member.canUnarchive)
        XCTAssertTrue(member.canLeave)
        let teamAdmin = ChannelAccessRules.evaluate(permissions: channelUser.union(["manage_team"]), channelType: "O", channelName: "old", isArchived: true)
        XCTAssertTrue(teamAdmin.canUnarchive)
    }

    func testGroupMessagesHaveNoSettings() {
        let result = ChannelAccessRules.evaluate(permissions: ["manage_system"], channelType: "G", channelName: "x", isArchived: false)
        // Nothing to edit, leave or archive; a system admin may still delete others' posts (4F).
        var expected = ChannelAccessRules.Result()
        expected.canDeleteOthersPosts = true
        XCTAssertEqual(result, expected)
    }

    func testRoleNames() {
        XCTAssertEqual(ChannelAccessRules.roleNames("system_user", "team_user team_admin", "", "channel_user  channel_admin"), ["system_user", "team_user", "team_admin", "channel_user", "channel_admin"])
    }
}

final class TeamInviteRulesTests: XCTestCase {
    /// `team_user` on the 11.7 dev server.
    private let teamUser: Set<String> = ["add_user_to_team", "invite_user", "list_team_channels", "view_team"]

    func testTeamMember() {
        let result = TeamInviteRules.evaluate(permissions: teamUser, inviteId: "7hskmz6zcjd9djf5xhfpy3de4c", groupConstrained: false, emailInvitationsEnabled: true)
        XCTAssertTrue(result.canShareLink)
        XCTAssertTrue(result.canAddMembers)
        XCTAssertTrue(result.canInviteByEmail)
        // The dev server's setting.
        let noEmail = TeamInviteRules.evaluate(permissions: teamUser, inviteId: "7hskmz6zcjd9djf5xhfpy3de4c", groupConstrained: false, emailInvitationsEnabled: false)
        XCTAssertFalse(noEmail.canInviteByEmail)
        XCTAssertTrue(noEmail.allowsAnything)
    }

    func testWithoutPermissions() {
        // A scheme that takes inviting away: the server leaves the invite id out.
        let result = TeamInviteRules.evaluate(permissions: ["view_team"], inviteId: "", groupConstrained: false, emailInvitationsEnabled: true)
        XCTAssertEqual(result, TeamInviteRules.Result())
        XCTAssertFalse(result.allowsAnything)
        // Adding existing users without inviting.
        let addOnly = TeamInviteRules.evaluate(permissions: ["add_user_to_team"], inviteId: "", groupConstrained: false, emailInvitationsEnabled: true)
        XCTAssertTrue(addOnly.canAddMembers)
        XCTAssertFalse(addOnly.canInviteByEmail)
        XCTAssertTrue(TeamInviteRules.evaluate(permissions: ["manage_system"], inviteId: "i", groupConstrained: false, emailInvitationsEnabled: true).canInviteByEmail)
    }

    func testUnknownRolesLeaveItToTheServer() {
        let result = TeamInviteRules.evaluate(permissions: nil, inviteId: "", groupConstrained: false, emailInvitationsEnabled: true)
        XCTAssertFalse(result.canShareLink)
        XCTAssertTrue(result.canAddMembers)
        XCTAssertTrue(result.canInviteByEmail)
    }

    func testGroupSyncedTeam() {
        let result = TeamInviteRules.evaluate(permissions: teamUser, inviteId: "i", groupConstrained: true, emailInvitationsEnabled: true)
        XCTAssertFalse(result.canShareLink)
        XCTAssertTrue(result.canAddMembers)
        XCTAssertFalse(result.canInviteByEmail)
    }

    func testInviteLink() {
        XCTAssertEqual(TeamInviteRules.inviteLink(serverURL: "https://chat.example.com/", inviteId: "abc"), "https://chat.example.com/signup_user_complete/?id=abc")
        XCTAssertEqual(TeamInviteRules.inviteLink(serverURL: "https://example.com/mattermost", inviteId: "abc"), "https://example.com/mattermost/signup_user_complete/?id=abc")
    }

    func testEmailAddresses() {
        let result = TeamInviteRules.emailAddresses(" dana@example.com, eve@example.org;frank@example.net\nDana@Example.com  not-an-address x@y ")
        XCTAssertEqual(result.valid, ["dana@example.com", "eve@example.org", "frank@example.net"])
        XCTAssertEqual(result.invalid, ["not-an-address", "x@y"])
        XCTAssertTrue(TeamInviteRules.emailAddresses("   ,, ").valid.isEmpty)
        XCTAssertTrue(TeamInviteRules.emailAddresses("   ,, ").invalid.isEmpty)
    }

    func testPastedAddresses() {
        let result = TeamInviteRules.emailAddresses("Dana Scully <dana@example.com>, \"Mulder, Fox\" <fox@example.com>, mailto:skinner@example.com, <walter@example.com>")
        XCTAssertEqual(result.valid, ["dana@example.com", "fox@example.com", "skinner@example.com", "walter@example.com"])
        XCTAssertEqual(result.invalid, [])
        XCTAssertEqual(TeamInviteRules.emailAddresses("a@@example.com @example.com a@.example.com a@example.").invalid, ["a@@example.com", "@example.com", "a@.example.com", "a@example."])
    }
}
