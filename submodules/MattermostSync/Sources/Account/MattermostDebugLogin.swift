import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit

/// Debug-only login for tests and scripted runs: server URL and credentials come from the launch
/// environment, e.g.
/// `SIMCTL_CHILD_RELAY_DEBUG_MM_URL=http://localhost:8065 SIMCTL_CHILD_RELAY_DEBUG_MM_LOGIN=alice
///  SIMCTL_CHILD_RELAY_DEBUG_MM_PASSWORD=… xcrun simctl launch …`.
/// Without these variables (and in release builds) the app shows the login screens.
public enum MattermostDebugLogin {
    private static let started = Atomic<Bool>(value: false)

    /// True in debug builds launched with all three variables.
    public static var isRequested: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["RELAY_DEBUG_MM_URL"] != nil && environment["RELAY_DEBUG_MM_LOGIN"] != nil && environment["RELAY_DEBUG_MM_PASSWORD"] != nil
        #else
        return false
        #endif
    }

    /// Called where Telegram would begin its phone login (no account, no login in progress) when
    /// `isRequested`. Logs in and creates the account with `MattermostAccountSetup` (new record);
    /// `SharedAccountContextImpl` loads it like any other. On failure, `fallback` runs on the main queue
    /// (it begins the normal login).
    public static func createAccountIfNeeded(accountManager: AccountManager<TelegramAccountManagerTypes>, rootPath: String, encryptionParameters: ValueBoxEncryptionParameters, fallback: @escaping () -> Void) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["RELAY_DEBUG_MM_URL"], let login = environment["RELAY_DEBUG_MM_LOGIN"], let password = environment["RELAY_DEBUG_MM_PASSWORD"] else {
            Queue.mainQueue().async(fallback)
            return
        }
        if self.started.swap(true) {
            return
        }
        Task {
            do {
                let server = try await MattermostAccountSetup.probe(address: urlString, allowInsecureLocal: true)
                let result = try await MattermostAccountSetup.login(server: server.url, loginId: login, password: password, mfaToken: environment["RELAY_DEBUG_MM_MFA"])
                MMLog.log("debug login: \(result.user.username) on \(server.url)")
                try await MattermostAccountSetup.createAccount(server: server, serverURL: server.url, login: result, loginId: login, target: .newAccount(rootPath: rootPath, encryptionParameters: encryptionParameters), accountManager: accountManager)
            } catch {
                MMLog.log("debug login failed: \(error); showing the login screen")
                let _ = self.started.swap(false)
                Queue.mainQueue().async(fallback)
            }
        }
        #else
        Queue.mainQueue().async(fallback)
        #endif
    }
}
