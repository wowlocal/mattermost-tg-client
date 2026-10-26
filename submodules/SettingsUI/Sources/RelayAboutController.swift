import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MATTERMOST: "About Relay" (docs/research/ui-inventory.md §5.4), in place of Telegram's help rows.
// Shows the version and build, and where the app's complete source code is published: Relay is built
// from Telegram-iOS, whose authors ask forks to publish their code (docs/plan/08-legal-and-licensing.md).
// Later: the connected Mattermost server and its version (MattermostSync), and third-party licenses.

/// TODO(release): replace with the public repository of the exact released source before any
/// distribution outside the team (docs/plan/08-legal-and-licensing.md). Placeholder until then.
public let relaySourceCodeURL = "https://example.com/relay-ios-source"

private final class RelayAboutArguments {
    let openSourceCode: () -> Void

    init(openSourceCode: @escaping () -> Void) {
        self.openSourceCode = openSourceCode
    }
}

private enum RelayAboutSection: Int32 {
    case version
    case source
}

private enum RelayAboutEntry: ItemListNodeEntry {
    case version(title: String, value: String)
    case sourceCode(title: String, value: String)
    case sourceCodeInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .version:
            return RelayAboutSection.version.rawValue
        case .sourceCode, .sourceCodeInfo:
            return RelayAboutSection.source.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .version:
            return 0
        case .sourceCode:
            return 1
        case .sourceCodeInfo:
            return 2
        }
    }

    static func <(lhs: RelayAboutEntry, rhs: RelayAboutEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: RelayAboutEntry, rhs: RelayAboutEntry) -> Bool {
        switch lhs {
        case let .version(title, value):
            if case .version(title, value) = rhs {
                return true
            }
            return false
        case let .sourceCode(title, value):
            if case .sourceCode(title, value) = rhs {
                return true
            }
            return false
        case let .sourceCodeInfo(text):
            if case .sourceCodeInfo(text) = rhs {
                return true
            }
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! RelayAboutArguments
        switch self {
        case let .version(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .sourceCode(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openSourceCode()
            })
        case let .sourceCodeInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// "13.0.1 (1)": the marketing version and the build number of the running app.
public func relayAppVersionString() -> String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? ""
    let build = info?[kCFBundleVersionKey as String] as? String ?? ""
    return build.isEmpty ? version : "\(version) (\(build))"
}

public func relayAboutController(context: AccountContext) -> ViewController {
    let arguments = RelayAboutArguments(openSourceCode: {
        context.sharedContext.applicationBindings.openUrl(relaySourceCodeURL)
    })

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let sourceHost = URL(string: relaySourceCodeURL)?.host ?? relaySourceCodeURL
        let entries: [RelayAboutEntry] = [
            .version(title: strings.Relay_About_Version, value: relayAppVersionString()),
            .sourceCode(title: strings.Relay_About_SourceCode, value: sourceHost),
            .sourceCodeInfo(strings.Relay_About_SourceCodeInfo + "\n\n" + strings.Relay_About_Disclaimer)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Relay_About_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal, tabBarItem: nil)
}
