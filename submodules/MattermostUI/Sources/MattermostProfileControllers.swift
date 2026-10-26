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

// Phase 3F: the Edit Profile screen's Username and Email rows (Telegram's edit mode has the name fields; nickname and
// position are inputs on that screen), and the notification preferences: the user's (Settings → Notifications →
// Push and Mentions) and a chat's (the profile's Notifications → Customize).

private func profileErrorText(_ error: MattermostProfileError, strings: PresentationStrings) -> String {
    switch error {
    case .unavailable:
        return mattermostDirectoryErrorText(.unavailable, strings: strings)
    case .network:
        return mattermostDirectoryErrorText(.network, strings: strings)
    case .usernameTaken:
        return strings.Relay_Username_Error_Taken
    case .invalidUsername:
        return strings.Relay_Username_Error_Characters
    case .emailTaken:
        return strings.Relay_Email_Error_Taken
    case .invalidEmail:
        return strings.Relay_Email_Error_Invalid
    case .wrongPassword:
        return strings.Relay_Email_Error_Password
    case let .server(message):
        return message
    }
}

public func mattermostPresentProfileError(_ error: MattermostProfileError, context: AccountContext, present: ((ViewController) -> Void)?) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present?(textAlertController(context: context, title: nil, text: presentationData.strings.Relay_Profile_SaveFailed(profileErrorText(error, strings: presentationData.strings)).string, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
}

private func usernameProblemText(_ problem: UsernameRules.Problem, strings: PresentationStrings) -> String {
    switch problem {
    case .tooShort:
        return strings.Relay_Username_Error_TooShort
    case .tooLong:
        return strings.Relay_Username_Error_TooLong
    case .mustStartWithLetter:
        return strings.Relay_Username_Error_FirstLetter
    case .invalidCharacters:
        return strings.Relay_Username_Error_Characters
    case .reserved:
        return strings.Relay_Username_Error_Reserved
    }
}

// MARK: - Username / email

private final class FieldArguments {
    let update: (Int, String) -> Void
    let submit: () -> Void

    init(update: @escaping (Int, String) -> Void, submit: @escaping () -> Void) {
        self.update = update
        self.submit = submit
    }
}

private enum FieldEntry: ItemListNodeEntry {
    case header(section: Int32, text: String, error: String?)
    case input(section: Int32, index: Int, placeholder: String, value: String, secure: Bool, isUsername: Bool, enabled: Bool)
    case footer(section: Int32, text: String)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _, _), let .input(section, _, _, _, _, _, _), let .footer(section, _):
            return section
        }
    }

    var stableId: Int {
        switch self {
        case let .header(section, _, _):
            return Int(section) * 10
        case let .input(section, _, _, _, _, _, _):
            return Int(section) * 10 + 1
        case let .footer(section, _):
            return Int(section) * 10 + 2
        }
    }

    static func <(lhs: FieldEntry, rhs: FieldEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: FieldEntry, rhs: FieldEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a1, a2, a3), .header(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.input(a1, a2, a3, a4, a5, a6, a7), .input(b1, b2, b3, b4, b5, b6, b7)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5 && a6 == b6 && a7 == b7
        case let (.footer(a1, a2), .footer(b1, b2)):
            return a1 == b1 && a2 == b2
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FieldArguments
        switch self {
        case let .header(_, text, error):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, multiline: true, accessoryText: error.map { ItemListSectionHeaderAccessoryText(value: $0, color: .destructive) }, sectionId: self.section)
        case let .input(_, index, placeholder, value, secure, isUsername, enabled):
            let type: ItemListSingleLineInputItemType = secure ? .password : (isUsername ? .username : .email)
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: type, returnKeyType: .done, clearType: .onFocus, enabled: enabled, sectionId: self.section, textUpdated: { text in
                arguments.update(index, text)
            }, action: {
                arguments.submit()
            })
        case let .footer(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct FieldState: Equatable {
    var values: [String]
    var error: String?
    var busy: Bool = false
}

/// Edit Profile → Username: `PUT /users/me/patch` with the new username (checked locally first).
public func mattermostUsernameController(context: AccountContext) -> ViewController {
    let accountId = context.account.id
    let current = MattermostProfile.currentOwnProfileFields(accountId: accountId)?.username ?? ""
    return mattermostProfileFieldController(context: context, name: "username", initial: [current], build: { state, strings in
        let value = state.values[0]
        return [
            .header(section: 0, text: strings.Relay_Username_Title.uppercased(), error: state.error),
            .input(section: 0, index: 0, placeholder: strings.Relay_Username_Placeholder, value: value, secure: false, isUsername: true, enabled: !state.busy),
            .footer(section: 0, text: strings.Relay_Username_Footer(value.isEmpty ? current : value.lowercased()).string)
        ]
    }, title: { $0.Relay_Username_Title }, validate: { values, strings in
        let username = values[0].trimmingCharacters(in: .whitespaces).lowercased()
        if username == current {
            return (nil, nil)
        }
        if let problem = UsernameRules.validate(username) {
            return (usernameProblemText(problem, strings: strings), nil)
        }
        return (nil, MattermostProfileChange(username: username))
    })
}

/// Edit Profile → Email: the new address and the current password (the server requires it).
public func mattermostEmailController(context: AccountContext) -> ViewController {
    let accountId = context.account.id
    let current = MattermostProfile.currentOwnProfileFields(accountId: accountId)?.email ?? ""
    return mattermostProfileFieldController(context: context, name: "email", initial: [current, ""], build: { state, strings in
        return [
            .header(section: 0, text: strings.Relay_Email_Title.uppercased(), error: state.error),
            .input(section: 0, index: 0, placeholder: strings.Relay_Email_Placeholder, value: state.values[0], secure: false, isUsername: false, enabled: !state.busy),
            .header(section: 1, text: strings.Relay_Email_PasswordHeader, error: nil),
            .input(section: 1, index: 1, placeholder: strings.Relay_Email_Password, value: state.values[1], secure: true, isUsername: false, enabled: !state.busy),
            .footer(section: 1, text: strings.Relay_Email_Footer)
        ]
    }, title: { $0.Relay_Email_Title }, validate: { values, strings in
        let email = values[0].trimmingCharacters(in: .whitespaces)
        if email == current {
            return (nil, nil)
        }
        let parts = email.split(separator: "@")
        if parts.count != 2 || parts[0].isEmpty || !parts[1].contains(".") {
            return (strings.Relay_Email_Error_Invalid, nil)
        }
        if values[1].isEmpty {
            return (strings.Relay_Email_Error_Password, nil)
        }
        return (nil, MattermostProfileChange(email: email, password: values[1]))
    })
}

private func mattermostProfileFieldController(context: AccountContext, name: String, initial: [String], build: @escaping (FieldState, PresentationStrings) -> [FieldEntry], title: @escaping (PresentationStrings) -> String, validate: @escaping ([String], PresentationStrings) -> (String?, MattermostProfileChange?)) -> ViewController {
    let accountId = context.account.id
    let statePromise = ValuePromise(FieldState(values: initial), ignoreRepeated: true)
    let stateValue = Atomic(value: FieldState(values: initial))
    let updateState: ((FieldState) -> FieldState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let actionDisposable = MetaDisposable()
    var dismissImpl: (() -> Void)?

    let submit: () -> Void = {
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let state = stateValue.with { $0 }
        if state.busy {
            return
        }
        let (error, change) = validate(state.values, strings)
        if let error {
            updateState { state in
                var state = state
                state.error = error
                return state
            }
            return
        }
        guard let change else {
            dismissImpl?()
            return
        }
        updateState { state in
            var state = state
            state.busy = true
            state.error = nil
            return state
        }
        actionDisposable.set((MattermostProfile.updateProfile(accountId: accountId, change)
        |> deliverOnMainQueue).start(error: { error in
            updateState { state in
                var state = state
                state.busy = false
                state.error = profileErrorText(error, strings: strings)
                return state
            }
        }, completed: {
            dismissImpl?()
        }))
    }
    let arguments = FieldArguments(update: { index, text in
        updateState { state in
            var state = state
            if index < state.values.count {
                state.values[index] = text
            }
            state.error = nil
            return state
        }
    }, submit: {
        submit()
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let rightButton: ItemListNavigationButton
        if state.busy {
            rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        } else {
            rightButton = ItemListNavigationButton(content: .text(strings.Common_Done), style: .bold, enabled: true, action: {
                submit()
            })
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title(strings)), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: build(state, strings), style: .blocks, focusItemTag: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    controller.debugName = name
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    controller.debugState = {
        let state = stateValue.with { $0 }
        return ["screen": name, "values": name == "email" ? [state.values[0], state.values.count > 1 && !state.values[1].isEmpty ? "(password)" : ""] : state.values, "error": state.error ?? "", "busy": state.busy]
    }
    controller.debugActions = [
        "set": { command in
            arguments.update((command["index"] as? Int) ?? 0, (command["value"] as? String) ?? "")
        },
        "submit": { _ in
            submit()
        }
    ]
    return controller
}

// MARK: - Notification preferences (the user's)

private final class NotificationArguments {
    let setPush: (PushLevel) -> Void
    let setPushStatus: (UserNotificationPreferences.PushStatus) -> Void
    let setThreads: (Bool) -> Void
    let setFirstName: (Bool) -> Void
    let setChannelWide: (Bool) -> Void
    let setKeywords: (String) -> Void
    let commitKeywords: () -> Void

    init(setPush: @escaping (PushLevel) -> Void, setPushStatus: @escaping (UserNotificationPreferences.PushStatus) -> Void, setThreads: @escaping (Bool) -> Void, setFirstName: @escaping (Bool) -> Void, setChannelWide: @escaping (Bool) -> Void, setKeywords: @escaping (String) -> Void, commitKeywords: @escaping () -> Void) {
        self.setPush = setPush
        self.setPushStatus = setPushStatus
        self.setThreads = setThreads
        self.setFirstName = setFirstName
        self.setChannelWide = setChannelWide
        self.setKeywords = setKeywords
        self.commitKeywords = commitKeywords
    }
}

private enum NotificationEntry: ItemListNodeEntry {
    case header(section: Int32, text: String)
    case footer(section: Int32, text: String)
    case push(index: Int, title: String, value: PushLevel, checked: Bool)
    case pushStatus(index: Int, title: String, value: UserNotificationPreferences.PushStatus, checked: Bool)
    case threads(title: String, value: Bool)
    case firstName(title: String, value: Bool)
    case channelWide(title: String, value: Bool)
    case keywords(placeholder: String, value: String)
    case loading(String)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _), let .footer(section, _):
            return section
        case .push, .loading:
            return 0
        case .pushStatus:
            return 1
        case .threads:
            return 2
        case .firstName, .channelWide:
            return 3
        case .keywords:
            return 4
        }
    }

    var stableId: Int {
        switch self {
        case let .header(section, _):
            return Int(section) * 100
        case let .footer(section, _):
            return Int(section) * 100 + 99
        case let .push(index, _, _, _):
            return 1 + index
        case .loading:
            return 50
        case let .pushStatus(index, _, _, _):
            return 101 + index
        case .threads:
            return 201
        case .firstName:
            return 301
        case .channelWide:
            return 302
        case .keywords:
            return 401
        }
    }

    static func <(lhs: NotificationEntry, rhs: NotificationEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: NotificationEntry, rhs: NotificationEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a1, a2), .header(b1, b2)), let (.footer(a1, a2), .footer(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.push(a1, a2, a3, a4), .push(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.pushStatus(a1, a2, a3, a4), .pushStatus(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.threads(a1, a2), .threads(b1, b2)), let (.firstName(a1, a2), .firstName(b1, b2)), let (.channelWide(a1, a2), .channelWide(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.keywords(a1, a2), .keywords(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.loading(a), .loading(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NotificationArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .footer(_, text), let .loading(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .push(_, title, value, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setPush(value)
            })
        case let .pushStatus(_, title, value, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setPushStatus(value)
            })
        case let .threads(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setThreads(value)
            })
        case let .firstName(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setFirstName(value)
            })
        case let .channelWide(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setChannelWide(value)
            })
        case let .keywords(placeholder, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), returnKeyType: .done, clearType: .onFocus, sectionId: self.section, textUpdated: { text in
                arguments.setKeywords(text)
            }, updatedFocus: { focused in
                if !focused {
                    arguments.commitKeywords()
                }
            }, action: {
                arguments.commitKeywords()
            })
        }
    }
}

private struct NotificationScreenState: Equatable {
    var keywordsDraft: String?
    var saving: Bool = false
}

/// Settings → Notifications → Push and Mentions: the user's `notify_props` (push level, when to push, thread replies,
/// mention triggers). Each change is saved at once (keywords when the field is left).
public func mattermostNotificationPreferencesController(context: AccountContext) -> ViewController {
    let accountId = context.account.id
    let statePromise = ValuePromise(NotificationScreenState(), ignoreRepeated: true)
    let stateValue = Atomic(value: NotificationScreenState())
    let updateState: ((NotificationScreenState) -> NotificationScreenState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let current = Atomic<UserNotificationPreferences?>(value: nil)
    let saveDisposable = MetaDisposable()
    var presentImpl: ((ViewController) -> Void)?

    let save: ((inout UserNotificationPreferences) -> Void) -> Void = { change in
        guard var preferences = current.with({ $0 }) else {
            return
        }
        change(&preferences)
        let _ = current.swap(preferences)
        updateState { state in
            var state = state
            state.saving = true
            return state
        }
        saveDisposable.set((MattermostProfile.setNotificationPreferences(accountId: accountId, preferences)
        |> deliverOnMainQueue).start(error: { error in
            updateState { state in
                var state = state
                state.saving = false
                return state
            }
            mattermostPresentError(error, context: context, present: presentImpl)
        }, completed: {
            updateState { state in
                var state = state
                state.saving = false
                state.keywordsDraft = nil
                return state
            }
        }))
    }

    let arguments = NotificationArguments(setPush: { value in
        save { $0.push = value }
    }, setPushStatus: { value in
        save { $0.pushStatus = value }
    }, setThreads: { value in
        save { $0.pushThreads = value ? .all : .mention }
    }, setFirstName: { value in
        save { $0.firstNameMentions = value }
    }, setChannelWide: { value in
        save { $0.channelMentions = value }
    }, setKeywords: { text in
        updateState { state in
            var state = state
            state.keywordsDraft = text
            return state
        }
    }, commitKeywords: {
        guard let draft = stateValue.with({ $0.keywordsDraft }) else {
            return
        }
        let keys = UserNotificationPreferences.parseMentionKeys(draft)
        if keys == current.with({ $0?.mentionKeys }) {
            return
        }
        save { $0.mentionKeys = keys }
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), MattermostProfile.notificationPreferences(accountId: accountId), MattermostProfile.ownProfileFields(accountId: accountId))
    |> deliverOnMainQueue
    |> map { presentationData, state, serverPreferences, fields -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        // The local value wins while a save is in flight; afterwards the server's.
        let preferences: UserNotificationPreferences?
        if state.saving {
            preferences = current.with { $0 } ?? serverPreferences
        } else {
            let _ = current.swap(serverPreferences)
            preferences = serverPreferences
        }
        var entries: [NotificationEntry] = []
        if let preferences {
            entries.append(.header(section: 0, text: strings.Relay_NotificationPrefs_PushHeader))
            let pushTitles: [(PushLevel, String)] = [(.all, strings.Relay_NotificationPrefs_Push_All), (.mention, strings.Relay_NotificationPrefs_Push_Mention), (.none, strings.Relay_NotificationPrefs_Push_None)]
            for (index, item) in pushTitles.enumerated() {
                entries.append(.push(index: index, title: item.1, value: item.0, checked: preferences.push == item.0))
            }
            if preferences.push != .none {
                entries.append(.header(section: 1, text: strings.Relay_NotificationPrefs_PushStatusHeader))
                let statusTitles: [(UserNotificationPreferences.PushStatus, String)] = [(.online, strings.Relay_NotificationPrefs_PushStatus_Online), (.away, strings.Relay_NotificationPrefs_PushStatus_Away), (.offline, strings.Relay_NotificationPrefs_PushStatus_Offline)]
                for (index, item) in statusTitles.enumerated() {
                    entries.append(.pushStatus(index: index, title: item.1, value: item.0, checked: preferences.pushStatus == item.0))
                }
            }
            if MattermostProfile.usesCollapsedThreads(accountId: accountId) && preferences.push == .mention {
                entries.append(.header(section: 2, text: strings.Relay_NotificationPrefs_ThreadsHeader))
                entries.append(.threads(title: strings.Relay_NotificationPrefs_Threads, value: preferences.pushThreads == .all))
                entries.append(.footer(section: 2, text: strings.Relay_NotificationPrefs_ThreadsFooter))
            }
            entries.append(.header(section: 3, text: strings.Relay_NotificationPrefs_MentionsHeader))
            if let firstName = fields?.firstName, !firstName.isEmpty {
                entries.append(.firstName(title: strings.Relay_NotificationPrefs_FirstName(firstName).string, value: preferences.firstNameMentions))
            }
            entries.append(.channelWide(title: strings.Relay_NotificationPrefs_ChannelWide, value: preferences.channelMentions))
            entries.append(.header(section: 4, text: strings.Relay_NotificationPrefs_KeywordsHeader))
            entries.append(.keywords(placeholder: strings.Relay_NotificationPrefs_KeywordsPlaceholder, value: state.keywordsDraft ?? preferences.mentionKeys.joined(separator: ", ")))
            entries.append(.footer(section: 4, text: strings.Relay_NotificationPrefs_KeywordsFooter(fields?.username ?? "").string))
        } else {
            entries.append(.loading(strings.Relay_PostList_Loading))
        }
        let rightButton: ItemListNavigationButton? = state.saving ? ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {}) : nil
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Relay_NotificationPrefs_Title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        saveDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    controller.debugName = "notification-preferences"
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    controller.debugState = {
        guard let preferences = current.with({ $0 }) else {
            return ["screen": "notification-preferences", "loaded": false]
        }
        return ["screen": "notification-preferences", "push": preferences.push.rawValue, "pushStatus": preferences.pushStatus.rawValue, "pushThreads": preferences.pushThreads.rawValue, "mentionKeys": preferences.mentionKeys, "firstName": preferences.firstNameMentions, "channel": preferences.channelMentions, "saving": stateValue.with { $0.saving }]
    }
    controller.debugActions = [
        "push": { command in
            if let value = (command["value"] as? String).flatMap(PushLevel.init(rawValue:)) {
                arguments.setPush(value)
            }
        },
        "push-status": { command in
            if let value = (command["value"] as? String).flatMap(UserNotificationPreferences.PushStatus.init(rawValue:)) {
                arguments.setPushStatus(value)
            }
        },
        "threads": { command in
            arguments.setThreads((command["value"] as? Bool) ?? true)
        },
        "first-name": { command in
            arguments.setFirstName((command["value"] as? Bool) ?? true)
        },
        "channel-wide": { command in
            arguments.setChannelWide((command["value"] as? Bool) ?? true)
        },
        "keywords": { command in
            arguments.setKeywords((command["value"] as? String) ?? "")
            arguments.commitKeywords()
        }
    ]
    return controller
}

// MARK: - Notification preferences (a chat's)

private final class ChannelNotificationArguments {
    let setPush: (PushLevel?) -> Void
    let setThreads: (Bool) -> Void
    let setIgnoreChannelMentions: (Bool) -> Void
    let setMuted: (Bool) -> Void
    let setAutoFollow: (Bool) -> Void

    init(setPush: @escaping (PushLevel?) -> Void, setThreads: @escaping (Bool) -> Void, setIgnoreChannelMentions: @escaping (Bool) -> Void, setMuted: @escaping (Bool) -> Void, setAutoFollow: @escaping (Bool) -> Void) {
        self.setPush = setPush
        self.setThreads = setThreads
        self.setIgnoreChannelMentions = setIgnoreChannelMentions
        self.setMuted = setMuted
        self.setAutoFollow = setAutoFollow
    }
}

private enum ChannelNotificationEntry: ItemListNodeEntry {
    case header(section: Int32, text: String)
    case footer(section: Int32, text: String)
    case push(index: Int, title: String, value: PushLevel?, checked: Bool)
    case threads(title: String, value: Bool)
    case ignoreChannelMentions(title: String, value: Bool)
    case autoFollow(title: String, value: Bool)
    case mute(title: String, value: Bool)
    case loading(String)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _), let .footer(section, _):
            return section
        case .push, .loading:
            return 0
        case .threads, .autoFollow:
            return 1
        case .ignoreChannelMentions:
            return 2
        case .mute:
            return 3
        }
    }

    var stableId: Int {
        switch self {
        case let .header(section, _):
            return Int(section) * 100
        case let .footer(section, _):
            return Int(section) * 100 + 99
        case let .push(index, _, _, _):
            return 1 + index
        case .loading:
            return 50
        case .threads:
            return 101
        case .autoFollow:
            return 102
        case .ignoreChannelMentions:
            return 201
        case .mute:
            return 301
        }
    }

    static func <(lhs: ChannelNotificationEntry, rhs: ChannelNotificationEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: ChannelNotificationEntry, rhs: ChannelNotificationEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a1, a2), .header(b1, b2)), let (.footer(a1, a2), .footer(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.push(a1, a2, a3, a4), .push(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.threads(a1, a2), .threads(b1, b2)), let (.ignoreChannelMentions(a1, a2), .ignoreChannelMentions(b1, b2)), let (.autoFollow(a1, a2), .autoFollow(b1, b2)), let (.mute(a1, a2), .mute(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.loading(a), .loading(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChannelNotificationArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .footer(_, text), let .loading(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .push(_, title, value, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setPush(value)
            })
        case let .threads(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setThreads(value)
            })
        case let .ignoreChannelMentions(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setIgnoreChannelMentions(value)
            })
        case let .autoFollow(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setAutoFollow(value)
            })
        case let .mute(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setMuted(value)
            })
        }
    }
}

/// A chat's notification settings (the profile's Notifications → Customize): pushes (default / all / mentions /
/// nothing), thread replies and auto-follow (collapsed threads), ignoring channel-wide mentions, mute. Written to the
/// channel member's `notify_props` at once; `isChannel` false for DMs and group messages (no channel-wide mentions or
/// thread auto-follow there).
public func mattermostChannelNotificationsController(context: AccountContext, peerId: PeerId, isChannel: Bool) -> ViewController {
    let accountId = context.account.id
    let preferencesPromise = ValuePromise<ChannelNotificationPreferences?>(nil, ignoreRepeated: true)
    let preferencesValue = Atomic<ChannelNotificationPreferences?>(value: nil)
    let setPreferences: (ChannelNotificationPreferences) -> Void = { value in
        let _ = preferencesValue.swap(value)
        preferencesPromise.set(value)
    }
    let loadDisposable = MetaDisposable()
    let saveDisposable = MetaDisposable()
    var presentImpl: ((ViewController) -> Void)?

    loadDisposable.set((MattermostProfile.channelNotificationPreferences(accountId: accountId, peerId: peerId)
    |> deliverOnMainQueue).start(next: { value in
        setPreferences(value)
    }, error: { error in
        mattermostPresentError(error, context: context, present: presentImpl)
    }))

    let save: ((inout ChannelNotificationPreferences) -> Void) -> Void = { change in
        guard var preferences = preferencesValue.with({ $0 }) else {
            return
        }
        let previous = preferences
        change(&preferences)
        setPreferences(preferences)
        saveDisposable.set((MattermostProfile.setChannelNotificationPreferences(accountId: accountId, peerId: peerId, preferences)
        |> deliverOnMainQueue).start(error: { error in
            setPreferences(previous)
            mattermostPresentError(error, context: context, present: presentImpl)
        }))
    }

    let arguments = ChannelNotificationArguments(setPush: { value in
        save { $0.push = value }
    }, setThreads: { value in
        save { $0.pushThreads = value ? .all : .mention }
    }, setIgnoreChannelMentions: { value in
        save { $0.ignoreChannelMentions = value }
    }, setMuted: { value in
        save { $0.muted = value }
    }, setAutoFollow: { value in
        save { $0.autoFollowThreads = value }
    })

    let signal = combineLatest(context.sharedContext.presentationData, preferencesPromise.get(), MattermostProfile.notificationPreferences(accountId: accountId))
    |> deliverOnMainQueue
    |> map { presentationData, preferences, user -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [ChannelNotificationEntry] = []
        if let preferences {
            let user = user ?? UserNotificationPreferences()
            let levelTitle: (PushLevel) -> String = { level in
                switch level {
                case .all:
                    return strings.Relay_NotificationPrefs_Push_All
                case .mention:
                    return strings.Relay_NotificationPrefs_Push_Mention
                case .none:
                    return strings.Relay_NotificationPrefs_Push_None
                }
            }
            entries.append(.header(section: 0, text: strings.Relay_NotificationPrefs_PushHeader))
            entries.append(.push(index: 0, title: strings.Relay_ChannelNotifications_Default(levelTitle(user.push)).string, value: nil, checked: preferences.push == nil))
            for (index, level) in PushLevel.allCases.enumerated() {
                entries.append(.push(index: index + 1, title: levelTitle(level), value: level, checked: preferences.push == level))
            }
            if MattermostProfile.usesCollapsedThreads(accountId: accountId) {
                var hasThreadRows = false
                if preferences.effectivePush(user: user) == .mention {
                    entries.append(.threads(title: strings.Relay_ChannelNotifications_ThreadReplies, value: (preferences.pushThreads ?? user.pushThreads) == .all))
                    hasThreadRows = true
                }
                if isChannel {
                    entries.append(.autoFollow(title: strings.Relay_ChannelNotifications_AutoFollow, value: preferences.autoFollowThreads))
                    hasThreadRows = true
                }
                if hasThreadRows {
                    entries.append(.header(section: 1, text: strings.Relay_ChannelNotifications_ThreadsHeader))
                }
            }
            if isChannel {
                entries.append(.ignoreChannelMentions(title: strings.Relay_ChannelNotifications_IgnoreChannelMentions, value: preferences.ignoreChannelMentions ?? !user.channelMentions))
            }
            entries.append(.mute(title: strings.Relay_ChannelNotifications_Mute, value: preferences.muted))
            entries.append(.footer(section: 3, text: strings.Relay_ChannelNotifications_MuteFooter))
        } else {
            entries.append(.loading(strings.Relay_PostList_Loading))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Relay_ChannelNotifications_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        loadDisposable.dispose()
        saveDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    controller.debugName = "channel-notifications"
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    controller.debugState = {
        guard let preferences = preferencesValue.with({ $0 }) else {
            return ["screen": "channel-notifications", "loaded": false]
        }
        return ["screen": "channel-notifications", "peerId": "\(peerId.toInt64())", "props": preferences.props]
    }
    controller.debugActions = [
        "push": { command in
            let value = command["value"] as? String ?? "default"
            arguments.setPush(PushLevel(rawValue: value))
        },
        "threads": { command in
            arguments.setThreads((command["value"] as? Bool) ?? true)
        },
        "ignore-channel-mentions": { command in
            arguments.setIgnoreChannelMentions((command["value"] as? Bool) ?? true)
        },
        "mute": { command in
            arguments.setMuted((command["value"] as? Bool) ?? true)
        },
        "auto-follow": { command in
            arguments.setAutoFollow((command["value"] as? Bool) ?? true)
        }
    ]
    return controller
}
