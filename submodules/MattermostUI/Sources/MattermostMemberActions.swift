import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import MattermostSync

/// Phase 3D-2: member management from a channel's profile (the members pane's swipe options and context menu),
/// in place of Telegram's ban and admin-rights editors. What is offered follows the channel's
/// `MattermostChannelAccess`; the server decides.
public enum MattermostMemberActions {
    /// What the user may do with a member of a channel (`nil`: not a Mattermost channel).
    public struct Available: Equatable {
        public var remove: Bool
        public var makeAdmin: Bool
        public var removeAdmin: Bool
    }

    public static func available(channel: TelegramChannel, accountPeerId: PeerId, memberPeerId: PeerId, memberIsAdmin: Bool, memberIsBot: Bool) -> Available? {
        guard let access = channel.mattermostAccess else {
            return nil
        }
        if memberPeerId == accountPeerId || access.contains(.groupMessage) || access.contains(.archived) {
            return Available(remove: false, makeAdmin: false, removeAdmin: false)
        }
        let canRoles = access.contains(.manageRoles) && !memberIsBot
        return Available(remove: access.contains(.manageMembers), makeAdmin: canRoles && !memberIsAdmin, removeAdmin: canRoles && memberIsAdmin)
    }

    /// "Remove from Channel": asks, then `DELETE /channels/{id}/members/{user}`; the member leaves the open lists.
    public static func remove(context: AccountContext, channel: EnginePeer, member: EnginePeer, confirm: Bool = true, present: @escaping (ViewController) -> Void, completed: (() -> Void)? = nil) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let run: () -> Void = {
            let _ = (MattermostDirectory.removeMember(accountId: context.account.id, channelPeerId: channel.id, memberPeerId: member.id)
            |> deliverOnMainQueue).start(error: { error in
                mattermostPresentError(error, context: context, present: present)
            }, completed: {
                completed?()
            })
        }
        if !confirm {
            run()
            return
        }
        let name = member.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        let channelName = channel.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        let alert = textAlertController(context: context, title: nil, text: presentationData.strings.Relay_Members_RemoveConfirm(name, channelName).string, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Relay_Members_RemoveAction, action: run)
        ], parseMarkdown: true)
        #if DEBUG
        MattermostDirectoryDebug.alertPresented(alert, confirm: run)
        #endif
        present(alert)
    }

    /// "Make Channel Admin" / "Remove Channel Admin" (`PUT …/members/{user}/schemeRoles`).
    public static func setAdmin(context: AccountContext, channelPeerId: PeerId, memberPeerId: PeerId, isAdmin: Bool, present: @escaping (ViewController) -> Void, completed: (() -> Void)? = nil) {
        let _ = (MattermostDirectory.setMemberAdmin(accountId: context.account.id, channelPeerId: channelPeerId, memberPeerId: memberPeerId, isAdmin: isAdmin)
        |> deliverOnMainQueue).start(error: { error in
            mattermostPresentError(error, context: context, present: present)
        }, completed: {
            completed?()
        })
    }
}
