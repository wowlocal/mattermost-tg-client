import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

// Phase 3F: the user's own status (online / away / do not disturb with an end / offline), custom status, profile
// fields and picture, and notification preferences (the user's and each channel's). Settings and the profile
// screens call these; every change goes to the server first and comes back through the same paths as changes made
// on other devices (`status_change`, `user_updated`, `channel_member_updated`).

/// The user's status and custom status as the server has them.
public struct MattermostOwnStatus: Equatable {
    public enum Status: String, Equatable, CaseIterable {
        case online
        case away
        case dnd
        case offline
    }

    public var status: Status
    /// Set by hand (Mattermost then doesn't switch between online and away by activity).
    public var isManual: Bool
    /// End of do-not-disturb, when set.
    public var dndEnd: Date?
    public var customStatus: MattermostCustomStatus?

    public init(status: Status, isManual: Bool, dndEnd: Date?, customStatus: MattermostCustomStatus?) {
        self.status = status
        self.isManual = isManual
        self.dndEnd = dndEnd
        self.customStatus = customStatus
    }
}

/// A custom status (own, recent or suggested).
public struct MattermostCustomStatus: Equatable {
    /// The emoji's name, as Mattermost stores it (empty: none).
    public let emojiName: String
    /// The emoji to show: Unicode, or `:name:` for a server custom emoji; the default emoji for a text-only status.
    public let emoji: String
    public let text: String
    /// Mattermost's `duration` (`""`, `thirty_minutes`, …, `date_and_time`).
    public let duration: String
    public let expiresAt: Date?

    public init(emojiName: String, text: String, duration: String, expiresAt: Date?) {
        self.emojiName = emojiName
        self.emoji = MattermostCustomStatus.displayEmoji(name: emojiName.isEmpty ? CustomStatusRules.defaultEmoji : emojiName)
        self.text = text
        self.duration = duration
        self.expiresAt = expiresAt
    }

    init(_ status: UserCustomStatus) {
        self.init(emojiName: status.emoji, text: status.text, duration: status.duration, expiresAt: status.expiryDate)
    }

    /// Unicode for a built-in emoji name, `:name:` otherwise.
    public static func displayEmoji(name: String) -> String {
        return EmojiTable.unicode(forName: name) ?? ":\(name):"
    }

    /// The Mattermost name of an emoji the picker returned (Unicode or `:name:`), nil if it has none.
    public static func emojiName(forDisplayEmoji emoji: String) -> String? {
        if emoji.count > 2, emoji.hasPrefix(":"), emoji.hasSuffix(":") {
            return String(emoji.dropFirst().dropLast())
        }
        if let name = EmojiTable.name(forUnicode: emoji) {
            return name
        }
        // The picker may hand over a variation the table lists without (or with) U+FE0F.
        let stripped = emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
        return EmojiTable.name(forUnicode: stripped) ?? EmojiTable.name(forUnicode: stripped + "\u{FE0F}")
    }
}

/// The user's editable profile fields.
public struct MattermostOwnProfileFields: Equatable {
    public let userId: String
    public let username: String
    public let firstName: String
    public let lastName: String
    public let nickname: String
    public let position: String
    public let email: String
    public let authService: String
    public let hasPicture: Bool
    public let access: ProfileFieldAccess
    /// The server lets users set custom statuses (`EnableCustomUserStatuses`).
    public let customStatusesEnabled: Bool
}

/// A profile change; nil fields stay as they are.
public struct MattermostProfileChange: Equatable {
    public var firstName: String?
    public var lastName: String?
    public var nickname: String?
    public var position: String?
    public var username: String?
    public var email: String?
    /// The current password, needed to change the email.
    public var password: String?

    public init(firstName: String? = nil, lastName: String? = nil, nickname: String? = nil, position: String? = nil, username: String? = nil, email: String? = nil, password: String? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.position = position
        self.username = username
        self.email = email
        self.password = password
    }
}

/// Shared by the account's sync and the screens: the last known own status, client config values.
final class MattermostOwnProfileState {
    struct Values {
        var status: UserStatus?
        var config: [String: String] = [:]
        var customStatusExpiryTask: Task<Void, Never>?
        /// Others' statuses as last written (the poller writes changes only).
        var knownStatuses: [String: UserStatus] = [:]
        var statusPollerStarted = false
    }

    let values = MMLocked(Values())
}

public enum MattermostProfile {
    private static let ownStatusPromises = MMLocked<[AccountRecordId: ValuePromise<MattermostOwnStatus?>]>([:])
    private static let fieldsPromises = MMLocked<[AccountRecordId: ValuePromise<MattermostOwnProfileFields?>]>([:])
    private static let notificationPromises = MMLocked<[AccountRecordId: ValuePromise<UserNotificationPreferences?>]>([:])

    static func ownStatusPromise(_ accountId: AccountRecordId) -> ValuePromise<MattermostOwnStatus?> {
        return self.ownStatusPromises.with { promises in
            if let promise = promises[accountId] {
                return promise
            }
            let promise = ValuePromise<MattermostOwnStatus?>(nil, ignoreRepeated: true)
            promises[accountId] = promise
            return promise
        }
    }

    static func fieldsPromise(_ accountId: AccountRecordId) -> ValuePromise<MattermostOwnProfileFields?> {
        return self.fieldsPromises.with { promises in
            if let promise = promises[accountId] {
                return promise
            }
            let promise = ValuePromise<MattermostOwnProfileFields?>(nil, ignoreRepeated: true)
            promises[accountId] = promise
            return promise
        }
    }

    static func notificationPromise(_ accountId: AccountRecordId) -> ValuePromise<UserNotificationPreferences?> {
        return self.notificationPromises.with { promises in
            if let promise = promises[accountId] {
                return promise
            }
            let promise = ValuePromise<UserNotificationPreferences?>(nil, ignoreRepeated: true)
            promises[accountId] = promise
            return promise
        }
    }

    // MARK: Status

    /// The own status, live (nil until the sync knows it).
    public static func ownStatus(accountId: AccountRecordId) -> Signal<MattermostOwnStatus?, NoError> {
        return self.ownStatusPromise(accountId).get()
    }

    /// The own status now (for building screens synchronously).
    public static func currentOwnStatus(accountId: AccountRecordId) -> MattermostOwnStatus? {
        return MattermostSync.sync(accountId: accountId)?.ownStatusSnapshot()
    }

    /// Sets the status by hand (`PUT /users/{id}/status`); `dnd` ends as `doNotDisturb` says.
    public static func setStatus(accountId: AccountRecordId, _ status: MattermostOwnStatus.Status, doNotDisturb: DoNotDisturbDuration = .indefinitely) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.setOwnStatus(status, doNotDisturb: doNotDisturb)
        }
        |> ignoreValues
    }

    /// Sets the custom status (`PUT /users/me/status/custom`); `emojiName` empty: the default emoji.
    public static func setCustomStatus(accountId: AccountRecordId, emojiName: String, text: String, duration: CustomStatusDuration) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.setCustomStatus(emojiName: emojiName, text: text, duration: duration)
        }
        |> ignoreValues
    }

    public static func clearCustomStatus(accountId: AccountRecordId) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.clearCustomStatus()
        }
        |> ignoreValues
    }

    /// The recently used custom statuses, newest first.
    public static func recentCustomStatuses(accountId: AccountRecordId) -> Signal<[MattermostCustomStatus], MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            return try await sync.client.recentCustomStatuses().map(MattermostCustomStatus.init)
        }
    }

    public static func removeRecentCustomStatus(accountId: AccountRecordId, _ status: MattermostCustomStatus) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.client.removeRecentCustomStatus(UserCustomStatus(emoji: status.emojiName, text: status.text, duration: status.duration, expiresAt: status.expiresAt.map(CustomStatusDuration.rfc3339) ?? ""))
        }
        |> ignoreValues
    }

    // MARK: Profile

    public static func ownProfileFields(accountId: AccountRecordId) -> Signal<MattermostOwnProfileFields?, NoError> {
        return self.fieldsPromise(accountId).get()
    }

    public static func currentOwnProfileFields(accountId: AccountRecordId) -> MattermostOwnProfileFields? {
        return MattermostSync.sync(accountId: accountId)?.ownProfileFieldsSnapshot()
    }

    /// `PUT /users/me/patch` with the changed fields; the own user is rewritten from the answer.
    public static func updateProfile(accountId: AccountRecordId, _ change: MattermostProfileChange) -> Signal<Never, MattermostProfileError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = MattermostSync.sync(accountId: accountId), !sync.isStopped else {
                    subscriber.putError(.unavailable)
                    return
                }
                await sync.waitUntilBootstrapped()
                do {
                    try await sync.updateProfile(change)
                    subscriber.putCompletion()
                } catch {
                    subscriber.putError(MattermostProfileError(error))
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    /// `POST /users/me/image` with a JPEG.
    public static func setProfilePicture(accountId: AccountRecordId, jpeg: Data) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.setProfilePicture(jpeg: jpeg)
        }
        |> ignoreValues
    }

    /// `DELETE /users/me/image`: back to the server's generated picture (Telegram's initials here).
    public static func removeProfilePicture(accountId: AccountRecordId) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.removeProfilePicture()
        }
        |> ignoreValues
    }

    // MARK: Notifications

    /// The user's notification preferences (`notify_props`), live.
    public static func notificationPreferences(accountId: AccountRecordId) -> Signal<UserNotificationPreferences?, NoError> {
        return self.notificationPromise(accountId).get()
    }

    public static func setNotificationPreferences(accountId: AccountRecordId, _ preferences: UserNotificationPreferences) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.setNotificationPreferences(preferences)
        }
        |> ignoreValues
    }

    /// A channel's (or DM's) notification preferences as the server has them now.
    public static func channelNotificationPreferences(accountId: AccountRecordId, peerId: PeerId) -> Signal<ChannelNotificationPreferences, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            return try await sync.channelNotificationPreferences(peerId: peerId)
        }
    }

    public static func setChannelNotificationPreferences(accountId: AccountRecordId, peerId: PeerId, _ preferences: ChannelNotificationPreferences) -> Signal<Never, MattermostDirectoryError> {
        return MattermostDirectory.run(accountId: accountId) { sync in
            try await sync.setChannelNotificationPreferences(peerId: peerId, preferences)
        }
        |> ignoreValues
    }

    /// Collapsed reply threads are on (the thread reply settings apply).
    public static func usesCollapsedThreads(accountId: AccountRecordId) -> Bool {
        return MattermostSync.sync(accountId: accountId)?.isCollapsedThreads ?? false
    }
}

/// Why a profile change failed.
public enum MattermostProfileError: Error, Equatable {
    case unavailable
    case network
    case usernameTaken
    case invalidUsername
    case emailTaken
    case invalidEmail
    case wrongPassword
    case server(String)

    init(_ error: Error) {
        if let error = error as? MattermostProfileError {
            self = error
            return
        }
        guard let error = error as? MattermostError else {
            self = .server("\(error)")
            return
        }
        if case .transport = error {
            self = .network
            return
        }
        switch error.appError?.id ?? "" {
        case "app.user.save.username_exists.app_error":
            self = .usernameTaken
        case "model.user.is_valid.username.app_error":
            self = .invalidUsername
        case "app.user.save.email_exists.app_error":
            self = .emailTaken
        case "model.user.is_valid.email.app_error":
            self = .invalidEmail
        case "api.user.check_user_password.invalid.app_error", "api.context.invalid_body_param.app_error":
            self = .wrongPassword
        default:
            self = .server(describeError(error))
        }
    }
}

// MARK: - The account's side

extension MattermostAccountSync {
    func ownStatusSnapshot() -> MattermostOwnStatus? {
        let status = self.ownProfile.values.with { $0.status }
        let me = self.state.with { $0.me }
        guard let status = status ?? me.map({ UserStatus(userId: $0.id, status: .online) }) else {
            return nil
        }
        let mapped: MattermostOwnStatus.Status
        switch status.status {
        case .online:
            mapped = .online
        case .away:
            mapped = .away
        case .dnd:
            mapped = .dnd
        case .offline, .unknown:
            mapped = .offline
        }
        var custom: MattermostCustomStatus?
        if let value = me?.customStatus, !value.isEmpty, !value.isExpired(at: Date()) {
            custom = MattermostCustomStatus(value)
        }
        let dndEnd: Date? = mapped == .dnd && status.dndEndTime > 0 ? Date(timeIntervalSince1970: TimeInterval(status.dndEndTime > 100_000_000_000 ? status.dndEndTime / 1000 : status.dndEndTime)) : nil
        return MattermostOwnStatus(status: mapped, isManual: status.manual, dndEnd: dndEnd, customStatus: custom)
    }

    func ownProfileFieldsSnapshot() -> MattermostOwnProfileFields? {
        guard let me = self.state.with({ $0.me }) else {
            return nil
        }
        let config = self.ownProfile.values.with { $0.config }
        return MattermostOwnProfileFields(
            userId: me.id,
            username: me.username,
            firstName: me.firstName,
            lastName: me.lastName,
            nickname: me.nickname,
            position: me.position,
            email: me.email,
            authService: me.authService,
            hasPicture: me.hasCustomPicture,
            access: ProfileFieldAccess.resolve(authService: me.authService, config: config),
            customStatusesEnabled: config["EnableCustomUserStatuses"].map { $0 == "true" } ?? true
        )
    }

    /// Publishes the own status, profile fields and notification preferences to the screens.
    func publishOwnProfile() {
        MattermostProfile.ownStatusPromise(self.account.id).set(self.ownStatusSnapshot())
        MattermostProfile.fieldsPromise(self.account.id).set(self.ownProfileFieldsSnapshot())
        if let me = self.state.with({ $0.me }) {
            MattermostProfile.notificationPromise(self.account.id).set(UserNotificationPreferences(props: me.notifyProps))
        }
    }

    /// The own status and the client config values the profile screens need; after the bootstrap and on every new
    /// WebSocket connection.
    func refreshOwnProfile() async {
        if let config = try? await self.client.clientConfig() {
            self.ownProfile.values.with { $0.config = config.values }
        }
        if let status = try? await self.client.userStatus() {
            self.ownProfile.values.with { $0.status = status }
            await self.writeOwnPresence(status)
        }
        self.publishOwnProfile()
        self.scheduleCustomStatusExpiry()
        self.startStatusPolling()
    }

    /// `status_change` for the user (another device, the server's DND end or auto away).
    func applyOwnStatusChange(_ change: StatusChangeEvent) async {
        // The event has no DND end; ask for it.
        var status = UserStatus(userId: change.userId, status: change.status, manual: true)
        if change.status == .dnd, let fetched = try? await self.client.userStatus() {
            status = fetched
        } else if let previous = self.ownProfile.values.with({ $0.status }) {
            status.manual = previous.manual
            status.lastActivityAt = previous.lastActivityAt
        }
        self.ownProfile.values.with { $0.status = status }
        await self.writeOwnPresence(status)
        self.publishOwnProfile()
        MMLog.log("profile: own status \(status.status.rawValue) (dnd end \(status.dndEndTime))")
    }

    /// The own presence in Postbox carries the status too (the account switcher and the own profile read it).
    private func writeOwnPresence(_ status: UserStatus) async {
        let presence = PeerConverter.presence(status: status.status, lastActivityAt: status.lastActivityAt, dndEndTime: status.dndEndTime, now: Date())
        let ownPeerId = self.ownPeerId
        await self.postbox.mmTransaction { transaction in
            transaction.updatePeerPresencesInternal(presences: [ownPeerId: presence], merge: { _, updated in
                return updated
            })
        }
    }

    /// Own `user_updated`: the event's copy is sanitized (no notify props), so the user is loaded again.
    func applyOwnUserUpdated() async {
        guard let me = try? await self.client.me() else {
            return
        }
        self.state.with { $0.me = me }
        await self.postbox.mmTransaction { transaction in
            self.writeUsers([me], transaction: transaction)
        }
        self.publishOwnProfile()
        self.scheduleCustomStatusExpiry()
    }

    func setOwnStatus(_ status: MattermostOwnStatus.Status, doNotDisturb: DoNotDisturbDuration) async throws {
        let apiStatus: UserStatus.Status
        switch status {
        case .online:
            apiStatus = .online
        case .away:
            apiStatus = .away
        case .dnd:
            apiStatus = .dnd
        case .offline:
            apiStatus = .offline
        }
        let end = status == .dnd ? doNotDisturb.endTime(now: Date()) : nil
        MMLog.log("profile: setting status \(apiStatus.rawValue) (dnd end \(end.map(String.init) ?? "none"))")
        let updated: UserStatus
        do {
            updated = try await self.client.updateStatus(apiStatus, userId: self.ownUserId, dndEndTime: end)
        } catch {
            MMLog.log("profile: status \(apiStatus.rawValue) refused: \(error)")
            throw error
        }
        MMLog.log("profile: status set to \(updated.status.rawValue) (dnd end \(updated.dndEndTime))")
        self.ownProfile.values.with { $0.status = updated }
        await self.writeOwnPresence(updated)
        self.publishOwnProfile()
    }

    func setCustomStatus(emojiName: String, text: String, duration: CustomStatusDuration) async throws {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CustomStatusRules.textMaxLength))
        let status = UserCustomStatus(emoji: emojiName.isEmpty ? CustomStatusRules.defaultEmoji : emojiName, text: trimmed, duration: duration.apiValue, expiresAt: duration.expiresAtString(now: Date()))
        try await self.client.updateCustomStatus(status)
        MMLog.log("profile: custom status set (\(status.duration), expires \(status.expiresAt.isEmpty ? "never" : status.expiresAt))")
        // The `user_updated` echo reloads the user too; this makes the change visible at once.
        await self.applyOwnUserUpdated()
    }

    func clearCustomStatus() async throws {
        try await self.client.removeCustomStatus()
        MMLog.log("profile: custom status cleared")
        await self.applyOwnUserUpdated()
    }

    func updateProfile(_ change: MattermostProfileChange) async throws {
        var patch = UserPatch()
        patch.firstName = change.firstName
        patch.lastName = change.lastName
        patch.nickname = change.nickname
        patch.position = change.position
        if let username = change.username {
            let normalized = username.trimmingCharacters(in: .whitespaces).lowercased()
            if UsernameRules.validate(normalized) != nil {
                throw MattermostProfileError.invalidUsername
            }
            patch.username = normalized
        }
        if let email = change.email {
            patch.email = email.trimmingCharacters(in: .whitespaces)
            patch.password = change.password
        }
        if patch.isEmpty {
            return
        }
        let user = try await self.client.patchUser(patch)
        MMLog.log("profile: patched")
        self.state.with { state in
            // The answer is the full own user (with notify props).
            state.me = user
            if let previous = state.users[user.id], previous.username != user.username {
                state.userIdByUsername[previous.username.lowercased()] = nil
            }
        }
        await self.postbox.mmTransaction { transaction in
            self.writeUsers([user], transaction: transaction)
        }
        self.publishOwnProfile()
    }

    func setProfilePicture(jpeg: Data) async throws {
        try await self.client.uploadProfileImage(jpeg)
        MMLog.log("profile: picture uploaded (\(jpeg.count) bytes)")
        await self.applyOwnUserUpdated()
    }

    func removeProfilePicture() async throws {
        try await self.client.deleteProfileImage()
        MMLog.log("profile: picture removed")
        await self.applyOwnUserUpdated()
    }

    func setNotificationPreferences(_ preferences: UserNotificationPreferences) async throws {
        let current = try await self.client.me()
        let props = preferences.props(updating: current.notifyProps)
        let user = try await self.client.patchUser(UserPatch(notifyProps: props))
        MMLog.log("profile: notify props \(props.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        self.state.with { $0.me = user }
        self.publishOwnProfile()
    }

    func channelNotificationPreferences(peerId: PeerId) async throws -> ChannelNotificationPreferences {
        guard let channelId = self.channelId(forPeerId: peerId) else {
            throw MattermostDirectoryError.unavailable
        }
        let member = try await self.client.channelMember(channelId: channelId)
        return ChannelNotificationPreferences(props: member.notifyProps)
    }

    func setChannelNotificationPreferences(peerId: PeerId, _ preferences: ChannelNotificationPreferences) async throws {
        guard let channelId = self.channelId(forPeerId: peerId) else {
            throw MattermostDirectoryError.unavailable
        }
        try await self.client.updateChannelNotifyProps(channelId: channelId, props: preferences.props)
        MMLog.log("profile: notify props of \(channelId): \(preferences.props.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // Mute lives in Telegram's notification settings; `channel_member_updated` rewrites it as well.
        await self.refreshChannel(channelId)
    }

    // MARK: Others' statuses

    /// Mattermost sends `status_change` only to the user whose status changed; its clients poll
    /// `POST /users/status/ids` (every `UsersStatusAndProfileFetchingPollIntervalMilliseconds`). This polls the
    /// statuses of the users with a DM (and the other users the sync knows, up to 400) while the WebSocket is up, at
    /// least every 20 s, and writes the presences that changed.
    func startStatusPolling() {
        let start = self.ownProfile.values.with { values -> Bool in
            if values.statusPollerStarted {
                return false
            }
            values.statusPollerStarted = true
            return true
        }
        guard start else {
            return
        }
        self.addTask(Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, !self.isStopped else {
                    return
                }
                let configured = self.ownProfile.values.with { Double($0.config["UsersStatusAndProfileFetchingPollIntervalMilliseconds"] ?? "") ?? 0 } / 1000.0
                let interval = max(20.0, configured)
                if self.isConnected.with({ $0 }) {
                    await self.pollStatuses()
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        })
    }

    func pollStatuses() async {
        let ownUserId = self.ownUserId
        let userIds = self.state.with { state -> [String] in
            var direct: [String] = []
            for channelState in state.channels.values where channelState.kind == .direct {
                if let partner = channelState.channel.directMessagePartnerId(myUserId: ownUserId) {
                    direct.append(partner)
                }
            }
            var others = state.users.keys.filter { $0 != ownUserId && !direct.contains($0) }.sorted()
            others = Array(others.prefix(max(0, 400 - direct.count)))
            return Array(Set(direct)).sorted() + others
        }
        if userIds.isEmpty {
            return
        }
        var statuses: [UserStatus] = []
        for start in stride(from: 0, to: userIds.count, by: 200) {
            guard let page = try? await self.client.userStatuses(ids: Array(userIds[start ..< min(userIds.count, start + 200)])) else {
                return
            }
            statuses.append(contentsOf: page)
        }
        let changed = self.ownProfile.values.with { values -> [UserStatus] in
            var changed: [UserStatus] = []
            for status in statuses {
                let previous = values.knownStatuses[status.userId]
                if previous?.status != status.status || previous?.dndEndTime != status.dndEndTime {
                    changed.append(status)
                }
                values.knownStatuses[status.userId] = status
            }
            return changed
        }
        if changed.isEmpty {
            return
        }
        await self.postbox.mmTransaction { transaction in
            self.writePresences(changed, transaction: transaction)
        }
        if changed.count < 10 {
            MMLog.log("profile: statuses changed: \(changed.map { "\($0.userId)=\($0.status.rawValue)" }.joined(separator: " "))")
        } else {
            MMLog.log("profile: \(changed.count) statuses changed")
        }
    }

    // MARK: Custom status expiry

    /// Mattermost doesn't announce an expired custom status (clients hide it themselves), and Telegram shows an emoji
    /// status until the peer changes: rewrite the users whose status expires next, then schedule the one after.
    func scheduleCustomStatusExpiry() {
        let now = Date()
        let next = self.state.with { state -> Date? in
            var users = Array(state.users.values)
            if let me = state.me {
                users.append(me)
            }
            return users.compactMap { $0.customStatus?.expiryDate }.filter { $0 > now }.min()
        }
        let task: Task<Void, Never>? = next.map { date in
            Task { [weak self] in
                let delay = max(1.0, date.timeIntervalSinceNow + 1.0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self = self, !Task.isCancelled, !self.isStopped else {
                    return
                }
                await self.rewriteExpiredCustomStatuses()
            }
        }
        let previous = self.ownProfile.values.with { values -> Task<Void, Never>? in
            let previous = values.customStatusExpiryTask
            values.customStatusExpiryTask = task
            return previous
        }
        previous?.cancel()
    }

    private func rewriteExpiredCustomStatuses() async {
        let now = Date()
        let expired = self.state.with { state -> [User] in
            var users = Array(state.users.values)
            if let me = state.me {
                users.append(me)
            }
            return users.filter { $0.customStatus?.isExpired(at: now) == true }
        }
        if !expired.isEmpty {
            MMLog.log("profile: custom status expired for \(expired.count) user(s)")
            await self.postbox.mmTransaction { transaction in
                self.writeUsers(expired, transaction: transaction)
            }
            self.publishOwnProfile()
        }
        self.scheduleCustomStatusExpiry()
    }
}
