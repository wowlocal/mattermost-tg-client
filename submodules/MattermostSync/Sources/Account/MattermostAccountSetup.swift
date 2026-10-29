import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// A server checked by `MattermostAccountSetup.probe`: reachable, a Mattermost server, new enough.
public struct MattermostServerDescription: Sendable {
    /// The normalized server URL (`ServerAddress.normalize`).
    public let url: URL
    public let siteName: String
    public let version: ServerVersion
    /// The logged-out client config (a subset of the full one).
    public let config: ClientConfig
    public let license: ClientLicense?

    public var displayName: String {
        return self.siteName.isEmpty ? (self.url.host ?? self.url.absoluteString) : self.siteName
    }

    public var allowsEmailLogin: Bool {
        return self.config.enableSignInWithEmail
    }

    public var allowsUsernameLogin: Bool {
        return self.config.enableSignInWithUsername
    }

    public var allowsLdapLogin: Bool {
        return self.config.enableLdap
    }

    /// Whether the login id + password form applies (email, username or AD/LDAP sign-in is on).
    public var allowsPasswordLogin: Bool {
        return self.allowsEmailLogin || self.allowsUsernameLogin || self.allowsLdapLogin
    }

    public var ssoProviders: [SSOProvider] {
        return self.config.enabledSSOProviders
    }

    /// The login id field's placeholder, as the official clients word it.
    public var loginIdPlaceholder: String {
        var kinds: [String] = []
        if self.allowsEmailLogin {
            kinds.append("Email")
        }
        if self.allowsUsernameLogin {
            kinds.append(kinds.isEmpty ? "Username" : "username")
        }
        if self.allowsLdapLogin {
            let field = self.config["LdapLoginFieldName"].flatMap { $0.isEmpty ? nil : $0 } ?? "AD/LDAP username"
            kinds.append(field)
        }
        switch kinds.count {
        case 0:
            return "Email or username"
        case 1:
            return kinds[0]
        case 2:
            return "\(kinds[0]) or \(kinds[1])"
        default:
            return "\(kinds[0]), \(kinds[1]) or \(kinds[2])"
        }
    }
}

public enum MattermostServerProbeError: Error, Equatable {
    case invalidAddress(ServerAddress.NormalizationError)
    /// Network-level failure (offline, DNS, TLS, timeout). Carries the system's description.
    case unreachable(host: String, reason: String)
    /// Something answered, but not a Mattermost API.
    case notMattermost(host: String)
    case tooOld(version: ServerVersion, minimum: ServerVersion)
    case unknownVersion
    /// Managed configuration allows only another server (Phase 4G); `allowed` is its host (and port, path).
    case notAllowed(allowed: String)
    /// The server's certificate doesn't match the pins managed configuration set for it (Phase 4G).
    case certificateRejected(host: String)

    public var message: String {
        switch self {
        case .invalidAddress(.empty):
            return "Enter your server's address, for example chat.example.com."
        case .invalidAddress(.invalid):
            return "That doesn't look like a server address. Enter something like chat.example.com."
        case .invalidAddress(.insecureNotAllowed):
            return "Relay only connects to servers over HTTPS."
        case let .unreachable(host, reason):
            return "Can't connect to \(host). Check the address and your internet connection.\n\n\(reason)"
        case let .notMattermost(host):
            return "\(host) doesn't look like a Mattermost server. Check the address; it's the one you open Mattermost at in a browser."
        case let .tooOld(version, minimum):
            return "This server runs Mattermost \(version). Relay needs Mattermost \(minimum.major).\(minimum.minor) or newer. Ask your administrator to upgrade the server."
        case .unknownVersion:
            return "Relay can't tell which Mattermost version this server runs, so it can't connect to it."
        case let .notAllowed(allowed):
            return "Your organization allows Relay to connect only to \(allowed)."
        case let .certificateRejected(host):
            return "The certificate of \(host) isn't the one your organization requires, so Relay didn't connect."
        }
    }
}

public enum MattermostAccountSetupError: Error, Equatable {
    /// This user on this server already has an account in the app.
    case alreadyLoggedIn(username: String)
    case storage(String)
    /// Managed configuration allows only another server (Phase 4G).
    case serverNotAllowed(allowed: String)

    public var message: String {
        switch self {
        case let .alreadyLoggedIn(username):
            return "You're already logged in to this server as \(username)."
        case let .storage(reason):
            return "Relay couldn't save the account on this device (\(reason))."
        case let .serverNotAllowed(allowed):
            return "Your organization allows Relay to connect only to \(allowed)."
        }
    }
}

/// Login and account creation, shared by the MattermostUI login screens and the debug login
/// (`MattermostDebugLogin`, launch-environment credentials).
public enum MattermostAccountSetup {
    /// Where a new account is created.
    public enum Target {
        /// The auth record behind the login UI (Telegram's own flow, docs/research/ui-inventory.md §4.3
        /// option (a)): its postbox gets the account state and its id becomes the account record.
        case authorization(UnauthorizedAccount)
        /// A new record and postbox (debug login, re-login as another user).
        case newAccount(rootPath: String, encryptionParameters: ValueBoxEncryptionParameters)
    }

    public static var userAgent: String {
        return MattermostSync.userAgent
    }

    // MARK: Server

    /// Checks a server address: normalizes it, `GET /system/ping`, the client config (site name, version,
    /// login options) and the license (best effort).
    /// Without a scheme, `https://` is tried; when insecure local servers are allowed (debug builds) and a
    /// local host can't be reached over HTTPS, `http://` is tried too (the dev server is plain HTTP).
    public static func probe(address: String, allowInsecureLocal: Bool) async throws -> MattermostServerDescription {
        let url: URL
        do {
            url = try ServerAddress.normalize(address, allowInsecureLocal: allowInsecureLocal)
        } catch let error as ServerAddress.NormalizationError {
            throw MattermostServerProbeError.invalidAddress(error)
        }
        // Phase 4G: managed configuration may allow only its own server.
        let managed = MattermostManagedSettings.current
        if let allowed = managed.restrictedServerURL, !managed.allowsServer(url) {
            MMLog.log("probe \(url): not allowed by managed configuration")
            throw MattermostServerProbeError.notAllowed(allowed: self.hostDisplay(allowed))
        }
        let hasScheme = address.contains("://")
        do {
            return try await self.probe(url: url)
        } catch MattermostServerProbeError.unreachable(let host, let reason) {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hasScheme, allowInsecureLocal, let urlHost = url.host, ServerAddress.isLocalHost(urlHost), let insecureURL = try? ServerAddress.normalize("http://" + trimmed, allowInsecureLocal: true) else {
                throw MattermostServerProbeError.unreachable(host: host, reason: reason)
            }
            MMLog.log("probe \(url): unreachable over HTTPS; trying \(insecureURL)")
            return try await self.probe(url: insecureURL)
        }
    }

    private static func probe(url: URL) async throws -> MattermostServerDescription {
        let host = url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
        var configuration = MattermostClient.Configuration(serverURL: url, userAgent: self.userAgent)
        configuration.timeoutInterval = 15
        let client = MattermostClient(configuration: configuration)

        do {
            let ping = try await client.ping()
            if ping.status.uppercased() != "OK" {
                MMLog.log("probe \(url): ping status \(ping.status)")
                throw MattermostServerProbeError.notMattermost(host: host)
            }
        } catch let error as MattermostError {
            MMLog.log("probe \(url): ping failed: \(error)")
            throw self.probeError(error, host: host)
        }

        let config: ClientConfig
        do {
            config = try await client.clientConfig()
        } catch let error as MattermostError {
            MMLog.log("probe \(url): client config failed: \(error)")
            throw self.probeError(error, host: host)
        }
        let version: ServerVersion
        switch ServerCompatibility.check(version: config.version) {
        case let .supported(value):
            version = value
        case let .tooOld(value, minimum):
            throw MattermostServerProbeError.tooOld(version: value, minimum: minimum)
        case .unknown:
            throw MattermostServerProbeError.unknownVersion
        }
        let license = try? await client.clientLicense()
        MMLog.log("probe \(url): \(config.siteName ?? "?") \(version), sso \(config.enabledSSOProviders.map { $0.rawValue })")
        return MattermostServerDescription(url: url, siteName: config.siteName ?? "", version: version, config: config, license: license)
    }

    /// `host[:port][/path]`, as the login shows a server.
    public static func hostDisplay(_ url: URL) -> String {
        var text = url.host ?? url.absoluteString
        if let port = url.port {
            text += ":\(port)"
        }
        if !url.path.isEmpty && url.path != "/" {
            text += url.path
        }
        return text
    }

    private static func probeError(_ error: MattermostError, host: String) -> MattermostServerProbeError {
        switch error {
        case let .transport(urlError) where urlError.mattermostPinMismatchHost != nil:
            return .certificateRejected(host: host)
        case let .transport(urlError):
            return .unreachable(host: host, reason: urlError.localizedDescription)
        case .rateLimited:
            return .unreachable(host: host, reason: "The server is busy. Try again in a moment.")
        case let .server(appError) where appError.statusCode >= 500 && !appError.id.isEmpty:
            return .unreachable(host: host, reason: appError.message)
        default:
            return .notMattermost(host: host)
        }
    }

    // MARK: Login

    /// `POST /users/login`. Throws `MattermostError`; `isMFARequired` asks for the MFA code.
    public static func login(server: URL, loginId: String, password: String, mfaToken: String?) async throws -> LoginResult {
        let client = MattermostClient(serverURL: server, userAgent: self.userAgent)
        return try await client.login(loginId: loginId, password: password, mfaToken: mfaToken)
    }

    /// Completes an SSO login: the token from the callback, the user from `GET /users/me`.
    public static func ssoLogin(server: URL, token: String) async throws -> LoginResult {
        let client = MattermostClient(serverURL: server, token: token, userAgent: self.userAgent)
        let user = try await client.me()
        return LoginResult(user: user, token: token)
    }

    /// A user-facing message for a failed login.
    public static func loginErrorMessage(_ error: Error) -> String {
        guard let error = error as? MattermostError else {
            return error.localizedDescription
        }
        switch error {
        case let .unauthorized(appError), let .forbidden(appError):
            if let appError = appError, !appError.message.isEmpty {
                return appError.message
            }
            return "The login id or password is incorrect."
        case let .transport(urlError):
            return "Can't connect to the server. Check your internet connection.\n\n\(urlError.localizedDescription)"
        case .rateLimited:
            return "Too many attempts. Wait a moment and try again."
        default:
            return error.errorDescription ?? "Login failed."
        }
    }

    // MARK: Account

    /// Creates the account for a logged-in user: sync store (server, own peer id), Keychain token, account
    /// postbox (authorized state, own user), then the account record, which becomes current.
    /// `SharedAccountContextImpl` then loads it and MattermostSync bootstraps it.
    @discardableResult
    public static func createAccount(server: MattermostServerDescription?, serverURL: URL, login: LoginResult, loginId: String?, target: Target, accountManager: AccountManager<TelegramAccountManagerTypes>) async throws -> AccountRecordId {
        let serverURLString = serverURL.absoluteString
        let managed = MattermostManagedSettings.current
        if let allowed = managed.restrictedServerURL, !managed.allowsServer(serverURL) {
            let client = MattermostClient(serverURL: serverURL, token: login.token, userAgent: self.userAgent)
            try? await client.logout()
            throw MattermostAccountSetupError.serverNotAllowed(allowed: self.hostDisplay(allowed))
        }
        if let existing = MattermostSync.registeredAccount(userId: login.user.id, serverURL: serverURLString) {
            MMLog.log("login: this user on \(serverURLString) already has account \(existing.int64)")
            // The login made a session the app won't use: end it (best effort).
            let client = MattermostClient(serverURL: serverURL, token: login.token, userAgent: self.userAgent)
            try? await client.logout()
            throw MattermostAccountSetupError.alreadyLoggedIn(username: login.user.username)
        }

        let id: AccountRecordId
        let basePath: String
        var directoryReservation: Disposable?
        switch target {
        case let .authorization(account):
            id = account.id
            basePath = account.basePath
        case let .newAccount(rootPath, _):
            id = generateAccountRecordId()
            basePath = rootPath + "/" + accountRecordIdPathName(id)
            // The account's files are written before its record exists; until then `managedCleanupAccounts`
            // would delete them. Released when this function returns: after the record, or on failure.
            directoryReservation = reserveAccountDirectory(id: id)
        }
        defer {
            directoryReservation?.dispose()
        }

        // A fresh store: an earlier attempt on the same auth record may have left one behind.
        let storeDirectory = (MattermostSyncStore.path(accountBasePath: basePath) as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: storeDirectory)
        let store: MattermostSyncStore
        do {
            store = try MattermostSyncStore(path: MattermostSyncStore.path(accountBasePath: basePath))
        } catch {
            throw MattermostAccountSetupError.storage("\(error)")
        }
        store.setServerInfo(MattermostServerInfo(
            url: serverURLString,
            userId: login.user.id,
            siteName: server?.siteName,
            version: server.map { "\($0.version)" },
            capabilitiesJSON: server.flatMap(self.capabilitiesJSON)
        ))
        if let loginId = loginId {
            store.setCursor(MattermostSync.loginIdCursor, loginId)
        }
        store.setCursor(MattermostSync.sessionCSRFCursor, login.csrfToken)
        let ownIdValue = MattermostPeerIds.ownUserIdValue(serverURL: serverURLString, userId: login.user.id)
        guard store.reserveOwnUserPeer(userId: login.user.id, peerId: ownIdValue) != nil else {
            throw MattermostAccountSetupError.storage("own peer id")
        }
        MattermostSync.noteTokenCreated(accountId: id)
        guard MattermostKeychain.setToken(login.token, accountId: id.int64) else {
            throw MattermostAccountSetupError.storage("Keychain")
        }
        let ownPeerId = MattermostPeerIds.userPeerId(ownIdValue)
        let ownUser = PeerConverter.user(login.user, peerId: ownPeerId)
        MMLog.log("login: \(serverURLString) → account \(id.int64), own peer \(ownPeerId)")

        let writeState: (Transaction) -> Void = { transaction in
            transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: ownPeerId, state: nil, invalidatedChannels: []))
            updatePeersCustom(transaction: transaction, peers: [ownUser], update: { _, updated in
                return updated
            })
            transaction.updatePeerCachedData(peerIds: [ownPeerId], update: { _, current in
                return (current as? CachedUserData ?? CachedUserData())
                    .withUpdatedBusinessIntro(nil)
                    .withUpdatedPeerStatusSettings(PeerStatusSettings())
            })
            // As Telegram's login does: no device-contact sync (with it on, no chat ever opens).
            transaction.updatePreferencesEntry(key: PreferencesKeys.contactsSettings, { _ in
                return PreferencesEntry(ContactsSettings(synchronizeContacts: false))
            })
        }
        let isAuthorization: Bool
        switch target {
        case let .authorization(account):
            isAuthorization = true
            let _ = await account.postbox.transaction { transaction -> Void in
                writeState(transaction)
            }.awaitValue()
        case let .newAccount(rootPath, encryptionParameters):
            isAuthorization = false
            let written = await (accountTransaction(rootPath: rootPath, id: id, encryptionParameters: encryptionParameters, isReadOnly: false, transaction: { _, transaction -> Bool in
                writeState(transaction)
                return true
            })
            |> `catch` { error -> Signal<Bool, NoError> in
                MMLog.log("login: could not open the account postbox: \(error)")
                return .single(false)
            }).awaitValue()
            if written != true {
                MattermostKeychain.removeToken(accountId: id.int64)
                throw MattermostAccountSetupError.storage("postbox")
            }
        }

        let _ = await accountManager.transaction { transaction -> Void in
            let nextSortOrder = (transaction.getRecords().map { record -> Int32 in
                for attribute in record.attributes {
                    if case let .sortOrder(sortOrder) = attribute {
                        return sortOrder.order
                    }
                }
                return 0
            }.max() ?? 0) + 1
            transaction.updateRecord(id, { _ in
                return AccountRecord(id: id, attributes: [
                    .environment(AccountEnvironmentAttribute(environment: .production)),
                    .sortOrder(AccountSortOrderAttribute(order: nextSortOrder))
                ], temporarySessionId: nil)
            })
            transaction.setCurrentId(id)
            if isAuthorization {
                transaction.removeAuth()
            }
        }.awaitValue()
        MMLog.log("login: account \(id.int64) created and selected")
        return id
    }

    /// The subset of the client config and license kept with the account (docs/plan/03, "Server capabilities").
    private static func capabilitiesJSON(_ server: MattermostServerDescription) -> String? {
        var capabilities: [String: Any] = [
            "version": "\(server.version)",
            "sso": server.ssoProviders.map { $0.rawValue },
            "mfaEnabled": server.config.enableMultifactorAuthentication,
            "mfaEnforced": server.config.enforceMultifactorAuthentication,
            "collapsedThreads": server.config.collapsedThreads.rawValue,
            "customEmoji": server.config.enableCustomEmoji,
            "licensed": server.license?.isLicensed ?? false
        ]
        if let diagnosticId = server.config.diagnosticId {
            capabilities["diagnosticId"] = diagnosticId
        }
        guard let data = try? JSONSerialization.data(withJSONObject: capabilities, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

extension Signal where E == NoError {
    /// The first value (nil if the signal completes without one).
    func awaitValue() async -> T? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = Atomic<Bool>(value: false)
            let _ = (self |> take(1)).start(next: { value in
                if !resumed.swap(true) {
                    continuation.resume(returning: value)
                }
            }, completed: {
                if !resumed.swap(true) {
                    continuation.resume(returning: nil)
                }
            })
        }
    }
}
