import Foundation
import UIKit
import UserNotifications
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import MattermostKit
import MattermostSync
import MattermostPushService

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

/// **Debug builds only.** Hooks other modules install into the debug remote.
public enum MattermostDebugHooks {
    /// Handles a chat-level command (TelegramUI's composer driver, Phase 3D): returns false for actions it
    /// doesn't know; otherwise calls `completion(ok, error, info)` once (`info` lands in the result's `state.chat`).
    public static var chatCommand: ((_ action: String, _ command: [String: Any], _ completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool)?
}

/// **Debug builds only.** Phase 3B: the debug remote's chat-screen commands, installed by TelegramUI (which can
/// reach the chat controller, `RelayDebugThreads`). The handler returns false for an action it doesn't know and
/// calls `completion` once done.
public enum MattermostDebugChatCommands {
    public static var handler: ((_ action: String, _ command: [String: Any], _ completion: @escaping (_ ok: Bool, _ error: String?, _ extra: [String: Any]) -> Void) -> Bool)?
}

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
/// - `notifications`: the delivered notifications (newest first), in the result's `deliveredNotifications`;
/// - `notification-open`, `notification-reply` (`text`), `notification-read` (`which`: request identifier,
///   index or `latest`): a tap, Reply or Mark as Read on a delivered notification, through the AppDelegate's
///   own handler (Phase 3A). The result's `visibleChat` shows the chat on top afterwards;
/// - `simulate-push` (`payload`: the APNs JSON, or `file`: its path; `delay`: seconds, default 1): a push as the
///   notification service extension would show it (Phase 3A, see `simulatePush`).
/// - `threads-row` (`index`): a tap on that row of the visible threads screen (Phase 3B);
/// - chat-screen commands (Phase 3B), handled by TelegramUI's `chatCommandHandler` (`RelayDebugScreens`): `chat`,
///   `post`, `replies`, `threads`, `follow`, `unfollow`, `scroll`, `visible`, `menu`, `back`. Their output is in
///   the result's `extra`;
/// - composer commands (Phase 3D), handled by TelegramUI's `RelayDebugComposer`: `compose` (`text`), `suggestions`,
///   `pick` (`index`), `send-composer`, `input`, `open-thread` (`post`). Their output is in the result's
///   `state.chat`;
/// - `dialog`, `dialog-set` (`name`, `value`, `type`), `dialog-picker` (`name`), `dialog-submit`, `dialog-cancel`:
///   the visible interactive dialog (Phase 3D), its state in the result's `state.dialog`.
///
/// Passwords filled by the remote are cleared once the login succeeds, so iOS doesn't offer to save them
/// (its "Save Password?" sheet would cover the next screenshots).
final class MattermostDebugRemote {
    static let shared = MattermostDebugRemote()
    static let notificationName = "org.relaychat.Relay.debug"

    private weak var screen: (AnyObject & MattermostDebugDrivable)?
    private var sharedContext: SharedAccountContext?
    private var lastExtra: [String: Any] = [:]

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
        self.lastExtra = [:]
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
        case "not-now":
            // "Not Now" on the "Session Expired" alert.
            let ok = MattermostSessionExpiryPresenter.shared.debugDismissAlert()
            self.writeResult(id: id, ok: ok, error: ok ? nil : "no alert")
        case "title-relogin":
            // A tap on the chat list title "Session Expired".
            MattermostBackend.requestRelogin?()
            Queue.mainQueue().after(1.5) {
                self.writeResult(id: id, ok: true, error: nil)
            }
        case "open-saved":
            // Opens the current account's Saved Messages (works while the session is expired, when the
            // `RELAY_DEBUG_OPEN_CHAT` hook, which runs after the bootstrap, does not).
            guard let sharedContext = self.sharedContext else {
                self.writeResult(id: id, ok: false, error: "no context")
                return
            }
            let _ = (sharedContext.activeAccountContexts
            |> take(1)
            |> mapToSignal { primary, _, _ -> Signal<(AccountContext, EnginePeer)?, NoError> in
                guard let context = primary else {
                    return .single(nil)
                }
                return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                |> map { peer in peer.flatMap { (context, $0) } }
            }
            |> deliverOnMainQueue).start(next: { [weak self] value in
                guard let (context, peer) = value, let navigationController = sharedContext.mainWindow?.viewController as? NavigationController else {
                    self?.writeResult(id: id, ok: false, error: "no account")
                    return
                }
                sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
                self?.writeResult(id: id, ok: true, error: nil)
            })
        case "send-saved":
            // A message to the current account's Saved Messages, as the composer sends it (works while the
            // session is expired: the message waits, pending, for a new login).
            guard let text = command["text"] as? String, let sharedContext = self.sharedContext else {
                self.writeResult(id: id, ok: false, error: "missing text")
                return
            }
            let _ = (sharedContext.activeAccountContexts
            |> take(1)
            |> mapToSignal { primary, _, _ -> Signal<[MessageId?], NoError> in
                guard let account = primary?.account else {
                    return .single([])
                }
                return enqueueMessages(account: account, peerId: account.peerId, messages: [.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
            }
            |> deliverOnMainQueue).start(next: { [weak self] ids in
                self?.writeResult(id: id, ok: !ids.isEmpty, error: ids.isEmpty ? "no account" : nil)
            })
        case "notifications", "notification-open", "notification-reply", "notification-read":
            self.runNotificationCommand(action: action, command: command, id: id)
        case "simulate-push":
            self.simulatePush(command: command, id: id)
        case "share-extension":
            // Phase 3F: the app's share extension with generated items (MattermostShareExtensionDebug).
            MattermostShareExtensionDebug.present(text: command["text"] as? String, url: (command["url"] as? String).flatMap(URL.init(string:)), imageCount: Int((command["images"] as? String) ?? "") ?? 0, fileCount: Int((command["files"] as? String) ?? "") ?? 0, completion: { [weak self] ok, error in
                self?.writeResult(id: id, ok: ok, error: error)
            })
        case "dialog", "dialog-set", "dialog-submit", "dialog-cancel", "dialog-picker":
            self.runDialogCommand(action: action, command: command, id: id)
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
        case "dump-chatlist":
            // Phase 3B: `Documents/relay-debug/chatlist.json` now (badges against the server's counters).
            self.withAccount(command: command, completion: { [weak self] accountId in
                guard let accountId = accountId else {
                    self?.writeResult(id: id, ok: false, error: "no account")
                    return
                }
                let _ = (MattermostSync.debugDumpChatList(accountId: accountId) |> deliverOnMainQueue).start(next: { ok in
                    self?.writeResult(id: id, ok: ok, error: ok ? nil : "no sync")
                })
            })
        case "threads-list":
            // Phase 3B: what the threads screen shows for a team (`team`, default the current account's first).
            self.withAccount(command: command, completion: { [weak self] accountId in
                guard let self, let accountId = accountId else {
                    self?.writeResult(id: id, ok: false, error: "no account")
                    return
                }
                let teamId = (command["team"] as? String) ?? MattermostSync.teams(accountId: accountId).first?.id ?? ""
                let _ = (MattermostSync.threadList(accountId: accountId, teamId: teamId)
                |> filter { $0?.isLoaded ?? true }
                |> take(1)
                |> deliverOnMainQueue).start(next: { [weak self] list in
                    guard let self else {
                        return
                    }
                    if let list = list {
                        self.lastExtra = [
                            "teamId": list.teamId,
                            "unreadThreads": list.unreadThreadCount,
                            "unreadMentions": list.unreadMentionCount,
                            "threads": list.items.map { item -> [String: Any] in
                                return ["id": item.rootPostId, "channel": item.channelTitle, "replies": item.replyCount, "unreadReplies": item.unreadReplies, "unreadMentions": item.unreadMentions, "lastReplyAt": item.lastReplyAt, "participants": item.participants.count, "threadId": item.threadId ?? 0, "text": String(item.rootText.prefix(40))]
                            }
                        ]
                    } else {
                        self.lastExtra = ["collapsedThreads": false]
                    }
                    self.writeResult(id: id, ok: true, error: nil)
                })
            })
        case "ax-tree":
            // Phase 4C: the accessibility elements VoiceOver reaches on screen, in reading order (label, value,
            // hint, traits, frame, custom actions).
            self.lastExtra = ["elements": MattermostAccessibilityDebug.elements()]
            self.writeResult(id: id, ok: true, error: nil)
        case "runtime":
            // Phase 4B: requests parked by the null network engine per Telegram function (total, still live,
            // `stacks=1`: where the first one started) and the app's memory footprint.
            self.lastExtra = MattermostDebugRemote.runtimeReport(stacks: (command["stacks"] as? String) == "1")
            self.writeResult(id: id, ok: true, error: nil)
        case "threads-row":
            let index = (command["index"] as? String).flatMap(Int.init) ?? 0
            if let openRow = MattermostThreadsDebug.openRow {
                openRow(index)
                Queue.mainQueue().after(1.5) {
                    self.writeResult(id: id, ok: true, error: nil)
                }
            } else {
                self.writeResult(id: id, ok: false, error: "no threads screen")
            }
        default:
            self.lastExtra = [:]
            // Phase 3D-2: directory and membership screens (`MattermostDirectoryDebug`); output in `extra`.
            if MattermostDirectoryDebug.handle(sharedContext: self.sharedContext, action: action, command: command, completion: { [weak self] ok, error, extra in
                self?.lastExtra = extra
                self?.writeResult(id: id, ok: ok, error: error)
            }) {
                return
            }
            if let handler = MattermostDebugChatCommands.handler, handler(action, command, { [weak self] ok, error, extra in
                self?.lastExtra = extra
                self?.writeResult(id: id, ok: ok, error: error)
            }) {
                return
            }
            // Chat-level commands of TelegramUI's debug driver (`compose`, `suggestions`, `pick`, `send`, …).
            if let handler = MattermostDebugHooks.chatCommand, handler(action, command, { [weak self] ok, error, info in
                self?.lastChatInfo = info
                self?.writeResult(id: id, ok: ok, error: error)
            }) {
                return
            }
            self.writeResult(id: id, ok: false, error: "unknown action \(action)")
        }
    }

    private var lastChatInfo: [String: Any]?

    // MARK: Runtime hygiene (Phase 4B)

    static func runtimeReport(stacks: Bool) -> [String: Any] {
        let parked = NullNetworkStatistics.snapshot()
        var functions: [[String: Any]] = []
        for item in parked {
            var entry: [String: Any] = ["function": item.function, "total": item.total, "live": item.live]
            if stacks {
                entry["stack"] = item.firstStack
            }
            functions.append(entry)
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        var memory: [String: Any] = [:]
        if result == KERN_SUCCESS {
            memory["physFootprintMB"] = Double(info.phys_footprint) / 1_048_576.0
            memory["residentMB"] = Double(info.resident_size) / 1_048_576.0
        }
        return [
            "parked": functions,
            "parkedKinds": parked.count,
            "parkedTotal": parked.reduce(0) { $0 + $1.total },
            "parkedLive": parked.reduce(0) { $0 + $1.live },
            "memory": memory,
            "uptime": ProcessInfo.processInfo.systemUptime
        ]
    }

    // MARK: Interactive dialogs (Phase 3D)

    private weak var dialog: MattermostDialogController?
    private var dialogSubmit: (() -> Void)?
    private var dialogOpenPicker: ((String) -> Void)?
    private var dialogUpdate: ((String, JSONValue) -> Void)?
    private var dialogState: (() -> [String: Any])?

    /// The visible interactive dialog registers its actions (debug builds).
    static func dialogAppeared(_ controller: MattermostDialogController, submit: @escaping () -> Void, openPicker: @escaping (String) -> Void, update: @escaping (String, JSONValue) -> Void, state: @escaping () -> [String: Any]) {
        #if DEBUG
        self.shared.dialog = controller
        self.shared.dialogSubmit = submit
        self.shared.dialogOpenPicker = openPicker
        self.shared.dialogUpdate = update
        self.shared.dialogState = state
        #endif
    }

    /// `dialog` (its title and values in the result's `dialog`), `dialog-set` (`name`, `value`, `type`: `bool` or
    /// `number`, default text), `dialog-submit` (the submit button), `dialog-cancel` (Cancel), `dialog-picker`
    /// (`name`: a select's option screen, as a tap on it).
    private func runDialogCommand(action: String, command: [String: Any], id: String?) {
        guard let dialog = self.dialog else {
            self.writeResult(id: id, ok: false, error: "no dialog")
            return
        }
        switch action {
        case "dialog-set":
            guard let name = command["name"] as? String, let value = command["value"] as? String else {
                self.writeResult(id: id, ok: false, error: "missing name or value")
                return
            }
            switch command["type"] as? String {
            case "bool":
                self.dialogUpdate?(name, .bool(value == "true"))
            case "number":
                self.dialogUpdate?(name, Int64(value).map(JSONValue.int) ?? .string(value))
            default:
                self.dialogUpdate?(name, .string(value))
            }
        case "dialog-submit":
            self.dialogSubmit?()
        case "dialog-cancel":
            MattermostComposer.cancelDialog(dialog.dialog)
            dialog.dismiss()
        case "dialog-picker":
            self.dialogOpenPicker?(command["name"] as? String ?? "")
        default:
            break
        }
        Queue.mainQueue().after(action == "dialog-submit" ? 1.5 : 0.3) {
            var info = self.dialogState?() ?? [:]
            info["title"] = dialog.dialog.request.dialog.title
            info["visible"] = self.dialog != nil && self.dialog?.view.window != nil
            self.lastDialogInfo = info
            self.writeResult(id: id, ok: true, error: nil)
        }
    }

    private var lastDialogInfo: [String: Any]?

    /// Phase 3A: delivered notifications, and a tap / Reply / Mark as Read on one of them through the app's
    /// own response handler (`MattermostSync.debugNotificationResponder`). `which` is a request identifier, an
    /// index into the list (newest first) or `latest` (default).
    private func runNotificationCommand(action: String, command: [String: Any], id: String?) {
        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { notifications in
            DispatchQueue.main.async {
                let sorted = notifications.sorted(by: { $0.date > $1.date })
                self.notificationList = sorted.map { notification -> [String: Any] in
                    let content = notification.request.content
                    var userInfo: [String: String] = [:]
                    for (key, value) in content.userInfo where key as? String != "aps" {
                        userInfo["\(key)"] = "\(value)"
                    }
                    return [
                        "identifier": notification.request.identifier,
                        "date": notification.date.timeIntervalSince1970,
                        "title": content.title,
                        "subtitle": content.subtitle,
                        "body": content.body,
                        "threadIdentifier": content.threadIdentifier,
                        "category": content.categoryIdentifier,
                        "badge": content.badge?.intValue ?? -1,
                        "userInfo": userInfo
                    ]
                }
                if action == "notifications" {
                    self.writeResult(id: id, ok: true, error: nil)
                    return
                }
                let which = command["which"] as? String ?? "latest"
                var selected: UNNotification?
                if which == "latest" {
                    selected = sorted.first
                } else if let index = Int(which), index >= 0, index < sorted.count {
                    selected = sorted[index]
                } else {
                    selected = sorted.first(where: { $0.request.identifier == which })
                }
                guard let notification = selected else {
                    self.writeResult(id: id, ok: false, error: "no delivered notification \(which)")
                    return
                }
                guard let responder = MattermostSync.debugNotificationResponder else {
                    self.writeResult(id: id, ok: false, error: "no notification responder")
                    return
                }
                let actionIdentifier: String
                switch action {
                case "notification-reply":
                    actionIdentifier = MattermostSync.notificationReplyActionIdentifier
                case "notification-read":
                    actionIdentifier = MattermostSync.notificationMarkReadActionIdentifier
                default:
                    actionIdentifier = UNNotificationDefaultActionIdentifier
                }
                responder(notification.request.content.userInfo, actionIdentifier, command["text"] as? String)
                Queue.mainQueue().after(1.0) {
                    self.writeResult(id: id, ok: true, error: nil)
                }
            }
        })
    }

    private var notificationList: [[String: Any]] = []
    private var simulatedPushes: [String: MattermostPushServiceHandler] = [:]

    /// Phase 3A: `xcrun simctl push` hands a push straight to SpringBoard and never starts the notification
    /// service extension (only APNs delivery does), so on a simulator without a real APNs key the extension's
    /// work can't be seen. This runs the same code (`MattermostPushServiceHandler`, MattermostPushService) on
    /// the payload in the app and gives the result to the system as a local notification after `delay`
    /// seconds: it is then shown, grouped, tapped and answered like a push, also when the app has been put in
    /// the background, locked or killed in the meantime. `clear` and `update_badge` go to the app's handler
    /// for background pushes, as on a device. infra/push-proxy/sim-bridge.py --deliver app sends the dev
    /// server's pushes here.
    private func simulatePush(command: [String: Any], id: String?) {
        var data: Data?
        if let text = command["payload"] as? String {
            data = Data(text.utf8)
        } else if let path = command["file"] as? String {
            data = try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard let data, let userInfo = (try? JSONSerialization.jsonObject(with: data)) as? [AnyHashable: Any] else {
            self.writeResult(id: id, ok: false, error: "no readable payload")
            return
        }
        let delay = max(0.1, (command["delay"] as? String).flatMap(Double.init) ?? 1.0)
        let aps = userInfo["aps"] as? [AnyHashable: Any] ?? [:]
        let type = userInfo["type"] as? String ?? ""
        if type == "clear" || type == "update_badge" {
            let handled = MattermostSync.handleBackgroundPush(userInfo: userInfo)
            if let badge = (aps["badge"] as? NSNumber)?.intValue {
                if #available(iOS 16.0, *) {
                    UNUserNotificationCenter.current().setBadgeCount(badge)
                } else {
                    UIApplication.shared.applicationIconBadgeNumber = badge
                }
            }
            self.writeResult(id: id, ok: handled, error: handled ? nil : "not a Mattermost push")
            return
        }
        let content = UNMutableNotificationContent()
        if let alert = aps["alert"] as? [AnyHashable: Any] {
            content.title = alert["title"] as? String ?? ""
            content.body = alert["body"] as? String ?? ""
        } else if let alert = aps["alert"] as? String {
            content.body = alert
        }
        content.userInfo = userInfo
        let key = (userInfo["ack_id"] as? String) ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: "relay-sim-\(key)", content: content, trigger: nil)
        let handler = MattermostPushServiceHandler(request: request, contentHandler: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.simulatedPushes.removeValue(forKey: key)
                if result.title.isEmpty && result.body.isEmpty {
                    NSLog("[Relay] debug remote: simulated push %@ dropped (no account)", key)
                    self.writeResult(id: id, ok: true, error: nil)
                    return
                }
                let local = UNNotificationRequest(identifier: request.identifier, content: result, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
                UNUserNotificationCenter.current().add(local, withCompletionHandler: { error in
                    DispatchQueue.main.async {
                        NSLog("[Relay] debug remote: simulated push %@ scheduled in %.1f s (%@)", key, delay, error.map { "\($0)" } ?? "ok")
                        self.writeResult(id: id, ok: error == nil, error: error.map { "\($0)" })
                    }
                })
            }
        })
        self.simulatedPushes[key] = handler
        handler.start()
    }

    /// The chat on top of the main navigation stack (to check where a tapped notification led).
    private func visibleChatDescription() -> [String: Any] {
        guard let navigationController = self.sharedContext?.mainWindow?.viewController as? NavigationController else {
            return [:]
        }
        guard let chat = navigationController.viewControllers.last as? ChatController else {
            return ["top": navigationController.viewControllers.last.map { "\(type(of: $0))" } ?? ""]
        }
        var result: [String: Any] = ["top": "\(type(of: chat))"]
        switch chat.chatLocation {
        case let .peer(peerId):
            result["peerId"] = "\(peerId.toInt64())"
        case let .replyThread(message):
            result["peerId"] = "\(message.peerId.toInt64())"
            result["threadId"] = "\(message.threadId)"
        case .customChatContents:
            break
        }
        return result
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
            state["push"] = MattermostSync.debugPushState()
            state["deliveredNotifications"] = self.notificationList
            state["visibleChat"] = self.visibleChatDescription()
            if let chat = self.lastChatInfo {
                state["chat"] = chat
                self.lastChatInfo = nil
            }
            if let dialog = self.lastDialogInfo {
                state["dialog"] = dialog
                self.lastDialogInfo = nil
            }
            result["state"] = state
            if !self.lastExtra.isEmpty {
                result["extra"] = self.lastExtra
            }
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
#endif
