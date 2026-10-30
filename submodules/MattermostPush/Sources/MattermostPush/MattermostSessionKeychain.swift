import Foundation
import Security

/// Mattermost session tokens in the Keychain, keyed by account record id, shared by the app and its
/// extensions.
///
/// The items live in the **app group's Keychain access group** (`group.<app bundle id>`): an app group id is
/// a valid access group for every target that has the group in `com.apple.security.application-groups`
/// (Apple, "Sharing access to keychain items among a collection of apps"), so no separate Keychain Sharing
/// capability is needed. The app and the notification service extension both have the group (Telegram/BUILD;
/// device builds get it from their provisioning profiles, simulator builds from the simulated entitlements).
///
/// Tokens written before the shared group was used are app-only (the application identifier's group); the
/// app moves each to the shared group the next time it reads it. If the app lacks the group entitlement
/// (`errSecMissingEntitlement`), tokens are stored app-only and the extension can't read them: it then shows
/// notifications without acknowledging them.
public enum MattermostSessionKeychain {
    /// The macOS app keeps one data set per build channel (debug, stable, …) and sets a service per channel at launch,
    /// before any token is read: with one service, a channel's launch cleanup (`accountIdsWithTokens` against its own
    /// accounts) removed the other channels' tokens.
    public static var service = "org.relaychat.mattermost.session"

    public enum Location: Equatable {
        case shared
        case appOnly
    }

    /// `group.<base bundle id>`, where an extension's base id drops its last component
    /// (`org.relaychat.Relay.NotificationService` → `org.relaychat.Relay`).
    public static func sharedAccessGroup(bundleIdentifier: String, isExtension: Bool) -> String {
        var base = bundleIdentifier
        if isExtension, let dot = bundleIdentifier.range(of: ".", options: .backwards) {
            base = String(bundleIdentifier[..<dot.lowerBound])
        }
        return "group." + base
    }

    public static var sharedAccessGroup: String? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return nil
        }
        return self.sharedAccessGroup(bundleIdentifier: bundleIdentifier, isExtension: Bundle.main.bundlePath.hasSuffix(".appex"))
    }

    /// Stores the token in the shared group (app-only if the group is not available). Returns where it went,
    /// or nil on failure; `log` gets a line for every problem.
    @discardableResult
    public static func setToken(_ token: String, accountId: Int64, log: (String) -> Void = { _ in }) -> Location? {
        let account = String(accountId)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account
        ]
        // Remove every copy (any group) first.
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let group = self.sharedAccessGroup {
            var shared = attributes
            shared[kSecAttrAccessGroup as String] = group
            let status = SecItemAdd(shared as CFDictionary, nil)
            if status == errSecSuccess {
                return .shared
            }
            log("keychain: could not store the session token in \(group) (\(status)); storing it app-only")
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            log("keychain: could not store the session token (\(status))")
            return nil
        }
        return .appOnly
    }

    /// The token of `accountId`, from any access group the caller can read. With `migrate` (the app), an
    /// app-only token is moved to the shared group.
    public static func token(accountId: Int64, migrate: Bool = false, log: (String) -> Void = { _ in }) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: String(accountId),
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data, let token = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                log("keychain: could not read the session token of account \(accountId) (\(status))")
            }
            return nil
        }
        if migrate, let group = self.sharedAccessGroup, (item[kSecAttrAccessGroup as String] as? String) != group {
            if self.setToken(token, accountId: accountId, log: log) == .shared {
                log("keychain: moved the session token of account \(accountId) to \(group)")
            }
        }
        return token
    }

    public static func removeToken(accountId: Int64, log: (String) -> Void = { _ in }) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: String(accountId)
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log("keychain: could not remove the session token of account \(accountId) (\(status))")
        }
    }

    /// Account ids with a stored token (any group).
    public static func accountIdsWithTokens() -> [Int64] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return Array(Set(items.compactMap { item in
            return (item[kSecAttrAccount as String] as? String).flatMap(Int64.init)
        }))
    }

    /// Where the token of `accountId` is stored (for the debug state and the logs).
    public static func location(accountId: Int64) -> Location? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: String(accountId),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let item = result as? [String: Any] else {
            return nil
        }
        return (item[kSecAttrAccessGroup as String] as? String) == self.sharedAccessGroup ? .shared : .appOnly
    }
}
