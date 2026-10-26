import Foundation
import UIKit
import UserNotifications
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramUIPreferences
import AccountContext
import PasscodeCore
import MattermostKit
import MattermostSyncCore
import MattermostSync
import MattermostPush

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

/// **Debug builds only.** Phase 4G commands of the debug remote (docs/BUILD.md "Phase 4G"); output in `extra`:
/// - `managed` (`do=state|reload`): the managed configuration in effect (MattermostSync), the UI policy and the
///   pasteboard guard;
/// - `passcode` (`do=state|set|clear|lock|unlock|press-set`, `code`): the passcode as Settings sets and turns it
///   off (PasscodeCore + the access challenge), the lock button, an unlock with the code (what the passcode screen
///   runs after a correct entry), "Set Passcode" on the "Passcode Required" alert;
/// - `pasteboard` (`do=state|copy`, `text`): the guard's view of the pasteboard; `copy` copies as the app does;
/// - `diagnostics` (`do=state|add-report|export`, `kind`): the MetricKit store, a synthetic report (MetricKit
///   can't be triggered on the simulator), an export without the share sheet (the zip stays in tmp; its entries are
///   listed).
enum RelaySecurityDebug {
    static func handle(sharedContext: SharedAccountContext?, action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let operation = (command["do"] as? String) ?? "state"
        switch action {
        case "managed":
            if operation == "reload" {
                MattermostManagedSettings.reload(reason: "debug remote")
            }
            Queue.mainQueue().after(0.3) {
                completion(true, nil, [
                    "configuration": MattermostManagedSettings.debugState(),
                    "ui": RelayManagedConfigurationPresenter.shared.debugState
                ])
            }
            return true
        case "passcode":
            guard let sharedContext else {
                completion(false, "no context", [:])
                return true
            }
            self.passcode(sharedContext: sharedContext, operation: operation, code: command["code"] as? String, completion: completion)
            return true
        case "pasteboard":
            if operation == "copy" {
                UIPasteboard.general.string = (command["text"] as? String) ?? "copied in Relay"
            }
            Queue.mainQueue().after(0.3) {
                completion(true, nil, RelayPasteboardGuard.shared.debugState)
            }
            return true
        case "diagnostics":
            guard let sharedContext else {
                completion(false, "no context", [:])
                return true
            }
            self.diagnostics(sharedContext: sharedContext, operation: operation, command: command, completion: completion)
            return true
        default:
            return false
        }
    }

    private static func passcodeState(sharedContext: SharedAccountContext, completion: @escaping ([String: Any]) -> Void) {
        let _ = (combineLatest(
            sharedContext.accountManager.accessChallengeData() |> take(1),
            sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]) |> take(1),
            sharedContext.appLockContext.isPasscodeLocked |> take(1)
        )
        |> deliverOnMainQueue).start(next: { accessChallenge, sharedData, isLocked in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]?.get(PresentationPasscodeSettings.self) ?? .defaultSettings
            var kind = "none"
            switch accessChallenge.data {
            case .none:
                kind = "none"
            default:
                kind = "\(accessChallenge.data)"
            }
            // The notification actions' options (Reply / Mark as Read need the device unlocked with a passcode).
            UNUserNotificationCenter.current().getNotificationCategories(completionHandler: { categories in
                let actions = categories.flatMap { category in
                    category.actions.map { action -> [String: Any] in
                        return ["category": category.identifier, "action": action.identifier, "authenticationRequired": action.options.contains(.authenticationRequired)]
                    }
                }.filter { ($0["category"] as? String) == MattermostPushUserInfo.messageCategory }
                DispatchQueue.main.async {
                    completion([
                        "passcode": kind,
                        "autolockTimeout": settings.autolockTimeout.map { Int($0) } ?? -1,
                        "isLocked": isLocked,
                        "notificationActions": actions,
                        "ui": RelayManagedConfigurationPresenter.shared.debugState
                    ])
                }
            })
        })
    }

    private static func passcode(sharedContext: SharedAccountContext, operation: String, code: String?, completion: @escaping (Bool, String?, [String: Any]) -> Void) {
        let finish: (Bool, String?) -> Void = { ok, error in
            Queue.mainQueue().after(0.5) {
                self.passcodeState(sharedContext: sharedContext, completion: { state in
                    completion(ok, error, state)
                })
            }
        }
        switch operation {
        case "state":
            finish(true, nil)
        case "lock":
            sharedContext.appLockContext.lock()
            finish(true, nil)
        case "press-set":
            let ok = RelayManagedConfigurationPresenter.shared.debugPressSetPasscode()
            finish(ok, ok ? nil : "no Passcode Required alert")
        case "set", "clear", "unlock":
            guard let code, !code.isEmpty else {
                finish(false, "missing code")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    switch operation {
                    case "set":
                        // As `applicationPasscodeSetupController` completes a new passcode.
                        let reference = try PasscodeCredentialStore.shared.setPasscode(code, kind: code.count == 6 ? .digits6 : .digits4, session: nil)
                        let autolock: Int32 = MattermostManagedApp.policy.requiresPasscode ? MattermostManagedAppPolicy.maximumAutolockTimeout : 60 * 60
                        let _ = sharedContext.accountManager.transaction { transaction -> Void in
                            transaction.setAccessChallengeData(accessChallengeData(reference: reference))
                            updatePresentationPasscodeSettingsInternal(transaction: transaction, { $0.withUpdatedAutolockTimeout(autolock) })
                        }.start()
                    case "clear":
                        // As Settings → Passcode → Turn Passcode Off.
                        let session = try PasscodeCredentialStore.shared.verify(code, scope: .settings)
                        try PasscodeCredentialStore.shared.disablePasscode(session: session)
                    default:
                        // As the passcode screen after a correct entry.
                        let _ = try PasscodeCredentialStore.shared.verify(code, scope: .settings)
                        DispatchQueue.main.async {
                            sharedContext.appLockContext.unlock()
                        }
                    }
                    DispatchQueue.main.async {
                        finish(true, nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        finish(false, "\(error)")
                    }
                }
            }
        default:
            finish(false, "unknown do=\(operation)")
        }
    }

    private static func diagnostics(sharedContext: SharedAccountContext, operation: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) {
        let store = RelayDiagnostics.shared.store
        let state: () -> [String: Any] = {
            return [
                "directory": store.directory.path,
                "reports": store.reports().map { ["file": $0.url.lastPathComponent, "kind": $0.kind.rawValue, "bytes": $0.size] },
                "lastExport": RelayDiagnosticsDebug.lastExport?.path ?? ""
            ]
        }
        switch operation {
        case "state":
            completion(true, nil, state())
        case "add-report":
            // A report shaped like MetricKit's JSON (a crash diagnostic), dated now.
            let kind = DiagnosticReportStore.Kind(rawValue: (command["kind"] as? String) ?? "diagnostics") ?? .diagnostics
            let payload: [String: Any] = [
                "timeStampBegin": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
                "timeStampEnd": ISO8601DateFormatter().string(from: Date()),
                "crashDiagnostics": kind == .diagnostics ? [["diagnosticMetaData": ["appBuildVersion": "debug", "exceptionType": 1, "signal": 11], "callStackTree": ["callStacks": [], "callStackPerThread": true]]] : [],
                "relayDebugSample": true
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            let ok = store.store(data, kind: kind, date: Date())
            completion(ok, ok ? nil : "not stored", state())
        case "export":
            let _ = (relayDiagnosticsExportInput(sharedContext: sharedContext)
            |> deliverOn(relayDiagnosticsQueue)
            |> map { input -> URL? in
                return RelayDiagnostics.export(input, store: store)
            }
            |> deliverOnMainQueue).start(next: { url in
                guard let url else {
                    completion(false, "export failed", state())
                    return
                }
                RelayDiagnosticsDebug.lastExport = url
                // The zip's entries, for a look without copying it out.
                var extra = state()
                extra["zip"] = url.path
                extra["zipBytes"] = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
                completion(true, nil, extra)
            })
        default:
            completion(false, "unknown do=\(operation)", state())
        }
    }
}

#endif
