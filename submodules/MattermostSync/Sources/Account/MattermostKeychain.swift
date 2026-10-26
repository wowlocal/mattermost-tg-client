import Foundation
import Security

/// Session tokens in the Keychain, keyed by account record id.
///
/// Spike D stores them **app-only** (the default access group): the app has no
/// `keychain-access-groups` entitlement yet, so a shared group for the notification and share
/// extensions needs signing work first (Phase 2).
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
        SecItemDelete(query as CFDictionary)
    }
}
