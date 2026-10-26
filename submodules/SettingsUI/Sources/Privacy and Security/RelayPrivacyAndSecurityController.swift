import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import LocalAuth
import OpenInExternalAppUI

// MATTERMOST: Relay's Privacy and Security screen (docs/research/ui-inventory.md §2.3).
//
// Telegram's screen is all server-side Telegram privacy (last seen, phone number, blocked users, 2FA,
// passkeys, auto-delete, data settings, …) and waits on `requestAccountPrivacySettings()`, which never
// returns under the null engine. Relay keeps the two local rows: Passcode (with Face ID / Touch ID) and
// Open Links In. Mattermost-side privacy settings, if any, are added here later.

private final class RelayPrivacyAndSecurityArguments {
    let openPasscode: () -> Void
    let openBrowserSelection: () -> Void

    init(openPasscode: @escaping () -> Void, openBrowserSelection: @escaping () -> Void) {
        self.openPasscode = openPasscode
        self.openBrowserSelection = openBrowserSelection
    }
}

private enum RelayPrivacyAndSecuritySection: Int32 {
    case passcode
    case links
}

private enum RelayPrivacyAndSecurityEntry: ItemListNodeEntry {
    case passcode(String, String)
    case openLinksIn(String, String)

    var section: ItemListSectionId {
        switch self {
        case .passcode:
            return RelayPrivacyAndSecuritySection.passcode.rawValue
        case .openLinksIn:
            return RelayPrivacyAndSecuritySection.links.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .passcode:
            return 0
        case .openLinksIn:
            return 1
        }
    }

    static func <(lhs: RelayPrivacyAndSecurityEntry, rhs: RelayPrivacyAndSecurityEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: RelayPrivacyAndSecurityEntry, rhs: RelayPrivacyAndSecurityEntry) -> Bool {
        switch lhs {
        case let .passcode(title, value):
            if case .passcode(title, value) = rhs {
                return true
            }
            return false
        case let .openLinksIn(title, value):
            if case .openLinksIn(title, value) = rhs {
                return true
            }
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! RelayPrivacyAndSecurityArguments
        switch self {
        case let .passcode(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.faceId, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openPasscode()
            })
        case let .openLinksIn(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openBrowserSelection()
            })
        }
    }
}

public func relayPrivacyAndSecurityController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var replaceTopControllerImpl: ((ViewController) -> Void)?

    let arguments = RelayPrivacyAndSecurityArguments(openPasscode: {
        let _ = passcodeOptionsAccessController(context: context, replaceController: { controller in
            replaceTopControllerImpl?(controller)
        }, authorizationCompleted: { result in
            guard case let .success(session) = result else { return }
            guard let replaceTopControllerImpl else { session.invalidate(); return }
            replaceTopControllerImpl(passcodeOptionsController(context: context, settingsSession: session))
        }).start(next: { controller in
            if let controller {
                pushControllerImpl?(controller)
            }
        })
    }, openBrowserSelection: {
        pushControllerImpl?(webBrowserSettingsController(context: context))
    })

    let webBrowserData = combineLatest(
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.webBrowserSettings]),
        context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: PreferencesKeys.webBrowserSettings))
    )

    let signal = combineLatest(
        queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.accessChallengeData(),
        webBrowserData
    )
    |> map { presentationData, accessChallengeData, webBrowserData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let passcodeValue: String
        switch accessChallengeData.data {
        case .none:
            passcodeValue = presentationData.strings.PrivacySettings_PasscodeOff
        default:
            passcodeValue = presentationData.strings.PrivacySettings_PasscodeOn
        }
        var passcodeTitle = presentationData.strings.PrivacySettings_Passcode
        if let biometricAuthentication = LocalAuth.biometricAuthentication {
            switch biometricAuthentication {
            case .touchId:
                passcodeTitle = presentationData.strings.PrivacySettings_PasscodeAndTouchId
            case .faceId:
                passcodeTitle = presentationData.strings.PrivacySettings_PasscodeAndFaceId
            }
        }

        // Same label logic as Telegram's Privacy and Security screen.
        let localWebBrowserSettings = webBrowserData.0.entries[ApplicationSpecificSharedDataKeys.webBrowserSettings]?.get(WebBrowserSettings.self) ?? WebBrowserSettings.defaultSettings
        let accountWebBrowserSettings = webBrowserData.1?.get(AccountWebBrowserSettings.self) ?? AccountWebBrowserSettings.defaultSettings
        let defaultWebBrowser: String
        if accountWebBrowserSettings.openExternalBrowser {
            var defaultExternalBrowser = localWebBrowserSettings.defaultWebBrowser
            if defaultExternalBrowser == nil || defaultExternalBrowser == "inApp" || defaultExternalBrowser == "inAppSafari" {
                defaultExternalBrowser = "safari"
            }
            let options = availableOpenInOptions(context: context, item: .url(url: "https://example.com"))
            if let option = options.first(where: { $0.identifier == defaultExternalBrowser }) {
                defaultWebBrowser = option.title
            } else {
                defaultWebBrowser = "Safari"
            }
        } else {
            defaultWebBrowser = presentationData.strings.WebBrowser_Telegram
        }

        let entries: [RelayPrivacyAndSecurityEntry] = [
            .passcode(passcodeTitle, passcodeValue),
            .openLinksIn(presentationData.strings.ChatSettings_OpenLinksIn, defaultWebBrowser)
        ]

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.PrivacySettings_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal, tabBarItem: nil)
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    replaceTopControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.replaceTopController(c, animated: true)
    }
    return controller
}
