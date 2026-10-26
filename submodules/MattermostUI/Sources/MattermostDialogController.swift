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
import MattermostKit
import MattermostSync

// Interactive dialogs (Phase 3D): the form an integration opens with `open_dialog` (from a slash command or a
// message button), as a modal `ItemListController`. One section per element: its name (and the server's or the
// local check's error, in red) as the header, the field, its help text below. Element types: text (with the
// email/number/password/tel/url keyboards), textarea, select (static options, or users/channels searched on the
// server, picked on a second screen), bool (a switch), radio (checkmarks). Defaults fill the form; required fields
// and lengths are checked before `POST /actions/dialogs/submit`; the server's per-field errors come back into
// the form. Cancel tells the integration when the dialog asks for it (`notify_on_cancel`).

private final class DialogArguments {
    let updateText: (DialogElement, String) -> Void
    let updateBool: (DialogElement, Bool) -> Void
    let select: (DialogElement, DialogOption) -> Void
    let openPicker: (DialogElement) -> Void

    init(updateText: @escaping (DialogElement, String) -> Void, updateBool: @escaping (DialogElement, Bool) -> Void, select: @escaping (DialogElement, DialogOption) -> Void, openPicker: @escaping (DialogElement) -> Void) {
        self.updateText = updateText
        self.updateBool = updateBool
        self.select = select
        self.openPicker = openPicker
    }
}

private enum DialogEntry: ItemListNodeEntry, Equatable {
    case intro(String)
    case header(index: Int, title: String, error: String?)
    case text(index: Int, element: DialogElement, value: String)
    case textarea(index: Int, element: DialogElement, value: String)
    case toggle(index: Int, element: DialogElement, title: String, value: Bool)
    case select(index: Int, element: DialogElement, title: String, isPlaceholder: Bool)
    case radio(index: Int, optionIndex: Int, element: DialogElement, option: DialogOption, checked: Bool)
    case help(index: Int, text: String)

    var section: ItemListSectionId {
        switch self {
        case .intro:
            return 0
        case let .header(index, _, _), let .text(index, _, _), let .textarea(index, _, _), let .toggle(index, _, _, _), let .select(index, _, _, _), let .radio(index, _, _, _, _), let .help(index, _):
            return Int32(index + 1)
        }
    }

    var stableId: Int {
        switch self {
        case .intro:
            return 0
        case let .header(index, _, _):
            return (index + 1) * 1000
        case let .text(index, _, _), let .textarea(index, _, _), let .toggle(index, _, _, _), let .select(index, _, _, _):
            return (index + 1) * 1000 + 1
        case let .radio(index, optionIndex, _, _, _):
            return (index + 1) * 1000 + 2 + optionIndex
        case let .help(index, _):
            return (index + 1) * 1000 + 999
        }
    }

    static func <(lhs: DialogEntry, rhs: DialogEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! DialogArguments
        switch self {
        case let .intro(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .header(_, title, error):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: title, multiline: true, accessoryText: error.map { ItemListSectionHeaderAccessoryText(value: $0, color: .destructive) }, sectionId: self.section)
        case let .text(_, element, value):
            let type: ItemListSingleLineInputItemType
            switch element.subtype {
            case "email":
                type = .email
            case "number":
                type = .number
            case "password":
                type = .password
            case "tel", "url":
                type = .regular(capitalization: false, autocorrection: false)
            default:
                type = .regular(capitalization: true, autocorrection: true)
            }
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: element.placeholder.isEmpty ? element.displayName : element.placeholder, type: type, maxLength: max(0, element.maxLength), sectionId: self.section, textUpdated: { text in
                arguments.updateText(element, text)
            }, action: {})
        case let .textarea(_, element, value):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: value, placeholder: element.placeholder.isEmpty ? element.displayName : element.placeholder, maxLength: element.maxLength > 0 ? ItemListMultilineInputItemTextLimit(value: element.maxLength, display: true) : nil, sectionId: self.section, style: .blocks, textUpdated: { text in
                arguments.updateText(element, text)
            })
        case let .toggle(_, element, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, maximumNumberOfLines: 3, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateBool(element, value)
            })
        case let .select(_, element, title, isPlaceholder):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, titleColor: isPlaceholder ? .accent : .primary, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openPicker(element)
            })
        case let .radio(_, _, element, option, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: option.text, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(element, option)
            })
        case let .help(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        }
    }
}

private struct DialogState: Equatable {
    var values: [String: JSONValue]
    /// The shown text of each select's value (dynamic options aren't known up front).
    var selectedTexts: [String: String]
    var errors: [String: String]
    var submitting: Bool
}

private func dialogEntries(dialog: InteractiveDialog, state: DialogState, strings: PresentationStrings) -> [DialogEntry] {
    var entries: [DialogEntry] = []
    if !dialog.introductionText.isEmpty {
        entries.append(.intro(dialogMarkdown(dialog.introductionText)))
    }
    for (index, element) in dialog.elements.enumerated() {
        var title = element.displayName
        if element.optional {
            title += " (\(strings.Relay_Dialog_Optional))"
        }
        entries.append(.header(index: index, title: title.uppercased(), error: state.errors[element.name]))
        let value = state.values[element.name]
        switch element.kind {
        case .textarea:
            entries.append(.textarea(index: index, element: element, value: dialogText(value)))
        case .bool:
            var on = false
            if case let .bool(flag)? = value {
                on = flag
            }
            entries.append(.toggle(index: index, element: element, title: element.placeholder.isEmpty ? element.displayName : element.placeholder, value: on))
        case .select:
            if let text = state.selectedTexts[element.name] {
                entries.append(.select(index: index, element: element, title: text, isPlaceholder: false))
            } else {
                entries.append(.select(index: index, element: element, title: element.placeholder.isEmpty ? strings.Relay_Dialog_Select : element.placeholder, isPlaceholder: true))
            }
        case .radio:
            let selected = dialogText(value)
            for (optionIndex, option) in element.options.enumerated() {
                entries.append(.radio(index: index, optionIndex: optionIndex, element: element, option: option, checked: option.value == selected))
            }
        case .text, .unknown:
            entries.append(.text(index: index, element: element, value: dialogText(value)))
        }
        if !element.helpText.isEmpty {
            entries.append(.help(index: index, text: dialogMarkdown(element.helpText)))
        }
    }
    return entries
}

/// Mattermost markdown for Telegram's list text (which knows bold and links): code spans lose their backticks.
private func dialogMarkdown(_ text: String) -> String {
    return text.replacingOccurrences(of: "`", with: "")
}

private func dialogText(_ value: JSONValue?) -> String {
    switch value {
    case let .string(text)?:
        return text
    case let .int(number)?:
        return String(number)
    case let .double(number)?:
        return String(number)
    default:
        return ""
    }
}

private func dialogErrorText(_ error: DialogValidationError, strings: PresentationStrings) -> String {
    switch error {
    case .required:
        return strings.Relay_Dialog_Required
    case let .tooShort(minLength):
        return strings.Relay_Dialog_TooShort("\(minLength)").string
    case let .tooLong(maxLength):
        return strings.Relay_Dialog_TooLong("\(maxLength)").string
    case .invalidEmail:
        return strings.Relay_Dialog_InvalidEmail
    case .invalidNumber:
        return strings.Relay_Dialog_InvalidNumber
    case .invalidURL:
        return strings.Relay_Dialog_InvalidURL
    }
}

/// The modal form of an interactive dialog.
final class MattermostDialogController: ItemListController {
    let dialog: MattermostDialogRequest

    init(context: AccountContext, dialog: MattermostDialogRequest) {
        self.dialog = dialog
        let form = dialog.request.dialog

        var initial = DialogState(values: [:], selectedTexts: [:], errors: [:], submitting: false)
        for element in form.elements {
            if let value = element.defaultSubmissionValue {
                initial.values[element.name] = value
                if element.kind == .select {
                    if let option = element.options.first(where: { $0.value == element.defaultValue }) {
                        initial.selectedTexts[element.name] = option.text
                    } else if element.dataSource.isEmpty {
                        initial.values[element.name] = nil
                    } else {
                        initial.selectedTexts[element.name] = element.defaultValue
                    }
                }
            }
        }
        let statePromise = ValuePromise(initial, ignoreRepeated: true)
        let stateValue = Atomic(value: initial)
        let updateState: ((DialogState) -> DialogState) -> Void = { f in
            statePromise.set(stateValue.modify { f($0) })
        }

        var pushImpl: ((ViewController) -> Void)?
        var dismissImpl: (() -> Void)?
        var presentImpl: ((ViewController) -> Void)?

        let arguments = DialogArguments(updateText: { element, text in
            updateState { state in
                var state = state
                state.values[element.name] = text.isEmpty ? nil : element.submissionValue(text: text)
                state.errors[element.name] = nil
                return state
            }
        }, updateBool: { element, value in
            updateState { state in
                var state = state
                state.values[element.name] = .bool(value)
                state.errors[element.name] = nil
                return state
            }
        }, select: { element, option in
            updateState { state in
                var state = state
                state.values[element.name] = .string(option.value)
                state.selectedTexts[element.name] = option.text
                state.errors[element.name] = nil
                return state
            }
        }, openPicker: { element in
            let current = stateValue.with { dialogText($0.values[element.name]) }
            let picker = mattermostDialogOptionPicker(context: context, dialog: dialog, element: element, selectedValue: current, selected: { option in
                updateState { state in
                    var state = state
                    state.values[element.name] = .string(option.value)
                    state.selectedTexts[element.name] = option.text
                    state.errors[element.name] = nil
                    return state
                }
            })
            pushImpl?(picker)
        })

        let submit: () -> Void = {
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            let state = stateValue.with { $0 }
            if state.submitting {
                return
            }
            var errors: [String: String] = [:]
            for element in form.elements {
                if let error = element.validate(state.values[element.name]) {
                    errors[element.name] = dialogErrorText(error, strings: strings)
                }
            }
            if !errors.isEmpty {
                updateState { state in
                    var state = state
                    state.errors = errors
                    return state
                }
                return
            }
            var values: [String: JSONValue] = [:]
            for element in form.elements {
                if let value = state.values[element.name] {
                    values[element.name] = value
                } else if element.kind == .bool {
                    values[element.name] = .bool(false)
                }
            }
            updateState { state in
                var state = state
                state.submitting = true
                return state
            }
            let _ = (MattermostComposer.submitDialog(dialog, values: values)
            |> deliverOnMainQueue).start(next: { result in
                switch result {
                case .done:
                    dismissImpl?()
                case let .errors(general, fields):
                    updateState { state in
                        var state = state
                        state.submitting = false
                        state.errors = fields
                        return state
                    }
                    if let general {
                        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                        presentImpl?(textAlertController(context: context, title: nil, text: general, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
                    }
                case let .failed(text):
                    updateState { state in
                        var state = state
                        state.submitting = false
                        return state
                    }
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    presentImpl?(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
                }
            })
        }

        let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
        |> deliverOnMainQueue
        |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let strings = presentationData.strings
            let submitTitle = form.submitLabel.isEmpty ? strings.Relay_Dialog_Submit : form.submitLabel
            let rightButton: ItemListNavigationButton
            if state.submitting {
                rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
            } else {
                rightButton = ItemListNavigationButton(content: .text(submitTitle), style: .bold, enabled: true, action: {
                    submit()
                })
            }
            let leftButton = ItemListNavigationButton(content: .text(strings.Common_Cancel), style: .regular, enabled: true, action: {
                MattermostComposer.cancelDialog(dialog)
                dismissImpl?()
            })
            let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(form.title), leftNavigationButton: leftButton, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
            let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: dialogEntries(dialog: form, state: state, strings: strings), style: .blocks, animateChanges: false)
            return (controllerState, (listState, arguments))
        }

        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(presentationData: ItemListPresentationData(presentationData), updatedPresentationData: context.sharedContext.presentationData |> map(ItemListPresentationData.init(_:)), state: signal, tabBarItem: nil)
        self.navigationPresentation = .modal

        pushImpl = { [weak self] controller in
            self?.push(controller)
        }
        dismissImpl = { [weak self] in
            self?.view.endEditing(true)
            self?.dismiss()
        }
        presentImpl = { [weak self] controller in
            self?.present(controller, in: .window(.root))
        }
        #if DEBUG
        MattermostDebugRemote.dialogAppeared(self, submit: submit, openPicker: { name in
            if let element = form.elements.first(where: { $0.name == name }) {
                arguments.openPicker(element)
            }
        }, update: { name, value in
            updateState { state in
                var state = state
                state.values[name] = value
                if case let .string(text) = value, let element = form.elements.first(where: { $0.name == name }), element.kind == .select {
                    state.selectedTexts[name] = element.options.first(where: { $0.value == text })?.text ?? text
                }
                state.errors[name] = nil
                return state
            }
        }, state: {
            let state = stateValue.with { $0 }
            return ["values": state.values.mapValues { "\($0)" }, "errors": state.errors, "submitting": state.submitting]
        })
        #endif
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Option picker

private final class PickerArguments {
    let updateQuery: (String) -> Void
    let select: (DialogOption) -> Void

    init(updateQuery: @escaping (String) -> Void, select: @escaping (DialogOption) -> Void) {
        self.updateQuery = updateQuery
        self.select = select
    }
}

private enum PickerEntry: ItemListNodeEntry, Equatable {
    case search(placeholder: String, query: String)
    case option(index: Int, option: DialogOption, checked: Bool)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .search:
            return 0
        case .option, .info:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case .search:
            return 0
        case let .option(index, _, _):
            return 10 + index
        case .info:
            return 1
        }
    }

    static func <(lhs: PickerEntry, rhs: PickerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! PickerArguments
        switch self {
        case let .search(placeholder, query):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: query, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { text in
                arguments.updateQuery(text)
            }, action: {})
        case let .option(_, option, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: option.text, style: .right, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(option)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct PickerState: Equatable {
    var query: String
    var options: [DialogOption]
    var loading: Bool
}

/// The choices of a select: static options (searchable when there are many), or users/channels searched on the
/// server as the user types.
private func mattermostDialogOptionPicker(context: AccountContext, dialog: MattermostDialogRequest, element: DialogElement, selectedValue: String, selected: @escaping (DialogOption) -> Void) -> ViewController {
    let isDynamic = !element.dataSource.isEmpty
    let initial = PickerState(query: "", options: isDynamic ? [] : element.options, loading: isDynamic)
    let statePromise = ValuePromise(initial, ignoreRepeated: true)
    let stateValue = Atomic(value: initial)
    let updateState: ((PickerState) -> PickerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let searchDisposable = MetaDisposable()
    let search: (String) -> Void = { query in
        guard isDynamic else {
            return
        }
        searchDisposable.set((MattermostComposer.dialogOptions(dialog, dataSource: element.dataSource, query: query)
        |> deliverOnMainQueue).start(next: { options in
            updateState { state in
                guard state.query == query else {
                    return state
                }
                var state = state
                state.options = options
                state.loading = false
                return state
            }
        }))
    }

    var dismissImpl: (() -> Void)?
    let arguments = PickerArguments(updateQuery: { query in
        updateState { state in
            var state = state
            state.query = query
            state.loading = isDynamic
            return state
        }
        search(query)
    }, select: { option in
        selected(option)
        dismissImpl?()
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [PickerEntry] = []
        if isDynamic || element.options.count > 8 {
            entries.append(.search(placeholder: strings.Relay_Dialog_Search, query: state.query))
        }
        let query = state.query.lowercased()
        let options = isDynamic || query.isEmpty ? state.options : state.options.filter { $0.text.lowercased().contains(query) }
        for (index, option) in options.enumerated() {
            entries.append(.option(index: index, option: option, checked: option.value == selectedValue))
        }
        if options.isEmpty {
            entries.append(.info(state.loading ? strings.Relay_Dialog_Loading : strings.Relay_PostActions_NoOptions))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(element.displayName), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        searchDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal, tabBarItem: nil)
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    search("")
    return controller
}
