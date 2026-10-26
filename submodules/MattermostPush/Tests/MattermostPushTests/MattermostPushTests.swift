import Foundation
import XCTest
@testable import MattermostPush

private func fixture(_ name: String) throws -> [AnyHashable: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "apns", subdirectory: "Fixtures"), "missing fixture \(name)")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try XCTUnwrap(object as? [AnyHashable: Any])
}

private let serverId = "cbmk94w77in6bnhiy5q5oh114o"

final class MattermostPushPayloadTests: XCTestCase {
    func testDirectMessage() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("dm")))
        XCTAssertEqual(payload.type, .message)
        XCTAssertEqual(payload.serverId, serverId)
        XCTAssertNotNil(payload.ackId)
        XCTAssertNotNil(payload.postId)
        XCTAssertNotNil(payload.channelId)
        XCTAssertNil(payload.rootId)
        XCTAssertEqual(payload.senderName, "bob")
        XCTAssertEqual(payload.channelName, "bob")
        XCTAssertEqual(payload.alertTitle, "bob")
        XCTAssertEqual(payload.message, "Lunch at noon?")
        XCTAssertEqual(payload.badge, 1)
        XCTAssertEqual(payload.category, "CAN_REPLY")
        XCTAssertEqual(payload.version, "v2")
        XCTAssertFalse(payload.isThreadReply)
        XCTAssertFalse(payload.isIdLoaded)
    }

    func testThreadReply() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("thread-reply")))
        XCTAssertEqual(payload.rootId, "rootpost000000000000000001")
        XCTAssertTrue(payload.isThreadReply)
        XCTAssertTrue(payload.isCRTEnabled)
        // The proxy groups collapsed-thread replies by root; the extension regroups by channel.
        XCTAssertEqual(payload.threadIdentifier, "rootpost000000000000000001")
    }

    func testOtherTypes() throws {
        XCTAssertEqual(MattermostPushPayload(userInfo: try fixture("clear"))?.type, .clear)
        XCTAssertEqual(MattermostPushPayload(userInfo: try fixture("clear"))?.badge, 0)
        XCTAssertEqual(MattermostPushPayload(userInfo: try fixture("update-badge"))?.type, .updateBadge)
        XCTAssertEqual(MattermostPushPayload(userInfo: try fixture("update-badge"))?.badge, 3)
        let session = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("session")))
        XCTAssertEqual(session.type, .session)
        // A plain-string alert.
        XCTAssertEqual(session.message, "Session Expired: Please log in to continue receiving notifications.")
        XCTAssertEqual(MattermostPushType(rawValue: "something_new"), .other("something_new"))
        XCTAssertEqual(MattermostPushType(rawValue: "update_badge").rawValue, "update_badge")
    }

    func testTelegramPushesAreNotMattermost() {
        XCTAssertNil(MattermostPushPayload(userInfo: ["p": "abc", "aps": ["alert": "x"]]))
        XCTAssertNil(MattermostPushPayload(userInfo: ["aps": ["alert": "x"]]))
        // `type` alone is not enough (Telegram uses other keys, but be strict).
        XCTAssertNil(MattermostPushPayload(userInfo: ["type": "message"]))
        XCTAssertNotNil(MattermostPushPayload(userInfo: ["type": "message", "server_id": "s"]))
    }

    func testLenientValues() {
        let payload = MattermostPushPayload(userInfo: [
            "type": "message",
            "ack_id": "a",
            "is_crt_enabled": NSNumber(value: true),
            "from_webhook": "true",
            "id_loaded": true,
            "aps": ["badge": "7"]
        ])
        XCTAssertEqual(payload?.isCRTEnabled, true)
        XCTAssertEqual(payload?.isFromWebhook, true)
        XCTAssertEqual(payload?.isIdLoaded, true)
        XCTAssertEqual(payload?.badge, 7)
    }

    func testIdLoadedMerge() {
        var payload = MattermostPushPayload(type: .message, serverId: serverId, ackId: "a", postId: "p", channelId: "c", message: "You have a new message.", isIdLoaded: true)
        payload.merge(idLoadedResponse: ["message": "bob: hi", "channel_name": "Town Square", "sender_name": "bob", "sender_id": "b", "root_id": "r", "is_crt_enabled": true, "badge": 4])
        XCTAssertEqual(payload.message, "bob: hi")
        XCTAssertEqual(payload.channelName, "Town Square")
        XCTAssertEqual(payload.senderName, "bob")
        XCTAssertEqual(payload.rootId, "r")
        XCTAssertEqual(payload.badge, 4)
        XCTAssertTrue(payload.isCRTEnabled)
        XCTAssertFalse(payload.isIdLoaded)
    }
}

final class MattermostPushTextTests: XCTestCase {
    func testDirectMessageIsTitledBySender() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("dm")))
        let text = MattermostPushTextBuilder.text(for: payload, kind: .direct, siteName: "Dev")
        XCTAssertEqual(text.title, "bob")
        XCTAssertEqual(text.body, "Lunch at noon?")
        XCTAssertEqual(text.senderName, "bob")
        XCTAssertNil(text.groupName)
        XCTAssertEqual(text.threadIdentifier, payload.channelId)
        XCTAssertTrue(text.isCommunication)
    }

    func testDirectMessageKindIsInferredWithoutStore() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("dm")))
        XCTAssertNil(MattermostPushTextBuilder.text(for: payload, kind: .unknown, siteName: nil).groupName)
    }

    func testChannelIsTitledByChannelWithSender() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("channel-mention")))
        let text = MattermostPushTextBuilder.text(for: payload, kind: .channel, siteName: nil)
        XCTAssertEqual(text.title, "Town Square")
        XCTAssertEqual(text.groupName, "Town Square")
        XCTAssertEqual(text.senderName, "bob")
        XCTAssertEqual(text.body, "@alice can you review the release notes?")
        XCTAssertEqual(text.threadIdentifier, "townsquare0000000000000000")
    }

    func testThreadReplies() throws {
        let crt = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("thread-reply")))
        let crtText = MattermostPushTextBuilder.text(for: crt, kind: .channel, siteName: nil)
        XCTAssertEqual(crtText.title, "Reply in Town Square")
        XCTAssertEqual(crtText.body, "done, merged")
        // Grouped by channel, not by root as the proxy's thread-id would.
        XCTAssertEqual(crtText.threadIdentifier, "townsquare0000000000000000")

        var plain = crt
        plain.isCRTEnabled = false
        plain.channelName = "Town Square"
        XCTAssertEqual(MattermostPushTextBuilder.text(for: plain, kind: .channel, siteName: nil).title, "Reply in Town Square")

        var dm = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("dm")))
        dm.rootId = "root"
        dm.message = "bob: in the thread"
        dm.channelName = "Reply in Direct Message"
        let dmText = MattermostPushTextBuilder.text(for: dm, kind: .direct, siteName: nil)
        XCTAssertEqual(dmText.title, "bob")
        XCTAssertEqual(dmText.subtitle, "Reply in thread")
        XCTAssertEqual(dmText.body, "in the thread")
    }

    func testWebhookOverrideAndGenericContents() {
        let webhook = MattermostPushPayload(type: .message, channelId: "c", senderId: "u", senderName: "ci-bot", overrideUsername: "ci-bot", isFromWebhook: true, channelName: "Builds", message: "ci-bot: build 42 passed")
        let text = MattermostPushTextBuilder.text(for: webhook, kind: .channel, siteName: nil)
        XCTAssertEqual(text.senderName, "ci-bot")
        XCTAssertEqual(text.body, "build 42 passed")

        let generic = MattermostPushPayload(type: .message, channelId: "c", senderName: "bob", channelName: "Town Square", message: "bob posted in Town Square")
        XCTAssertEqual(MattermostPushTextBuilder.text(for: generic, kind: .channel, siteName: nil).body, "bob posted in Town Square")

        let noChannel = MattermostPushPayload(type: .message, channelId: "c", senderName: "bob", message: "bob posted a message")
        XCTAssertEqual(MattermostPushTextBuilder.text(for: noChannel, kind: .channel, siteName: "Dev").title, "Dev")
    }

    func testSession() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("session")))
        let text = MattermostPushTextBuilder.text(for: payload, kind: .unknown, siteName: "Relay Dev")
        XCTAssertEqual(text.title, "Session Expired")
        XCTAssertEqual(text.body, "Your session on Relay Dev has ended. Open Relay to log in again.")
        XCTAssertFalse(text.isCommunication)
    }
}

final class MattermostPushRouterTests: XCTestCase {
    private let alice = MattermostPushAccount(accountId: 1, serverURL: "http://localhost:8065", serverId: serverId, userId: "aliceuserid00000000000000a", username: "alice", order: 1)
    private let bob = MattermostPushAccount(accountId: 2, serverURL: "http://localhost:8065", serverId: serverId, userId: "bobuserid000000000000000bb", username: "bob", order: 2)
    private let other = MattermostPushAccount(accountId: 3, serverURL: "https://chat.example.com", serverId: "otherserver000000000000000", userId: "aliceuserid00000000000000a", username: "alice", order: 0)

    func testServerIdPicksTheServer() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("dm")))
        let route = MattermostPushRouter.route(payload, accounts: [self.other, self.alice], isMember: { _ in nil }, alreadyDelivered: [])
        XCTAssertEqual(route.account?.accountId, 1)
        XCTAssertFalse(route.isAmbiguous)
    }

    func testUnknownServerGetsNothing() throws {
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("dm")))
        let route = MattermostPushRouter.route(payload, accounts: [self.other], isMember: { _ in nil }, alreadyDelivered: [])
        XCTAssertNil(route.account)
    }

    func testTheSenderIsNotTheRecipient() throws {
        // bob wrote the DM; both accounts are on the server and in the DM channel.
        let payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("dm")))
        let route = MattermostPushRouter.route(payload, accounts: [self.bob, self.alice], isMember: { _ in true }, alreadyDelivered: [])
        XCTAssertEqual(route.account?.accountId, 1)
        XCTAssertFalse(route.isAmbiguous)
    }

    func testMembership() {
        let payload = MattermostPushPayload(type: .message, serverId: serverId, postId: "p", channelId: "c", senderId: "carol", message: "carol: hi")
        let route = MattermostPushRouter.route(payload, accounts: [self.alice, self.bob], isMember: { $0.accountId == 2 }, alreadyDelivered: [])
        XCTAssertEqual(route.account?.accountId, 2)
    }

    func testMention() throws {
        var payload = try XCTUnwrap(MattermostPushPayload(userInfo: try fixture("channel-mention")))
        payload.senderId = "carol"
        let route = MattermostPushRouter.route(payload, accounts: [self.bob, self.alice], isMember: { _ in true }, alreadyDelivered: [])
        XCTAssertEqual(route.account?.accountId, 1)
        XCTAssertTrue(route.reason.contains("mention"))
    }

    func testTwoPushesForOnePostGoToTwoAccounts() {
        let payload = MattermostPushPayload(type: .message, serverId: serverId, postId: "p", channelId: "c", senderId: "carol", message: "carol: @channel standup")
        let first = MattermostPushRouter.route(payload, accounts: [self.alice, self.bob], isMember: { _ in true }, alreadyDelivered: [])
        XCTAssertEqual(first.account?.accountId, 1)
        XCTAssertTrue(first.isAmbiguous)
        let second = MattermostPushRouter.route(payload, accounts: [self.alice, self.bob], isMember: { _ in true }, alreadyDelivered: [1])
        XCTAssertEqual(second.account?.accountId, 2)
    }

    func testAWebhookMayPostAsTheRecipient() {
        let payload = MattermostPushPayload(type: .message, serverId: serverId, postId: "p", channelId: "c", senderId: self.alice.userId, isFromWebhook: true, message: "deploy done")
        let route = MattermostPushRouter.route(payload, accounts: [self.alice], isMember: { _ in true }, alreadyDelivered: [])
        XCTAssertEqual(route.account?.accountId, 1)
    }

    func testMentionParsing() {
        XCTAssertTrue(MattermostPushRouter.mentions("@alice hi", username: "alice"))
        XCTAssertTrue(MattermostPushRouter.mentions("hi @Alice.", username: "alice"))
        XCTAssertTrue(MattermostPushRouter.mentions("(@alice)", username: "alice"))
        XCTAssertFalse(MattermostPushRouter.mentions("@alicex", username: "alice"))
        XCTAssertFalse(MattermostPushRouter.mentions("@alice.smith", username: "alice"))
        XCTAssertFalse(MattermostPushRouter.mentions("mail alice@example.com", username: "example"))
        XCTAssertTrue(MattermostPushRouter.mentions("@alice.smith thanks", username: "alice.smith"))
    }
}

final class MattermostPushClearTests: XCTestCase {
    private func delivered(_ name: String, accountId: Int64) throws -> [AnyHashable: Any] {
        var userInfo = try fixture(name)
        for (key, value) in MattermostPushUserInfo.additions(accountId: accountId, serverURL: "http://localhost:8065") {
            userInfo[key] = value
        }
        return userInfo
    }

    func testChannelClearKeepsCollapsedThreadReplies() throws {
        let mention = try self.delivered("channel-mention", accountId: 1)
        let reply = try self.delivered("thread-reply", accountId: 1)
        let dm = try self.delivered("dm", accountId: 1)
        XCTAssertTrue(MattermostPushClear.matches(userInfo: mention, channelId: "townsquare0000000000000000", rootId: nil, isCRTEnabled: true, serverId: serverId, accountId: nil))
        XCTAssertFalse(MattermostPushClear.matches(userInfo: reply, channelId: "townsquare0000000000000000", rootId: nil, isCRTEnabled: true, serverId: serverId, accountId: nil))
        XCTAssertFalse(MattermostPushClear.matches(userInfo: dm, channelId: "townsquare0000000000000000", rootId: nil, isCRTEnabled: true, serverId: serverId, accountId: nil))
        // Without collapsed threads everything in the channel goes.
        XCTAssertTrue(MattermostPushClear.matches(userInfo: reply, channelId: "townsquare0000000000000000", rootId: nil, isCRTEnabled: false, serverId: serverId, accountId: nil))
    }

    func testThreadClear() throws {
        let reply = try self.delivered("thread-reply", accountId: 1)
        let mention = try self.delivered("channel-mention", accountId: 1)
        XCTAssertTrue(MattermostPushClear.matches(userInfo: reply, channelId: "townsquare0000000000000000", rootId: "rootpost000000000000000001", isCRTEnabled: true, serverId: serverId, accountId: nil))
        XCTAssertFalse(MattermostPushClear.matches(userInfo: mention, channelId: "townsquare0000000000000000", rootId: "rootpost000000000000000001", isCRTEnabled: true, serverId: serverId, accountId: nil))
    }

    func testClearIsPerServerAndAccount() throws {
        let mention = try self.delivered("channel-mention", accountId: 1)
        XCTAssertFalse(MattermostPushClear.matches(userInfo: mention, channelId: "townsquare0000000000000000", rootId: nil, isCRTEnabled: true, serverId: "another", accountId: nil))
        XCTAssertFalse(MattermostPushClear.matches(userInfo: mention, channelId: "townsquare0000000000000000", rootId: nil, isCRTEnabled: true, serverId: serverId, accountId: 2))
        XCTAssertTrue(MattermostPushClear.matches(userInfo: mention, channelId: "townsquare0000000000000000", rootId: nil, isCRTEnabled: true, serverId: serverId, accountId: 1))
    }

    func testNotificationTarget() throws {
        let target = try XCTUnwrap(MattermostNotificationTarget(userInfo: try self.delivered("thread-reply", accountId: 7)))
        XCTAssertEqual(target.accountId, 7)
        XCTAssertEqual(target.channelId, "townsquare0000000000000000")
        XCTAssertEqual(target.postId, "replypost00000000000000001")
        XCTAssertEqual(target.replyRootId, "rootpost000000000000000001")
        XCTAssertEqual(target.serverURL, "http://localhost:8065")
        let dmTarget = try XCTUnwrap(MattermostNotificationTarget(userInfo: try self.delivered("dm", accountId: 7)))
        XCTAssertNil(dmTarget.replyRootId)
        XCTAssertNil(MattermostNotificationTarget(userInfo: try fixture("session")))
    }
}

final class MattermostPushDeviceTests: XCTestCase {
    func testDeviceId() {
        let token = Data([0x00, 0x01, 0xab, 0xff])
        XCTAssertEqual(MattermostPushDevice.deviceId(token: token, environment: .sandbox), "relay_apple_sandbox:0001abff")
        XCTAssertEqual(MattermostPushDevice.deviceId(token: token, environment: .production), "relay_apple:0001abff")
        // The proxy reads "-v<N>" in a platform as an app version: none of ours may contain it.
        XCTAssertFalse(MattermostPushDevice.sandboxPlatform.contains("-v"))
        XCTAssertFalse(MattermostPushDevice.productionPlatform.contains("-v"))
    }

    func testEnvironmentFromProfile() {
        let development = Data("garbage<plist><dict><key>Entitlements</key><dict><key>aps-environment</key>\n<string>development</string></dict></dict></plist>garbage".utf8)
        let production = Data("<key>aps-environment</key><string>production</string>".utf8)
        XCTAssertEqual(MattermostPushDevice.environment(isSimulator: false, embeddedProfile: development), .sandbox)
        XCTAssertEqual(MattermostPushDevice.environment(isSimulator: false, embeddedProfile: production), .production)
        XCTAssertEqual(MattermostPushDevice.environment(isSimulator: false, embeddedProfile: nil), .production)
        XCTAssertEqual(MattermostPushDevice.environment(isSimulator: true, embeddedProfile: production), .sandbox)
    }

    func testRegistrationRecord() {
        let session = MattermostPushRegistrationRecord.sessionTag(token: "token-a")
        XCTAssertNotEqual(session, MattermostPushRegistrationRecord.sessionTag(token: "token-b"))
        XCTAssertFalse(session.contains("token"))
        let record = MattermostPushRegistrationRecord(session: session, deviceId: "relay_apple_sandbox:aa", appVersion: "13.0.1 (1)", registeredAt: 1000)
        XCTAssertEqual(MattermostPushRegistrationRecord(encoded: record.encoded), record)
        XCTAssertFalse(record.needsRegistration(session: session, deviceId: "relay_apple_sandbox:aa", appVersion: "13.0.1 (1)", now: 2000))
        XCTAssertTrue(record.needsRegistration(session: "other", deviceId: "relay_apple_sandbox:aa", appVersion: "13.0.1 (1)", now: 2000))
        XCTAssertTrue(record.needsRegistration(session: session, deviceId: "relay_apple_sandbox:bb", appVersion: "13.0.1 (1)", now: 2000))
        XCTAssertTrue(record.needsRegistration(session: session, deviceId: "relay_apple_sandbox:aa", appVersion: "13.0.2 (1)", now: 2000))
        XCTAssertTrue(record.needsRegistration(session: session, deviceId: "relay_apple_sandbox:aa", appVersion: "13.0.1 (1)", now: 1000 + MattermostPushRegistrationRecord.refreshInterval + 1))
        XCTAssertNil(MattermostPushRegistrationRecord(encoded: "not json"))
    }

    func testSharedAccessGroup() {
        XCTAssertEqual(MattermostSessionKeychain.sharedAccessGroup(bundleIdentifier: "org.relaychat.Relay", isExtension: false), "group.org.relaychat.Relay")
        XCTAssertEqual(MattermostSessionKeychain.sharedAccessGroup(bundleIdentifier: "org.relaychat.Relay.NotificationService", isExtension: true), "group.org.relaychat.Relay")
    }
}

final class MattermostPushNamesTests: XCTestCase {
    func testOneAccountKeepsTheName() {
        let names = MattermostPushNames(title: "Town Square", recipientAccountName: nil)
        XCTAssertEqual(names.title, "Town Square")
        XCTAssertEqual(names.displayedName, "Town Square")
        XCTAssertEqual(names.donatedName, "Town Square")
    }

    func testSeveralAccountsNameTheRecipient() {
        let names = MattermostPushNames(title: "bob", recipientAccountName: "alice")
        XCTAssertEqual(names.title, "bob → alice")
        XCTAssertEqual(names.displayedName, "bob → alice")
        XCTAssertEqual(names.donatedName, "bob")
    }

    func testRightToLeftNamesPointTheOtherWay() {
        XCTAssertEqual(MattermostPushNames(title: "שלום", recipientAccountName: "alice").title, "שלום ← alice")
        XCTAssertEqual(MattermostPushNames(title: "42", recipientAccountName: "عمر").title, "42 ← عمر")
    }
}

final class MattermostPushDeliveryLogTests: XCTestCase {
    func testRecordsAndExpires() throws {
        let directory = NSTemporaryDirectory() + "/mm-push-log-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        let log = MattermostPushDeliveryLog(directory: directory)
        XCTAssertEqual(log.accounts(postId: "p", now: 100), [])
        log.record(postId: "p", accountId: 1, now: 100)
        log.record(postId: "p", accountId: 2, now: 101)
        log.record(postId: "q", accountId: 1, now: 102)
        XCTAssertEqual(log.accounts(postId: "p", now: 103), [1, 2])
        XCTAssertEqual(MattermostPushDeliveryLog(directory: directory).accounts(postId: "q", now: 103), [1])
        XCTAssertEqual(log.accounts(postId: "p", now: 100 + MattermostPushDeliveryLog.maxAge + 1), [])
    }
}
