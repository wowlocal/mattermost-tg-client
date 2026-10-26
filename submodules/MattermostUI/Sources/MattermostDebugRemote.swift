import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import MattermostSync

/// A login screen the debug remote can fill and press.
protocol MattermostDebugDrivable: AnyObject {
    var debugScreenName: String { get }
    func debugFill(field: String, text: String) -> Bool
    func debugPress(button: String) -> Bool
    /// "OK" on the error alert the screen shows, if any.
    func debugDismissAlerts() -> Bool
}

/// **Debug builds only.** Drives the login screens and the account lifecycle through the same code paths as
/// taps, for verification without UI automation (docs/BUILD.md, "Debug remote").
///
/// The host writes one JSON command to `<app data container>/Documents/relay-debug/command.json`, then posts
/// the Darwin notification `org.relaychat.Relay.debug` (`xcrun simctl spawn <udid> notifyutil -p …`). The app
/// runs it and writes `{"id", "ok", "error"?, "state"}` to `relay-debug/result.json`. Commands
/// (`"action"` plus arguments):
/// - `state`: the visible login screen, accounts, expired sessions, Keychain tokens, account directories;
/// - `fill` (`field`, `text`): a field of the visible login screen (`url`, `login`, `password`, `code`);
/// - `press` (`button`): `primary` (Connect / Log In), `cancel`, `back`, `confirm` ("Continue" on the
///   re-login's "Log In as …?" alert), or an SSO provider (`gitlab`, …);
/// - `add-account`: Settings → Add Account (`beginNewAuth`);
/// - `switch` (`username` or `accountId`): the account switcher;
/// - `logout` (`username` or `accountId`, default: the current account): Settings → Log Out → OK
///   (`logoutFromAccount`);
/// - `relogin`: "Log In" on the session-expired alert;
/// - `dismiss-alerts`: "OK" on visible in-app alerts.
///
/// Passwords filled by the remote are cleared once the login succeeds, so iOS doesn't offer to save them
/// (its "Save Password?" sheet would cover the next screenshots).
final class MattermostDebugRemote {
    static let shared = MattermostDebugRemote()
    static let notificationName = "org.relaychat.Relay.debug"

    private weak var screen: (AnyObject & MattermostDebugDrivable)?
    private var sharedContext: SharedAccountContext?

    static func screenAppeared(_ screen: AnyObject & MattermostDebugDrivable) {
        #if DEBUG
        self.shared.screen = screen
        #endif
    }

    func start(sharedContext: SharedAccountContext) {
        #if DEBUG
        self.sharedContext = sharedContext
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async {
                MattermostDebugRemote.shared.runCommand()
            }
        }, MattermostDebugRemote.notificationName as CFString, nil, .deliverImmediately)
        NSLog("[Relay] debug remote: listening for %@", MattermostDebugRemote.notificationName)
        #endif
    }

    private var directory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("relay-debug")
    }

    private func runCommand() {
        let commandURL = self.directory.appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: commandURL), let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let action = command["action"] as? String else {
            self.writeResult(id: nil, ok: false, error: "no readable command.json")
            return
        }
        let id = command["id"] as? String
        NSLog("[Relay] debug remote: %@", action)
        switch action {
        case "state":
            self.writeResult(id: id, ok: true, error: nil)
        case "fill":
            guard let field = command["field"] as? String, let text = command["text"] as? String, let screen = self.screen else {
                self.writeResult(id: id, ok: false, error: "no screen or missing field/text")
                return
            }
            let ok = screen.debugFill(field: field, text: text)
            self.writeResult(id: id, ok: ok, error: ok ? nil : "no field \(field) on \(screen.debugScreenName)")
        case "press":
            guard let button = command["button"] as? String, let screen = self.screen else {
                self.writeResult(id: id, ok: false, error: "no screen or missing button")
                return
            }
            let ok = screen.debugPress(button: button)
            self.writeResult(id: id, ok: ok, error: ok ? nil : "no button \(button) on \(screen.debugScreenName)")
        case "add-account":
            self.sharedContext?.beginNewAuth(testingEnvironment: false)
            self.writeResult(id: id, ok: true, error: nil)
        case "switch", "logout":
            self.withAccount(command: command, completion: { [weak self] accountId in
                guard let self, let sharedContext = self.sharedContext else {
                    return
                }
                guard let accountId = accountId else {
                    self.writeResult(id: id, ok: false, error: "no matching account")
                    return
                }
                if action == "switch" {
                    sharedContext.switchToAccount(id: accountId, fromSettingsController: nil, withChatListController: nil)
                } else {
                    let _ = logoutFromAccount(id: accountId, accountManager: sharedContext.accountManager, alreadyLoggedOutRemotely: false).start()
                }
                Queue.mainQueue().after(1.0) {
                    self.writeResult(id: id, ok: true, error: nil)
                }
            })
        case "relogin":
            let ok = MattermostSessionExpiryPresenter.shared.debugOpenLogin()
            self.writeResult(id: id, ok: ok, error: ok ? nil : "no expired session")
        case "dismiss-alerts":
            // "OK" on the login screens' error alerts (each screen in the flow, top first).
            var dismissed = false
            if let screen = self.screen {
                dismissed = screen.debugDismissAlerts()
                if let navigationController = (screen as? ViewController)?.navigationController {
                    for case let other as MattermostDebugDrivable in navigationController.viewControllers.reversed() where other !== screen {
                        dismissed = other.debugDismissAlerts() || dismissed
                    }
                }
            }
            self.writeResult(id: id, ok: dismissed, error: dismissed ? nil : "no alert")
        default:
            self.writeResult(id: id, ok: false, error: "unknown action \(action)")
        }
    }

    /// The account named by `username` or `accountId`, else the current one.
    private func withAccount(command: [String: Any], completion: @escaping (AccountRecordId?) -> Void) {
        guard let sharedContext = self.sharedContext else {
            completion(nil)
            return
        }
        let _ = (sharedContext.activeAccountsWithInfo
        |> take(1)
        |> deliverOnMainQueue).start(next: { primary, accounts in
            if let username = command["username"] as? String {
                completion(accounts.first(where: { $0.peer.addressName?.lowercased() == username.lowercased() })?.account.id)
            } else if let accountId = (command["accountId"] as? String).flatMap(Int64.init) {
                completion(accounts.first(where: { $0.account.id.int64 == accountId })?.account.id)
            } else {
                completion(primary)
            }
        })
    }

    private func writeResult(id: String?, ok: Bool, error: String?) {
        guard let sharedContext = self.sharedContext else {
            return
        }
        let _ = (combineLatest(sharedContext.activeAccountsWithInfo |> take(1), sharedContext.activeAccountContexts |> take(1))
        |> deliverOnMainQueue).start(next: { [weak self] accountsWithInfo, contexts in
            guard let self else {
                return
            }
            var result: [String: Any] = ["ok": ok]
            if let id = id {
                result["id"] = id
            }
            if let error = error {
                result["error"] = error
            }
            var state: [String: Any] = MattermostSync.debugState()
            state["screen"] = self.screen?.debugScreenName ?? ""
            state["loginVisible"] = contexts.currentAuth != nil
            state["primaryAccountId"] = accountsWithInfo.primary.map { "\($0.int64)" } ?? ""
            state["uiAccounts"] = accountsWithInfo.accounts.map { info -> [String: Any] in
                return [
                    "accountId": "\(info.account.id.int64)",
                    "peerId": "\(info.account.peerId.toInt64())",
                    "username": info.peer.addressName ?? "",
                    "name": info.peer.debugDisplayTitle
                ]
            }
            state["sessionExpiry"] = MattermostSessionExpiryPresenter.shared.debugState
            result["state"] = state
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: self.directory.appendingPathComponent("result.json"), options: .atomic)
            } catch {
                NSLog("[Relay] debug remote: cannot write the result: %@", "\(error)")
            }
        })
    }
}
