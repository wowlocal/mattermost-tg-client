import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit

/// Managed app configuration (Phase 4G, docs/release/managed-configuration.md): what an MDM/EMM sets for the app
/// under `com.apple.configuration.managed`, with the Mattermost mobile app's key names
/// (`MattermostManagedConfiguration`).
///
/// - **App** (`startInApp`, at launch before any account connects): reads `UserDefaults.standard`, applies the
///   certificate pins to every MattermostKit connection (`MattermostServerTrust.shared`), writes the copy the
///   extensions read (`relay-managed-configuration.json` in the app group's data root), and follows changes
///   (`UserDefaults.didChangeNotification`, and a re-read whenever the app becomes active). Accounts on a server
///   the configuration doesn't allow are logged out (`enforceServerRestriction`), and the probe of the login
///   refuses such servers.
/// - **Extensions** (`loadInExtension`): the pins (and the restriction) from the app's copy. Only the app can
///   read the managed configuration; an extension that runs before the app has seen a new configuration uses the
///   previous one.
///
/// What the UI does with the rest (passcode, app switcher, pasteboard, login prefill) is MattermostUI's.
public enum MattermostManagedSettings {
    private static let state = MMLocked<MattermostManagedConfiguration>(.none)
    private static let promise = ValuePromise<MattermostManagedConfiguration>(.none, ignoreRepeated: true)
    private static let sharedDirectory = MMLocked<URL?>(nil)
    private static let observers = MMLocked<[NSObjectProtocol]>([])
    private static let restrictedLogoutsPipe = ValuePipe<MattermostRestrictedLogout>()

    /// The configuration in effect (`.none` when nothing is managed).
    public static var current: MattermostManagedConfiguration {
        return self.state.with { $0 }
    }

    /// The configuration in effect and every change.
    public static var updates: Signal<MattermostManagedConfiguration, NoError> {
        return self.promise.get()
    }

    /// Accounts logged out because the configuration doesn't allow their server, for the app to tell the user.
    public static var restrictedLogouts: Signal<MattermostRestrictedLogout, NoError> {
        return self.restrictedLogoutsPipe.signal()
    }

    /// The managed dictionary as iOS delivers it (also through the launch argument domain:
    /// `-com.apple.configuration.managed '<dict>…</dict>'`).
    static func readManagedDictionary() -> [String: Any]? {
        return UserDefaults.standard.dictionary(forKey: MattermostManagedConfiguration.userDefaultsKey)
    }

    // MARK: App

    /// Main app, once, at launch: before accounts are loaded, so no connection is made without the pins.
    public static func startInApp(sharedDirectory: URL) {
        self.sharedDirectory.with { $0 = sharedDirectory }
        self.reload(reason: "launch")
        let center = NotificationCenter.default
        let defaultsObserver = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil, using: { _ in
            MattermostManagedSettings.reload(reason: "defaults changed")
        })
        // `UIApplication.didBecomeActiveNotification` (MattermostSync doesn't import UIKit): an MDM may have
        // changed the configuration while the app was suspended.
        let activeObserver = center.addObserver(forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: nil, using: { _ in
            MattermostManagedSettings.reload(reason: "app became active")
        })
        self.observers.with { $0 = [defaultsObserver, activeObserver] }
    }

    /// Reads the managed dictionary again and applies it when it changed.
    public static func reload(reason: String) {
        let configuration = MattermostManagedConfiguration(dictionary: self.readManagedDictionary())
        self.apply(configuration, reason: reason, writeShared: true)
    }

    private static func apply(_ configuration: MattermostManagedConfiguration, reason: String, writeShared: Bool) {
        let (changed, pinsChanged) = self.state.with { current -> (Bool, Bool) in
            let changed = current != configuration
            let pinsChanged = current.certificatePins != configuration.certificatePins
            current = configuration
            return (changed, pinsChanged)
        }
        guard changed else {
            return
        }
        MMLog.log("managed configuration (\(reason)): \(self.summary(configuration))")
        if pinsChanged {
            // Connections opened under the old pins are not reused: a new session for new requests, and every
            // WebSocket reconnects (URLSession checks a certificate only when it opens a connection).
            MattermostServerTrust.shared.setPins(configuration.certificatePins)
            MattermostURLSession.renew()
            MattermostSync.reconnectSockets(reason: "certificate pins changed")
        }
        if writeShared, let directory = self.sharedDirectory.with({ $0 }) {
            do {
                try configuration.writeShared(directory: directory)
            } catch {
                MMLog.log("managed configuration: cannot write the extensions' copy: \(error)")
            }
        }
        self.promise.set(configuration)
        MattermostSync.enforceServerRestriction()
    }

    /// One line for the log: which keys are set, never their values (the pins are counted).
    public static func summary(_ configuration: MattermostManagedConfiguration) -> String {
        guard configuration.isManaged || !configuration.ignoredKeys.isEmpty else {
            return "none"
        }
        var parts: [String] = []
        if let url = configuration.managedServerURL {
            parts.append("server \(url.host ?? "?")\(configuration.allowOtherServers ? "" : " only")")
        }
        if configuration.serverName != nil {
            parts.append("server name")
        }
        if configuration.username != nil {
            parts.append("username")
        }
        if configuration.inAppPinCode {
            parts.append("passcode required")
        }
        if configuration.blurApplicationScreen {
            parts.append("app switcher hidden")
        }
        if configuration.copyAndPasteProtection {
            parts.append("copy/paste protection")
        }
        if configuration.jailbreakDetection {
            parts.append("jailbreak detection")
        }
        if configuration.vendor != nil {
            parts.append("organization name")
        }
        if !configuration.certificatePins.isEmpty {
            let hosts = configuration.certificatePins.pinsByHost
            parts.append("pins for \(hosts.count) host(s) (\(hosts.values.reduce(0) { $0 + $1.count }) pin(s)\(configuration.certificatePins.problems.isEmpty ? "" : ", \(configuration.certificatePins.problems.count) unreadable"))")
        }
        if !configuration.ignoredKeys.isEmpty {
            parts.append("ignored \(configuration.ignoredKeys)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Extensions

    /// Share and notification extensions: the pins and the restriction from the app's copy.
    public static func loadInExtension(sharedDirectory: URL) {
        let configuration = MattermostManagedConfiguration.readShared(directory: sharedDirectory) ?? .none
        self.state.with { $0 = configuration }
        MattermostServerTrust.shared.setPins(configuration.certificatePins)
        self.promise.set(configuration)
    }

    static func notifyRestrictedLogout(_ logout: MattermostRestrictedLogout) {
        self.restrictedLogoutsPipe.putNext(logout)
    }

    #if DEBUG
    /// Debug remote: the configuration in effect and what reached the app.
    public static func debugState() -> [String: Any] {
        let configuration = self.current
        var result: [String: Any] = [
            "summary": self.summary(configuration),
            "managed": configuration.isManaged,
            "allowOtherServers": configuration.allowOtherServers,
            "inAppPinCode": configuration.inAppPinCode,
            "blurApplicationScreen": configuration.blurApplicationScreen,
            "copyAndPasteProtection": configuration.copyAndPasteProtection,
            "jailbreakDetection": configuration.jailbreakDetection,
            "pins": configuration.certificatePins.pinsByHost.mapValues { Array($0).sorted() },
            "pinProblems": configuration.certificatePins.problems,
            "ignoredKeys": configuration.ignoredKeys,
            "trustPins": MattermostServerTrust.shared.pins.pinsByHost.mapValues { $0.count },
            "rawKeys": (self.readManagedDictionary() ?? [:]).keys.sorted()
        ]
        result["serverUrl"] = configuration.serverURL
        result["managedServer"] = configuration.managedServerURL?.absoluteString
        result["restrictedServer"] = configuration.restrictedServerURL?.absoluteString
        result["serverName"] = configuration.serverName
        result["username"] = configuration.username
        result["vendor"] = configuration.vendor
        if let directory = self.sharedDirectory.with({ $0 }) {
            result["sharedCopy"] = MattermostManagedConfiguration.readShared(directory: directory).map { self.summary($0) } ?? "absent"
        }
        return result
    }
    #endif
}

/// An account logged out because managed configuration allows only another server.
public struct MattermostRestrictedLogout: Equatable {
    public let accountId: AccountRecordId
    /// The account's server (host, port and path).
    public let server: String
    /// The server the configuration allows.
    public let allowedServer: String
}

extension MattermostSync {
    /// Reconnects every running account's WebSocket now.
    static func reconnectSockets(reason: String) {
        for sync in self.accounts.with({ Array($0.values) }) {
            sync.reconnectNow(reason: reason)
        }
    }

    /// Logs out every loaded account whose server the managed configuration doesn't allow (a configuration with
    /// `allowOtherServers = false` that arrived after the account was added). Accounts are logged out as Settings →
    /// Log Out does: the session ends on the server and the local data is deleted.
    static func enforceServerRestriction() {
        let configuration = MattermostManagedSettings.current
        guard let allowed = configuration.restrictedServerURL else {
            return
        }
        let disallowed = self.registry.with { registry -> [(AccountRecordId, String)] in
            return registry.compactMap { id, registered -> (AccountRecordId, String)? in
                guard let url = URL(string: registered.server.url), !configuration.allowsServer(url) else {
                    return nil
                }
                return (id, registered.server.url)
            }
        }
        for (accountId, serverURL) in disallowed {
            self.logOutRestricted(accountId: accountId, serverURL: serverURL, allowed: allowed)
        }
    }

    /// Logs out an account whose server the managed configuration doesn't allow; nothing of it syncs meanwhile.
    static func logOutRestricted(accountId: AccountRecordId, serverURL: String, allowed: URL) {
        guard let accountManager = self.lifecycleAccountManager else {
            return
        }
        guard self.restrictedLogouts.with({ $0.insert(accountId).inserted }) else {
            return
        }
        MMLog.log("managed configuration: account \(accountId.int64) is on a server that is not allowed; logging it out")
        self.stopAccount(accountId)
        let display: (URL?) -> String = { url in
            guard let url, let host = url.host else {
                return serverURL
            }
            var text = host
            if let port = url.port {
                text += ":\(port)"
            }
            if !url.path.isEmpty && url.path != "/" {
                text += url.path
            }
            return text
        }
        MattermostManagedSettings.notifyRestrictedLogout(MattermostRestrictedLogout(accountId: accountId, server: display(URL(string: serverURL)), allowedServer: display(allowed)))
        let _ = logoutFromAccount(id: accountId, accountManager: accountManager, alreadyLoggedOutRemotely: false).start()
    }
}
