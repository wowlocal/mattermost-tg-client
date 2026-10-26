import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import ContextUI
import MattermostSync

// MATTERMOST: debug only (Phase 3F). What the debug remote's profile commands run on the Settings screen
// (TelegramUI `RelayDebugProfile.swift`), each through the handler a tap runs. Release builds compile none of this.
public extension PeerInfoScreenImpl {
    /// A Settings row: `status`, `custom-status`, `edit`, `avatar`, `notifications`; Edit Profile's `username`, `email`.
    func relayDebugOpenSettingsRow(_ row: String) -> Bool {
        #if DEBUG
        let section: PeerInfoSettingsSection
        switch row {
        case "status":
            section = .mattermostStatus
        case "custom-status":
            section = .mattermostCustomStatus
        case "edit":
            section = .edit
        case "avatar":
            section = .avatar
        case "notifications":
            section = .notificationsAndSounds
        case "username":
            section = .mattermostUsername
        case "email":
            section = .mattermostEmail
        default:
            return false
        }
        self.controllerNode.openSettings(section: section)
        return true
        #else
        return false
        #endif
    }

    /// The Settings tab's long-press status items (titles, the checked one).
    func relayDebugStatusMenu() -> [String] {
        #if DEBUG
        return self.mattermostStatusMenuItems().compactMap { item -> String? in
            if case let .action(action) = item {
                return action.text
            }
            return nil
        }
        #else
        return []
        #endif
    }

    /// Runs the action of the status menu item titled `title` (as a tap does); for Do Not Disturb, then the duration
    /// item titled `subtitle` of the submenu it pushes.
    func relayDebugPickStatusMenu(title: String, subtitle: String?) -> Bool {
        #if DEBUG
        for item in self.mattermostStatusMenuItems() {
            guard case let .action(action) = item, action.text == title else {
                continue
            }
            let controller = RelayDebugContextMenuController()
            action.action?(ContextMenuActionItem.Action(controller: controller, dismissWithResult: { _ in }, updateAction: { _, _ in }))
            if let subtitle {
                for subItem in controller.pushed {
                    if case let .action(subAction) = subItem, subAction.text == subtitle {
                        subAction.action?(ContextMenuActionItem.Action(controller: controller, dismissWithResult: { _ in }, updateAction: { _, _ in }))
                        return true
                    }
                }
                return false
            }
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Shows the Settings tab's long-press menu over the screen (for a screenshot; the tab bar's own gesture needs a
    /// touch).
    func relayDebugPresentStatusMenu() {
        #if DEBUG
        var items = self.mattermostStatusMenuItems()
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Settings_AddAccount, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Add"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.dismissWithoutContent)
        })))
        let controller = makeContextController(presentationData: self.presentationData, source: .reference(HeaderContextReferenceContentSource(controller: self, sourceView: self.view)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: nil)
        self.context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
        #endif
    }

    /// Edit Profile: `begin` (the Edit button), `set` (`field`: first, last, nickname, position; `value`), `done`,
    /// `cancel`. Returns the editing state.
    func relayDebugEditProfile(action: String, field: String?, value: String?) -> [String: Any] {
        #if DEBUG
        let node = self.controllerNode
        switch action {
        case "begin":
            node.headerNode.navigationButtonContainer.performAction?(.edit, nil, nil)
        case "set":
            let draft = MattermostProfileEditDraft.draft(accountId: self.context.account.id, isEditing: true)
            switch field ?? "" {
            case "nickname":
                draft.nickname = value ?? ""
            case "position":
                draft.position = value ?? ""
            case "first", "last":
                if let itemNode = node.headerNode.editingContentNode.itemNodes[field == "first" ? .firstName : .lastName], let textField = relayDebugFindTextField(itemNode.view) {
                    textField.text = value ?? ""
                }
            default:
                break
            }
            if let (layout, navigationHeight) = node.validLayout {
                node.containerLayoutUpdated(layout: layout, navigationHeight: navigationHeight, transition: .immediate, additive: false)
            }
        case "done":
            node.headerNode.navigationButtonContainer.performAction?(.done, nil, nil)
        case "cancel":
            node.headerNode.navigationButtonContainer.performAction?(.cancel, nil, nil)
        default:
            break
        }
        let draft = MattermostProfileEditDraft.draft(accountId: self.context.account.id, isEditing: node.state.isEditing)
        return [
            "editing": node.state.isEditing,
            "first": node.headerNode.editingContentNode.editingTextForKey(.firstName) ?? "",
            "last": node.headerNode.editingContentNode.editingTextForKey(.lastName) ?? "",
            "nickname": draft.nickname,
            "position": draft.position
        ]
        #else
        return [:]
        #endif
    }

    /// The profile picture through the Settings handler a picked photo runs (`updateProfilePhoto`); `remove` runs
    /// what the removal sheet's Remove runs.
    func relayDebugSetProfilePhoto(_ image: UIImage?) {
        #if DEBUG
        if let image {
            self.updateProfilePhoto(image, mode: .generic, uploadStatus: nil)
        } else {
            let node = self.controllerNode
            node.updateAvatarDisposable.set((mattermostRemoveAccountPhoto(context: self.context)
            |> deliverOnMainQueue).startStrict(next: { [weak node] result in
                guard let node, case .complete = result else {
                    return
                }
                node.state = node.state.withUpdatingAvatar(nil)
                if let (layout, navigationHeight) = node.validLayout {
                    node.containerLayoutUpdated(layout: layout, navigationHeight: navigationHeight, transition: .immediate, additive: false)
                }
            }))
        }
        #endif
    }
}

/// The profile of a chat: Notifications → Customize (Mattermost's chat notification settings).
public extension PeerInfoScreenImpl {
    func relayDebugOpenChatNotificationSettings() -> Bool {
        #if DEBUG
        return self.controllerNode.mattermostOpenChatNotificationSettings()
        #else
        return false
        #endif
    }
}

#if DEBUG
private func relayDebugFindTextField(_ view: UIView) -> UITextField? {
    if let field = view as? UITextField {
        return field
    }
    for subview in view.subviews {
        if let field = relayDebugFindTextField(subview) {
            return field
        }
    }
    return nil
}

/// Collects the items a menu action pushes (Do Not Disturb's durations).
private final class RelayDebugContextMenuController: ViewController, ContextControllerProtocol {
    var pushed: [ContextMenuItem] = []
    private let disposable = MetaDisposable()

    var useComplexItemsTransitionAnimation: Bool = false
    var immediateItemsTransitionAnimation: Bool = false
    var getOverlayViews: (() -> [UIView])?

    init() {
        super.init(navigationBarPresentationData: nil)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable.dispose()
    }

    func dismiss(result: ContextMenuActionResult, completion: (() -> Void)?) {
        completion?()
    }

    override func dismiss(completion: (() -> Void)? = nil) {
        completion?()
    }

    func getActionsMinHeight() -> ContextController.ActionsHeight? {
        return nil
    }

    func setItems(_ items: Signal<ContextController.Items, NoError>, minHeight: ContextController.ActionsHeight?, animated: Bool) {
        self.capture(items)
    }

    func setItems(_ items: Signal<ContextController.Items, NoError>, minHeight: ContextController.ActionsHeight?, previousActionsTransition: ContextController.PreviousActionsTransition) {
        self.capture(items)
    }

    func pushItems(items: Signal<ContextController.Items, NoError>) {
        self.capture(items)
    }

    func popItems() {
    }

    private func capture(_ items: Signal<ContextController.Items, NoError>) {
        self.disposable.set((items |> take(1)).start(next: { [weak self] items in
            if case let .list(list) = items.content {
                self?.pushed = list
            }
        }))
    }
}
#endif
