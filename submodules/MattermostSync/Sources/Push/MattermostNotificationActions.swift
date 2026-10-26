import Foundation
import UserNotifications
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import MattermostPush

/// Where a tapped Mattermost notification leads.
public struct MattermostNotificationDestination: Equatable {
    public let accountId: AccountRecordId
    public let peerId: PeerId
    /// The thread (root post's local id) for a reply in a channel; nil otherwise.
    public let threadId: Int64?
    /// The notified post.
    public let messageId: MessageId?
}

/// The app side of Mattermost notifications (docs/plan/04 "Notification actions"): what a tap opens, Reply and
/// Mark as Read, `clear` pushes, and removing delivered notifications of a channel the user read.
///
/// The notification service extension stores the account it routed a push to (`accountId`) next to the
/// push's own keys (`MattermostPushUserInfo`); without it (the extension did not run) the account is the one
/// on the push's server that knows the channel.
extension MattermostSync {
    // MARK: Entry points for TelegramUI (userInfo only, so TelegramUI needs no MattermostPush import)

    /// Whether a delivered notification (or a push) came from a Mattermost server.
    public static func isMattermostNotification(userInfo: [AnyHashable: Any]) -> Bool {
        return MattermostPushPayload.isMattermostPush(userInfo)
    }

    /// The account a Mattermost notification belongs to, for the account switch before opening the chat.
    public static func notificationAccountId(userInfo: [AnyHashable: Any]) -> AccountRecordId? {
        guard let target = MattermostNotificationTarget(userInfo: userInfo) else {
            return self.registry.with { registry in
                let payload = MattermostPushPayload(userInfo: userInfo)
                return registry.first(where: { payload?.serverId != nil && $0.value.server.diagnosticId == payload?.serverId })?.key
            }
        }
        return self.accountId(for: target)
    }

    /// The account and chat of a notification if the account's sync already knows the channel (no waiting;
    /// for the foreground presentation).
    public static func notificationChat(userInfo: [AnyHashable: Any]) -> (AccountRecordId, PeerId)? {
        guard let target = MattermostNotificationTarget(userInfo: userInfo), let accountId = self.accountId(for: target), let peerId = self.sync(accountId: accountId)?.channelState(target.channelId)?.peerId else {
            return nil
        }
        return (accountId, peerId)
    }

    /// The chat (and post) a tapped notification opens. Waits for the account's sync (the app may have been
    /// launched by the tap) and maps the post if the sync has not seen it yet.
    public static func notificationDestination(userInfo: [AnyHashable: Any]) -> Signal<MattermostNotificationDestination?, NoError> {
        guard let target = MattermostNotificationTarget(userInfo: userInfo) else {
            return .single(nil)
        }
        return self.signal {
            return await self.destination(for: target)
        }
    }

    /// Reply from the notification: through the write path (pending message, retried until the server takes
    /// it) once the account's sync runs; `POST /posts` directly if it doesn't within 20 s. True when the
    /// server has the post.
    public static func replyFromNotification(userInfo: [AnyHashable: Any], text: String) -> Signal<Bool, NoError> {
        guard let target = MattermostNotificationTarget(userInfo: userInfo) else {
            return .single(false)
        }
        return self.signal {
            return await self.reply(target: target, text: text)
        }
    }

    /// Mark as Read: `POST /channels/members/me/view` (and the thread for a collapsed-thread reply), then the
    /// local read state and the channel's delivered notifications.
    public static func markReadFromNotification(userInfo: [AnyHashable: Any]) -> Signal<Bool, NoError> {
        guard let target = MattermostNotificationTarget(userInfo: userInfo) else {
            return .single(false)
        }
        return self.signal {
            return await self.markRead(target: target)
        }
    }

    /// A background push for the app (`clear`): removes the delivered notifications it names. Returns
    /// whether the push was a Mattermost one (the caller completes the fetch handler either way).
    public static func handleBackgroundPush(userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = MattermostPushPayload(userInfo: userInfo) else {
            return false
        }
        MMLog.log("push: background \(payload.type.rawValue) for channel \(payload.channelId ?? "-")")
        if payload.type == .clear, let channelId = payload.channelId {
            self.removeDeliveredNotifications(channelId: channelId, rootId: payload.rootId, isCRTEnabled: payload.isCRTEnabled, serverId: payload.serverId, accountId: nil)
        }
        return true
    }

    /// The notification category of Mattermost message notifications: Reply and Mark as Read.
    public static func notificationCategories(replyTitle: String, replyPlaceholder: String, markReadTitle: String, hiddenPreviewsBodyPlaceholder: String, options: UNNotificationCategoryOptions) -> [UNNotificationCategory] {
        let reply = UNTextInputNotificationAction(identifier: MattermostPushUserInfo.replyActionIdentifier, title: replyTitle, options: [], textInputButtonTitle: replyTitle, textInputPlaceholder: replyPlaceholder)
        let markRead = UNNotificationAction(identifier: MattermostPushUserInfo.markReadActionIdentifier, title: markReadTitle, options: [])
        return [
            UNNotificationCategory(identifier: MattermostPushUserInfo.messageCategory, actions: [reply, markRead], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenPreviewsBodyPlaceholder, options: options)
        ]
    }

    public static let notificationReplyActionIdentifier = MattermostPushUserInfo.replyActionIdentifier
    public static let notificationMarkReadActionIdentifier = MattermostPushUserInfo.markReadActionIdentifier

    // MARK: Debug

    /// **Debug builds:** the app's handler for notification responses (set by the AppDelegate), so the debug
    /// remote can run a tap or an action on a delivered notification without UI automation. Arguments:
    /// `userInfo`, action identifier (`UNNotificationDefaultActionIdentifier`, reply, mark read), reply text.
    public static var debugNotificationResponder: (([AnyHashable: Any], String, String?) -> Void)?

    /// Push state for the debug remote: token, environment, each account's registration and where its token
    /// is stored.
    public static func debugPushState() -> [String: Any] {
        var accounts: [[String: Any]] = []
        for (id, registered) in self.registry.with({ $0 }) {
            var entry: [String: Any] = [
                "accountId": "\(id.int64)",
                "serverId": registered.server.diagnosticId ?? "",
                "keychain": MattermostSessionKeychain.location(accountId: id.int64).map { $0 == .shared ? "shared" : "appOnly" } ?? "none"
            ]
            if let sync = self.sync(accountId: id), let record = MattermostPushRegistrationRecord(encoded: sync.store.cursor(self.pushRegistrationCursor)) {
                entry["deviceId"] = record.deviceId
                entry["appVersion"] = record.appVersion
                entry["registeredAt"] = record.registeredAt
            }
            accounts.append(entry)
        }
        return [
            "token": self.currentPushToken.map { MattermostPushDevice.hexToken($0) } ?? "",
            "environment": MattermostPushDevice.currentEnvironment().rawValue,
            "accounts": accounts.sorted(by: { ($0["accountId"] as? String ?? "") < ($1["accountId"] as? String ?? "") })
        ]
    }

    // MARK: Removing delivered notifications

    /// Removes the delivered notifications of a channel (or of one collapsed thread). `accountId` limits it to
    /// one account's notifications.
    static func removeDeliveredNotifications(channelId: String, rootId: String?, isCRTEnabled: Bool, serverId: String?, accountId: Int64?) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications(completionHandler: { notifications in
            let ids = notifications.filter { notification in
                return MattermostPushClear.matches(userInfo: notification.request.content.userInfo, channelId: channelId, rootId: rootId, isCRTEnabled: isCRTEnabled, serverId: serverId, accountId: accountId)
            }.map { $0.request.identifier }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
                MMLog.log("push: removed \(ids.count) delivered notification(s) of \(channelId)")
            }
        })
    }

    // MARK: Accounts

    static func runningSyncs() -> [MattermostAccountSync] {
        return self.accounts.with { Array($0.values) }
    }

    /// The extension's account, else the account on the push's server (the one whose sync knows the channel
    /// first).
    static func accountId(for target: MattermostNotificationTarget) -> AccountRecordId? {
        if let value = target.accountId {
            let id = AccountRecordId(rawValue: value)
            if self.registry.with({ $0[id] != nil }) {
                return id
            }
        }
        let candidates = self.registry.with { registry -> [AccountRecordId] in
            return registry.filter { _, registered in
                if let serverId = target.serverId, let known = registered.server.diagnosticId {
                    return known == serverId
                }
                if let serverURL = target.serverURL {
                    return registered.server.url == serverURL
                }
                return true
            }.map { $0.key }.sorted(by: { $0.int64 < $1.int64 })
        }
        return candidates.first(where: { self.sync(accountId: $0)?.channelState(target.channelId) != nil }) ?? candidates.first
    }

    /// `accountId(for:)` once the app has loaded its accounts (a tap or an action may have launched it), waiting
    /// up to 20 s.
    static func waitForAccountId(for target: MattermostNotificationTarget) async -> AccountRecordId? {
        let deadline = CFAbsoluteTimeGetCurrent() + 20.0
        while CFAbsoluteTimeGetCurrent() < deadline && !Task.isCancelled {
            if let id = self.accountId(for: target) {
                // The extension's account, or one on the push's server once every account is loaded.
                if target.accountId == nil || target.accountId == id.int64 || CFAbsoluteTimeGetCurrent() > deadline - 15.0 {
                    return id
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return self.accountId(for: target)
    }

    /// The account's sync once it runs and has bootstrapped, waiting up to `timeout` seconds.
    static func waitForBootstrappedSync(accountId: AccountRecordId, timeout: Double) async -> MattermostAccountSync? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline && !Task.isCancelled {
            if let sync = self.sync(accountId: accountId), sync.state.with({ $0.isBootstrapped }) {
                return sync
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// A client for the account even when its sync is not running (token from the Keychain).
    static func notificationClient(accountId: AccountRecordId) -> (client: MattermostClient, server: MattermostServerInfo)? {
        if let sync = self.sync(accountId: accountId) {
            return (sync.client, sync.server)
        }
        guard let registered = self.registry.with({ $0[accountId] }), let url = URL(string: registered.server.url), let token = MattermostKeychain.token(accountId: accountId.int64) else {
            return nil
        }
        var configuration = MattermostClient.Configuration(serverURL: url, userAgent: self.userAgent)
        configuration.timeoutInterval = 15
        return (MattermostClient(configuration: configuration, token: token), registered.server)
    }

    static func signal<T>(_ body: @escaping () async -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            let task = Task {
                let value = await body()
                subscriber.putNext(value)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    // MARK: Tap

    static func destination(for target: MattermostNotificationTarget) async -> MattermostNotificationDestination? {
        guard let accountId = await self.waitForAccountId(for: target) else {
            MMLog.log("push: no account for the notification of channel \(target.channelId)")
            return nil
        }
        guard let sync = await self.waitForBootstrappedSync(accountId: accountId, timeout: 20.0) else {
            MMLog.log("push: account \(accountId.int64) did not start in time; opening nothing")
            return nil
        }
        guard let channelState = sync.channelState(target.channelId) else {
            MMLog.log("push: account \(accountId.int64) has no channel \(target.channelId)")
            return nil
        }
        let peerId = channelState.peerId
        var threadId: Int64?
        var messageId: MessageId?
        // A reply opens in its thread with collapsed reply threads, else in its chat (where it shows inline).
        if channelState.kind != .saved, sync.isCollapsedThreads, let rootId = target.replyRootId, let rootLocalId = await sync.notificationLocalId(postId: rootId, channelId: target.channelId) {
            threadId = Int64(rootLocalId)
        }
        if let postId = target.postId, let localId = await sync.notificationLocalId(postId: postId, channelId: target.channelId) {
            messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: localId)
        }
        MMLog.log("push: open \(target.channelId) post \(target.postId ?? "-") → peer \(peerId), thread \(threadId.map { "\($0)" } ?? "-"), message \(messageId.map { "\($0.id)" } ?? "-")")
        return MattermostNotificationDestination(accountId: accountId, peerId: peerId, threadId: threadId, messageId: messageId)
    }

    // MARK: Reply

    static func reply(target: MattermostNotificationTarget, text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let accountId = await self.waitForAccountId(for: target) else {
            return false
        }
        if let sync = await self.waitForBootstrappedSync(accountId: accountId, timeout: 20.0), let channelState = sync.channelState(target.channelId) {
            var replySubject: EngineMessageReplySubject?
            if let rootId = target.replyRootId {
                guard let rootLocalId = await sync.notificationLocalId(postId: rootId, channelId: target.channelId) else {
                    return await self.replyDirectly(target: target, accountId: accountId, text: text)
                }
                replySubject = EngineMessageReplySubject(messageId: MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: rootLocalId), quote: nil, innerSubject: nil)
            }
            let ids = await enqueueMessages(account: sync.account, peerId: channelState.peerId, messages: [.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: replySubject, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).awaitValue()
            guard let messageId = ids?.first ?? nil else {
                MMLog.log("push: reply to \(target.channelId) was not enqueued")
                return false
            }
            MMLog.log("push: reply to \(target.channelId) enqueued as \(messageId)")
            return await sync.waitUntilSent(messageId: messageId, seconds: 25.0)
        }
        return await self.replyDirectly(target: target, accountId: accountId, text: text)
    }

    /// `POST /posts` without the write path (the sync is not running, or the thread root is unknown).
    static func replyDirectly(target: MattermostNotificationTarget, accountId: AccountRecordId, text: String) async -> Bool {
        guard let (client, _) = self.notificationClient(accountId: accountId) else {
            return false
        }
        do {
            let post = try await client.createPost(PostDraft(channelId: target.channelId, message: text, rootId: target.replyRootId ?? "", pendingPostId: "relay-notification-\(UUID().uuidString.lowercased())"))
            MMLog.log("push: reply posted directly as \(post.id) in \(target.channelId)")
            return true
        } catch {
            MMLog.log("push: direct reply to \(target.channelId) failed: \(error)")
            return false
        }
    }

    // MARK: Mark as read

    static func markRead(target: MattermostNotificationTarget) async -> Bool {
        guard let accountId = await self.waitForAccountId(for: target), let (client, server) = self.notificationClient(accountId: accountId) else {
            return false
        }
        do {
            _ = try await client.viewChannel(channelId: target.channelId)
            if target.isCRTEnabled, let rootId = target.replyRootId {
                var teamId = target.teamId
                if teamId == nil {
                    teamId = self.sync(accountId: accountId)?.state.with { $0.teams.first?.id }
                }
                if let teamId = teamId {
                    do {
                        try await client.markThreadRead(teamId: teamId, threadId: rootId, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
                    } catch {
                        MMLog.log("push: marking thread \(rootId) read failed: \(error)")
                    }
                }
            }
            MMLog.log("push: marked \(target.channelId) read (account \(accountId.int64))")
        } catch {
            MMLog.log("push: marking \(target.channelId) read failed: \(error)")
            return false
        }
        if let sync = self.sync(accountId: accountId) {
            await sync.refreshReadState(channelId: target.channelId)
        }
        self.removeDeliveredNotifications(channelId: target.channelId, rootId: nil, isCRTEnabled: false, serverId: server.diagnosticId, accountId: accountId.int64)
        return true
    }
}

extension MattermostServerInfo {
    /// The server's `DiagnosticId` (= `server_id` of its pushes), kept with the capabilities at login.
    var diagnosticId: String? {
        guard let json = self.capabilitiesJSON, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        return (object["diagnosticId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension MattermostAccountSync {
    /// The local id of a post for a notification: from the ID map (after a short wait for the catch-up that a
    /// launch or reconnect runs), else mapped now as a jump target (`.aroundId` then loads it with its
    /// neighbours, as for a permalink).
    func notificationLocalId(postId: String, channelId: String) async -> Int32? {
        for _ in 0 ..< 20 {
            if let entry = self.store.entries(channelId: channelId, postIds: [postId])[postId] {
                return entry.isDeleted ? nil : entry.localId
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if let entry = self.store.entries(channelId: channelId, postIds: [postId])[postId] {
            return entry.isDeleted ? nil : entry.localId
        }
        do {
            let post = try await self.client.post(id: postId)
            guard post.channelId == channelId else {
                return nil
            }
            return await self.postbox.mmTransaction { _ -> Int32? in
                if let entry = self.store.entries(channelId: channelId, postIds: [postId])[postId] {
                    return entry.isDeleted ? nil : entry.localId
                }
                var store = self.storeRef()
                var ingest: IngestResult?
                let _ = self.store.idMapTransaction {
                    ingest = try self.allocator.insertPost(PostOrderKey(createAt: post.createAt, postId: post.id), channelId: channelId, store: &store)
                }
                guard let localId = ingest?.localId(for: post.id) else {
                    return nil
                }
                self.state.with { $0.reservedJumpIds[channelId, default: []].insert(localId) }
                MMLog.log("push: mapped post \(postId) of \(channelId) as local id \(localId) (jump)")
                return localId
            }
        } catch {
            MMLog.log("push: post \(postId) could not be loaded: \(error)")
            return nil
        }
    }

    /// Waits until PendingMessageManager is done with a message; true if it was sent (not failed).
    func waitUntilSent(messageId: MessageId, seconds: Double) async -> Bool {
        let done = await (self.postbox.unsentMessageIdsView()
        |> filter { view in
            return !view.ids.contains(messageId)
        }
        |> take(1)
        |> map { _ -> Bool in
            return true
        }
        |> SwiftSignalKit.timeout(seconds, queue: Queue.concurrentDefaultQueue(), alternate: Signal<Bool, NoError>.single(false))).awaitValue() ?? false
        if !done {
            MMLog.log("push: reply \(messageId) still pending after \(Int(seconds)) s (it is sent when the app runs next)")
            return false
        }
        let failed = await self.postbox.mmTransaction { transaction -> Bool in
            return transaction.getMessage(messageId)?.flags.contains(.Failed) ?? false
        }
        MMLog.log("push: reply \(messageId) \(failed ? "failed" : "sent")")
        return !failed
    }

    /// The channel's read state from the server (after Mark as Read).
    func refreshReadState(channelId: String) async {
        do {
            let member = try await self.client.channelMember(channelId: channelId)
            let mentionCount = self.memberMentionCount(member)
            await self.postbox.mmTransaction { transaction in
                self.state.with { state in
                    state.channels[channelId]?.member = member
                    state.channels[channelId]?.mentionCount = mentionCount
                }
                self.applyServerReadState(channelId: channelId, transaction: transaction)
            }
        } catch {
            MMLog.log("push: read state of \(channelId) not refreshed: \(error)")
        }
    }
}
