import Foundation
import Network
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// An account whose Mattermost session the server no longer accepts (expired, revoked, or the token is
/// missing). Its sync is stopped; its local data stays until the user logs in again or logs out.
public struct MattermostExpiredSession: Equatable {
    public let accountId: AccountRecordId
    public let serverURL: String
    public let siteName: String?
    public let userId: String
    /// What the user typed as login id at the last login (prefills the re-login form).
    public let loginId: String?
}

public enum MattermostRenewSessionError: Error, Equatable {
    case unknownAccount
    /// The login belongs to another user than the account's. The caller decides what to do
    /// (`replaceAccount`).
    case differentUser
    case storage

    public var message: String {
        switch self {
        case .unknownAccount:
            return "This account is no longer on this device."
        case .differentUser:
            return "You logged in as a different user."
        case .storage:
            return "Relay couldn't save the new session on this device."
        }
    }
}

/// Entry points for TelegramUI and MattermostUI: starting and stopping account syncs, session expiry and
/// re-login, and the account lifecycle (logout).
///
/// **Logout** (`startLifecycle`): Telegram's logout marks the account record `.loggedOut` and waits in
/// `managedCleanupAccounts` for an MTProto answer that never comes (Telegram's cleanup is off while
/// `MattermostBackend.isEnabled`). MattermostSync instead watches the records: for a `.loggedOut` record it
/// stops the sync, ends the session on the server (`POST /users/logout`, best effort), removes the Keychain
/// token, removes the record and deletes the account's directory (postbox, media, sync store).
///
/// **Session expiry**: a 401 to any request made with the token (confirmed with `GET /users/me`), a
/// WebSocket the server rejects, or a rejected token check when the app becomes active (a revoked session
/// otherwise goes unnoticed while the WebSocket stays open) stops the account's sync and marks it expired
/// (`expiredSessions`); the flag
/// is kept in the sync store, so it survives relaunches. Logging in again as the same user keeps the local
/// data (`renewSession`); as another user, the old account is logged out and a new one created
/// (`replaceAccount`), because local ids, read states and caches belong to the old user.
public enum MattermostSync {
    struct Registered {
        let account: Account
        let server: MattermostServerInfo
    }

    private struct Lifecycle {
        let accountManager: AccountManager<TelegramAccountManagerTypes>
        let rootPath: String
        let encryptionParameters: ValueBoxEncryptionParameters
    }

    static let accounts = MMLocked<[AccountRecordId: MattermostAccountSync]>([:])
    /// Every account loaded in this process, running or expired.
    static let registry = MMLocked<[AccountRecordId: Registered]>([:])
    private static let expired = MMLocked<[AccountRecordId: MattermostExpiredSession]>([:])
    private static let expiredPromise = ValuePromise<[MattermostExpiredSession]>([], ignoreRepeated: true)
    private static let checkingTokens = MMLocked<Set<AccountRecordId>>([])
    /// Tokens written in this process; the launch-time Keychain sweep keeps them (a login may be running).
    private static let createdTokens = MMLocked<Set<AccountRecordId>>([])
    private static let lifecycle = MMLocked<Lifecycle?>(nil)
    private static let lifecycleDisposable = MetaDisposable()
    private static let activationObserver = MMLocked<NSObjectProtocol?>(nil)
    private static let backgroundObserver = MMLocked<NSObjectProtocol?>(nil)
    private static let pathMonitor = MMLocked<NWPathMonitor?>(nil)
    /// Phase 4B: when the app last entered the background (nil while it is active).
    private static let enteredBackgroundAt = MMLocked<Double?>(nil)

    static let userAgent = "Relay/0.1 (iOS; MattermostSync)"
    /// Sync-store cursors kept by the account lifecycle.
    static let loginIdCursor = "login_id"
    static let sessionExpiredCursor = "session_expired"
    /// The current session's CSRF token (`LoginResult.csrfToken`): marks it in the Devices list.
    static let sessionCSRFCursor = "session_csrf"

    // MARK: Accounts

    /// Starts MattermostSync for an account loaded by `SharedAccountContextImpl` (instead of
    /// `Account.resetStateManagement()`). Does nothing for an account without a Mattermost server. An account
    /// whose session expired (flag in the store, or no token) is registered as expired instead.
    public static func startAccount(_ account: Account) {
        if self.accounts.with({ $0[account.id] != nil }) {
            return
        }
        let path = MattermostSyncStore.path(accountBasePath: account.basePath)
        let store: MattermostSyncStore
        do {
            store = try MattermostSyncStore(path: path)
        } catch {
            MMLog.log("account \(account.id.int64): cannot open \(path): \(error)")
            return
        }
        guard let server = store.serverInfo(), URL(string: server.url) != nil else {
            MMLog.log("account \(account.id.int64): no Mattermost server in \(path)")
            return
        }
        self.registry.with { $0[account.id] = Registered(account: account, server: server) }
        guard let token = MattermostKeychain.token(accountId: account.id.int64) else {
            MMLog.log("account \(account.id.int64): no session token in the Keychain")
            self.markExpired(accountId: account.id, store: store, server: server)
            return
        }
        if store.cursor(self.sessionExpiredCursor) != nil {
            MMLog.log("account \(account.id.int64): session expired earlier; waiting for a new login")
            self.markExpired(accountId: account.id, store: store, server: server)
            return
        }
        self.run(account: account, store: store, server: server, token: token)
    }

    private static func run(account: Account, store: MattermostSyncStore, server: MattermostServerInfo, token: String) {
        guard let url = URL(string: server.url) else {
            return
        }
        let accountId = account.id
        var configuration = MattermostClient.Configuration(serverURL: url, userAgent: self.userAgent)
        configuration.onUnauthorized = {
            MattermostSync.reportUnauthorized(accountId: accountId)
        }
        configuration.onServerReached = {
            MattermostSync.sync(accountId: accountId)?.reconnectSoon(reason: "the server answered a request")
        }
        let client = MattermostClient(configuration: configuration, token: token)
        let sync = MattermostAccountSync(account: account, client: client, store: store, server: server)
        let previous = self.accounts.with { accounts -> MattermostAccountSync? in
            let previous = accounts[accountId]
            accounts[accountId] = sync
            return previous
        }
        previous?.stop()
        sync.start()
        // Phase 3A: attach the APNs token to this session (a new login has no device yet).
        self.registerPushDevice(sync: sync)
    }

    static func sync(accountId: AccountRecordId) -> MattermostAccountSync? {
        return self.accounts.with { $0[accountId] }
    }

    private static let noticePipes = MMLocked<[AccountRecordId: ValuePipe<String>]>([:])

    static func noticePipe(accountId: AccountRecordId) -> ValuePipe<String> {
        return self.noticePipes.with { pipes in
            if let pipe = pipes[accountId] {
                return pipe
            }
            let pipe = ValuePipe<String>()
            pipes[accountId] = pipe
            return pipe
        }
    }

    /// User-facing messages about failed writes (a delete the server refused, a message that could not be
    /// sent, …) for the app to show as toasts.
    public static func notices(accountId: AccountRecordId) -> Signal<String, NoError> {
        return self.noticePipe(accountId: accountId).signal()
    }

    /// The account of `userId` loaded in this process, if any (one account per Mattermost user: user ids
    /// are unique per server and, being random, across servers).
    static func registeredAccount(userId: String, serverURL: String) -> AccountRecordId? {
        return self.registry.with { registry in
            return registry.first(where: { $0.value.server.userId == userId })?.key
        }
    }

    private static func stopAccount(_ accountId: AccountRecordId) {
        let sync = self.accounts.with { $0.removeValue(forKey: accountId) }
        sync?.stop()
    }

    // MARK: Session expiry

    /// Accounts whose session ended, sorted by account id.
    public static var expiredSessions: Signal<[MattermostExpiredSession], NoError> {
        return self.expiredPromise.get()
    }

    public static func expiredSession(accountId: AccountRecordId) -> MattermostExpiredSession? {
        return self.expired.with { $0[accountId] }
    }

    /// A request made with the account's token got a 401: confirm with `GET /users/me`, then expire.
    static func reportUnauthorized(accountId: AccountRecordId) {
        self.verifySession(accountId: accountId, reason: "a request was rejected (401)")
    }

    /// Asks the server whether the account's token is still accepted (`GET /users/me`); expires it if not.
    private static func verifySession(accountId: AccountRecordId, reason: String) {
        guard let sync = self.sync(accountId: accountId) else {
            return
        }
        let isNew = self.checkingTokens.with { $0.insert(accountId).inserted }
        if !isNew {
            return
        }
        Task {
            let accepted = await sync.client.isTokenAccepted()
            self.checkingTokens.with { $0.remove(accountId) }
            if !accepted {
                self.sessionExpired(accountId: accountId, reason: reason)
            }
        }
    }

    /// A revoked session gets no WebSocket close and no 401 until the app sends a request, so every running
    /// account checks its token when the app becomes active.
    private static func verifySessionsOnActivation() {
        let ids = self.accounts.with { Array($0.keys) }
        for id in ids {
            self.verifySession(accountId: id, reason: "the token was rejected when the app became active")
        }
    }

    /// Phase 4B: when the network path becomes usable again (airplane mode off, Wi-Fi back), WebSockets waiting out
    /// their backoff reconnect at once.
    private static func startPathMonitor() {
        let monitor = NWPathMonitor()
        let wasSatisfied = MMLocked<Bool?>(nil)
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let previous = wasSatisfied.with { value -> Bool? in
                let previous = value
                value = satisfied
                return previous
            }
            if satisfied && previous == false {
                for sync in self.accounts.with({ Array($0.values) }) {
                    sync.reconnectSoon(reason: "the network is back")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.relaychat.MattermostSync.path"))
        self.pathMonitor.with { $0 = monitor }
    }

    /// Phase 4B: after more than 10 s in the background, every running account checks that its WebSocket
    /// survived the suspension (a dead one would otherwise only be noticed by the next 30-second ping).
    private static func checkConnectionsOnActivation() {
        guard let since = self.enteredBackgroundAt.with({ value -> Double? in
            let since = value
            value = nil
            return since
        }) else {
            return
        }
        let seconds = CFAbsoluteTimeGetCurrent() - since
        if seconds < 10.0 {
            return
        }
        for sync in self.accounts.with({ Array($0.values) }) {
            sync.appBecameActive(afterBackground: seconds)
        }
    }

    /// Phase 4B: a background refresh (`BGAppRefreshTask`, registered by the app): waits up to `timeout` seconds
    /// for the accounts to start (the system may have launched the app for this task), then catches every running
    /// account up. Returns false when it ran out of time or was cancelled.
    public static func backgroundRefresh(timeout: Double) async -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        MMLog.log("background refresh: started")
        var syncs: [MattermostAccountSync] = []
        while CFAbsoluteTimeGetCurrent() - started < timeout && !Task.isCancelled {
            syncs = self.accounts.with { Array($0.values) }
            if !syncs.isEmpty && syncs.allSatisfy({ $0.state.with { $0.isBootstrapped } }) {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        syncs = syncs.filter { $0.state.with { $0.isBootstrapped } }
        await withTaskGroup(of: Void.self) { group in
            for sync in syncs {
                group.addTask {
                    await sync.catchUp()
                }
            }
        }
        let ok = !syncs.isEmpty && !Task.isCancelled
        MMLog.log("background refresh: \(syncs.count) account(s) caught up in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms\(ok ? "" : " (incomplete)")")
        return ok
    }

    /// Stops the account's sync and marks its session expired (also called for a rejected WebSocket).
    static func sessionExpired(accountId: AccountRecordId, reason: String) {
        guard let sync = self.accounts.with({ $0.removeValue(forKey: accountId) }) else {
            return
        }
        MMLog.log("account \(accountId.int64): session expired (\(reason)); sync stopped")
        sync.stop()
        sync.store.setCursor(self.sessionExpiredCursor, String(Int64(Date().timeIntervalSince1970)))
        self.markExpired(accountId: accountId, store: sync.store, server: sync.server)
    }

    private static func markExpired(accountId: AccountRecordId, store: MattermostSyncStore, server: MattermostServerInfo) {
        let session = MattermostExpiredSession(accountId: accountId, serverURL: server.url, siteName: server.siteName, userId: server.userId, loginId: store.cursor(self.loginIdCursor))
        self.updateExpired { $0[accountId] = session }
        // The title says "Session Expired" instead of "Connecting…".
        self.registry.with { $0[accountId]?.account }?.mattermostSessionExpired.set(true)
    }

    /// The account's running sync, waiting while its session is expired (until a re-login starts a new one).
    /// Nil once the account is gone (logged out, or replaced by a login as another user).
    static func waitForRunningSync(accountId: AccountRecordId) async -> MattermostAccountSync? {
        while !Task.isCancelled {
            if let sync = self.sync(accountId: accountId), !sync.isStopped {
                return sync
            }
            if self.registry.with({ $0[accountId] == nil }) {
                return nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// Whether `error` (from a request of `sync`) means the session is gone: a 401 confirmed with
    /// `GET /users/me` (the session is then marked expired), or a sync already stopped for expiry.
    static func isSessionRejected(_ error: Error, sync: MattermostAccountSync) async -> Bool {
        if sync.isStopped {
            return self.registry.with { $0[sync.account.id] != nil }
        }
        guard error.isMattermostUnauthorized else {
            return false
        }
        if await sync.client.isTokenAccepted() {
            return false
        }
        self.sessionExpired(accountId: sync.account.id, reason: "a write was rejected (401)")
        return true
    }

    private static func updateExpired(_ f: (inout [AccountRecordId: MattermostExpiredSession]) -> Void) {
        let sessions = self.expired.with { expired -> [MattermostExpiredSession] in
            f(&expired)
            return expired.values.sorted(by: { $0.accountId.int64 < $1.accountId.int64 })
        }
        self.expiredPromise.set(sessions)
    }

    /// Re-login as the same user: stores the new token, clears the expired flag and restarts the sync with
    /// the account's local data.
    public static func renewSession(accountId: AccountRecordId, login: LoginResult, loginId: String?) throws {
        guard let registered = self.registry.with({ $0[accountId] }) else {
            throw MattermostRenewSessionError.unknownAccount
        }
        guard login.user.id == registered.server.userId else {
            throw MattermostRenewSessionError.differentUser
        }
        let store: MattermostSyncStore
        do {
            store = try MattermostSyncStore(path: MattermostSyncStore.path(accountBasePath: registered.account.basePath))
        } catch {
            throw MattermostRenewSessionError.storage
        }
        guard MattermostKeychain.setToken(login.token, accountId: accountId.int64) else {
            throw MattermostRenewSessionError.storage
        }
        store.setCursor(self.sessionExpiredCursor, nil)
        store.setCursor(self.sessionCSRFCursor, login.csrfToken)
        if let loginId = loginId {
            store.setCursor(self.loginIdCursor, loginId)
        }
        self.updateExpired { $0.removeValue(forKey: accountId) }
        registered.account.mattermostSessionExpired.set(false)
        MMLog.log("account \(accountId.int64): session renewed for \(login.user.username); restarting sync")
        self.run(account: registered.account, store: store, server: registered.server, token: login.token)
    }

    /// Re-login as another user: creates a new account for that user (current), then logs the old one out
    /// (its local data is deleted).
    public static func replaceAccount(accountId: AccountRecordId, server: MattermostServerDescription?, serverURL: URL, login: LoginResult, loginId: String?) async throws {
        guard let lifecycle = self.lifecycle.with({ $0 }) else {
            throw MattermostRenewSessionError.unknownAccount
        }
        try await MattermostAccountSetup.createAccount(server: server, serverURL: serverURL, login: login, loginId: loginId, target: .newAccount(rootPath: lifecycle.rootPath, encryptionParameters: lifecycle.encryptionParameters), accountManager: lifecycle.accountManager)
        MMLog.log("account \(accountId.int64): replaced by a login as \(login.user.username); logging the old account out")
        let _ = await logoutFromAccount(id: accountId, accountManager: lifecycle.accountManager, alreadyLoggedOutRemotely: false).awaitValue()
    }

    static func noteTokenCreated(accountId: AccountRecordId) {
        self.createdTokens.with { $0.insert(accountId) }
    }

    // MARK: Lifecycle (logout)

    /// Starts the account lifecycle manager (main app, once): logout of `.loggedOut` records, stopping syncs
    /// of removed records, removing Keychain tokens of accounts that no longer exist.
    public static func startLifecycle(accountManager: AccountManager<TelegramAccountManagerTypes>, rootPath: String, encryptionParameters: ValueBoxEncryptionParameters) {
        let lifecycle = Lifecycle(accountManager: accountManager, rootPath: rootPath, encryptionParameters: encryptionParameters)
        self.lifecycle.with { $0 = lifecycle }
        // `UIApplication.didBecomeActiveNotification` (MattermostSync doesn't import UIKit).
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: nil, using: { _ in
            MattermostSync.verifySessionsOnActivation()
            MattermostSync.checkConnectionsOnActivation()
        })
        self.activationObserver.with { $0 = observer }
        // `UIApplication.didEnterBackgroundNotification` (Phase 4B: how long the app was away).
        let backgroundObserver = NotificationCenter.default.addObserver(forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"), object: nil, queue: nil, using: { _ in
            MattermostSync.enteredBackgroundAt.with { $0 = CFAbsoluteTimeGetCurrent() }
        })
        self.backgroundObserver.with { $0 = backgroundObserver }
        self.startPathMonitor()
        let handled = MMLocked<Set<AccountRecordId>>([])
        let isFirstView = MMLocked<Bool>(true)
        self.lifecycleDisposable.set(accountManager.accountRecords().start(next: { view in
            var live = Set<AccountRecordId>()
            var loggedOut: [AccountRecordId] = []
            for record in view.records {
                if record.attributes.contains(where: { attribute in
                    if case .loggedOut = attribute {
                        return true
                    }
                    return false
                }) {
                    loggedOut.append(record.id)
                } else {
                    live.insert(record.id)
                }
            }
            if let auth = view.currentAuthAccount {
                live.insert(auth.id)
            }

            // Records removed without a logout (Telegram's `alreadyLoggedOutRemotely`): stop their sync.
            let removed = self.registry.with { registry in
                return registry.keys.filter { !live.contains($0) && !loggedOut.contains($0) }
            }
            for id in removed {
                MMLog.log("account \(id.int64): record removed; stopping its sync")
                self.forget(accountId: id)
                MattermostKeychain.removeToken(accountId: id.int64)
            }

            for id in loggedOut where handled.with({ $0.insert(id).inserted }) {
                Task {
                    await self.performLogout(accountId: id, lifecycle: lifecycle)
                }
            }

            if isFirstView.with({ value -> Bool in
                let first = value
                value = false
                return first
            }) {
                let created = self.createdTokens.with { $0 }
                for id in MattermostKeychain.accountIdsWithTokens() {
                    let recordId = AccountRecordId(rawValue: id)
                    if !live.contains(recordId) && !loggedOut.contains(recordId) && !created.contains(recordId) {
                        MMLog.log("keychain: removing the token of account \(id), which no longer exists")
                        MattermostKeychain.removeToken(accountId: id)
                    }
                }
            }
        }))
    }

    #if DEBUG
    /// For debug checks (MattermostUI's debug remote): loaded accounts, Keychain tokens and account
    /// directories on disk.
    public static func debugState() -> [String: Any] {
        let accounts = self.registry.with { registry -> [[String: Any]] in
            return registry.map { id, registered -> [String: Any] in
                return [
                    "accountId": "\(id.int64)",
                    "peerId": "\(registered.account.peerId.toInt64())",
                    "serverURL": registered.server.url,
                    "userId": registered.server.userId,
                    "running": self.sync(accountId: id) != nil,
                    "expired": self.expiredSession(accountId: id) != nil
                ]
            }
        }
        var directories: [String] = []
        if let rootPath = self.lifecycle.with({ $0?.rootPath }), let names = try? FileManager.default.contentsOfDirectory(atPath: rootPath) {
            directories = names.filter { $0.hasPrefix("account-") }.sorted()
        }
        return [
            "accounts": accounts.sorted(by: { ($0["accountId"] as? String ?? "") < ($1["accountId"] as? String ?? "") }),
            "keychainAccountIds": MattermostKeychain.accountIdsWithTokens().sorted().map { "\($0)" },
            "accountDirectories": directories
        ]
    }
    #endif

    private static func forget(accountId: AccountRecordId) {
        self.stopAccount(accountId)
        self.registry.with { $0.removeValue(forKey: accountId) }
        self.updateExpired { $0.removeValue(forKey: accountId) }
    }

    private static func performLogout(accountId: AccountRecordId, lifecycle: Lifecycle) async {
        MMLog.log("logout: account \(accountId.int64)")
        let sync = self.sync(accountId: accountId)
        self.forget(accountId: accountId)

        let basePath = lifecycle.rootPath + "/" + accountRecordIdPathName(accountId)
        var server = sync?.server
        let storePath = MattermostSyncStore.path(accountBasePath: basePath)
        if server == nil, FileManager.default.fileExists(atPath: storePath) {
            server = (try? MattermostSyncStore(path: storePath))?.serverInfo()
        }
        if let server = server, let url = URL(string: server.url), let token = MattermostKeychain.token(accountId: accountId.int64) {
            var configuration = MattermostClient.Configuration(serverURL: url, userAgent: self.userAgent)
            configuration.timeoutInterval = 10
            let client = MattermostClient(configuration: configuration, token: token)
            do {
                try await client.logout()
                MMLog.log("logout: account \(accountId.int64): session ended on \(server.url)")
            } catch {
                MMLog.log("logout: account \(accountId.int64): POST /users/logout failed (\(error)); continuing")
            }
        }
        MattermostKeychain.removeToken(accountId: accountId.int64)
        let _ = await lifecycle.accountManager.transaction { transaction -> Void in
            transaction.updateRecord(accountId, { _ in
                return nil
            })
        }.awaitValue()
        // Telegram's `managedCleanupAccounts` also deletes directories of removed records, so the two may
        // race; what counts is that the directory is gone.
        do {
            if FileManager.default.fileExists(atPath: basePath) {
                try FileManager.default.removeItem(atPath: basePath)
            }
        } catch {
            if FileManager.default.fileExists(atPath: basePath) {
                try? FileManager.default.removeItem(atPath: basePath)
            }
        }
        if FileManager.default.fileExists(atPath: basePath) {
            MMLog.log("logout: account \(accountId.int64): could not delete \(basePath)")
        } else {
            MMLog.log("logout: account \(accountId.int64) removed (record, token, \(basePath))")
        }
    }
}
