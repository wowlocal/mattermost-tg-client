import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

/// Debug-only login for tests and scripted runs: server URL and credentials come from the launch
/// environment, e.g.
/// `SIMCTL_CHILD_RELAY_DEBUG_MM_URL=http://localhost:8065 SIMCTL_CHILD_RELAY_DEBUG_MM_LOGIN=alice
///  SIMCTL_CHILD_RELAY_DEBUG_MM_PASSWORD=… xcrun simctl launch …`.
/// Without these variables (and in release builds) the app shows the login screens.
public enum MattermostDebugLogin {
    private enum State {
        case notStarted
        case running
        case finished
    }

    private static let state = Atomic<State>(value: .notStarted)

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
    /// `SharedAccountContextImpl` loads it like any other. Runs once per launch: on failure, and on later calls
    /// (the last account logged out), `fallback` runs on the main queue instead (it begins the normal login).
    public static func createAccountIfNeeded(accountManager: AccountManager<TelegramAccountManagerTypes>, rootPath: String, encryptionParameters: ValueBoxEncryptionParameters, fallback: @escaping () -> Void) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["RELAY_DEBUG_MM_URL"], let login = environment["RELAY_DEBUG_MM_LOGIN"], let password = environment["RELAY_DEBUG_MM_PASSWORD"] else {
            Queue.mainQueue().async(fallback)
            return
        }
        // Once per launch: after that (logout of the last account, a failed attempt) the login screens show.
        var previous: State = .notStarted
        let _ = self.state.modify { current -> State in
            previous = current
            return current == .notStarted ? .running : current
        }
        switch previous {
        case .notStarted:
            break
        case .running:
            return
        case .finished:
            Queue.mainQueue().async(fallback)
            return
        }
        Task {
            do {
                let server = try await MattermostAccountSetup.probe(address: urlString, allowInsecureLocal: true)
                let result = try await MattermostAccountSetup.login(server: server.url, loginId: login, password: password, mfaToken: environment["RELAY_DEBUG_MM_MFA"])
                MMLog.log("debug login: \(result.user.username) on \(server.url)")
                try await MattermostAccountSetup.createAccount(server: server, serverURL: server.url, login: result, loginId: login, target: .newAccount(rootPath: rootPath, encryptionParameters: encryptionParameters), accountManager: accountManager)
                let _ = self.state.swap(.finished)
            } catch {
                MMLog.log("debug login failed: \(error); showing the login screen")
                let _ = self.state.swap(.finished)
                Queue.mainQueue().async(fallback)
            }
        }
        #else
        Queue.mainQueue().async(fallback)
        #endif
    }
}
#endif
