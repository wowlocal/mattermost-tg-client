import Foundation
import MattermostPush

/// Session tokens in the Keychain, keyed by account record id.
///
/// Stored in the app group's Keychain access group (`MattermostSessionKeychain`), so the notification
/// service extension can read them to acknowledge pushes. Tokens written app-only by earlier builds move to
/// the shared group the next time the app reads them. Written at login (`MattermostAccountSetup`), replaced
/// at re-login, removed at logout.
enum MattermostKeychain {
    static func setToken(_ token: String, accountId: Int64) -> Bool {
        let location = MattermostSessionKeychain.setToken(token, accountId: accountId, log: { MMLog.log($0) })
        return location != nil
    }

    static func token(accountId: Int64) -> String? {
        return MattermostSessionKeychain.token(accountId: accountId, migrate: true, log: { MMLog.log($0) })
    }

    static func removeToken(accountId: Int64) {
        MattermostSessionKeychain.removeToken(accountId: accountId, log: { MMLog.log($0) })
    }

    /// Account ids with a stored token. Keychain items survive uninstalling the app, so tokens of accounts
    /// that no longer exist are removed at launch (`MattermostSync.startLifecycle`).
    static func accountIdsWithTokens() -> [Int64] {
        return MattermostSessionKeychain.accountIdsWithTokens()
    }
}
