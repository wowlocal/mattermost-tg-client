import Foundation
import Security

/// Session tokens in the Keychain, keyed by account record id.
///
/// Stored **app-only** (the default access group): the app has no `keychain-access-groups`
/// entitlement yet, so a shared group for the notification and share extensions needs signing work
/// first. Written at login (`MattermostAccountSetup`), replaced at re-login, removed at logout.
enum MattermostKeychain {
    private static let service = "org.relaychat.mattermost.session"

    static func setToken(_ token: String, accountId: Int64) -> Bool {
        let account = String(accountId)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            MMLog.log("keychain: could not store the session token (\(status))")
            return false
        }
        return true
    }

    static func token(accountId: Int64) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(accountId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                MMLog.log("keychain: could not read the session token (\(status))")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func removeToken(accountId: Int64) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(accountId)
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            MMLog.log("keychain: could not remove the session token of account \(accountId) (\(status))")
        }
    }

    /// Account ids with a stored token. Keychain items survive uninstalling the app, so tokens of accounts
    /// that no longer exist are removed at launch (`MattermostSync.startLifecycle`).
    static func accountIdsWithTokens() -> [Int64] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            return (item[kSecAttrAccount as String] as? String).flatMap(Int64.init)
        }
    }
}
