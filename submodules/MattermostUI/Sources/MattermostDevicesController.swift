import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import MattermostSync

// Settings → Devices for a Mattermost account: the user's login sessions (`GET /users/me/sessions`), the
// current one marked, with "Terminate Session" per session and "Terminate All Other Sessions". Replaces
// Telegram's sessions screen, which reads Telegram's authorization list and can't be fed locally.

private final class DevicesArguments {
    let openSession: (MattermostDeviceSession) -> Void
    let terminateOthers: () -> Void

    init(openSession: @escaping (MattermostDeviceSession) -> Void, terminateOthers: @escaping () -> Void) {
        self.openSession = openSession
        self.terminateOthers = terminateOthers
    }
}

private enum DevicesSection: Int32 {
    case current
    case others
}

private enum DevicesEntry: ItemListNodeEntry {
    case currentHeader(String)
    case session(index: Int32, section: DevicesSection, session: MattermostDeviceSession, title: String, detail: String)
    case terminateOthers(String)
    case terminateOthersInfo(String)
    case othersHeader(String)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .currentHeader, .terminateOthers, .terminateOthersInfo:
            return DevicesSection.current.rawValue
        case let .session(_, section, _, _, _):
            return section.rawValue
        case .othersHeader, .info:
            return DevicesSection.others.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .currentHeader:
            return 0
        case let .session(index, section, _, _, _):
            return section == .current ? 1 : 100 + index
        case .terminateOthers:
            return 2
        case .terminateOthersInfo:
            return 3
        case .othersHeader:
            return 99
        case .info:
            return 10000
        }
    }

    static func <(lhs: DevicesEntry, rhs: DevicesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: DevicesEntry, rhs: DevicesEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.currentHeader(a), .currentHeader(b)), let (.terminateOthers(a), .terminateOthers(b)), let (.terminateOthersInfo(a), .terminateOthersInfo(b)), let (.othersHeader(a), .othersHeader(b)), let (.info(a), .info(b)):
            return a == b
        case let (.session(lIndex, lSection, lSession, lTitle, lDetail), .session(rIndex, rSection, rSession, rTitle, rDetail)):
            return lIndex == rIndex && lSection == rSection && lSession == rSession && lTitle == rTitle && lDetail == rDetail
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! DevicesArguments
        switch self {
        case let .currentHeader(text), let .othersHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .session(_, section, session, title, detail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: detail, labelStyle: .detailText, sectionId: self.section, style: .blocks, disclosureStyle: section == .current ? .none : .arrow, action: section == .current ? nil : {
                arguments.openSession(session)
            })
        case let .terminateOthers(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.terminateOthers()
            })
        case let .terminateOthersInfo(text), let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private enum DevicesState: Equatable {
    case loading
    case loaded([MattermostDeviceSession])
    case failed(String)
}

private func sessionTitle(_ session: MattermostDeviceSession) -> String {
    return session.system.isEmpty ? session.client : "\(session.client) · \(session.system)"
}

private func activityText(_ session: MattermostDeviceSession, strings: PresentationStrings) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return strings.Relay_Devices_LastActive(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(session.lastActivity)))).string
}

private func devicesEntries(state: DevicesState, knowsCurrent: Bool, strings: PresentationStrings) -> [DevicesEntry] {
    var entries: [DevicesEntry] = []
    switch state {
    case .loading:
        entries.append(.info(strings.Relay_Devices_Loading))
    case let .failed(text):
        entries.append(.info(text))
    case let .loaded(sessions):
        let current = sessions.first(where: { $0.isCurrent })
        let others = sessions.filter { !$0.isCurrent }
        entries.append(.currentHeader(strings.Relay_Devices_ThisDevice.uppercased()))
        if let current {
            entries.append(.session(index: 0, section: .current, session: current, title: sessionTitle(current), detail: strings.Relay_Devices_CurrentSession))
        }
        if !others.isEmpty {
            if knowsCurrent {
                entries.append(.terminateOthers(strings.Relay_Devices_TerminateOthers))
                entries.append(.terminateOthersInfo(strings.Relay_Devices_TerminateOthersInfo))
            } else {
                entries.append(.terminateOthersInfo(strings.Relay_Devices_CurrentUnknown))
            }
            entries.append(.othersHeader(strings.Relay_Devices_ActiveSessions.uppercased()))
            for (index, session) in others.enumerated() {
                entries.append(.session(index: Int32(index), section: .others, session: session, title: sessionTitle(session), detail: activityText(session, strings: strings)))
            }
        } else {
            entries.append(.terminateOthersInfo(strings.Relay_Devices_NoOtherSessions))
        }
    }
    return entries
}

public func mattermostDevicesController(context: AccountContext) -> ViewController {
    let accountId = context.account.id
    let statePromise = ValuePromise<DevicesState>(.loading, ignoreRepeated: true)
    var presentControllerImpl: ((ViewController) -> Void)?

    let reload: () -> Void = {
        Task {
            do {
                let sessions = try await MattermostSync.deviceSessions(accountId: accountId)
                statePromise.set(.loaded(sessions))
            } catch {
                let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
                statePromise.set(.failed(devicesErrorText(error, strings: strings)))
            }
        }
    }

    let showError: (Error) -> Void = { error in
        Queue.mainQueue().async {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            presentControllerImpl?(textAlertController(context: context, title: nil, text: devicesErrorText(error, strings: presentationData.strings), actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
        }
    }

    let terminate: (MattermostDeviceSession) -> Void = { session in
        Task {
            do {
                try await MattermostSync.revokeDeviceSession(accountId: accountId, sessionId: session.id)
            } catch {
                showError(error)
            }
            reload()
        }
    }
    let terminateOthers: () -> Void = {
        Task {
            do {
                try await MattermostSync.revokeOtherDeviceSessions(accountId: accountId)
            } catch {
                showError(error)
            }
            reload()
        }
    }

    let arguments = DevicesArguments(openSession: { session in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: "\(sessionTitle(session))\n\(activityText(session, strings: presentationData.strings))"),
                ActionSheetButtonItem(title: presentationData.strings.Relay_Devices_TerminateSession, color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    terminate(session)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, terminateOthers: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: presentationData.strings.Relay_Devices_TerminateOthersConfirm),
                ActionSheetButtonItem(title: presentationData.strings.Relay_Devices_TerminateOthers, color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    terminateOthers()
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let entries = devicesEntries(state: state, knowsCurrent: MattermostSync.knowsCurrentDeviceSession(accountId: accountId), strings: strings)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Settings_Devices), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal, tabBarItem: nil)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }
    controller.didAppear = { firstTime in
        if !firstTime {
            reload()
        }
    }
    reload()

    #if DEBUG
    // Debug (no UI automation): `RELAY_DEBUG_DEVICES_ACTION=terminate-first|terminate-others` runs the confirmed
    // action of the first other session's sheet / of "Terminate All Other Sessions" once the list loaded.
    if let action = ProcessInfo.processInfo.environment["RELAY_DEBUG_DEVICES_ACTION"], !action.isEmpty {
        let _ = (statePromise.get()
        |> filter { state in
            if case .loaded = state {
                return true
            }
            return false
        }
        |> take(1)
        |> delay(3.0, queue: .mainQueue())).start(next: { state in
            guard case let .loaded(sessions) = state else {
                return
            }
            if action == "terminate-others" {
                terminateOthers()
            } else if action == "terminate-first", let session = sessions.first(where: { !$0.isCurrent }) {
                terminate(session)
            }
        })
    }
    #endif

    return controller
}

private func devicesErrorText(_ error: Error, strings: PresentationStrings) -> String {
    switch error as? MattermostSessionsError {
    case .notConnected?:
        return strings.Relay_Devices_NotConnected
    case .currentSessionUnknown?:
        return strings.Relay_Devices_CurrentUnknown
    case let .server(text)?:
        return strings.Relay_Devices_Error(text).string
    case nil:
        return strings.Relay_Devices_Error(error.localizedDescription).string
    }
}
