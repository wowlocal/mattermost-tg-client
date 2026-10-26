import Foundation
import SwiftSignalKit

// MATTERMOST: what managed app configuration (MDM/EMM, Phase 4G) asks of upstream screens that can't depend on
// MattermostSync: the app lock (AppLock), the passcode settings (SettingsUI) and the composer's paste. MattermostUI
// sets it from `MattermostManagedSettings` (docs/release/managed-configuration.md); without a managed configuration
// it stays `.none` and upstream behaviour is unchanged.
public struct MattermostManagedAppPolicy: Equatable {
    /// A passcode is required (`inAppPinCode`): it can't be turned off, and the app locks after at most
    /// `maximumAutolockTimeout` seconds away.
    public var requiresPasscode: Bool
    /// Hide the app's content whenever it is not active, e.g. in the app switcher (`blurApplicationScreen`).
    public var hidesContentWhenInactive: Bool
    /// Copied content stays in the app and content from other apps can't be pasted (`copyAndPasteProtection`).
    public var protectsPasteboard: Bool
    /// The organisation's name for messages (`vendor`); nil: "your organization".
    public var organizationName: String?

    /// Mattermost's `inAppPinCode` asks again after more than five minutes in the background.
    public static let maximumAutolockTimeout: Int32 = 5 * 60

    public init(requiresPasscode: Bool = false, hidesContentWhenInactive: Bool = false, protectsPasteboard: Bool = false, organizationName: String? = nil) {
        self.requiresPasscode = requiresPasscode
        self.hidesContentWhenInactive = hidesContentWhenInactive
        self.protectsPasteboard = protectsPasteboard
        self.organizationName = organizationName
    }

    public static let none = MattermostManagedAppPolicy()
}

public enum MattermostManagedApp {
    private static let lock = NSLock()
    private static var value: MattermostManagedAppPolicy = .none
    private static let promise = ValuePromise<MattermostManagedAppPolicy>(.none, ignoreRepeated: true)

    public static var policy: MattermostManagedAppPolicy {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }

    public static var policyUpdates: Signal<MattermostManagedAppPolicy, NoError> {
        return self.promise.get()
    }

    public static func setPolicy(_ policy: MattermostManagedAppPolicy) {
        self.lock.lock()
        self.value = policy
        self.lock.unlock()
        self.promise.set(policy)
    }

    /// Whether the pasteboard's current content may be pasted into the app (`protectsPasteboard`: only what the
    /// app copied itself). Installed by MattermostUI; nil allows everything.
    public static var allowsPastingCurrentPasteboard: (() -> Bool)?

    /// Called when a paste was refused, to tell the user. Installed by MattermostUI.
    public static var pasteRefused: (() -> Void)?
}
