import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import ContextUI
import OverlayStatusController
import PresentationDataUtils
import UndoUI
import EmojiStatusSelectionComponent
import EntityKeyboard
import MattermostSync
import MattermostSyncCore
import MattermostUI

// MATTERMOST: Phase 3F in Settings and the own profile. Settings shows the own status and custom status (rows at the
// top, and in the Settings tab's long-press menu); Edit Profile edits Mattermost's fields (first/last name in the
// header, nickname and position, username and email rows) and saves them with `PUT /users/me/patch`; the profile
// picture goes to `POST/DELETE /users/me/image` (PeerInfoScreenAvatarSetup); tapping the status emoji next to the
// own name opens the custom status. Upstream call sites are marked `// MATTERMOST:` and call these.

// MARK: - Settings rows

/// The Status and Custom Status rows at the top of Settings.
func mattermostSettingsStatusItems(context: AccountContext, presentationData: PresentationData, interaction: PeerInfoInteraction) -> [PeerInfoScreenItem] {
    let strings = presentationData.strings
    var items: [PeerInfoScreenItem] = []
    let own = MattermostProfile.currentOwnStatus(accountId: context.account.id)
    let status = own?.status ?? .online
    items.append(PeerInfoScreenDisclosureItem(id: "mattermost-status", label: .text(own.map { MattermostStatusAppearance.label($0, strings: strings) } ?? ""), text: strings.Relay_Status_Title, icon: MattermostStatusAppearance.settingsIcon(status), action: {
        interaction.openSettings(.mattermostStatus)
    }))
    if MattermostProfile.currentOwnProfileFields(accountId: context.account.id)?.customStatusesEnabled ?? true {
        let custom = own?.customStatus
        items.append(PeerInfoScreenDisclosureItem(id: "mattermost-custom-status", label: .text(custom.map(MattermostStatusAppearance.customStatusText) ?? strings.Relay_Status_SetCustomStatus), text: strings.Relay_Status_CustomStatus, icon: MattermostStatusAppearance.emojiIcon(custom?.emoji ?? "🙂", side: 30.0), action: {
            interaction.openSettings(.mattermostCustomStatus)
        }))
    }
    return items
}

/// Settings re-renders when the own status or profile fields change (they aren't Postbox data).
func mattermostSettingsScreenData(_ data: Signal<PeerInfoScreenData, NoError>, context: AccountContext) -> Signal<PeerInfoScreenData, NoError> {
    guard MattermostBackend.isEnabled else {
        return data
    }
    let accountId = context.account.id
    return combineLatest(data, MattermostProfile.ownStatus(accountId: accountId), MattermostProfile.ownProfileFields(accountId: accountId))
    |> map { data, _, _ -> PeerInfoScreenData in
        return data
    }
}

// MARK: - Edit Profile

/// The values typed into Edit Profile's nickname and position fields (the header holds the names).
final class MattermostProfileEditDraft {
    var nickname: String
    var position: String

    init(nickname: String, position: String) {
        self.nickname = nickname
        self.position = position
    }

    private static var drafts: [AccountRecordId: MattermostProfileEditDraft] = [:]

    /// The draft of an editing session; a new one (with the server's values) after the session ended.
    static func draft(accountId: AccountRecordId, isEditing: Bool) -> MattermostProfileEditDraft {
        let fields = MattermostProfile.currentOwnProfileFields(accountId: accountId)
        if !isEditing {
            self.drafts[accountId] = nil
            return MattermostProfileEditDraft(nickname: fields?.nickname ?? "", position: fields?.position ?? "")
        }
        if let draft = self.drafts[accountId] {
            return draft
        }
        let draft = MattermostProfileEditDraft(nickname: fields?.nickname ?? "", position: fields?.position ?? "")
        self.drafts[accountId] = draft
        return draft
    }
}

/// Edit Profile for a Mattermost account: name help, nickname, position, username and email, accounts, Log Out.
/// Telegram's bio, birthday, phone, colour, personal channel and chat automation rows have no Mattermost meaning.
func mattermostSettingsEditingItems(data: PeerInfoScreenData, state: PeerInfoState, context: AccountContext, presentationData: PresentationData, interaction: PeerInfoInteraction) -> [(AnyHashable, [PeerInfoScreenItem])] {
    let strings = presentationData.strings
    let accountId = context.account.id
    let fields = MattermostProfile.currentOwnProfileFields(accountId: accountId)
    let access = fields?.access ?? ProfileFieldAccess()
    let draft = MattermostProfileEditDraft.draft(accountId: accountId, isEditing: state.isEditing)

    var result: [(AnyHashable, [PeerInfoScreenItem])] = []
    result.append(("mm-help", [PeerInfoScreenCommentItem(id: "mm-name-help", text: strings.EditProfile_NameAndPhotoOrVideoHelp)]))

    var details: [PeerInfoScreenItem] = []
    if access.nickname {
        details.append(PeerInfoScreenMultilineInputItem(id: "mm-nickname", text: draft.nickname, placeholder: strings.Relay_Profile_Edit_Nickname, textUpdated: { text in
            draft.nickname = text
        }, action: {
            interaction.dismissInput()
        }, maxLength: 64))
    } else {
        details.append(PeerInfoScreenDisclosureItem(id: "mm-nickname", label: .text(fields?.nickname ?? ""), text: strings.Relay_Profile_Edit_Nickname, hasArrow: false, action: nil))
    }
    if access.position {
        details.append(PeerInfoScreenMultilineInputItem(id: "mm-position", text: draft.position, placeholder: strings.Relay_Profile_Edit_Position, textUpdated: { text in
            draft.position = text
        }, action: {
            interaction.dismissInput()
        }, maxLength: 128))
    } else {
        details.append(PeerInfoScreenDisclosureItem(id: "mm-position", label: .text(fields?.position ?? ""), text: strings.Relay_Profile_Edit_Position, hasArrow: false, action: nil))
    }
    details.append(PeerInfoScreenCommentItem(id: "mm-details-help", text: strings.Relay_Profile_Edit_Help))
    result.append(("mm-details", details))

    var info: [PeerInfoScreenItem] = []
    let username = fields.map { "@" + $0.username } ?? ""
    info.append(PeerInfoScreenDisclosureItem(id: "mm-username", label: .text(username), text: strings.Relay_Username_Title, icon: PresentationResourcesSettings.email, hasArrow: access.username, action: access.username ? {
        interaction.openSettings(.mattermostUsername)
    } : nil))
    if let email = fields?.email, !email.isEmpty {
        info.append(PeerInfoScreenDisclosureItem(id: "mm-email", label: .text(email), text: strings.Relay_Email_Title, icon: PresentationResourcesSettings.recentCalls, hasArrow: access.email, action: access.email ? {
            interaction.openSettings(.mattermostEmail)
        } : nil))
    }
    if !access.username || !access.email {
        info.append(PeerInfoScreenCommentItem(id: "mm-managed", text: strings.Relay_Profile_Edit_Managed))
    }
    result.append(("mm-info", info))

    result.append(("mm-account", [
        PeerInfoScreenActionItem(id: "mm-add-account", text: strings.Settings_AddAnotherAccount, alignment: .center, action: {
            interaction.openSettings(.addAccount)
        }),
        PeerInfoScreenCommentItem(id: "mm-add-account-help", text: strings.Settings_AddAnotherAccount_Help)
    ]))
    result.append(("mm-logout", [
        PeerInfoScreenActionItem(id: "mm-logout", text: strings.Settings_Logout, color: .destructive, alignment: .center, action: {
            interaction.openSettings(.logout)
        })
    ]))
    let _ = data
    return result
}

extension PeerInfoScreenNode {
    /// Edit Profile's Done: the changed fields go to `PUT /users/me/patch`; editing ends when the server took them.
    func mattermostSaveProfileEdits() {
        let accountId = self.context.account.id
        guard let fields = MattermostProfile.currentOwnProfileFields(accountId: accountId) else {
            self.headerNode.navigationButtonContainer.performAction?(.cancel, nil, nil)
            return
        }
        let draft = MattermostProfileEditDraft.draft(accountId: accountId, isEditing: true)
        let firstName = (self.headerNode.editingContentNode.editingTextForKey(.firstName) ?? fields.firstName).trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = (self.headerNode.editingContentNode.editingTextForKey(.lastName) ?? fields.lastName).trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let position = draft.position.trimmingCharacters(in: .whitespacesAndNewlines)
        // The header shows the username when both names are empty (a Mattermost user without a name).
        let shownFirstName = fields.firstName.isEmpty && fields.lastName.isEmpty ? fields.username : fields.firstName

        var change = MattermostProfileChange()
        if fields.access.firstName && firstName != shownFirstName && firstName != fields.firstName {
            change.firstName = firstName
        }
        if fields.access.lastName && lastName != fields.lastName {
            change.lastName = lastName
        }
        if fields.access.nickname && nickname != fields.nickname {
            change.nickname = nickname
        }
        if fields.access.position && position != fields.position {
            change.position = position
        }
        if change == MattermostProfileChange() {
            self.headerNode.navigationButtonContainer.performAction?(.cancel, nil, nil)
            return
        }
        var dismissStatus: (() -> Void)?
        let statusController = OverlayStatusController(theme: self.presentationData.theme, type: .loading(cancelled: { [weak self] in
            self?.activeActionDisposable.set(nil)
            dismissStatus?()
        }))
        dismissStatus = { [weak statusController] in
            statusController?.dismiss()
        }
        self.controller?.present(statusController, in: .window(.root))
        self.activeActionDisposable.set((MattermostProfile.updateProfile(accountId: accountId, change)
        |> deliverOnMainQueue).startStrict(error: { [weak self] error in
            dismissStatus?()
            guard let self else {
                return
            }
            mattermostPresentProfileError(error, context: self.context, present: { [weak self] c in
                self?.controller?.present(c, in: .window(.root))
            })
        }, completed: { [weak self] in
            dismissStatus?()
            self?.headerNode.navigationButtonContainer.performAction?(.cancel, nil, nil)
        }))
    }

    /// Settings rows of Phase 3F (`PeerInfoSettingsSection.mattermost*`).
    func mattermostOpenSettings(_ section: PeerInfoSettingsSection) {
        guard let controller = self.controller else {
            return
        }
        switch section {
        case .mattermostStatus:
            controller.push(mattermostStatusController(context: self.context, openCustomStatus: { [weak self] in
                self?.mattermostOpenCustomStatus()
            }))
        case .mattermostCustomStatus:
            self.mattermostOpenCustomStatus()
        case .mattermostUsername:
            controller.push(mattermostUsernameController(context: self.context))
        case .mattermostEmail:
            controller.push(mattermostEmailController(context: self.context))
        default:
            break
        }
    }

    func mattermostOpenCustomStatus() {
        guard let controller = self.controller else {
            return
        }
        let context = self.context
        let statusController = mattermostCustomStatusController(context: context, pickEmoji: { [weak controller] sourceView, completion in
            guard let controller else {
                return
            }
            mattermostPickEmoji(context: context, sourceView: sourceView, present: { picker in
                // Over the custom status screen (presented modally above Settings).
                if let top = (controller.navigationController as? NavigationController)?.topViewController as? ViewController {
                    top.present(picker, in: .window(.root))
                } else {
                    controller.present(picker, in: .window(.root))
                }
            }, completion: completion)
        })
        controller.push(statusController)
    }

    /// A tap on someone's status emoji next to their name: the custom status as a toast.
    func mattermostShowCustomStatus(peer: EnginePeer) -> Bool {
        guard MattermostBackend.isEnabled else {
            return false
        }
        if peer.id == self.context.account.peerId {
            self.mattermostOpenCustomStatus()
            return true
        }
        guard let profile = MattermostDirectory.userProfile(accountId: self.context.account.id, peerId: peer.id), !(profile.customStatusEmoji.isEmpty && profile.customStatusText.isEmpty) else {
            return true
        }
        var text = [profile.customStatusEmoji, profile.customStatusText].filter { !$0.isEmpty }.joined(separator: " ")
        if let expiresAt = profile.customStatusExpiresAt {
            text = self.presentationData.strings.Relay_Profile_StatusUntil(text, MattermostStatusAppearance.shortDate(expiresAt)).string
        }
        self.controller?.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: text, timeout: 4.0, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: true, action: { _ in return false }), in: .current)
        return true
    }
}

/// Telegram's emoji keyboard (Unicode emoji, categories, search) as the custom status's emoji picker.
func mattermostPickEmoji(context: AccountContext, sourceView: UIView, present: (ViewController) -> Void, completion: @escaping (String) -> Void) {
    let picker = EmojiStatusSelectionController(
        context: context,
        mode: .customStatusSelection(completion: { file, _ in
            guard let file else {
                return
            }
            for attribute in file.attributes {
                if case let .CustomEmoji(_, _, alt, _) = attribute, !alt.isEmpty {
                    completion(alt)
                    return
                }
            }
        }),
        sourceView: sourceView,
        emojiContent: EmojiPagerContentComponent.emojiInputData(
            context: context,
            animationCache: context.animationCache,
            animationRenderer: context.animationRenderer,
            isStandalone: false,
            subject: .emoji,
            hasTrending: false,
            topReactionItems: [],
            areUnicodeEmojiEnabled: true,
            areCustomEmojiEnabled: false,
            chatPeerId: context.account.peerId,
            selectedItems: Set()
        ),
        currentSelection: nil,
        destinationItemView: { [weak sourceView] in
            return sourceView
        }
    )
    present(picker)
}

// MARK: - Settings tab menu

extension PeerInfoScreenImpl {
    /// The Settings tab's long-press menu starts with the status: Online, Away, Do Not Disturb (with its end), Offline,
    /// then the custom status.
    func mattermostStatusMenuItems() -> [ContextMenuItem] {
        guard MattermostBackend.isEnabled else {
            return []
        }
        let context = self.context
        let accountId = context.account.id
        let strings = self.presentationData.strings
        let own = MattermostProfile.currentOwnStatus(accountId: accountId)
        var items: [ContextMenuItem] = []
        let setStatus: (MattermostOwnStatus.Status, DoNotDisturbDuration) -> Void = { status, duration in
            let _ = MattermostProfile.setStatus(accountId: accountId, status, doNotDisturb: duration).startStandalone()
        }
        for status in MattermostOwnStatus.Status.allCases {
            let isCurrent = own?.status == status
            var textLayout: ContextMenuActionItemTextLayout = .singleLine
            if status == .dnd, isCurrent, let end = own?.dndEnd, end > Date() {
                textLayout = .secondLineWithValue(strings.Relay_Status_Until(MattermostStatusAppearance.shortDate(end)).string)
            }
            items.append(.action(ContextMenuActionItem(text: MattermostStatusAppearance.title(status, strings: strings), textLayout: textLayout, icon: { _ in
                return MattermostStatusAppearance.dot(status, diameter: 14.0)
            }, additionalLeftIcon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: isCurrent ? theme.contextMenu.primaryColor : .clear)
            }, action: { [weak self] c, f in
                guard status == .dnd else {
                    setStatus(status, .indefinitely)
                    f(.default)
                    return
                }
                var subItems: [ContextMenuItem] = []
                subItems.append(.action(ContextMenuActionItem(text: strings.Common_Back, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
                }, iconPosition: .left, action: { c, _ in
                    c?.popItems()
                })))
                subItems.append(.separator)
                for duration in DoNotDisturbDuration.presets {
                    subItems.append(.action(ContextMenuActionItem(text: MattermostStatusAppearance.doNotDisturbTitle(duration, strings: strings), icon: { _ in
                        return nil
                    }, action: { _, f in
                        setStatus(.dnd, duration)
                        f(.default)
                    })))
                }
                subItems.append(.action(ContextMenuActionItem(text: strings.Relay_Status_Dnd_Custom, icon: { _ in
                    return nil
                }, action: { _, f in
                    f(.dismissWithoutContent)
                    self?.controllerNode.mattermostOpenSettings(.mattermostStatus)
                })))
                c?.pushItems(items: .single(ContextController.Items(content: .list(subItems))))
            })))
        }
        if MattermostProfile.currentOwnProfileFields(accountId: accountId)?.customStatusesEnabled ?? true {
            items.append(.separator)
            let custom = own?.customStatus
            items.append(.action(ContextMenuActionItem(text: custom.map(MattermostStatusAppearance.customStatusText) ?? strings.Relay_Status_SetCustomStatus, icon: { _ in
                return MattermostStatusAppearance.emojiIcon(custom?.emoji ?? "🙂", side: 22.0)
            }, action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.controllerNode.mattermostOpenCustomStatus()
            })))
        }
        return items
    }
}

// MARK: - Profile picture

/// `POST /users/me/image` in place of Telegram's photo upload (Settings and the own profile).
func mattermostUploadAccountPhoto(context: AccountContext, image: UIImage) -> Signal<UpdatePeerPhotoStatus, UploadPeerPhotoError> {
    // Mattermost scales pictures down to 128×128 and rejects files over its limit; 512 px keeps them sharp.
    let side: CGFloat = 512.0
    let scale = min(1.0, side / max(image.size.width, image.size.height, 1.0))
    let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else {
        return .fail(.generic)
    }
    return MattermostProfile.setProfilePicture(accountId: context.account.id, jpeg: jpeg)
    |> mapError { _ -> UploadPeerPhotoError in
        return .generic
    }
    |> map { _ -> UpdatePeerPhotoStatus in }
    |> then(.single(.complete([])))
}

/// `DELETE /users/me/image` in place of Telegram's photo removal.
func mattermostRemoveAccountPhoto(context: AccountContext) -> Signal<UpdatePeerPhotoStatus, UploadPeerPhotoError> {
    return MattermostProfile.removeProfilePicture(accountId: context.account.id)
    |> mapError { _ -> UploadPeerPhotoError in
        return .generic
    }
    |> map { _ -> UpdatePeerPhotoStatus in }
    |> then(.single(.complete([])))
}

// MARK: - A chat's notification settings

extension PeerInfoScreenNode {
    /// The profile's Notifications → Customize: Mattermost's notification settings of the chat.
    func mattermostOpenChatNotificationSettings() -> Bool {
        guard MattermostBackend.isEnabled, let peer = self.data?.peer, let controller = self.controller else {
            return false
        }
        var isChannel = false
        if case let .channel(channel) = peer, case .group = channel.info {
            // Group messages are channels here too; they have no channel-wide mentions or auto-follow.
            isChannel = MattermostDirectory.teamId(accountId: self.context.account.id, peerId: peer.id) != nil
        }
        controller.push(mattermostChannelNotificationsController(context: self.context, peerId: peer.id, isChannel: isChannel))
        return true
    }
}
