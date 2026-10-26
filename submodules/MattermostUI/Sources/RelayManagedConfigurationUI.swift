import Foundation
import UIKit
import MachO
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import PresentationDataUtils
import PasscodeUI
import MattermostKit
import MattermostSync

/// Managed app configuration in the UI (Phase 4G, docs/release/managed-configuration.md). MattermostSync reads the
/// configuration and applies the pins and the server restriction; this applies the rest:
/// - the policy upstream screens read (`MattermostManagedApp`: required passcode, hidden app switcher, pasteboard);
/// - `inAppPinCode`: without a passcode, a "Passcode Required" alert that only leads to Telegram's passcode setup
///   (again after a cancelled setup and whenever the app becomes active), auto-lock kept at five minutes or less;
/// - `copyAndPasteProtection`: `RelayPasteboardGuard`;
/// - `jailbreakDetection`: a blocking alert on a jailbroken device (`RelayDeviceIntegrity`);
/// - accounts logged out for the server restriction: an alert naming them.
final class RelayManagedConfigurationPresenter {
    static let shared = RelayManagedConfigurationPresenter()

    private var sharedContext: SharedAccountContext?
    private let disposables = DisposableSet()
    private weak var passcodeAlert: ViewController?
    private weak var passcodeSetup: ViewController?
    private weak var deviceAlert: ViewController?
    private var isPresentingPasscodeSetup = false
    /// Bumped to re-run the passcode requirement with unchanged inputs (after a cancelled setup).
    private let recheck = ValuePromise<Int>(0, ignoreRepeated: true)
    private var recheckValue = 0

    func start(sharedContext: SharedAccountContext) {
        self.sharedContext = sharedContext
        MattermostManagedApp.allowsPastingCurrentPasteboard = {
            return RelayPasteboardGuard.shared.allowsPasting()
        }
        MattermostManagedApp.pasteRefused = { [weak self] in
            self?.presentPasteRefused()
        }

        self.disposables.add((MattermostManagedSettings.updates
        |> deliverOnMainQueue).start(next: { [weak self] configuration in
            self?.apply(configuration)
        }))
        self.disposables.add((MattermostManagedSettings.restrictedLogouts
        |> deliverOnMainQueue).start(next: { [weak self] logout in
            self?.presentRestrictedLogout(logout)
        }))

        let primary = sharedContext.activeAccountContexts
        |> map { primary, _, _ -> AccountContext? in
            return primary
        }
        |> distinctUntilChanged(isEqual: { $0?.account.id == $1?.account.id })
        self.disposables.add((combineLatest(queue: .mainQueue(),
            MattermostManagedApp.policyUpdates,
            sharedContext.accountManager.accessChallengeData(),
            sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]),
            sharedContext.applicationBindings.applicationIsActive,
            primary,
            self.recheck.get()
        )).start(next: { [weak self] policy, accessChallenge, sharedData, isActive, primary, _ in
            let passcodeSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]?.get(PresentationPasscodeSettings.self) ?? .defaultSettings
            self?.updatePasscodeRequirement(policy: policy, accessChallenge: accessChallenge.data, passcodeSettings: passcodeSettings, isActive: isActive, primary: primary)
        }))
    }

    private func apply(_ configuration: MattermostManagedConfiguration) {
        MattermostManagedApp.setPolicy(MattermostManagedAppPolicy(
            requiresPasscode: configuration.inAppPinCode,
            hidesContentWhenInactive: configuration.blurApplicationScreen,
            protectsPasteboard: configuration.copyAndPasteProtection,
            organizationName: configuration.vendor
        ))
        RelayPasteboardGuard.shared.setEnabled(configuration.copyAndPasteProtection)
        if configuration.jailbreakDetection, RelayDeviceIntegrity.isJailbroken() {
            self.presentDeviceNotAllowed()
        } else if let alert = self.deviceAlert {
            alert.dismiss()
            self.deviceAlert = nil
        }
    }

    private var strings: PresentationStrings {
        return self.sharedContext?.currentPresentationData.with({ $0 }).strings ?? defaultPresentationStrings
    }

    private func organizationName(_ strings: PresentationStrings) -> String {
        return MattermostManagedApp.policy.organizationName ?? strings.Relay_Managed_Organization
    }

    // MARK: Passcode (`inAppPinCode`)

    private func updatePasscodeRequirement(policy: MattermostManagedAppPolicy, accessChallenge: PostboxAccessChallengeData, passcodeSettings: PresentationPasscodeSettings, isActive: Bool, primary: AccountContext?) {
        guard policy.requiresPasscode else {
            self.dismissPasscodeAlert()
            return
        }
        if case .none = accessChallenge {
        } else {
            self.dismissPasscodeAlert()
            // Mattermost asks again after more than five minutes away; "Disabled" and longer choices go.
            if let sharedContext = self.sharedContext, passcodeSettings.autolockTimeout.map({ $0 > MattermostManagedAppPolicy.maximumAutolockTimeout }) ?? true {
                let _ = updatePresentationPasscodeSettingsInteractively(accountManager: sharedContext.accountManager, { current in
                    return current.withUpdatedAutolockTimeout(MattermostManagedAppPolicy.maximumAutolockTimeout)
                }).start()
            }
            return
        }
        // Asked once an account is signed in (nothing to protect on the login screens), while the app is in use.
        guard isActive, let context = primary, let sharedContext = self.sharedContext, self.passcodeAlert == nil, !self.isPresentingPasscodeSetup else {
            return
        }
        let strings = self.strings
        let alert = textAlertController(sharedContext: sharedContext, title: strings.Relay_Managed_PasscodeRequiredTitle, text: strings.Relay_Managed_PasscodeRequiredText(self.organizationName(strings)).string, actions: [
            TextAlertAction(type: .defaultAction, title: strings.Relay_Managed_SetPasscode, action: { [weak self] in
                self?.passcodeAlert = nil
                self?.presentPasscodeSetup(context: context)
            })
        ], dismissOnOutsideTap: false)
        self.passcodeAlert = alert
        sharedContext.mainWindow?.present(alert, on: .root)
    }

    private func dismissPasscodeAlert() {
        if let alert = self.passcodeAlert {
            alert.dismiss()
            self.passcodeAlert = nil
        }
    }

    /// Telegram's passcode setup (Settings → Privacy and Security → Passcode → Turn Passcode On), starting with
    /// the five-minute auto-lock.
    private func presentPasscodeSetup(context: AccountContext) {
        guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
            return
        }
        self.isPresentingPasscodeSetup = true
        let controller = applicationPasscodeSetupController(context: context, session: nil, change: false, initialAutolockTimeout: MattermostManagedAppPolicy.maximumAutolockTimeout, cancelled: { [weak self] in
            // Back without a passcode: the requirement asks again.
            self?.isPresentingPasscodeSetup = false
            self?.reevaluateSoon()
        }, completion: { [weak self, weak navigationController] _ in
            self?.isPresentingPasscodeSetup = false
            if let navigationController, let setup = self?.passcodeSetup, navigationController.viewControllers.last === setup {
                let _ = navigationController.popViewController(animated: true)
            }
        })
        self.passcodeSetup = controller
        navigationController.pushViewController(controller)
    }

    private func reevaluateSoon() {
        Queue.mainQueue().after(0.5) { [weak self] in
            guard let self else {
                return
            }
            self.recheckValue += 1
            self.recheck.set(self.recheckValue)
        }
    }

    // MARK: Alerts

    private func presentRestrictedLogout(_ logout: MattermostRestrictedLogout) {
        guard let sharedContext = self.sharedContext else {
            return
        }
        // Once the account is gone: logging out the current account replaces the root screen, which would take
        // an alert shown earlier with it.
        let _ = (sharedContext.activeAccountContexts
        |> filter { _, accounts, _ in
            return !accounts.contains(where: { $0.1.account.id == logout.accountId })
        }
        |> take(1)
        |> delay(0.6, queue: .mainQueue())).start(next: { [weak self] _, _, _ in
            guard let self, let sharedContext = self.sharedContext else {
                return
            }
            let strings = self.strings
            let alert = textAlertController(sharedContext: sharedContext, title: strings.Relay_Managed_SignedOutTitle, text: strings.Relay_Managed_SignedOutText(logout.allowedServer, logout.server).string, actions: [
                TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})
            ])
            sharedContext.mainWindow?.present(alert, on: .root)
        })
    }

    private func presentDeviceNotAllowed() {
        guard self.deviceAlert == nil, let sharedContext = self.sharedContext else {
            return
        }
        let strings = self.strings
        // No way past it: OK only shows it again.
        let alert = textAlertController(sharedContext: sharedContext, title: strings.Relay_Managed_DeviceNotAllowedTitle, text: strings.Relay_Managed_DeviceNotAllowedText(self.organizationName(strings)).string, actions: [
            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: { [weak self] in
                self?.deviceAlert = nil
                Queue.mainQueue().after(0.3) {
                    if MattermostManagedSettings.current.jailbreakDetection, RelayDeviceIntegrity.isJailbroken() {
                        self?.presentDeviceNotAllowed()
                    }
                }
            })
        ], dismissOnOutsideTap: false)
        self.deviceAlert = alert
        sharedContext.mainWindow?.present(alert, on: .root)
    }

    private func presentPasteRefused() {
        guard let sharedContext = self.sharedContext else {
            return
        }
        let strings = self.strings
        let alert = textAlertController(sharedContext: sharedContext, title: nil, text: strings.Relay_Managed_PasteBlocked(self.organizationName(strings)).string, actions: [
            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})
        ])
        sharedContext.mainWindow?.present(alert, on: .root)
    }

    #if DEBUG
    var debugState: [String: Any] {
        let policy = MattermostManagedApp.policy
        return [
            "requiresPasscode": policy.requiresPasscode,
            "hidesContentWhenInactive": policy.hidesContentWhenInactive,
            "protectsPasteboard": policy.protectsPasteboard,
            "organizationName": policy.organizationName ?? "",
            "passcodeAlertVisible": self.passcodeAlert != nil,
            "passcodeSetupVisible": self.isPresentingPasscodeSetup,
            "deviceAlertVisible": self.deviceAlert != nil,
            "pasteboard": RelayPasteboardGuard.shared.debugState
        ]
    }

    func debugPressSetPasscode() -> Bool {
        guard let alert = self.passcodeAlert, let sharedContext = self.sharedContext else {
            return false
        }
        alert.dismiss()
        self.passcodeAlert = nil
        let _ = (sharedContext.activeAccountContexts |> take(1) |> deliverOnMainQueue).start(next: { [weak self] primary, _, _ in
            if let primary {
                self?.presentPasscodeSetup(context: primary)
            }
        })
        return true
    }
    #endif
}

/// Mattermost's `copyAndPasteProtection` (Phase 4G): what is copied in Relay stays in Relay, and what was copied
/// elsewhere isn't pasted into the message composer.
///
/// - Content the app writes (any copy: message text, links, selections) is re-marked local-only, so Universal
///   Clipboard doesn't hand it to the user's other devices, and is cleared when the app goes to the background, so
///   no other app on the device can paste it. Copy and paste inside Relay work as before.
/// - The composer asks `allowsPasting()` before a paste: only content Relay wrote itself is pasted.
///
/// The app can't see other apps' text fields, and other text fields of its own (search, login) keep the system's
/// paste. MDMs that need a complete boundary between managed and unmanaged apps set iOS's managed pasteboard
/// restriction (`requireManagedPasteboard` with the open-in restrictions), which iOS enforces itself.
final class RelayPasteboardGuard {
    static let shared = RelayPasteboardGuard()

    private var isEnabled = false
    private var observers: [NSObjectProtocol] = []
    /// The change count of content Relay wrote itself (nil: the pasteboard holds something from elsewhere).
    private var ownChangeCount: Int?
    /// What that content was (text, link, number of images), for a copy of it written back by a pasteboard sync
    /// (the simulator syncs with the Mac's pasteboard; a sync writes the same content again as a new change).
    private var ownFingerprint: PasteboardFingerprint?
    /// The change count when the app last became active: content from other apps.
    private var outsideChangeCount: Int?
    private var isRewriting = false
    private var clearedCount = 0

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.isEnabled else {
            return
        }
        self.isEnabled = enabled
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.observers = []
        self.ownChangeCount = nil
        guard enabled else {
            return
        }
        let center = NotificationCenter.default
        self.outsideChangeCount = UIPasteboard.general.changeCount
        self.observers.append(center.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.pasteboardChanged()
        }))
        self.observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            guard let self else {
                return
            }
            let count = UIPasteboard.general.changeCount
            if count != self.ownChangeCount {
                self.outsideChangeCount = count
                self.ownChangeCount = nil
            }
        }))
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.clearOwnContent()
        }))
    }

    /// A change made by the app itself while it is active (other apps' changes don't arrive here while Relay is
    /// in use; one noticed on return keeps the count seen at activation and is not taken as the app's own).
    private func pasteboardChanged() {
        guard self.isEnabled, !self.isRewriting, UIApplication.shared.applicationState == .active else {
            return
        }
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != self.outsideChangeCount else {
            return
        }
        // Keep it off Universal Clipboard: write the same items again, local only.
        self.isRewriting = true
        let items = pasteboard.items
        if !items.isEmpty {
            pasteboard.setItems(items, options: [.localOnly: true])
        }
        self.isRewriting = false
        self.ownChangeCount = pasteboard.changeCount
        self.ownFingerprint = PasteboardFingerprint(pasteboard)
    }

    private func clearOwnContent() {
        guard self.isEnabled, let own = self.ownChangeCount, UIPasteboard.general.changeCount == own else {
            return
        }
        self.isRewriting = true
        UIPasteboard.general.items = []
        self.isRewriting = false
        self.ownChangeCount = nil
        self.ownFingerprint = nil
        self.outsideChangeCount = UIPasteboard.general.changeCount
        self.clearedCount += 1
    }

    /// Whether the pasteboard's content may be pasted: everything while the protection is off, otherwise only
    /// what Relay copied (or nothing at all on the pasteboard).
    func allowsPasting() -> Bool {
        guard self.isEnabled else {
            return true
        }
        let pasteboard = UIPasteboard.general
        if pasteboard.numberOfItems == 0 || pasteboard.changeCount == self.ownChangeCount {
            return true
        }
        // Asked when the user pastes (the content is read for the paste anyway): the same content as Relay's own
        // copy, written again, still counts as Relay's.
        if let own = self.ownFingerprint, PasteboardFingerprint(pasteboard) == own {
            return true
        }
        return false
    }

    #if DEBUG
    var debugState: [String: Any] {
        return [
            "enabled": self.isEnabled,
            "changeCount": UIPasteboard.general.changeCount,
            "ownChangeCount": self.ownChangeCount ?? -1,
            "outsideChangeCount": self.outsideChangeCount ?? -1,
            "items": UIPasteboard.general.numberOfItems,
            "allowsPasting": self.allowsPasting(),
            "clearedOnBackground": self.clearedCount
        ]
    }
    #endif
}

/// The parts of a pasteboard's content that a paste uses: its text, its link, how many images.
private struct PasteboardFingerprint: Equatable {
    let text: String?
    let url: String?
    let imageCount: Int

    init(_ pasteboard: UIPasteboard) {
        self.text = pasteboard.string
        self.url = pasteboard.url?.absoluteString
        self.imageCount = pasteboard.hasImages ? pasteboard.numberOfItems : 0
    }
}

/// Mattermost's `jailbreakDetection` (Phase 4G): signs of a jailbreak that a stock iOS device never shows (files
/// and directories jailbreaks install, a writable path outside the sandbox, injected libraries). A heuristic
/// deterrent, not a guarantee: a determined user can hide a jailbreak from any app. The simulator is never
/// reported (its file system is the Mac's).
enum RelayDeviceIntegrity {
    static func isJailbroken() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RELAY_DEBUG_JAILBROKEN"] == "1" {
            return true
        }
        #endif
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/var/jb",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/lib/TweakInject",
            "/usr/sbin/sshd",
            "/usr/bin/ssh",
            "/etc/apt",
            "/private/var/lib/apt",
            "/bin/bash"
        ]
        for path in paths where access(path, F_OK) == 0 {
            return true
        }
        let probe = "/private/relay-integrity-\(UUID().uuidString)"
        if FileManager.default.createFile(atPath: probe, contents: Data(), attributes: nil) {
            try? FileManager.default.removeItem(atPath: probe)
            return true
        }
        for index in 0 ..< _dyld_image_count() {
            guard let name = _dyld_get_image_name(index).map({ String(cString: $0).lowercased() }) else {
                continue
            }
            if name.contains("mobilesubstrate") || name.contains("substrateloader") || name.contains("tweakinject") || name.contains("libhooker") || name.contains("frida") {
                return true
            }
        }
        return false
        #endif
    }
}
