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
import MattermostSyncCore

// Phase 3D-2: New Channel and Channel Settings (the channel profile's Edit button).
//
// Both edit the same fields: display name, URL name (derived from the display name as Mattermost's clients do
// until the user edits it; checked locally like the server does), purpose and header. New Channel also picks the
// team and public/private; Channel Settings offers what the user's roles allow: convert to private, archive,
// unarchive. Errors from the server come back as alerts (or, for a URL another channel has, under the URL).

private enum ChannelField: String {
    case displayName
    case urlName
}

private final class ChannelEditArguments {
    let updateDisplayName: (String) -> Void
    let updateURLName: (String) -> Void
    let updatePurpose: (String) -> Void
    let updateHeader: (String) -> Void
    let setPrivate: (Bool) -> Void
    let convertToPrivate: () -> Void
    let archive: () -> Void
    let unarchive: () -> Void

    init(updateDisplayName: @escaping (String) -> Void, updateURLName: @escaping (String) -> Void, updatePurpose: @escaping (String) -> Void, updateHeader: @escaping (String) -> Void, setPrivate: @escaping (Bool) -> Void, convertToPrivate: @escaping () -> Void, archive: @escaping () -> Void, unarchive: @escaping () -> Void) {
        self.updateDisplayName = updateDisplayName
        self.updateURLName = updateURLName
        self.updatePurpose = updatePurpose
        self.updateHeader = updateHeader
        self.setPrivate = setPrivate
        self.convertToPrivate = convertToPrivate
        self.archive = archive
        self.unarchive = unarchive
    }
}

private enum ChannelEditEntry: ItemListNodeEntry {
    case header(section: Int32, id: Int, text: String, error: String?)
    case displayName(placeholder: String, value: String, enabled: Bool)
    case urlName(placeholder: String, value: String, enabled: Bool)
    case footer(section: Int32, id: Int, text: String)
    case typePublic(title: String, checked: Bool)
    case typePrivate(title: String, checked: Bool)
    case purpose(placeholder: String, value: String, enabled: Bool)
    case channelHeader(placeholder: String, value: String, enabled: Bool)
    case convertToPrivate(String)
    case archive(String)
    case unarchive(String)
    case info(String)
    case loading(String)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _, _, _), let .footer(section, _, _):
            return section
        case .info, .loading:
            return 0
        case .displayName:
            return 1
        case .urlName:
            return 2
        case .typePublic, .typePrivate:
            return 3
        case .purpose:
            return 4
        case .channelHeader:
            return 5
        case .convertToPrivate:
            return 6
        case .archive, .unarchive:
            return 7
        }
    }

    var stableId: Int {
        switch self {
        case .info:
            return 0
        case .loading:
            return 1
        case let .header(_, id, _, _):
            return 100 + id * 10
        case .displayName:
            return 111
        case .urlName:
            return 121
        case .typePublic:
            return 131
        case .typePrivate:
            return 132
        case .purpose:
            return 141
        case .channelHeader:
            return 151
        case let .footer(_, id, _):
            return 100 + id * 10 + 9
        case .convertToPrivate:
            return 200
        case .archive:
            return 210
        case .unarchive:
            return 211
        }
    }

    static func <(lhs: ChannelEditEntry, rhs: ChannelEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: ChannelEditEntry, rhs: ChannelEditEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a, b, c, d), .header(e, f, g, h)):
            return a == e && b == f && c == g && d == h
        case let (.displayName(a, b, c), .displayName(d, e, f)), let (.urlName(a, b, c), .urlName(d, e, f)), let (.purpose(a, b, c), .purpose(d, e, f)), let (.channelHeader(a, b, c), .channelHeader(d, e, f)):
            return a == d && b == e && c == f
        case let (.footer(a, b, c), .footer(d, e, f)):
            return a == d && b == e && c == f
        case let (.typePublic(a, b), .typePublic(c, d)), let (.typePrivate(a, b), .typePrivate(c, d)):
            return a == c && b == d
        case let (.convertToPrivate(a), .convertToPrivate(b)), let (.archive(a), .archive(b)), let (.unarchive(a), .unarchive(b)), let (.info(a), .info(b)), let (.loading(a), .loading(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChannelEditArguments
        switch self {
        case let .header(_, _, text, error):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, multiline: true, accessoryText: error.map { ItemListSectionHeaderAccessoryText(value: $0, color: .destructive) }, sectionId: self.section)
        case let .displayName(placeholder, value, enabled):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .regular(capitalization: true, autocorrection: true), maxLength: ChannelNaming.displayNameMaxLength, enabled: enabled, sectionId: self.section, textUpdated: { text in
                arguments.updateDisplayName(text)
            }, action: {})
        case let .urlName(placeholder, value, enabled):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .username, maxLength: ChannelNaming.urlNameMaxLength, enabled: enabled, sectionId: self.section, textUpdated: { text in
                arguments.updateURLName(text)
            }, action: {})
        case let .footer(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .typePublic(title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setPrivate(false)
            })
        case let .typePrivate(title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setPrivate(true)
            })
        case let .purpose(placeholder, value, enabled):
            if !enabled {
                return ItemListMultilineTextItem(presentationData: presentationData, text: value.isEmpty ? "—" : value, enabledEntityTypes: [], sectionId: self.section, style: .blocks)
            }
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: value, placeholder: placeholder, maxLength: ItemListMultilineInputItemTextLimit(value: ChannelNaming.purposeMaxLength, display: true), sectionId: self.section, style: .blocks, textUpdated: { text in
                arguments.updatePurpose(text)
            })
        case let .channelHeader(placeholder, value, enabled):
            if !enabled {
                return ItemListMultilineTextItem(presentationData: presentationData, text: value.isEmpty ? "—" : value, enabledEntityTypes: [], sectionId: self.section, style: .blocks)
            }
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: value, placeholder: placeholder, maxLength: ItemListMultilineInputItemTextLimit(value: ChannelNaming.headerMaxLength, display: true), sectionId: self.section, style: .blocks, textUpdated: { text in
                arguments.updateHeader(text)
            })
        case let .convertToPrivate(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.convertToPrivate()
            })
        case let .archive(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.archive()
            })
        case let .unarchive(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.unarchive()
            })
        case let .info(text), let .loading(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        }
    }
}

private struct ChannelFieldsState: Equatable {
    var displayName: String = ""
    var urlName: String = ""
    /// The URL name follows the display name until the user edits it (New Channel).
    var urlEdited: Bool = false
    var purpose: String = ""
    var header: String = ""
    var isPrivate: Bool = false
    var errors: [String: String] = [:]
    var busy: Bool = false
}

private func urlNameErrorText(_ error: ChannelNaming.URLNameError, strings: PresentationStrings) -> String {
    switch error {
    case .tooShort:
        return strings.Relay_Channel_Error_URLTooShort
    case .tooLong:
        return strings.Relay_Channel_Error_URLTooLong
    case .invalidCharacters:
        return strings.Relay_Channel_Error_URLCharacters
    case .badEdges:
        return strings.Relay_Channel_Error_URLEdges
    case .doubleUnderscore:
        return strings.Relay_Channel_Error_URLDoubleUnderscore
    }
}

/// Local checks of the name fields; empty when the server may get them.
private func validateFields(_ state: ChannelFieldsState, strings: PresentationStrings) -> [String: String] {
    var errors: [String: String] = [:]
    switch ChannelNaming.validate(displayName: state.displayName) {
    case .empty?:
        errors[ChannelField.displayName.rawValue] = strings.Relay_Channel_Error_NameEmpty
    case .tooLong?:
        errors[ChannelField.displayName.rawValue] = strings.Relay_Channel_Error_NameTooLong
    case nil:
        break
    }
    if let error = ChannelNaming.validate(urlName: state.urlName) {
        errors[ChannelField.urlName.rawValue] = urlNameErrorText(error, strings: strings)
    }
    return errors
}

private func fieldEntries(state: ChannelFieldsState, editable: Bool, link: String, strings: PresentationStrings) -> [ChannelEditEntry] {
    var entries: [ChannelEditEntry] = []
    entries.append(.header(section: 1, id: 1, text: strings.Relay_Channel_Name, error: state.errors[ChannelField.displayName.rawValue]))
    entries.append(.displayName(placeholder: strings.Relay_Channel_NamePlaceholder, value: state.displayName, enabled: editable && !state.busy))
    entries.append(.header(section: 2, id: 2, text: strings.Relay_Channel_URL, error: state.errors[ChannelField.urlName.rawValue]))
    entries.append(.urlName(placeholder: strings.Relay_Channel_URLPlaceholder, value: state.urlName, enabled: editable && !state.busy))
    entries.append(.footer(section: 2, id: 2, text: link + state.urlName))
    return entries
}

// MARK: - New Channel

/// New Channel (`POST /channels`), then the new channel opens. `teamId` nil: the first team (tabs pick another).
public func mattermostCreateChannelController(context: AccountContext, teamId: String?) -> ViewController {
    let accountId = context.account.id
    let teams = MattermostDirectory.teams(accountId: accountId)
    let selectedTeam = ValuePromise<String>(teamId ?? teams.first?.id ?? "", ignoreRepeated: true)
    let selectedTeamValue = Atomic<String>(value: teamId ?? teams.first?.id ?? "")
    let initialCreation = MattermostDirectory.channelCreation(accountId: accountId, teamId: selectedTeamValue.with { $0 })
    var initial = ChannelFieldsState()
    initial.isPrivate = !initialCreation.publicChannel && initialCreation.privateChannel
    let statePromise = ValuePromise(initial, ignoreRepeated: true)
    let stateValue = Atomic(value: initial)
    let updateState: ((ChannelFieldsState) -> ChannelFieldsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let createDisposable = MetaDisposable()
    var navigationControllerImpl: (() -> NavigationController?)?
    var presentImpl: ((ViewController) -> Void)?
    let generatedName = ChannelNaming.generatedName()

    let arguments = ChannelEditArguments(updateDisplayName: { text in
        updateState { state in
            var state = state
            state.displayName = text
            if !state.urlEdited {
                state.urlName = text.isEmpty ? "" : ChannelNaming.urlName(fromDisplayName: text, fallback: { generatedName })
                state.errors[ChannelField.urlName.rawValue] = nil
            }
            state.errors[ChannelField.displayName.rawValue] = nil
            return state
        }
    }, updateURLName: { text in
        updateState { state in
            var state = state
            state.urlName = text.lowercased()
            state.urlEdited = true
            state.errors[ChannelField.urlName.rawValue] = nil
            return state
        }
    }, updatePurpose: { text in
        updateState { state in
            var state = state
            state.purpose = text
            return state
        }
    }, updateHeader: { text in
        updateState { state in
            var state = state
            state.header = text
            return state
        }
    }, setPrivate: { value in
        updateState { state in
            var state = state
            state.isPrivate = value
            return state
        }
    }, convertToPrivate: {}, archive: {}, unarchive: {})

    let create: () -> Void = {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let state = stateValue.with { $0 }
        if state.busy {
            return
        }
        let errors = validateFields(state, strings: strings)
        if !errors.isEmpty {
            updateState { state in
                var state = state
                state.errors = errors
                return state
            }
            return
        }
        updateState { state in
            var state = state
            state.busy = true
            return state
        }
        let draft = MattermostNewChannel(teamId: selectedTeamValue.with { $0 }, displayName: state.displayName, urlName: state.urlName, isPrivate: state.isPrivate, purpose: state.purpose, header: state.header)
        createDisposable.set((MattermostDirectory.createChannel(accountId: accountId, channel: draft)
        |> deliverOnMainQueue).start(next: { peerId in
            mattermostOpenChat(context: context, navigationController: navigationControllerImpl?(), peerId: peerId)
        }, error: { error in
            updateState { state in
                var state = state
                state.busy = false
                if case .urlNameTaken = error {
                    state.errors[ChannelField.urlName.rawValue] = strings.Relay_Directory_Error_URLTaken
                }
                return state
            }
            if case .urlNameTaken = error {
                return
            }
            mattermostPresentError(error, context: context, present: presentImpl)
        }))
    }

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), selectedTeam.get())
    |> deliverOnMainQueue
    |> map { presentationData, state, teamId -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let creation = MattermostDirectory.channelCreation(accountId: accountId, teamId: teamId)
        let team = teams.first(where: { $0.id == teamId })
        var entries = fieldEntries(state: state, editable: true, link: mattermostChannelLinkPrefix(context: context, teamName: team?.name ?? ""), strings: strings)
        entries.append(.header(section: 3, id: 3, text: strings.Relay_Channel_Type, error: nil))
        if creation.publicChannel {
            entries.append(.typePublic(title: strings.Relay_Channel_PublicChannel, checked: !state.isPrivate))
        }
        if creation.privateChannel {
            entries.append(.typePrivate(title: strings.Relay_Channel_PrivateChannel, checked: state.isPrivate))
        }
        entries.append(.footer(section: 3, id: 3, text: state.isPrivate ? strings.Relay_Channel_PrivateFooter : strings.Relay_Channel_PublicFooter))
        entries.append(.header(section: 4, id: 4, text: strings.Relay_Channel_Purpose, error: nil))
        entries.append(.purpose(placeholder: strings.Relay_Channel_PurposePlaceholder, value: state.purpose, enabled: !state.busy))
        entries.append(.footer(section: 4, id: 4, text: strings.Relay_Channel_PurposeFooter))
        entries.append(.header(section: 5, id: 5, text: strings.Relay_Channel_Header, error: nil))
        entries.append(.channelHeader(placeholder: strings.Relay_Channel_HeaderPlaceholder, value: state.header, enabled: !state.busy))
        entries.append(.footer(section: 5, id: 5, text: strings.Relay_Channel_HeaderFooter))

        let rightButton: ItemListNavigationButton
        if state.busy {
            rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        } else {
            rightButton = ItemListNavigationButton(content: .text(strings.Relay_Compose_Create), style: .bold, enabled: !state.displayName.trimmingCharacters(in: .whitespaces).isEmpty, action: {
                create()
            })
        }
        let title: ItemListControllerTitle
        if teams.count > 1 && teams.count <= 4 {
            title = .textWithTabs(strings.Relay_Compose_NewChannel, teams.map { $0.displayName }, teams.firstIndex(where: { $0.id == teamId }) ?? 0)
        } else {
            title = .text(strings.Relay_Compose_NewChannel)
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: title, leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        createDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    controller.debugName = "new-channel"
    controller.titleControlValueChanged = { index in
        if index >= 0 && index < teams.count {
            let _ = selectedTeamValue.swap(teams[index].id)
            selectedTeam.set(teams[index].id)
            let creation = MattermostDirectory.channelCreation(accountId: accountId, teamId: teams[index].id)
            updateState { state in
                var state = state
                if state.isPrivate && !creation.privateChannel {
                    state.isPrivate = false
                } else if !state.isPrivate && !creation.publicChannel {
                    state.isPrivate = true
                }
                state.errors[ChannelField.urlName.rawValue] = nil
                return state
            }
        }
    }
    navigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    controller.debugState = {
        let state = stateValue.with { $0 }
        return ["screen": "new-channel", "teamId": selectedTeamValue.with { $0 }, "displayName": state.displayName, "urlName": state.urlName, "private": state.isPrivate, "purpose": state.purpose, "header": state.header, "errors": state.errors, "busy": state.busy]
    }
    controller.debugActions = [
        "set": { args in
            let value = args["value"] as? String ?? ""
            switch args["field"] as? String {
            case "name":
                arguments.updateDisplayName(value)
            case "url":
                arguments.updateURLName(value)
            case "purpose":
                arguments.updatePurpose(value)
            case "header":
                arguments.updateHeader(value)
            case "private":
                arguments.setPrivate(value == "true")
            default:
                break
            }
        },
        "team": { args in
            if let index = teams.firstIndex(where: { $0.id == (args["team"] as? String) || $0.name == (args["team"] as? String) }) {
                controller.titleControlValueChanged?(index)
            }
        },
        "submit": { _ in
            create()
        }
    ]
    return controller
}

/// `<server>/<team>/channels/` for the URL field's footer.
private func mattermostChannelLinkPrefix(context: AccountContext, teamName: String) -> String {
    var server = MattermostSync.serverURL(accountId: context.account.id) ?? ""
    while server.hasSuffix("/") {
        server.removeLast()
    }
    server = server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    return "\(server)/\(teamName)/channels/"
}

// MARK: - Channel Settings

private struct SettingsState: Equatable {
    var settings: MattermostChannelSettings?
    var loadError: String?
    var fields = ChannelFieldsState()
}

/// The channel profile's Edit button: name, URL, purpose, header (when the user may edit them), convert to private,
/// archive, unarchive. `dismissed` runs after an archive (the chat moved to Archived Chats).
public func mattermostChannelSettingsController(context: AccountContext, peerId: PeerId) -> ViewController {
    let accountId = context.account.id
    let statePromise = ValuePromise(SettingsState(), ignoreRepeated: true)
    let stateValue = Atomic(value: SettingsState())
    let updateState: ((SettingsState) -> SettingsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let actionDisposable = MetaDisposable()
    let loadDisposable = MetaDisposable()
    var presentImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?

    let reload: () -> Void = {
        loadDisposable.set((MattermostDirectory.channelSettings(accountId: accountId, peerId: peerId)
        |> deliverOnMainQueue).start(next: { settings in
            updateState { state in
                var state = state
                state.settings = settings
                state.loadError = nil
                state.fields = ChannelFieldsState(displayName: settings.displayName, urlName: settings.urlName, urlEdited: true, purpose: settings.purpose, header: settings.header, isPrivate: settings.isPrivate, errors: [:], busy: false)
                return state
            }
        }, error: { error in
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            updateState { state in
                var state = state
                state.loadError = mattermostDirectoryErrorText(error, strings: strings)
                return state
            }
        }))
    }

    let setBusy: (Bool) -> Void = { busy in
        updateState { state in
            var state = state
            state.fields.busy = busy
            return state
        }
    }

    /// Runs a confirmed action: busy while it runs, an alert on failure, `done` after it.
    let perform: (Signal<Void, MattermostDirectoryError>, @escaping () -> Void) -> Void = { signal, done in
        setBusy(true)
        actionDisposable.set((signal |> deliverOnMainQueue).start(error: { error in
            setBusy(false)
            mattermostPresentError(error, context: context, present: presentImpl)
        }, completed: {
            setBusy(false)
            done()
        }))
    }

    let confirm: (String, String, String, Bool, @escaping () -> Void) -> Void = { title, text, action, destructive, f in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let alert = textAlertController(context: context, title: title, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: destructive ? .destructiveAction : .defaultAction, title: action, action: f)
        ], parseMarkdown: true)
        MattermostDirectoryDebug.alertPresented(alert, confirm: f)
        presentImpl?(alert)
    }

    let arguments = ChannelEditArguments(updateDisplayName: { text in
        updateState { state in
            var state = state
            state.fields.displayName = text
            state.fields.errors[ChannelField.displayName.rawValue] = nil
            return state
        }
    }, updateURLName: { text in
        updateState { state in
            var state = state
            state.fields.urlName = text.lowercased()
            state.fields.errors[ChannelField.urlName.rawValue] = nil
            return state
        }
    }, updatePurpose: { text in
        updateState { state in
            var state = state
            state.fields.purpose = text
            return state
        }
    }, updateHeader: { text in
        updateState { state in
            var state = state
            state.fields.header = text
            return state
        }
    }, setPrivate: { _ in }, convertToPrivate: {
        guard let settings = stateValue.with({ $0.settings }) else {
            return
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        confirm(strings.Relay_ChannelSettings_ConvertConfirmTitle, strings.Relay_ChannelSettings_ConvertConfirmText(settings.displayName).string, strings.Relay_ChannelSettings_Convert, false, {
            perform(MattermostDirectory.convertToPrivate(accountId: accountId, peerId: peerId), {
                reload()
            })
        })
    }, archive: {
        guard let settings = stateValue.with({ $0.settings }) else {
            return
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        confirm(strings.Relay_ChannelSettings_ArchiveConfirmTitle, strings.Relay_ChannelSettings_ArchiveConfirmText(settings.displayName).string, strings.Relay_ChannelSettings_ArchiveAction, true, {
            perform(MattermostDirectory.archiveChannel(accountId: accountId, peerId: peerId), {
                dismissImpl?()
            })
        })
    }, unarchive: {
        guard let settings = stateValue.with({ $0.settings }) else {
            return
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        confirm(strings.Relay_ChannelSettings_UnarchiveConfirmTitle, strings.Relay_ChannelSettings_UnarchiveConfirmText(settings.displayName).string, strings.Relay_ChannelSettings_UnarchiveAction, false, {
            perform(MattermostDirectory.unarchiveChannel(accountId: accountId, peerId: peerId), {
                dismissImpl?()
            })
        })
    })

    let save: () -> Void = {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let state = stateValue.with { $0 }
        guard let settings = state.settings, !state.fields.busy else {
            return
        }
        let errors = validateFields(state.fields, strings: strings)
        if !errors.isEmpty {
            updateState { state in
                var state = state
                state.fields.errors = errors
                return state
            }
            return
        }
        let fields = state.fields
        let displayName = fields.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let signal = MattermostDirectory.updateChannel(
            accountId: accountId,
            peerId: peerId,
            displayName: displayName != settings.displayName ? displayName : nil,
            urlName: fields.urlName != settings.urlName ? fields.urlName : nil,
            purpose: fields.purpose != settings.purpose ? fields.purpose : nil,
            header: fields.header != settings.header ? fields.header : nil
        )
        setBusy(true)
        actionDisposable.set((signal |> deliverOnMainQueue).start(error: { error in
            updateState { state in
                var state = state
                state.fields.busy = false
                if case .urlNameTaken = error {
                    state.fields.errors[ChannelField.urlName.rawValue] = strings.Relay_Directory_Error_URLTaken
                }
                return state
            }
            if case .urlNameTaken = error {
                return
            }
            mattermostPresentError(error, context: context, present: presentImpl)
        }, completed: {
            setBusy(false)
            dismissImpl?()
        }))
    }

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [ChannelEditEntry] = []
        var hasChanges = false
        if let settings = state.settings {
            let access = settings.access
            let editable = access.contains(.editProperties)
            let fields = state.fields
            hasChanges = fields.displayName.trimmingCharacters(in: .whitespacesAndNewlines) != settings.displayName || fields.urlName != settings.urlName || fields.purpose != settings.purpose || fields.header != settings.header
            if settings.isArchived {
                entries.append(.info(strings.Relay_ChannelSettings_ArchivedInfo))
            } else if !editable {
                entries.append(.info(strings.Relay_ChannelSettings_ReadOnlyInfo))
            }
            entries.append(contentsOf: fieldEntries(state: fields, editable: editable, link: mattermostChannelLinkPrefix(context: context, teamName: settings.teamName), strings: strings))
            entries.append(.header(section: 4, id: 4, text: strings.Relay_Channel_Purpose, error: nil))
            entries.append(.purpose(placeholder: strings.Relay_Channel_PurposePlaceholder, value: fields.purpose, enabled: editable && !fields.busy))
            entries.append(.header(section: 5, id: 5, text: strings.Relay_Channel_Header, error: nil))
            entries.append(.channelHeader(placeholder: strings.Relay_Channel_HeaderPlaceholder, value: fields.header, enabled: editable && !fields.busy))
            if editable {
                entries.append(.footer(section: 5, id: 5, text: strings.Relay_Channel_HeaderFooter))
            }
            if access.contains(.convertToPrivate) && !settings.isPrivate {
                entries.append(.convertToPrivate(strings.Relay_ChannelSettings_ConvertToPrivate))
            }
            if access.contains(.archive) {
                entries.append(.archive(strings.Relay_ChannelSettings_Archive))
            }
            if access.contains(.unarchive) {
                entries.append(.unarchive(strings.Relay_ChannelSettings_Unarchive))
            }
        } else if let error = state.loadError {
            entries.append(.loading(error))
        } else {
            entries.append(.loading(strings.Relay_Compose_Loading))
        }

        let rightButton: ItemListNavigationButton?
        if state.fields.busy {
            rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        } else if state.settings?.access.contains(.editProperties) == true {
            rightButton = ItemListNavigationButton(content: .text(strings.Relay_ChannelSettings_Save), style: .bold, enabled: hasChanges, action: {
                save()
            })
        } else {
            rightButton = nil
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Relay_ChannelSettings_Title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionDisposable.dispose()
        loadDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    controller.debugName = "channel-settings"
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    controller.debugState = {
        let state = stateValue.with { $0 }
        var result: [String: Any] = ["screen": "channel-settings", "displayName": state.fields.displayName, "urlName": state.fields.urlName, "purpose": state.fields.purpose, "header": state.fields.header, "errors": state.fields.errors, "busy": state.fields.busy, "loadError": state.loadError ?? ""]
        if let settings = state.settings {
            result["access"] = Int(settings.access.rawValue)
            result["private"] = settings.isPrivate
            result["archived"] = settings.isArchived
            result["link"] = settings.link
        }
        return result
    }
    controller.debugActions = [
        "set": { args in
            let value = args["value"] as? String ?? ""
            switch args["field"] as? String {
            case "name":
                arguments.updateDisplayName(value)
            case "url":
                arguments.updateURLName(value)
            case "purpose":
                arguments.updatePurpose(value)
            case "header":
                arguments.updateHeader(value)
            default:
                break
            }
        },
        "submit": { _ in
            save()
        },
        "convert": { _ in
            perform(MattermostDirectory.convertToPrivate(accountId: accountId, peerId: peerId), { reload() })
        },
        "archive": { _ in
            perform(MattermostDirectory.archiveChannel(accountId: accountId, peerId: peerId), { dismissImpl?() })
        },
        "unarchive": { _ in
            perform(MattermostDirectory.unarchiveChannel(accountId: accountId, peerId: peerId), { dismissImpl?() })
        },
        "confirm-archive": { _ in
            arguments.archive()
        },
        "confirm-convert": { _ in
            arguments.convertToPrivate()
        },
        "confirm-unarchive": { _ in
            arguments.unarchive()
        }
    ]
    reload()
    return controller
}
