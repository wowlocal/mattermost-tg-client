import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import MattermostPush

/// Push registration (docs/plan/04 "Client: registration"): every running account attaches the device's APNs
/// token to its session with `PUT /users/sessions/device` (`MattermostPushDevice` formats the device id; its
/// platform names an entry of our push proxy, `infra/push-proxy`).
///
/// The app hands over each token it gets (`setPushToken`, from `SharedAccountContextImpl`); an account
/// registers when its sync starts (launch, login, re-login) and when the token changes, unless its store's
/// `push_registration` record says the same session already has this device id for this app version
/// (re-registered weekly regardless). Logout needs no call: ending the session (`POST /users/logout`)
/// removes its device on the server.
extension MattermostSync {
    static let pushRegistrationCursor = "push_registration"
    /// The own username, for the notification service extension (`MattermostNotificationService.swift`).
    static let ownUsernameCursor = "own_username"

    private static let pushToken = MMLocked<Data?>(nil)
    private static let pushRegistrations = MMLocked<[AccountRecordId: Task<Void, Never>]>([:])

    /// The APNs token (nil until iOS gives one). Registers it with every running account.
    public static func setPushToken(_ token: Data?) {
        let changed = self.pushToken.with { current -> Bool in
            let changed = current != token
            current = token
            return changed
        }
        guard changed, let token = token else {
            return
        }
        let environment = MattermostPushDevice.currentEnvironment()
        // The device token stays out of release logs (4G: logs may be exported); debug checks read it whole.
        #if DEBUG
        MMLog.log("push: APNs \(environment.rawValue) token \(MattermostPushDevice.hexToken(token))")
        #else
        MMLog.log("push: APNs \(environment.rawValue) token \(MattermostPushDevice.hexToken(token).prefix(8))…")
        #endif
        let syncs = self.runningSyncs()
        for sync in syncs {
            self.registerPushDevice(sync: sync)
        }
    }

    static var currentPushToken: Data? {
        return self.pushToken.current
    }

    /// Registers the device for one account if needed (called when its sync starts).
    static func registerPushDevice(sync: MattermostAccountSync) {
        guard let token = self.currentPushToken else {
            return
        }
        let accountId = sync.account.id
        let task = Task {
            await sync.registerPushDevice(token: token)
        }
        let previous = self.pushRegistrations.with { tasks -> Task<Void, Never>? in
            let previous = tasks[accountId]
            tasks[accountId] = task
            return previous
        }
        previous?.cancel()
        sync.addTask(task)
    }
}

extension MattermostAccountSync {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    func registerPushDevice(token: Data) async {
        // After the bootstrap: the server is reachable then, and the own username is known. The notification
        // service extension reads it from the store to route `@username` mentions between accounts.
        await self.waitUntilBootstrapped()
        if Task.isCancelled {
            return
        }
        let username = self.ownUsername
        if !username.isEmpty && self.store.cursor(MattermostSync.ownUsernameCursor) != username {
            self.store.setCursor(MattermostSync.ownUsernameCursor, username)
        }
        let environment = MattermostPushDevice.currentEnvironment()
        let deviceId = MattermostPushDevice.deviceId(token: token, environment: environment)
        let appVersion = MattermostAccountSync.appVersion
        let session = MattermostPushRegistrationRecord.sessionTag(token: self.client.token ?? "")
        let now = Date().timeIntervalSince1970
        if let record = MattermostPushRegistrationRecord(encoded: self.store.cursor(MattermostSync.pushRegistrationCursor)), !record.needsRegistration(session: session, deviceId: deviceId, appVersion: appVersion, now: now) {
            MMLog.log("push: account \(self.account.id.int64): device \(MattermostPushDevice.platform(environment)) already registered")
            return
        }
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await self.client.attachDevice(deviceId: deviceId)
                let record = MattermostPushRegistrationRecord(session: session, deviceId: deviceId, appVersion: appVersion, registeredAt: Date().timeIntervalSince1970)
                self.store.setCursor(MattermostSync.pushRegistrationCursor, record.encoded)
                MMLog.log("push: account \(self.account.id.int64): registered device \(MattermostPushDevice.platform(environment)):\(MattermostPushDevice.hexToken(token).prefix(8))… with \(self.server.url)")
                return
            } catch let error as MattermostError where error.isTransient {
                attempt += 1
                let delay = min(60.0, pow(2.0, Double(min(attempt, 6))))
                MMLog.log("push: account \(self.account.id.int64): registration failed (\(error)); retrying in \(Int(delay)) s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                MMLog.log("push: account \(self.account.id.int64): registration failed: \(error)")
                return
            }
        }
    }
}

extension MattermostAccountSync {
    /// The account's name format for the notification extension's sender names (4F, `MattermostPushSenderName`):
    /// the user's `name_format` display preference, else the server's `TeammateNameDisplay`. Kept without a config
    /// (an old server or a failed request), so the last known one stays.
    func updatePushNameFormat(config: ClientConfig?, preferences: [Preference]) {
        guard let config = config else {
            return
        }
        let preference = preferences.last(where: { $0.category == PreferenceCategory.displaySettings && $0.name == "name_format" })?.value
        let format = MattermostPushSenderName.nameFormat(preference: preference, serverDefault: config["TeammateNameDisplay"], locked: config.bool("LockTeammateNameDisplay") ?? false)
        if self.store.cursor(MattermostPushSenderName.nameFormatCursor) != format {
            self.store.setCursor(MattermostPushSenderName.nameFormatCursor, format)
            MMLog.log("push: sender names as \(format)")
        }
    }

    /// After a `name_format` preference or the server config changed.
    func reloadPushNameFormat() async {
        guard let config = try? await self.client.clientConfig(), let preferences = try? await self.client.preferences() else {
            return
        }
        self.updatePushNameFormat(config: config, preferences: preferences)
    }
}
