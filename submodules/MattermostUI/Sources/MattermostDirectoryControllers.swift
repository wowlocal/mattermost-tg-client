import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ItemListPeerItem
import ItemListPeerActionItem
import PresentationDataUtils
import AppBundle
import MattermostSync

// Phase 3D-2: the user directory and the channel directory.
//
// - "New Message" (the chat list's compose button, `mattermostComposeController`): the Mattermost user directory
//   (paged, with search), a tap opens the DM (`POST /channels/direct`); "New Group Message" selects 2 to 7 people
//   (`POST /channels/group`); "New Channel" and "Browse Channels".
// - "Add Members" (the members pane of a channel, `mattermostAddMembersController`): the team's users who aren't in
//   the channel, several at once.
// - "Browse Channels" (`mattermostBrowseChannelsController`): a team's public (or archived) channels, with search;
//   a channel the user isn't in opens a preview with Join.
// The chats themselves arrive through the normal sync path; these screens only wait for their peer to exist.

// MARK: - Shared

func mattermostDirectoryErrorText(_ error: MattermostDirectoryError, strings: PresentationStrings) -> String {
    switch error {
    case .unavailable:
        return strings.Relay_Directory_Error_Unavailable
    case .network:
        return strings.Relay_Directory_Error_Network
    case .urlNameTaken:
        return strings.Relay_Directory_Error_URLTaken
    case let .server(message):
        return message
    }
}

func mattermostPresentError(_ error: MattermostDirectoryError, context: AccountContext, present: ((ViewController) -> Void)?) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present?(textAlertController(context: context, title: nil, text: mattermostDirectoryErrorText(error, strings: presentationData.strings), actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
}

/// Opens a chat by its peer id (once the sync wrote it), replacing the screens above the chat list.
func mattermostOpenChat(context: AccountContext, navigationController: NavigationController?, peerId: PeerId) {
    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
    |> deliverOnMainQueue).startStandalone(next: { peer in
        guard let peer, let navigationController else {
            return
        }
        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
    })
}

private func directoryUserText(_ user: MattermostDirectoryUser, strings: PresentationStrings) -> String {
    var parts = ["@" + user.username]
    if user.isBot {
        parts.append(strings.Relay_Compose_Bot)
    } else if !user.position.isEmpty {
        parts.append(user.position)
    } else if !user.nickname.isEmpty {
        parts.append(user.nickname)
    }
    return parts.joined(separator: " · ")
}

// MARK: - User directory (New Message, New Group Message, Add Members)

enum MattermostUserDirectoryMode: Equatable {
    /// New Message: a tap opens the DM.
    case compose
    /// New Group Message: select 2 to 7 people, then Create.
    case groupMessage
    /// Add Members to a channel: select people, then Add.
    case addMembers(channelPeerId: PeerId)

    var isSelecting: Bool {
        if case .compose = self {
            return false
        }
        return true
    }
}

private final class UserDirectoryArguments {
    let context: AccountContext
    let updateQuery: (String) -> Void
    let openUser: (MattermostDirectoryUser) -> Void
    let newGroupMessage: () -> Void
    let newChannel: () -> Void
    let browseChannels: () -> Void

    init(context: AccountContext, updateQuery: @escaping (String) -> Void, openUser: @escaping (MattermostDirectoryUser) -> Void, newGroupMessage: @escaping () -> Void, newChannel: @escaping () -> Void, browseChannels: @escaping () -> Void) {
        self.context = context
        self.updateQuery = updateQuery
        self.openUser = openUser
        self.newGroupMessage = newGroupMessage
        self.newChannel = newChannel
        self.browseChannels = browseChannels
    }
}

private enum UserDirectoryEntry: ItemListNodeEntry {
    case search(placeholder: String, query: String)
    case newGroupMessage(String)
    case newChannel(String)
    case browseChannels(String)
    case info(String)
    case header(String)
    case user(index: Int, user: MattermostDirectoryUser, text: String, selected: Bool?)
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .search:
            return 0
        case .newGroupMessage, .newChannel, .browseChannels, .info:
            return 1
        case .header, .user, .status:
            return 2
        }
    }

    var stableId: Int {
        switch self {
        case .search:
            return 0
        case .newGroupMessage:
            return 1
        case .newChannel:
            return 2
        case .browseChannels:
            return 3
        case .info:
            return 4
        case .header:
            return 5
        case let .user(index, _, _, _):
            return 100 + index
        case .status:
            return Int.max
        }
    }

    static func <(lhs: UserDirectoryEntry, rhs: UserDirectoryEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: UserDirectoryEntry, rhs: UserDirectoryEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.search(a, b), .search(c, d)):
            return a == c && b == d
        case let (.newGroupMessage(a), .newGroupMessage(b)), let (.newChannel(a), .newChannel(b)), let (.browseChannels(a), .browseChannels(b)), let (.info(a), .info(b)), let (.header(a), .header(b)), let (.status(a), .status(b)):
            return a == b
        case let (.user(a, b, c, d), .user(e, f, g, h)):
            return a == e && b == f && c == g && d == h
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! UserDirectoryArguments
        switch self {
        case let .search(placeholder, query):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: query, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { text in
                arguments.updateQuery(text)
            }, action: {})
        case let .newGroupMessage(title):
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: UIImage(bundleImageName: "Contact List/CreateGroupActionIcon")?.withRenderingMode(.alwaysTemplate), title: title, sectionId: self.section, height: .generic, editing: false, action: {
                arguments.newGroupMessage()
            })
        case let .newChannel(title):
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: UIImage(bundleImageName: "Contact List/CreateChannelActionIcon")?.withRenderingMode(.alwaysTemplate), title: title, sectionId: self.section, height: .generic, editing: false, action: {
                arguments.newChannel()
            })
        case let .browseChannels(title):
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: UIImage(bundleImageName: "Contact List/LinkActionIcon")?.withRenderingMode(.alwaysTemplate), title: title, sectionId: self.section, height: .generic, editing: false, action: {
                arguments.browseChannels()
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .user(_, user, text, selected):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: PresentationDateTimeFormat(), nameDisplayOrder: .firstLast, context: arguments.context, peer: user.peer, presence: nil, text: .text(text, .secondary), label: .none, editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false), switchValue: selected.map { ItemListPeerItemSwitch(value: $0, style: .leftCheck) }, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.openUser(user)
            }, setPeerIdWithRevealedOptions: { _, _ in }, removePeer: { _ in })
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct UserDirectoryState: Equatable {
    var query: String = ""
    var users: [MattermostDirectoryUser] = []
    var nextPage: Int = 0
    var hasMore: Bool = true
    var loading: Bool = false
    var error: String?
    var selected: [PeerId] = []
    var busy: Bool = false
}

/// The chat list's compose screen while the Mattermost backend is on (`SharedAccountContext.makeComposeController`).
public func mattermostComposeController(context: AccountContext) -> ViewController {
    return mattermostUserDirectoryController(context: context, mode: .compose, completion: nil)
}

/// "Add Members" of a channel; `completion` runs after the server added them.
public func mattermostAddMembersController(context: AccountContext, channelPeerId: PeerId, completion: (() -> Void)? = nil) -> ViewController {
    return mattermostUserDirectoryController(context: context, mode: .addMembers(channelPeerId: channelPeerId), completion: completion)
}

func mattermostUserDirectoryController(context: AccountContext, mode: MattermostUserDirectoryMode, completion: (() -> Void)?) -> ViewController {
    let accountId = context.account.id
    let statePromise = ValuePromise(UserDirectoryState(), ignoreRepeated: true)
    let stateValue = Atomic(value: UserDirectoryState())
    let updateState: ((UserDirectoryState) -> UserDirectoryState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let loadDisposable = MetaDisposable()
    let actionDisposable = MetaDisposable()

    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var navigationControllerImpl: (() -> NavigationController?)?
    var dismissImpl: (() -> Void)?

    var channelPeerId: PeerId?
    if case let .addMembers(peerId) = mode {
        channelPeerId = peerId
    }

    // Loads the next page of the current query (a new query starts at page 0 after a short pause).
    let load: (Bool) -> Void = { reset in
        let state = stateValue.with { $0 }
        if !reset && (state.loading || !state.hasMore) {
            return
        }
        let query = state.query
        let page = reset ? 0 : state.nextPage
        updateState { state in
            var state = state
            state.loading = true
            state.error = nil
            if reset {
                state.users = []
                state.nextPage = 0
                state.hasMore = true
            }
            return state
        }
        let pause: Double = reset && !query.isEmpty ? 0.25 : 0.0
        loadDisposable.set((Signal<Void, MattermostDirectoryError>.single(Void()) |> delay(pause, queue: .mainQueue())
        |> mapToSignal { _ in
            return MattermostDirectory.users(accountId: accountId, query: query, page: page, notInChannel: channelPeerId)
        }
        |> deliverOnMainQueue).start(next: { result in
            updateState { state in
                guard state.query == query else {
                    return state
                }
                var state = state
                let known = Set(state.users.map { $0.peer.id })
                state.users.append(contentsOf: result.users.filter { !known.contains($0.peer.id) })
                state.nextPage = page + 1
                state.hasMore = result.hasMore
                state.loading = false
                return state
            }
        }, error: { error in
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            updateState { state in
                guard state.query == query else {
                    return state
                }
                var state = state
                state.loading = false
                state.hasMore = false
                state.error = mattermostDirectoryErrorText(error, strings: strings)
                return state
            }
        }))
    }

    let openUser: (MattermostDirectoryUser) -> Void = { user in
        switch mode {
        case .compose:
            if stateValue.with({ $0.busy }) {
                return
            }
            updateState { state in
                var state = state
                state.busy = true
                return state
            }
            actionDisposable.set((MattermostDirectory.openDirectMessage(accountId: accountId, userPeerId: user.peer.id)
            |> deliverOnMainQueue).start(next: { peerId in
                updateState { state in
                    var state = state
                    state.busy = false
                    return state
                }
                mattermostOpenChat(context: context, navigationController: navigationControllerImpl?(), peerId: peerId)
            }, error: { _ in
                updateState { state in
                    var state = state
                    state.busy = false
                    return state
                }
                // Offline: open the chat anyway; the first message creates the DM (2A).
                mattermostOpenChat(context: context, navigationController: navigationControllerImpl?(), peerId: user.peer.id)
            }))
        case .groupMessage, .addMembers:
            updateState { state in
                var state = state
                if let index = state.selected.firstIndex(of: user.peer.id) {
                    state.selected.remove(at: index)
                } else {
                    state.selected.append(user.peer.id)
                }
                return state
            }
        }
    }

    let submit: () -> Void = {
        let state = stateValue.with { $0 }
        if state.busy || state.selected.isEmpty {
            return
        }
        updateState { state in
            var state = state
            state.busy = true
            return state
        }
        switch mode {
        case .compose:
            break
        case .groupMessage:
            actionDisposable.set((MattermostDirectory.createGroupMessage(accountId: accountId, userPeerIds: state.selected)
            |> deliverOnMainQueue).start(next: { peerId in
                mattermostOpenChat(context: context, navigationController: navigationControllerImpl?(), peerId: peerId)
            }, error: { error in
                updateState { state in
                    var state = state
                    state.busy = false
                    return state
                }
                mattermostPresentError(error, context: context, present: presentImpl)
            }))
        case let .addMembers(channelPeerId):
            actionDisposable.set((MattermostDirectory.addMembers(accountId: accountId, channelPeerId: channelPeerId, userPeerIds: state.selected)
            |> deliverOnMainQueue).start(next: { failed in
                updateState { state in
                    var state = state
                    state.busy = false
                    return state
                }
                if failed.isEmpty {
                    completion?()
                    dismissImpl?()
                    return
                }
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let names = stateValue.with { state in
                    failed.map { peerId, message -> String in
                        let name = state.users.first(where: { $0.peer.id == peerId }).map { "@" + $0.username } ?? ""
                        return name.isEmpty ? message : "\(name): \(message)"
                    }
                }
                presentImpl?(textAlertController(context: context, title: nil, text: presentationData.strings.Relay_AddMembers_Failed(names.joined(separator: "\n")).string, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {
                    completion?()
                    dismissImpl?()
                })]))
            }, error: { error in
                updateState { state in
                    var state = state
                    state.busy = false
                    return state
                }
                mattermostPresentError(error, context: context, present: presentImpl)
            }))
        }
    }

    let arguments = UserDirectoryArguments(context: context, updateQuery: { query in
        updateState { state in
            var state = state
            state.query = query
            return state
        }
        load(true)
    }, openUser: openUser, newGroupMessage: {
        pushImpl?(mattermostUserDirectoryController(context: context, mode: .groupMessage, completion: nil))
    }, newChannel: {
        pushImpl?(mattermostCreateChannelController(context: context, teamId: nil))
    }, browseChannels: {
        pushImpl?(mattermostBrowseChannelsController(context: context, teamId: nil))
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [UserDirectoryEntry] = []
        entries.append(.search(placeholder: strings.Relay_Compose_Search, query: state.query))
        let title: String
        var rightButton: ItemListNavigationButton?
        switch mode {
        case .compose:
            title = strings.Relay_Compose_Title
            if state.query.isEmpty {
                entries.append(.newGroupMessage(strings.Relay_Compose_NewGroupMessage))
                entries.append(.newChannel(strings.Relay_Compose_NewChannel))
                entries.append(.browseChannels(strings.Relay_Compose_BrowseChannels))
            }
            if state.busy {
                rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
            }
        case .groupMessage:
            title = strings.Relay_Compose_NewGroupMessage
            entries.append(.info(state.selected.count > 7 ? strings.Relay_Compose_TooMany : strings.Relay_Compose_GroupMessageInfo))
            if state.busy {
                rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
            } else {
                rightButton = ItemListNavigationButton(content: .text(strings.Relay_Compose_Create), style: .bold, enabled: state.selected.count >= 2 && state.selected.count <= 7, action: {
                    submit()
                })
            }
        case .addMembers:
            title = strings.Relay_AddMembers_Title
            entries.append(.info(strings.Relay_AddMembers_Info))
            if state.busy {
                rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
            } else {
                let addTitle = state.selected.isEmpty ? strings.Relay_AddMembers_Add : "\(strings.Relay_AddMembers_Add) (\(state.selected.count))"
                rightButton = ItemListNavigationButton(content: .text(addTitle), style: .bold, enabled: !state.selected.isEmpty, action: {
                    submit()
                })
            }
        }
        entries.append(.header(strings.Relay_Compose_People))
        for (index, user) in state.users.enumerated() {
            entries.append(.user(index: index, user: user, text: directoryUserText(user, strings: strings), selected: mode.isSelecting ? state.selected.contains(user.peer.id) : nil))
        }
        if let error = state.error {
            entries.append(.status(error))
        } else if state.loading {
            entries.append(.status(strings.Relay_Compose_Loading))
        } else if state.users.isEmpty {
            entries.append(.status(strings.Relay_Compose_NoResults))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        loadDisposable.dispose()
        actionDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    #if DEBUG
    controller.debugName = {
        switch mode {
        case .compose:
            return "compose"
        case .groupMessage:
            return "group-message"
        case .addMembers:
            return "add-members"
        }
    }()
    #endif
    controller.visibleBottomContentOffsetChanged = { offset in
        if case let .known(value) = offset, value < 400.0 {
            load(false)
        }
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    navigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    #if DEBUG
    controller.debugState = {
        let state = stateValue.with { $0 }
        return [
            "screen": controller.debugName,
            "query": state.query,
            "users": state.users.map { ["username": $0.username, "peerId": "\($0.peer.id.toInt64())", "selected": state.selected.contains($0.peer.id)] },
            "hasMore": state.hasMore,
            "loading": state.loading,
            "error": state.error ?? "",
            "busy": state.busy
        ]
    }
    controller.debugActions = [
        "search": { args in
            arguments.updateQuery(args["text"] as? String ?? "")
        },
        "tap": { args in
            let username = (args["username"] as? String ?? "").lowercased()
            if let user = stateValue.with({ $0.users.first(where: { $0.username.lowercased() == username }) }) {
                openUser(user)
            }
        },
        "submit": { _ in
            submit()
        },
        "more": { _ in
            load(false)
        },
        "new-group": { _ in
            arguments.newGroupMessage()
        },
        "new-channel": { _ in
            arguments.newChannel()
        },
        "browse": { _ in
            arguments.browseChannels()
        }
    ]
    #endif
    load(true)
    return controller
}

/// An `ItemListController` the debug remote can drive (no UI automation on this setup): its state and the
/// actions its rows run when tapped.
final class MattermostDirectoryListController: ItemListController {
    #if DEBUG
    var debugName: String = ""
    var debugState: (() -> [String: Any])?
    var debugActions: [String: ([String: Any]) -> Void] = [:]
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        MattermostDirectoryDebug.screenAppeared(self)
        #endif
    }
}

// MARK: - Browse channels

private final class BrowseArguments {
    let context: AccountContext
    let updateQuery: (String) -> Void
    let toggleArchived: (Bool) -> Void
    let open: (MattermostBrowsedChannel) -> Void

    init(context: AccountContext, updateQuery: @escaping (String) -> Void, toggleArchived: @escaping (Bool) -> Void, open: @escaping (MattermostBrowsedChannel) -> Void) {
        self.context = context
        self.updateQuery = updateQuery
        self.toggleArchived = toggleArchived
        self.open = open
    }
}

private enum BrowseEntry: ItemListNodeEntry {
    case search(placeholder: String, query: String)
    case archived(title: String, value: Bool)
    case channel(index: Int, channel: MattermostBrowsedChannel, text: String, label: String?)
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .search:
            return 0
        case .archived:
            return 1
        case .channel, .status:
            return 2
        }
    }

    var stableId: Int {
        switch self {
        case .search:
            return 0
        case .archived:
            return 1
        case let .channel(index, _, _, _):
            return 100 + index
        case .status:
            return Int.max
        }
    }

    static func <(lhs: BrowseEntry, rhs: BrowseEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: BrowseEntry, rhs: BrowseEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.search(a, b), .search(c, d)):
            return a == c && b == d
        case let (.archived(a, b), .archived(c, d)):
            return a == c && b == d
        case let (.channel(a, b, c, d), .channel(e, f, g, h)):
            return a == e && b == f && c == g && d == h
        case let (.status(a), .status(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! BrowseArguments
        switch self {
        case let .search(placeholder, query):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: query, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { text in
                arguments.updateQuery(text)
            }, action: {})
        case let .archived(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleArchived(value)
            })
        case let .channel(_, channel, text, label):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: PresentationDateTimeFormat(), nameDisplayOrder: .firstLast, context: arguments.context, peer: channel.previewPeer, presence: nil, text: .text(text, .secondary), label: label.map { .text($0, .standard, nil, false) } ?? .none, editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false), switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.open(channel)
            }, setPeerIdWithRevealedOptions: { _, _ in }, removePeer: { _ in })
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct BrowseState: Equatable {
    var teamId: String
    var query: String = ""
    var archived: Bool = false
    var channels: [MattermostBrowsedChannel] = []
    var nextPage: Int = 0
    var hasMore: Bool = true
    var loading: Bool = false
    var error: String?
}

private func browseChannelText(_ channel: MattermostBrowsedChannel, strings: PresentationStrings) -> String {
    var parts: [String] = []
    if let count = channel.memberCount {
        parts.append(strings.Relay_Browse_Members(Int32(clamping: count)))
    }
    let purpose = channel.purpose.replacingOccurrences(of: "\n", with: " ")
    if !purpose.isEmpty {
        parts.append(purpose)
    }
    return parts.isEmpty ? "~" + channel.name : parts.joined(separator: " · ")
}

/// A team's channels to join (`teamId` nil: the first team).
public func mattermostBrowseChannelsController(context: AccountContext, teamId: String?) -> ViewController {
    let accountId = context.account.id
    let teams = MattermostDirectory.teams(accountId: accountId)
    let initialTeam = teamId ?? teams.first?.id ?? ""
    let statePromise = ValuePromise(BrowseState(teamId: initialTeam), ignoreRepeated: true)
    let stateValue = Atomic(value: BrowseState(teamId: initialTeam))
    let updateState: ((BrowseState) -> BrowseState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let loadDisposable = MetaDisposable()
    var pushImpl: ((ViewController) -> Void)?
    var navigationControllerImpl: (() -> NavigationController?)?

    let load: (Bool) -> Void = { reset in
        let state = stateValue.with { $0 }
        if !reset && (state.loading || !state.hasMore) {
            return
        }
        let (teamId, query, archived) = (state.teamId, state.query, state.archived)
        let page = reset ? 0 : state.nextPage
        updateState { state in
            var state = state
            state.loading = true
            state.error = nil
            if reset {
                state.channels = []
                state.nextPage = 0
                state.hasMore = true
            }
            return state
        }
        let pause: Double = reset && !query.isEmpty ? 0.25 : 0.0
        loadDisposable.set((Signal<Void, MattermostDirectoryError>.single(Void()) |> delay(pause, queue: .mainQueue())
        |> mapToSignal { _ in
            return MattermostDirectory.browseChannels(accountId: accountId, teamId: teamId, query: query, archived: archived, page: page)
        }
        |> deliverOnMainQueue).start(next: { result in
            updateState { state in
                guard state.teamId == teamId, state.query == query, state.archived == archived else {
                    return state
                }
                var state = state
                let known = Set(state.channels.map(\.id))
                state.channels.append(contentsOf: result.channels.filter { !known.contains($0.id) })
                state.nextPage = page + 1
                state.hasMore = result.hasMore
                state.loading = false
                return state
            }
        }, error: { error in
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            updateState { state in
                var state = state
                state.loading = false
                state.hasMore = false
                state.error = mattermostDirectoryErrorText(error, strings: strings)
                return state
            }
        }))
    }

    let open: (MattermostBrowsedChannel) -> Void = { channel in
        if let peerId = channel.memberPeerId {
            mattermostOpenChat(context: context, navigationController: navigationControllerImpl?(), peerId: peerId)
        } else {
            pushImpl?(mattermostChannelPreviewController(context: context, channel: channel))
        }
    }

    let arguments = BrowseArguments(context: context, updateQuery: { query in
        updateState { state in
            var state = state
            state.query = query
            return state
        }
        load(true)
    }, toggleArchived: { value in
        updateState { state in
            var state = state
            state.archived = value
            return state
        }
        load(true)
    }, open: open)

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [BrowseEntry] = []
        entries.append(.search(placeholder: strings.Relay_Browse_Search, query: state.query))
        entries.append(.archived(title: strings.Relay_Browse_Archived, value: state.archived))
        for (index, channel) in state.channels.enumerated() {
            entries.append(.channel(index: index, channel: channel, text: browseChannelText(channel, strings: strings), label: channel.memberPeerId != nil ? strings.Relay_Browse_Joined : nil))
        }
        if let error = state.error {
            entries.append(.status(error))
        } else if state.loading {
            entries.append(.status(strings.Relay_Compose_Loading))
        } else if state.channels.isEmpty {
            entries.append(.status(state.archived ? strings.Relay_Browse_EmptyArchived : strings.Relay_Browse_Empty))
        }
        let title: ItemListControllerTitle
        if teams.count > 1 && teams.count <= 4 {
            title = .textWithTabs(strings.Relay_Compose_BrowseChannels, teams.map { $0.displayName }, teams.firstIndex(where: { $0.id == state.teamId }) ?? 0)
        } else {
            title = .text(strings.Relay_Compose_BrowseChannels)
        }
        let rightButton = ItemListNavigationButton(content: .text(strings.Relay_Browse_New), style: .regular, enabled: true, action: {
            pushImpl?(mattermostCreateChannelController(context: context, teamId: stateValue.with { $0.teamId }))
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: title, leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        loadDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    #if DEBUG
    controller.debugName = "browse"
    #endif
    controller.titleControlValueChanged = { index in
        if index >= 0 && index < teams.count {
            updateState { state in
                var state = state
                state.teamId = teams[index].id
                return state
            }
            load(true)
        }
    }
    controller.visibleBottomContentOffsetChanged = { offset in
        if case let .known(value) = offset, value < 400.0 {
            load(false)
        }
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    navigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    #if DEBUG
    controller.debugState = {
        let state = stateValue.with { $0 }
        return [
            "screen": "browse",
            "teamId": state.teamId,
            "query": state.query,
            "archived": state.archived,
            "channels": state.channels.map { ["id": $0.id, "name": $0.name, "displayName": $0.displayName, "members": $0.memberCount.map { Int($0) } ?? -1, "joined": $0.memberPeerId != nil] },
            "hasMore": state.hasMore,
            "loading": state.loading,
            "error": state.error ?? ""
        ]
    }
    controller.debugActions = [
        "search": { args in
            arguments.updateQuery(args["text"] as? String ?? "")
        },
        "archived": { args in
            arguments.toggleArchived((args["value"] as? Bool) ?? ((args["value"] as? String) == "true"))
        },
        "team": { args in
            if let index = teams.firstIndex(where: { $0.id == (args["team"] as? String) || $0.name == (args["team"] as? String) }) {
                controller.titleControlValueChanged?(index)
            }
        },
        "tap": { args in
            let name = args["name"] as? String ?? ""
            if let channel = stateValue.with({ $0.channels.first(where: { $0.name == name || $0.id == name }) }) {
                open(channel)
            }
        },
        "new-channel": { _ in
            pushImpl?(mattermostCreateChannelController(context: context, teamId: stateValue.with { $0.teamId }))
        }
    ]
    #endif
    load(true)
    return controller
}

// MARK: - Channel preview

private final class PreviewArguments {
    let context: AccountContext
    let join: () -> Void

    init(context: AccountContext, join: @escaping () -> Void) {
        self.context = context
        self.join = join
    }
}

private enum PreviewEntry: ItemListNodeEntry {
    case channel(MattermostBrowsedChannel, text: String)
    case header(id: Int, text: String)
    case text(id: Int, text: String)
    case join(title: String, enabled: Bool)
    case info(String)
    case recentHeader(String)
    case recent(index: Int, text: String)
    case recentInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .channel:
            return 0
        case let .header(id, _), let .text(id, _):
            return Int32(1 + id)
        case .join, .info:
            return 10
        case .recentHeader, .recent, .recentInfo:
            return 11
        }
    }

    var stableId: Int {
        switch self {
        case .channel:
            return 0
        case let .header(id, _):
            return 10 + id * 2
        case let .text(id, _):
            return 11 + id * 2
        case .join:
            return 100
        case .info:
            return 101
        case .recentHeader:
            return 200
        case let .recent(index, _):
            return 201 + index
        case .recentInfo:
            return 1000
        }
    }

    static func <(lhs: PreviewEntry, rhs: PreviewEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: PreviewEntry, rhs: PreviewEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.channel(a, b), .channel(c, d)):
            return a == c && b == d
        case let (.header(a, b), .header(c, d)), let (.text(a, b), .text(c, d)):
            return a == c && b == d
        case let (.join(a, b), .join(c, d)):
            return a == c && b == d
        case let (.info(a), .info(b)), let (.recentHeader(a), .recentHeader(b)), let (.recentInfo(a), .recentInfo(b)):
            return a == b
        case let (.recent(a, b), .recent(c, d)):
            return a == c && b == d
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! PreviewArguments
        switch self {
        case let .channel(channel, text):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: PresentationDateTimeFormat(), nameDisplayOrder: .firstLast, context: arguments.context, peer: channel.previewPeer, presence: nil, text: .text(text, .secondary), label: .none, editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false), switchValue: nil, enabled: true, selectable: false, sectionId: self.section, action: nil, setPeerIdWithRevealedOptions: { _, _ in }, removePeer: { _ in })
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .text(_, text):
            return ItemListMultilineTextItem(presentationData: presentationData, text: text, enabledEntityTypes: [], sectionId: self.section, style: .blocks)
        case let .join(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.join()
            })
        case let .info(text), let .recentInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .recentHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .recent(_, text):
            return ItemListMultilineTextItem(presentationData: presentationData, text: text, enabledEntityTypes: [], sectionId: self.section, style: .blocks)
        }
    }
}

/// A channel the user isn't in: its name, members, purpose and header, and Join.
func mattermostChannelPreviewController(context: AccountContext, channel: MattermostBrowsedChannel) -> ViewController {
    return mattermostChannelPreviewController(context: context, channelId: channel.id, loaded: .single(channel))
}

/// The preview of a public channel by its id (also opened by search for a channel the user hasn't joined, 3C).
/// `afterJoin` replaces opening the chat once the user joined (or was a member already): a permalink into the
/// channel opens at its post then (4F).
public func mattermostChannelPreviewController(context: AccountContext, channelId: String, afterJoin: ((PeerId) -> Void)? = nil) -> ViewController {
    return mattermostChannelPreviewController(context: context, channelId: channelId, loaded: MattermostDirectory.channelPreview(accountId: context.account.id, channelId: channelId), afterJoin: afterJoin)
}

private func mattermostChannelPreviewController(context: AccountContext, channelId: String, loaded: Signal<MattermostBrowsedChannel, MattermostDirectoryError>, afterJoin: ((PeerId) -> Void)? = nil) -> ViewController {
    let accountId = context.account.id
    let joining = ValuePromise<Bool>(false, ignoreRepeated: true)
    let joiningValue = Atomic<Bool>(value: false)
    let joinDisposable = MetaDisposable()
    var navigationControllerImpl: (() -> NavigationController?)?
    var presentImpl: ((ViewController) -> Void)?

    let channelPromise = Promise<(MattermostBrowsedChannel?, String?)>((nil, nil))
    let channelValue = Atomic<MattermostBrowsedChannel?>(value: nil)
    channelPromise.set(loaded
    |> map { channel -> (MattermostBrowsedChannel?, String?) in
        let _ = channelValue.swap(channel)
        return (channel, nil)
    }
    |> `catch` { error -> Signal<(MattermostBrowsedChannel?, String?), NoError> in
        return .single((nil, mattermostDirectoryErrorText(error, strings: context.sharedContext.currentPresentationData.with { $0 }.strings)))
    })

    // A read-only look at the channel: its newest messages.
    let recentPromise = Promise<[MattermostPreviewPost]?>(nil)
    recentPromise.set(.single(nil) |> then(MattermostDirectory.previewPosts(accountId: accountId, channelId: channelId)
    |> map(Optional.init)
    |> `catch` { _ -> Signal<[MattermostPreviewPost]?, NoError> in
        return .single([])
    }))

    let join: () -> Void = {
        guard let channel = channelValue.with({ $0 }), !channel.isArchived else {
            return
        }
        if let peerId = channel.memberPeerId {
            if let afterJoin = afterJoin {
                afterJoin(peerId)
            } else {
                mattermostOpenChat(context: context, navigationController: navigationControllerImpl?(), peerId: peerId)
            }
            return
        }
        if joiningValue.swap(true) {
            return
        }
        joining.set(true)
        joinDisposable.set((MattermostDirectory.joinChannel(accountId: accountId, channelId: channel.id)
        |> deliverOnMainQueue).start(next: { peerId in
            let _ = joiningValue.swap(false)
            joining.set(false)
            if let afterJoin = afterJoin {
                afterJoin(peerId)
            } else {
                mattermostOpenChat(context: context, navigationController: navigationControllerImpl?(), peerId: peerId)
            }
        }, error: { error in
            let _ = joiningValue.swap(false)
            joining.set(false)
            mattermostPresentError(error, context: context, present: presentImpl)
        }))
    }
    let arguments = PreviewArguments(context: context, join: join)

    let signal = combineLatest(context.sharedContext.presentationData, joining.get(), recentPromise.get(), channelPromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, joining, recent, channelAndError -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [PreviewEntry] = []
        let (channel, loadError) = channelAndError
        if let channel {
            var subtitle = "~" + channel.name
            if let count = channel.memberCount {
                subtitle += " · " + strings.Relay_Browse_Members(Int32(clamping: count))
            }
            entries.append(.channel(channel, text: subtitle))
            if !channel.purpose.isEmpty {
                entries.append(.header(id: 0, text: strings.Relay_Channel_Purpose))
                entries.append(.text(id: 0, text: channel.purpose))
            }
            if !channel.header.isEmpty {
                entries.append(.header(id: 1, text: strings.Relay_Channel_Header))
                entries.append(.text(id: 1, text: channel.header))
            }
            if channel.isArchived {
                entries.append(.info(strings.Relay_ChannelPreview_Archived))
            } else {
                entries.append(.join(title: channel.memberPeerId != nil ? strings.Relay_ChannelPreview_Open : strings.Relay_ChannelPreview_Join, enabled: !joining))
            }
            entries.append(.recentHeader(strings.Relay_ChannelPreview_Recent))
            if let recent {
                if recent.isEmpty {
                    entries.append(.recentInfo(strings.Relay_ChannelPreview_NoMessages))
                }
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                for (index, post) in recent.enumerated() {
                    entries.append(.recent(index: index, text: "\(post.author) · \(formatter.string(from: post.date))\n\(post.text)"))
                }
            } else {
                entries.append(.recentInfo(strings.Relay_Compose_Loading))
            }
        } else {
            entries.append(.info(loadError ?? strings.Relay_Compose_Loading))
        }
        let rightButton: ItemListNavigationButton? = joining ? ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {}) : nil
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(channel?.displayName ?? ""), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        joinDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    #if DEBUG
    controller.debugName = "channel-preview"
    #endif
    navigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    #if DEBUG
    controller.debugState = {
        let channel = channelValue.with { $0 }
        return ["screen": "channel-preview", "channelId": channelId, "name": channel?.name ?? "", "archived": channel?.isArchived ?? false, "joined": channel?.memberPeerId != nil, "joining": joiningValue.with { $0 }]
    }
    controller.debugActions = [
        "join": { _ in
            join()
        }
    ]
    #endif
    return controller
}
