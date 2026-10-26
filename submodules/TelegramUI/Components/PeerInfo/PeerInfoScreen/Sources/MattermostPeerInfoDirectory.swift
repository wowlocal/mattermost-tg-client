import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import MattermostSync
import MattermostUI

// MATTERMOST: Phase 3D-2 on the profile screens. A channel's settings (the Edit button), Add Members, member
// actions (remove, channel admin) and Leave follow the channel's `MattermostChannelAccess` (written by
// MattermostSync from the user's roles) and go to Mattermost (MattermostUI) instead of Telegram's editors; a user's
// profile shows the Mattermost profile fields. Upstream call sites are marked `// MATTERMOST:` and call these.

/// Whether the profile's Edit button opens anything (nil: Telegram's rules apply).
func mattermostCanEditChannel(_ channel: TelegramChannel) -> Bool? {
    guard MattermostBackend.isEnabled else {
        return nil
    }
    return channel.mattermostAccess?.hasSettings ?? false
}

/// Whether "Add Members" is offered (nil: Telegram's rules apply).
func mattermostCanAddMembers(_ channel: TelegramChannel) -> Bool? {
    guard MattermostBackend.isEnabled else {
        return nil
    }
    return channel.mattermostAccess?.contains(.manageMembers) ?? false
}

/// Whether Leave is offered: not for the town square and not for group messages.
func mattermostCanLeave(_ channel: TelegramChannel) -> Bool {
    guard MattermostBackend.isEnabled else {
        return true
    }
    return channel.mattermostAccess?.contains(.leave) ?? false
}

/// The member actions of a Mattermost channel: `.restrict` stands for "Remove from Channel", `.promote` for "Make
/// / Remove Channel Admin" (nil: Telegram's rules apply).
func mattermostMemberActions(accountPeerId: PeerId, peer: EnginePeer?, member: PeerInfoMember) -> PeerInfoMemberActions? {
    guard MattermostBackend.isEnabled, case let .channel(channel) = peer else {
        return nil
    }
    var isBot = false
    if case let .user(user) = member.peer, user.botInfo != nil {
        isBot = true
    }
    guard let available = MattermostMemberActions.available(channel: channel, accountPeerId: accountPeerId, memberPeerId: member.id, memberIsAdmin: member.role != .member, memberIsBot: isBot) else {
        return []
    }
    var result: PeerInfoMemberActions = []
    if available.remove {
        result.insert(.restrict)
    }
    if available.makeAdmin || available.removeAdmin {
        result.insert(.promote)
    }
    return result
}

func mattermostPromoteTitle(member: PeerInfoMember, strings: PresentationStrings) -> String {
    return member.role == .member ? strings.Relay_Members_MakeAdmin : strings.Relay_Members_RemoveAdmin
}

extension PeerInfoScreenNode {
    /// The Edit button of a Mattermost channel: Channel Settings. False for other peers.
    func mattermostOpenChannelSettings() -> Bool {
        guard MattermostBackend.isEnabled, case let .channel(channel)? = self.data?.peer, case .peer = self.chatLocation else {
            return false
        }
        self.controller?.push(mattermostChannelSettingsController(context: self.context, peerId: channel.id))
        return true
    }

    /// "Add Members" of a Mattermost channel: the team's users who aren't in it.
    func mattermostOpenAddMembers() -> Bool {
        guard MattermostBackend.isEnabled, case let .channel(channel)? = self.data?.peer else {
            return false
        }
        self.controller?.push(mattermostAddMembersController(context: self.context, channelPeerId: channel.id))
        return true
    }

    /// Remove and channel admin for a member of a Mattermost channel; false for other actions and peers.
    func mattermostPerformMemberAction(member: PeerInfoMember, action: PeerInfoMemberAction) -> Bool {
        guard MattermostBackend.isEnabled, let channel = self.data?.peer, case .channel = channel else {
            return false
        }
        let present: (ViewController) -> Void = { [weak self] controller in
            self?.controller?.present(controller, in: .window(.root))
        }
        switch action {
        case .remove, .restrict:
            MattermostMemberActions.remove(context: self.context, channel: channel, member: member.peer, present: present)
            return true
        case .promote:
            MattermostMemberActions.setAdmin(context: self.context, channelPeerId: channel.id, memberPeerId: member.id, isAdmin: member.role == .member, present: present)
            return true
        case .editRank, .openStories:
            return false
        }
    }
}

/// The Mattermost profile rows of a user (after the username): nickname, position, email, local time, custom
/// status. The bio row (the position, see MattermostSync `writeUsers`) is left out for people.
func mattermostProfileItems(context: AccountContext, user: TelegramUser, presentationData: PresentationData, requestLayout: @escaping (Bool) -> Void) -> [PeerInfoScreenItem] {
    guard MattermostBackend.isEnabled, let profile = MattermostDirectory.userProfile(accountId: context.account.id, peerId: user.id) else {
        return []
    }
    let strings = presentationData.strings
    var items: [PeerInfoScreenItem] = []
    let baseId = 3100
    if profile.isDeactivated {
        items.append(PeerInfoScreenLabeledValueItem(id: baseId, label: "", text: strings.Relay_Profile_Deactivated, textColor: .primary, action: nil, requestLayout: requestLayout))
    }
    if !profile.customStatusEmoji.isEmpty || !profile.customStatusText.isEmpty {
        var text = [profile.customStatusEmoji, profile.customStatusText].filter { !$0.isEmpty }.joined(separator: " ")
        if let expiresAt = profile.customStatusExpiresAt {
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDateInToday(expiresAt) ? .none : .medium
            formatter.timeStyle = .short
            text = strings.Relay_Profile_StatusUntil(text, formatter.string(from: expiresAt)).string
        }
        items.append(PeerInfoScreenLabeledValueItem(id: baseId + 1, label: strings.Relay_Profile_Status, text: text, textColor: .primary, textBehavior: .multiLine(maxLines: 3, enabledEntities: []), action: nil, requestLayout: requestLayout))
    }
    if !profile.nickname.isEmpty {
        items.append(PeerInfoScreenLabeledValueItem(id: baseId + 2, label: strings.Relay_Profile_Nickname, text: profile.nickname, textColor: .primary, action: nil, requestLayout: requestLayout))
    }
    if !profile.position.isEmpty && !profile.isBot {
        items.append(PeerInfoScreenLabeledValueItem(id: baseId + 3, label: strings.Relay_Profile_Position, text: profile.position, textColor: .primary, action: nil, requestLayout: requestLayout))
    }
    if !profile.email.isEmpty && !profile.isBot {
        let email = profile.email
        items.append(PeerInfoScreenLabeledValueItem(id: baseId + 4, label: strings.Relay_Profile_Email, text: email, textColor: .accent, action: { _, _ in
            if let url = URL(string: "mailto:\(email)") {
                context.sharedContext.applicationBindings.openUrl(url.absoluteString)
            }
        }, requestLayout: requestLayout))
    }
    if let timeZone = profile.timeZone, !profile.isBot {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let zone = timeZone.localizedName(for: .shortGeneric, locale: Locale.current) ?? timeZone.identifier
        items.append(PeerInfoScreenLabeledValueItem(id: baseId + 5, label: strings.Relay_Profile_LocalTime, text: strings.Relay_Profile_LocalTimeValue(formatter.string(from: Date()), zone).string, textColor: .primary, action: nil, requestLayout: requestLayout))
    }
    return items
}

/// The channel header row (Mattermost markdown with its links and mentions).
func mattermostChannelHeaderItem(context: AccountContext, channel: TelegramChannel, presentationData: PresentationData, linkItemAction: @escaping (TextLinkItemActionType, TextLinkItem, ASDisplayNode, CGRect?, Promise<Bool>?) -> Void, requestLayout: @escaping (Bool) -> Void) -> PeerInfoScreenItem? {
    guard MattermostBackend.isEnabled, let header = MattermostDirectory.channelHeader(accountId: context.account.id, peerId: channel.id) else {
        return nil
    }
    return PeerInfoScreenLabeledValueItem(id: 3100, context: context, label: presentationData.strings.Relay_Profile_Header, text: header.text, entities: header.entities, textColor: .primary, textBehavior: .multiLine(maxLines: 100, enabledEntities: []), action: nil, linkItemAction: linkItemAction, requestLayout: requestLayout)
}

/// Whether the bio row is shown: for bots (their description) only; a person's position has its own row.
func mattermostShowsAbout(_ user: TelegramUser) -> Bool {
    return !MattermostBackend.isEnabled || user.botInfo != nil
}

#if DEBUG
extension PeerInfoScreenNode {
    /// Debug builds: the debug remote's `info-*` commands for this profile (`MattermostDirectoryDebug`).
    func relayDebugRegister() {
        MattermostDirectoryDebug.peerInfo = { [weak self] action, command, completion in
            guard let self else {
                return false
            }
            return self.relayDebugRun(action: action, command: command, completion: completion)
        }
    }

    private func relayDebugState() -> [String: Any] {
        var result: [String: Any] = ["peerId": "\(self.peerId.toInt64())"]
        if case let .channel(channel)? = self.data?.peer {
            result["title"] = channel.title
            result["access"] = Int(channel.mattermostAccess?.rawValue ?? -1)
            result["canEdit"] = mattermostCanEditChannel(channel) ?? false
            result["canAddMembers"] = mattermostCanAddMembers(channel) ?? false
            result["canLeave"] = mattermostCanLeave(channel)
        } else if case let .user(user)? = self.data?.peer {
            result["user"] = user.addressName ?? ""
            if let profile = MattermostDirectory.userProfile(accountId: self.context.account.id, peerId: user.id) {
                result["profile"] = ["nickname": profile.nickname, "position": profile.position, "email": profile.email, "timeZone": profile.timeZone?.identifier ?? "", "status": profile.customStatusEmoji + " " + profile.customStatusText]
            }
        }
        result["headerButtons"] = self.headerNode.buttonNodes.keys.map { "\($0)" }.sorted()
        result["top"] = (self.controller?.navigationController as? NavigationController)?.viewControllers.last.map { "\(type(of: $0))" } ?? ""
        return result
    }

    private func relayDebugRun(action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let after: (Double, @escaping () -> Void) -> Void = { delay, f in
            Queue.mainQueue().after(delay, f)
        }
        switch action {
        case "info-state":
            guard let members = self.data?.members else {
                completion(true, nil, self.relayDebugState())
                return true
            }
            let _ = (members.membersContext.state |> take(1) |> deliverOnMainQueue).startStandalone(next: { [weak self] state in
                guard let self else {
                    return
                }
                var result = self.relayDebugState()
                result["canAddMembersPane"] = state.canAddMembers
                result["members"] = state.members.map { member -> [String: Any] in
                    let actions = availableActionsForMemberOfPeer(accountPeerId: self.context.account.peerId, peer: self.data?.peer, member: member)
                    return ["name": member.peer.addressName ?? member.peer.debugDisplayTitle, "role": "\(member.role)", "remove": actions.contains(.restrict), "promote": actions.contains(.promote)]
                }
                completion(true, nil, result)
            })
            return true
        case "info-edit":
            // The Edit button.
            self.headerNode.navigationButtonContainer.performAction?(.edit, nil, nil)
            after(1.5) {
                completion(true, nil, self.relayDebugState())
            }
            return true
        case "info-more":
            // The header's More button (its menu, for a screenshot).
            guard let buttonNode = self.headerNode.buttonNodes[.more] else {
                completion(false, "no more button", self.relayDebugState())
                return true
            }
            self.performButtonAction(key: .more, buttonNode: buttonNode, gesture: nil)
            after(1.5) {
                completion(true, nil, self.relayDebugState())
            }
            return true
        case "info-add-member":
            self.openAddMember()
            after(1.5) {
                completion(true, nil, self.relayDebugState())
            }
            return true
        case "info-member":
            let username = (command["username"] as? String ?? "").lowercased()
            let actionName = command["do"] as? String ?? ""
            guard let members = self.data?.members else {
                completion(false, "no members", self.relayDebugState())
                return true
            }
            let _ = (members.membersContext.state |> take(1) |> deliverOnMainQueue).startStandalone(next: { [weak self] state in
                guard let self, let member = state.members.first(where: { $0.peer.addressName?.lowercased() == username }) else {
                    completion(false, "no member \(username)", [:])
                    return
                }
                switch actionName {
                case "menu":
                    // The member's context menu, as a long press on its row opens it (for a screenshot).
                    var rowNode: ASDisplayNode = self
                    for (_, section) in self.regularSections {
                        if let itemNode = section.itemNodes[AnyHashable(member.id)] {
                            rowNode = itemNode
                        }
                    }
                    self.openMemberContextMenu(member: member, node: rowNode, gesture: nil)
                case "promote":
                    self.performMemberAction(member: member, action: .promote)
                case "remove-confirmed":
                    // "Remove" after the confirmation (the alert can't be tapped here).
                    if case let .channel(channel)? = self.data?.peer {
                        MattermostMemberActions.remove(context: self.context, channel: .channel(channel), member: member.peer, confirm: false, present: { _ in })
                    }
                default:
                    self.performMemberAction(member: member, action: .remove)
                }
                after(1.5) {
                    completion(true, nil, self.relayDebugState())
                }
            })
            return true
        case "info-leave":
            // The Leave confirmation (for a screenshot); `confirm=1` then runs what its Leave button runs.
            self.openLeavePeer(delete: false)
            if (command["confirm"] as? String) == "1" {
                after(1.0) {
                    let _ = self.context.engine.peers.removePeerChat(peerId: self.peerId, reportChatSpam: false).startStandalone()
                }
            }
            after(2.0) {
                completion(true, nil, self.relayDebugState())
            }
            return true
        default:
            return false
        }
    }
}
#endif
