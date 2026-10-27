import Foundation
import UIKit
import UserNotifications
import Intents
import AppLockState
import NotificationsPresentationData
import AppBundle
import MattermostKit
import MattermostSyncCore
import MattermostPush

// Relay's notification service for Mattermost pushes (Phase 3A, docs/plan/04). The notification service
// extension runs it for every Mattermost push (Telegram/NotificationService); debug builds of the app run the
// same code to deliver pushes on a simulator, where `simctl push` never starts a service extension
// (MattermostUI's debug remote, `simulate-push`).
//
// For a `message` push it
// 1. picks the account (`MattermostPushRouter`: server id, sender, channel membership, mention, delivery log)
//    from the accounts on this device: `<group>/telegram-data/account-*/mattermost/sync.sqlite` (read only;
//    the app writes it) with a session token in the shared Keychain group;
// 2. acknowledges the push (`POST /notifications/ack`, the account's token), and for an ID-only push takes
//    the text from the answer;
// 3. writes the text (`MattermostPushTextBuilder`: DM, channel, thread), groups by channel, adds the account
//    for the app (`MattermostPushUserInfo`), and makes it a communication notification from the sender
//    (`INSendMessageIntent`) with their picture: the one the app already downloaded (media box), else one
//    cached here, else `GET /users/{id}/image`;
// 4. names the account in the title when several are signed in (`MattermostPushNames`), as Telegram's
//    notifications do;
// 5. says "Voice message" for a Relay voice message (5A): the server wrote "attached a file." and pushes carry no
//    `props`, so the post is fetched (`GET /posts/{id}`, in parallel with the rest) for its `relay_voice` marker.
//
// `session` says to log in again. `clear` and `update_badge` arrive without `mutable-content` and never run
// the extension (the app removes cleared notifications; iOS applies the badge); if one does run it, it is
// handled the same way. A push for no account on this device (a session the app no longer has) is dropped.

private func mmLog(_ text: String) {
    let role = Bundle.main.bundlePath.hasSuffix(".appex") ? "nse" : "push-service (app)"
    NSLog("[Relay] %@: %@", role, text)
}

/// A sender's names, cached by the extension for a day (4F).
private struct MattermostPushSenderCache: Codable {
    let username: String
    let firstName: String
    let lastName: String
    let nickname: String
}

/// One account on this device, as far as the extension needs it.
private struct MattermostDeviceAccount {
    let account: MattermostPushAccount
    let basePath: String
    let siteName: String?
    let store: SQLiteMattermostSyncStore
}

/// One push: `start()` processes it and calls `contentHandler` once with the content to show;
/// `timeWillExpire()` delivers the best content ready so far.
public final class MattermostPushServiceHandler: @unchecked Sendable {
    private let request: UNNotificationRequest
    private let contentHandler: (UNNotificationContent) -> Void
    private let lock = NSLock()
    private var completed = false
    /// The best content so far, for `serviceExtensionTimeWillExpire`.
    private var fallbackContent: UNNotificationContent
    private var task: Task<Void, Never>?

    public init(request: UNNotificationRequest, contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.request = request
        self.contentHandler = contentHandler
        self.fallbackContent = request.content
    }

    public func start() {
        self.task = Task {
            let content = await self.process()
            self.complete(content)
        }
    }

    public func timeWillExpire() {
        mmLog("time expired; delivering what is ready")
        self.task?.cancel()
        let content = self.lock.mmWithLock { self.fallbackContent }
        self.complete(content)
    }

    private func complete(_ content: UNNotificationContent) {
        let shouldCall = self.lock.mmWithLock { () -> Bool in
            if self.completed {
                return false
            }
            self.completed = true
            return true
        }
        if shouldCall {
            self.contentHandler(content)
        }
    }

    private func setFallback(_ content: UNNotificationContent) {
        self.lock.mmWithLock {
            self.fallbackContent = content
        }
    }

    // MARK: Processing

    private func process() async -> UNNotificationContent {
        let userInfo = self.request.content.userInfo
        guard var payload = MattermostPushPayload(userInfo: userInfo) else {
            return self.request.content
        }
        // The app group (`group.<app bundle id>`) is also the shared Keychain group.
        guard let appGroup = MattermostSessionKeychain.sharedAccessGroup, let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            mmLog("no app group container")
            return self.request.content
        }
        // Telegram's data root (`rootPathForBasePath`, TelegramCore).
        let rootPath = groupURL.path + "/telegram-data"
        let pushDirectory = rootPath + "/mattermost-push"
        // Phase 4G: the certificate pins of the app's managed configuration (its copy in the app group) apply to
        // the acknowledgement, the sender and the avatar requests. The app applies its own.
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            let managed = MattermostManagedConfiguration.readShared(directory: URL(fileURLWithPath: rootPath)) ?? .none
            if MattermostServerTrust.shared.pins != managed.certificatePins {
                // The extension's process outlives a push: new pins get a new session (no connection reused).
                MattermostServerTrust.shared.setPins(managed.certificatePins)
                MattermostURLSession.renew()
            }
        }

        let accounts = self.loadAccounts(rootPath: rootPath)
        defer {
            for account in accounts {
                account.store.close()
            }
        }
        mmLog("\(payload.type.rawValue) push (server \(payload.serverId ?? "-"), channel \(payload.channelId ?? "-"), post \(payload.postId ?? "-")); \(accounts.count) account(s)")

        switch payload.type {
        case .clear:
            if let channelId = payload.channelId {
                await self.removeDelivered(channelId: channelId, payload: payload)
            }
            return self.emptyContent(badge: payload.badge)
        case .updateBadge:
            return self.emptyContent(badge: payload.badge)
        default:
            break
        }

        let deliveryLog = MattermostPushDeliveryLog(directory: pushDirectory)
        let channelId = payload.channelId
        let route = MattermostPushRouter.route(payload, accounts: accounts.map { $0.account }, isMember: { account in
            guard let channelId = channelId, let device = accounts.first(where: { $0.account.accountId == account.accountId }) else {
                return nil
            }
            // A channel the store knows is one the account is in; an unknown one may just be new.
            let isDirect = ((try? device.store.directChannelUserId(channelId: channelId)) ?? nil) != nil
            let isChannel = ((try? device.store.peer(mattermostId: channelId)) ?? nil) != nil
            return isDirect || isChannel ? true : nil
        }, alreadyDelivered: payload.postId.map { deliveryLog.accounts(postId: $0) } ?? [])
        guard var routed = route.account else {
            mmLog("no account for this push (\(route.reason)); dropped")
            return UNMutableNotificationContent()
        }
        if payload.type == .session && route.isAmbiguous {
            // A session push names no channel or sender: ask the server which candidate's session ended.
            for candidateId in route.candidateIds {
                guard let candidate = accounts.first(where: { $0.account.accountId == candidateId }), let client = self.client(for: candidate.account) else {
                    continue
                }
                let accepted = await client.isTokenAccepted()
                if !accepted {
                    routed = candidate.account
                    mmLog("session push: account \(candidateId)'s token is rejected")
                    break
                }
            }
        }
        guard let device = accounts.first(where: { $0.account.accountId == routed.accountId }) else {
            return UNMutableNotificationContent()
        }
        mmLog("routed to account \(routed.accountId) (\(route.reason)\(route.isAmbiguous ? ", ambiguous among \(route.candidateIds)" : ""))")
        if let postId = payload.postId {
            deliveryLog.record(postId: postId, accountId: routed.accountId)
        }

        let kind = self.channelKind(payload: payload, store: device.store)
        // Several accounts signed in: the title names the one notified ("Town Square → alice").
        let names = accounts.count > 1 ? (routed.username ?? routed.userId) : nil
        let lockedMessage = self.lockedMessage(rootPath: rootPath)

        // The sender as this account's display setting names users (4F); a cached name for the first version.
        let namesDirectory = pushDirectory + "/names"
        let cachedSenderName = lockedMessage == nil ? self.senderDisplayName(payload: payload, device: device, cacheDirectory: namesDirectory, user: nil) : nil

        // A first version without network work, in case time runs out.
        self.setFallback(self.content(payload: payload, kind: kind, device: device, recipientAccountName: names, lockedMessage: lockedMessage, avatar: nil, senderDisplayName: cachedSenderName))

        let client = self.client(for: routed)
        if client == nil {
            mmLog("account \(routed.accountId): no session token readable here; not acknowledging")
        }

        // Acknowledgement and picture in parallel.
        let pushed = payload
        let wantsAvatar = payload.type == .message && lockedMessage == nil
        async let ackResponse: Data? = self.acknowledge(payload: pushed, client: client)
        async let avatarData: Data? = wantsAvatar ? self.avatar(payload: pushed, device: device, client: client, cacheDirectory: pushDirectory + "/avatars") : nil
        async let senderUser: MattermostPushSenderCache? = (wantsAvatar && cachedSenderName == nil) ? self.senderUser(payload: pushed, device: device, client: client, cacheDirectory: namesDirectory) : nil
        async let isVoiceMessage: Bool = wantsAvatar ? self.isVoiceMessage(payload: pushed, client: client) : false
        if let data = await ackResponse, payload.isIdLoaded, let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            payload.merge(idLoadedResponse: response)
        }
        let avatar = await avatarData
        let fetchedUser = await senderUser
        let senderName = cachedSenderName ?? (lockedMessage == nil ? self.senderDisplayName(payload: payload, device: device, cacheDirectory: namesDirectory, user: fetchedUser) : nil)
        let voiceMessage = await isVoiceMessage ? self.voiceMessageText() : nil
        return self.content(payload: payload, kind: kind, device: device, recipientAccountName: names, lockedMessage: lockedMessage, avatar: avatar, senderDisplayName: senderName, voiceMessage: voiceMessage)
    }

    // MARK: Voice messages (5A)

    /// Whether the pushed post is a Relay voice message: the `relay_voice` marker, one audio file and no text.
    private func isVoiceMessage(payload: MattermostPushPayload, client: MattermostClient?) async -> Bool {
        guard let client = client, let postId = payload.postId else {
            return false
        }
        do {
            let post = try await client.post(id: postId)
            let marker = VoiceMessageMarker(propsValue: post.props[VoiceMessageMarker.propsKey]?.foundationObject)
            let files = (post.metadata?.files ?? []).filter { $0.deleteAt == 0 }.map { (name: $0.name, mimeType: $0.mimeType) }
            let isVoice = post.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && VoiceMessageFile.isVoicePost(marker: marker, files: files)
            if isVoice {
                mmLog("post \(postId) is a voice message")
            }
            return isVoice
        } catch {
            mmLog("post \(postId) not loaded: \(error)")
            return false
        }
    }

    /// "Voice message" in the app's language: the extension has no strings, the app's bundle has Relay's.
    private func voiceMessageText() -> String {
        return getAppBundle().localizedString(forKey: "Relay.Push.VoiceMessage", value: "Voice message", table: nil)
    }

    // MARK: Sender name (4F)

    /// The sender's name in the account's display format (`MattermostPushSenderName`, stored by the app), from
    /// `user` or the cache; nil without a stored format, for webhook names, and when the sender isn't known yet.
    private func senderDisplayName(payload: MattermostPushPayload, device: MattermostDeviceAccount, cacheDirectory: String, user: MattermostPushSenderCache?) -> String? {
        guard payload.type == .message, let senderId = payload.senderId, (payload.overrideUsername ?? "").isEmpty, let format = (try? device.store.cursor(MattermostPushSenderName.nameFormatCursor)) ?? nil else {
            return nil
        }
        guard let user = user ?? self.cachedSender(accountId: device.account.accountId, senderId: senderId, cacheDirectory: cacheDirectory) else {
            return nil
        }
        return MattermostPushSenderName.displayName(username: user.username, firstName: user.firstName, lastName: user.lastName, nickname: user.nickname, format: format)
    }

    private func cachedSender(accountId: Int64, senderId: String, cacheDirectory: String) -> MattermostPushSenderCache? {
        let path = cacheDirectory + "/\(accountId)-\(senderId).json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 24 * 60 * 60, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(MattermostPushSenderCache.self, from: data)
    }

    /// `GET /users/{id}` for the sender (cached for a day), when the account has a stored display format.
    private func senderUser(payload: MattermostPushPayload, device: MattermostDeviceAccount, client: MattermostClient?, cacheDirectory: String) async -> MattermostPushSenderCache? {
        guard let client = client, let senderId = payload.senderId, (payload.overrideUsername ?? "").isEmpty, ((try? device.store.cursor(MattermostPushSenderName.nameFormatCursor)) ?? nil) != nil else {
            return nil
        }
        do {
            let user = try await client.user(id: senderId)
            let value = MattermostPushSenderCache(username: user.username, firstName: user.firstName, lastName: user.lastName, nickname: user.nickname)
            try? FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(value) {
                try? data.write(to: URL(fileURLWithPath: cacheDirectory + "/\(device.account.accountId)-\(senderId).json"), options: .atomic)
            }
            return value
        } catch {
            mmLog("sender \(senderId) not loaded: \(error)")
            return nil
        }
    }

    // MARK: Accounts

    /// A client with the account's session token from the shared Keychain group, if this process can read it.
    private func client(for account: MattermostPushAccount) -> MattermostClient? {
        guard let token = MattermostSessionKeychain.token(accountId: account.accountId), let url = URL(string: account.serverURL) else {
            return nil
        }
        var configuration = MattermostClient.Configuration(serverURL: url, userAgent: "Relay/0.1 (iOS; NotificationService)")
        configuration.timeoutInterval = 8
        return MattermostClient(configuration: configuration, token: token)
    }

    private func loadAccounts(rootPath: String) -> [MattermostDeviceAccount] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else {
            return []
        }
        // Every account directory with a server counts, with or without a readable token (an app-only token of
        // an earlier build is moved to the shared group only when the app runs). A logged-out account's
        // directory is deleted right after its session ended, so the server no longer pushes for it.
        var result: [MattermostDeviceAccount] = []
        for name in names where name.hasPrefix("account-") {
            guard let unsigned = UInt64(name.dropFirst("account-".count)) else {
                continue
            }
            let accountId = Int64(bitPattern: unsigned)
            let basePath = rootPath + "/" + name
            let storePath = basePath + "/mattermost/sync.sqlite"
            guard FileManager.default.fileExists(atPath: storePath) else {
                continue
            }
            guard let store = try? SQLiteMattermostSyncStore(path: storePath) else {
                continue
            }
            guard let server = (try? store.serverInfo()) ?? nil else {
                store.close()
                continue
            }
            var diagnosticId: String?
            if let json = server.capabilitiesJSON, let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
                diagnosticId = object["diagnosticId"] as? String
            }
            let username = (try? store.cursor("own_username")) ?? nil
            let account = MattermostPushAccount(accountId: accountId, serverURL: server.url, serverId: diagnosticId, userId: server.userId, username: username, order: 0)
            result.append(MattermostDeviceAccount(account: account, basePath: basePath, siteName: server.siteName, store: store))
        }
        return result.sorted(by: { $0.account.accountId < $1.account.accountId })
    }

    private func channelKind(payload: MattermostPushPayload, store: SQLiteMattermostSyncStore) -> MattermostPushChannelKind {
        guard let channelId = payload.channelId else {
            return .unknown
        }
        if ((try? store.directChannelUserId(channelId: channelId)) ?? nil) != nil {
            return .direct
        }
        if let peer = (try? store.peer(mattermostId: channelId)) ?? nil {
            switch peer.kind {
            case .groupMessage:
                return .group
            case .channel:
                return .channel
            case .user:
                return .direct
            }
        }
        return .unknown
    }

    private func lockedMessage(rootPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: rootPath))), let state = try? JSONDecoder().decode(LockState.self, from: data), isAppLocked(state: state) else {
            return nil
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: notificationsPresentationDataPath(rootPath: rootPath))), let value = try? JSONDecoder().decode(NotificationsPresentationData.self, from: data) {
            return value.applicationLockedMessageString
        }
        return "You have a new message"
    }

    // MARK: Network

    /// The answer of an ID-only push's acknowledgement (the post as `model.PushNotification` JSON).
    private func acknowledge(payload: MattermostPushPayload, client: MattermostClient?) async -> Data? {
        guard let client = client, let ackId = payload.ackId else {
            return nil
        }
        let ack = PushNotificationAck(id: ackId, platform: MattermostPushDevice.ackPlatform, type: payload.type.rawValue, postId: payload.postId, isIdLoaded: payload.isIdLoaded, receivedAt: Int64(Date().timeIntervalSince1970 * 1000))
        do {
            let response = try await client.acknowledgeNotification(ack)
            mmLog("acknowledged \(ackId)")
            guard payload.isIdLoaded, case .object = response else {
                return nil
            }
            return try? JSONEncoder().encode(response)
        } catch {
            mmLog("ack \(ackId) failed: \(error)")
            return nil
        }
    }

    /// The sender's picture: the app's copy in the account's media box, else the extension's cache (a day),
    /// else the server.
    private func avatar(payload: MattermostPushPayload, device: MattermostDeviceAccount, client: MattermostClient?, cacheDirectory: String) async -> Data? {
        guard let senderId = payload.senderId, !payload.isFromWebhook || payload.overrideIconURL == nil else {
            return nil
        }
        let mediaPath = device.basePath + "/postbox/media"
        let prefix = "mm-avatar-\(senderId)-"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: mediaPath) {
            let candidates = names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("_partial") }.sorted(by: { lhs, rhs in
                return (Int64(lhs.dropFirst(prefix.count)) ?? 0) > (Int64(rhs.dropFirst(prefix.count)) ?? 0)
            })
            if let name = candidates.first, let data = try? Data(contentsOf: URL(fileURLWithPath: mediaPath + "/" + name)), UIImage(data: data) != nil {
                return data
            }
        }
        try? FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
        let cachePath = cacheDirectory + "/\(device.account.accountId)-\(senderId)"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath), let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 24 * 60 * 60, let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) {
            return data
        }
        guard let client = client else {
            return nil
        }
        do {
            let data = try await client.data(for: .userImage(userId: senderId))
            guard UIImage(data: data) != nil else {
                return nil
            }
            try? data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
            return data
        } catch {
            mmLog("avatar of \(senderId) not loaded: \(error)")
            return nil
        }
    }

    private func removeDelivered(channelId: String, payload: MattermostPushPayload) async {
        let center = UNUserNotificationCenter.current()
        let notifications = await center.deliveredNotifications()
        let ids = notifications.filter { MattermostPushClear.matches(userInfo: $0.request.content.userInfo, channelId: channelId, rootId: payload.rootId, isCRTEnabled: payload.isCRTEnabled, serverId: payload.serverId, accountId: nil) }.map { $0.request.identifier }
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: Content

    private func emptyContent(badge: Int?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        if let badge = badge {
            content.badge = badge as NSNumber
        }
        return content
    }

    private func content(payload: MattermostPushPayload, kind: MattermostPushChannelKind, device: MattermostDeviceAccount, recipientAccountName: String?, lockedMessage: String?, avatar: Data?, senderDisplayName: String?, voiceMessage: String? = nil) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        var userInfo = self.request.content.userInfo
        for (key, value) in MattermostPushUserInfo.additions(accountId: device.account.accountId, serverURL: device.account.serverURL) {
            userInfo[key] = value
        }
        content.userInfo = userInfo
        if let badge = payload.badge {
            content.badge = badge as NSNumber
        }
        if payload.sound != nil || payload.type == .message {
            content.sound = .default
        }

        if let lockedMessage = lockedMessage {
            let text = MattermostPushTextBuilder.lockedText(for: payload, placeholder: lockedMessage)
            content.body = text.body
            content.threadIdentifier = text.threadIdentifier
            return content
        }

        let text = MattermostPushTextBuilder.text(for: payload, kind: kind, siteName: device.siteName, senderDisplayName: senderDisplayName, voiceMessage: voiceMessage)
        let names = MattermostPushNames(title: text.title, recipientAccountName: recipientAccountName)
        content.title = names.title
        if let subtitle = text.subtitle {
            content.subtitle = subtitle
        }
        content.body = text.body
        content.threadIdentifier = text.threadIdentifier
        if payload.type == .message {
            content.categoryIdentifier = MattermostPushUserInfo.messageCategory
        }

        guard text.isCommunication, let senderId = payload.senderId, let senderName = text.senderName else {
            return content
        }
        // iOS draws a communication notification's title from the intent (the sender of a DM, the group of a
        // channel), not from `content.title`, so the account goes into that name; the donated interaction
        // (Siri and share suggestions) keeps the plain names.
        let image = avatar.map { INImage(imageData: $0) }
        let conversationId = payload.channelId ?? senderId
        let displayed: INSendMessageIntent
        let donated: INSendMessageIntent
        if text.groupName != nil {
            displayed = self.intent(senderId: senderId, senderName: senderName, groupName: names.displayedName, conversationId: conversationId, body: content.body, image: image)
            donated = names.displayedName == names.donatedName ? displayed : self.intent(senderId: senderId, senderName: senderName, groupName: names.donatedName, conversationId: conversationId, body: content.body, image: image)
        } else {
            displayed = self.intent(senderId: senderId, senderName: names.displayedName, groupName: nil, conversationId: conversationId, body: content.body, image: image)
            donated = names.displayedName == names.donatedName ? displayed : self.intent(senderId: senderId, senderName: names.donatedName, groupName: nil, conversationId: conversationId, body: content.body, image: image)
        }
        let interaction = INInteraction(intent: donated, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        do {
            return try content.updating(from: displayed)
        } catch {
            mmLog("not a communication notification: \(error)")
            return content
        }
    }

    /// A message from `senderName`; with `groupName`, in a group conversation (channels, group messages), which
    /// iOS titles with the group and draws with the sender's picture.
    private func intent(senderId: String, senderName: String, groupName: String?, conversationId: String, body: String, image: INImage?) -> INSendMessageIntent {
        var nameComponents = PersonNameComponents()
        nameComponents.nickname = senderName
        let sender = INPerson(
            personHandle: INPersonHandle(value: senderId, type: .unknown),
            nameComponents: nameComponents,
            displayName: senderName,
            image: image,
            contactIdentifier: nil,
            customIdentifier: senderId,
            isMe: false,
            suggestionType: .none
        )
        let me = INPerson(personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true, suggestionType: .none)
        var recipients = [me]
        if groupName != nil {
            // iOS treats a conversation as a group only with more than one recipient.
            recipients.append(INPerson(personHandle: INPersonHandle(value: conversationId, type: .unknown), nameComponents: nil, displayName: groupName, image: nil, contactIdentifier: nil, customIdentifier: conversationId, isMe: false, suggestionType: .none))
        }
        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: groupName.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: conversationId,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        if let image = image {
            intent.setImage(image, forParameterNamed: \.sender)
        }
        return intent
    }
}

extension NSLock {
    fileprivate func mmWithLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}
