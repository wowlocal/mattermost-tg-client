import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ItemListPeerActionItem
import PresentationDataUtils
import OverlayStatusController
import AppBundle
import MattermostSyncCore
import MattermostSync

// Invite People (the compose screen's row): bringing people into a team as Mattermost's apps do. The team's invite
// link, shared or copied (anyone with it can join the team, signing up first when the server allows new accounts);
// "Add to Team", the directory of the server's users who aren't in the team; email invitations, when the server
// sends them. Only what the user may do is shown (`MattermostTeamInvite`, `TeamInviteRules`); the server decides.

private final class InviteArguments {
    let chooseTeam: () -> Void
    let shareLink: () -> Void
    let copyLink: () -> Void
    let addFromServer: () -> Void
    let updateEmails: (String) -> Void
    let sendEmails: () -> Void

    init(chooseTeam: @escaping () -> Void, shareLink: @escaping () -> Void, copyLink: @escaping () -> Void, addFromServer: @escaping () -> Void, updateEmails: @escaping (String) -> Void, sendEmails: @escaping () -> Void) {
        self.chooseTeam = chooseTeam
        self.shareLink = shareLink
        self.copyLink = copyLink
        self.addFromServer = addFromServer
        self.updateEmails = updateEmails
        self.sendEmails = sendEmails
    }
}

private enum InviteEntry: ItemListNodeEntry, Equatable {
    case team(title: String, value: String)
    case linkHeader(String)
    case shareLink(String)
    case copyLink(String)
    case linkInfo(String)
    case addHeader(String)
    case addFromServer(String)
    case addInfo(String)
    case emailHeader(String)
    case emails(placeholder: String, text: String, enabled: Bool)
    case send(title: String, enabled: Bool)
    case emailInfo(String)
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .team:
            return 0
        case .linkHeader, .shareLink, .copyLink, .linkInfo:
            return 1
        case .addHeader, .addFromServer, .addInfo:
            return 2
        case .emailHeader, .emails, .send, .emailInfo:
            return 3
        case .status:
            return 4
        }
    }

    var stableId: Int {
        switch self {
        case .team:
            return 0
        case .linkHeader:
            return 1
        case .shareLink:
            return 2
        case .copyLink:
            return 3
        case .linkInfo:
            return 4
        case .addHeader:
            return 5
        case .addFromServer:
            return 6
        case .addInfo:
            return 7
        case .emailHeader:
            return 8
        case .emails:
            return 9
        case .send:
            return 10
        case .emailInfo:
            return 11
        case .status:
            return 12
        }
    }

    static func <(lhs: InviteEntry, rhs: InviteEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! InviteArguments
        switch self {
        case let .team(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.chooseTeam()
            })
        case let .linkHeader(text), let .addHeader(text), let .emailHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .shareLink(title):
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: UIImage(bundleImageName: "Contact List/LinkActionIcon")?.withRenderingMode(.alwaysTemplate), title: title, sectionId: self.section, height: .generic, editing: false, action: {
                arguments.shareLink()
            })
        case let .copyLink(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.copyLink()
            })
        case let .addFromServer(title):
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: UIImage(bundleImageName: "Contact List/AddMemberIcon")?.withRenderingMode(.alwaysTemplate), title: title, sectionId: self.section, height: .generic, editing: false, action: {
                arguments.addFromServer()
            })
        case let .emails(placeholder, text, enabled):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .email, returnKeyType: .send, clearType: .always, enabled: enabled, sectionId: self.section, textUpdated: { text in
                arguments.updateEmails(text)
            }, action: {
                arguments.sendEmails()
            })
        case let .send(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.sendEmails()
            })
        case let .linkInfo(text), let .addInfo(text), let .emailInfo(text), let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct InviteState: Equatable {
    var teamId: String
    var invite: MattermostTeamInvite?
    var loading: Bool = false
    var error: String?
    var emails: String = ""
    var sending: Bool = false
}

/// Invite People for a team (`teamId` nil: the first team; the others are tabs, or a Team row with more than four).
public func mattermostInvitePeopleController(context: AccountContext, teamId: String?) -> ViewController {
    let accountId = context.account.id
    let teams = MattermostDirectory.teams(accountId: accountId)
    let initialTeam = teamId ?? teams.first?.id ?? ""
    let statePromise = ValuePromise(InviteState(teamId: initialTeam), ignoreRepeated: true)
    let stateValue = Atomic(value: InviteState(teamId: initialTeam))
    let updateState: ((InviteState) -> InviteState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let loadDisposable = MetaDisposable()
    let actionDisposable = MetaDisposable()
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var shareImpl: ((String) -> Void)?
    var endEditingImpl: (() -> Void)?

    let load: () -> Void = {
        let teamId = stateValue.with { $0.teamId }
        updateState { state in
            var state = state
            state.invite = nil
            state.loading = true
            state.error = nil
            return state
        }
        loadDisposable.set((MattermostDirectory.teamInvite(accountId: accountId, teamId: teamId)
        |> deliverOnMainQueue).start(next: { invite in
            updateState { state in
                guard state.teamId == teamId else {
                    return state
                }
                var state = state
                state.invite = invite
                state.loading = false
                return state
            }
        }, error: { error in
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            updateState { state in
                guard state.teamId == teamId else {
                    return state
                }
                var state = state
                state.loading = false
                state.error = mattermostDirectoryErrorText(error, strings: strings)
                return state
            }
        }))
    }

    let selectTeam: (String) -> Void = { teamId in
        if stateValue.with({ $0.teamId == teamId }) {
            return
        }
        updateState { state in
            var state = state
            state.teamId = teamId
            state.emails = ""
            return state
        }
        load()
    }

    let shareLink: () -> Void = {
        guard let link = stateValue.with({ $0.invite?.inviteLink }) else {
            return
        }
        shareImpl?(link)
    }

    let copyLink: () -> Void = {
        guard let link = stateValue.with({ $0.invite?.inviteLink }) else {
            return
        }
        UIPasteboard.general.string = link
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess(presentationData.strings.Relay_Invite_LinkCopied, false)))
    }

    let addFromServer: () -> Void = {
        guard let invite = stateValue.with({ $0.invite }), invite.canAddMembers else {
            return
        }
        pushImpl?(mattermostUserDirectoryController(context: context, mode: .addToTeam(teamId: invite.teamId, teamName: invite.teamDisplayName), completion: nil))
    }

    let sendEmails: () -> Void = {
        let state = stateValue.with { $0 }
        guard let invite = state.invite, invite.canInviteByEmail, !state.sending else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let addresses = TeamInviteRules.emailAddresses(state.emails)
        if !addresses.invalid.isEmpty {
            presentImpl?(textAlertController(context: context, title: nil, text: strings.Relay_Invite_EmailInvalid(addresses.invalid.joined(separator: ", ")).string, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]))
            return
        }
        if addresses.valid.isEmpty {
            return
        }
        endEditingImpl?()
        updateState { state in
            var state = state
            state.sending = true
            return state
        }
        actionDisposable.set((MattermostDirectory.inviteByEmail(accountId: accountId, teamId: invite.teamId, emails: addresses.valid)
        |> deliverOnMainQueue).start(next: { failed in
            updateState { state in
                var state = state
                state.sending = false
                // The addresses that weren't invited stay in the field, to correct and send again.
                state.emails = failed.map { $0.0 }.joined(separator: ", ")
                return state
            }
            if failed.isEmpty {
                presentImpl?(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess(strings.Relay_Invite_EmailSent(Int32(addresses.valid.count)), false)))
            } else {
                let lines = failed.map { address, message in "\(address): \(message)" }
                presentImpl?(textAlertController(context: context, title: nil, text: strings.Relay_Invite_EmailFailed(lines.joined(separator: "\n")).string, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]))
            }
        }, error: { error in
            updateState { state in
                var state = state
                state.sending = false
                return state
            }
            mattermostPresentError(error, context: context, present: presentImpl)
        }))
    }

    let chooseTeam: () -> Void = {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        for team in teams {
            items.append(ActionSheetButtonItem(title: team.displayName, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                selectTeam(team.id)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentImpl?(actionSheet)
    }

    let arguments = InviteArguments(chooseTeam: chooseTeam, shareLink: shareLink, copyLink: copyLink, addFromServer: addFromServer, updateEmails: { text in
        updateState { state in
            var state = state
            state.emails = text
            return state
        }
    }, sendEmails: sendEmails)

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [InviteEntry] = []
        let teamName = state.invite?.teamDisplayName ?? teams.first(where: { $0.id == state.teamId })?.displayName ?? ""
        if teams.count > 4 {
            entries.append(.team(title: strings.Relay_Invite_Team, value: teamName))
        }
        if let invite = state.invite {
            if let link = invite.inviteLink {
                entries.append(.linkHeader(strings.Relay_Invite_LinkHeader))
                entries.append(.shareLink(strings.Relay_Invite_ShareLink))
                entries.append(.copyLink(strings.Relay_Invite_CopyLink))
                entries.append(.linkInfo(invite.allowsSignUp ? strings.Relay_Invite_LinkInfo(invite.teamDisplayName, link).string : strings.Relay_Invite_LinkInfoNoSignUp(invite.teamDisplayName, link).string))
            }
            if invite.canAddMembers {
                entries.append(.addHeader(strings.Relay_Invite_AddHeader))
                entries.append(.addFromServer(strings.Relay_Invite_AddFromServer))
                entries.append(.addInfo(strings.Relay_Invite_AddInfo(invite.teamDisplayName).string))
            }
            if invite.canInviteByEmail {
                let hasAddresses = !TeamInviteRules.emailAddresses(state.emails).valid.isEmpty
                entries.append(.emailHeader(strings.Relay_Invite_EmailHeader))
                entries.append(.emails(placeholder: strings.Relay_Invite_EmailPlaceholder, text: state.emails, enabled: !state.sending))
                entries.append(.send(title: strings.Relay_Invite_Send, enabled: hasAddresses && !state.sending))
                entries.append(.emailInfo(strings.Relay_Invite_EmailInfo(invite.teamDisplayName).string))
            }
            if invite.inviteLink == nil && !invite.canAddMembers && !invite.canInviteByEmail {
                entries.append(.status(strings.Relay_Invite_Nothing(invite.teamDisplayName).string))
            }
        } else if let error = state.error {
            entries.append(.status(error))
        } else {
            entries.append(.status(strings.Relay_Compose_Loading))
        }
        let title: ItemListControllerTitle
        if teams.count > 1 && teams.count <= 4 {
            title = .textWithTabs(strings.Relay_Invite_Title, teams.map { $0.displayName }, teams.firstIndex(where: { $0.id == state.teamId }) ?? 0)
        } else {
            title = .text(strings.Relay_Invite_Title)
        }
        let rightButton: ItemListNavigationButton? = state.sending ? ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {}) : nil
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: title, leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        loadDisposable.dispose()
        actionDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    #if DEBUG
    controller.debugName = "invite"
    #endif
    controller.titleControlValueChanged = { index in
        if index >= 0 && index < teams.count {
            selectTeam(teams[index].id)
        }
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    endEditingImpl = { [weak controller] in
        controller?.view.endEditing(true)
    }
    shareImpl = { [weak controller] link in
        guard let controller else {
            return
        }
        let activity = UIActivityViewController(activityItems: [URL(string: link).map { $0 as Any } ?? link], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
        }
        context.sharedContext.mainWindow?.presentNative(activity)
    }
    #if DEBUG
    controller.debugState = {
        let state = stateValue.with { $0 }
        return [
            "screen": "invite",
            "teamId": state.teamId,
            "team": state.invite?.teamDisplayName ?? "",
            "loading": state.loading,
            "error": state.error ?? "",
            "link": state.invite?.inviteLink ?? "",
            "allowsSignUp": state.invite?.allowsSignUp ?? false,
            "canAddMembers": state.invite?.canAddMembers ?? false,
            "canInviteByEmail": state.invite?.canInviteByEmail ?? false,
            "emails": state.emails,
            "sending": state.sending
        ]
    }
    controller.debugActions = [
        "team": { args in
            if let team = teams.first(where: { $0.id == (args["team"] as? String) || $0.name == (args["team"] as? String) }) {
                selectTeam(team.id)
            }
        },
        "share": { _ in
            shareLink()
        },
        "copy": { _ in
            copyLink()
        },
        "add": { _ in
            addFromServer()
        },
        "set": { args in
            arguments.updateEmails(args["value"] as? String ?? "")
        },
        "send": { _ in
            sendEmails()
        }
    ]
    #endif
    load()
    return controller
}
