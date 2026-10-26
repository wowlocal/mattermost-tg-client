import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AlertUI
import PresentationDataUtils
import UndoUI
import MattermostSync

// MATTERMOST: buttons and menus of Mattermost's interactive message attachments. MattermostSync renders
// them as an inline keyboard of callback buttons; `ChatController`'s `requestMessageActionCallback` (the
// bot callback query of a button tap) routes here while `MattermostBackend.isEnabled`:
// - a button posts its action (`POST /posts/{post}/actions/{id}`);
// - a menu opens an action sheet of its options, then posts the action with the chosen option.
// The integration's update of the post arrives as a post edit; its ephemeral answer is shown as a toast.
extension ChatControllerImpl {
    func mattermostRequestPostAction(message: Message, data: MemoryBuffer?, progress: Promise<Bool>?) {
        guard let action = MattermostPostActions.action(data: data) else {
            return
        }
        if action.isSelect {
            self.mattermostPresentPostActionMenu(message: message, action: action, progress: progress)
        } else {
            self.mattermostPerformPostAction(message: message, action: action, selectedOption: nil, progress: progress)
        }
    }

    private func mattermostPresentPostActionMenu(message: Message, action: MattermostPostActionData, progress: Promise<Bool>?) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let options = MattermostPostActions.options(accountId: self.context.account.id, action: action)
        let controller = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: action.name)]
        for option in options {
            items.append(ActionSheetButtonItem(title: option.text, color: .accent, action: { [weak self, weak controller] in
                controller?.dismissAnimated()
                self?.mattermostPerformPostAction(message: message, action: action, selectedOption: option.value, progress: progress)
            }))
        }
        if options.isEmpty {
            items.append(ActionSheetTextItem(title: presentationData.strings.Relay_PostActions_NoOptions))
        }
        controller.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak controller] in
                controller?.dismissAnimated()
            })
        ])])
        self.chatDisplayNode.dismissInput()
        self.present(controller, in: .window(.root))

        #if DEBUG
        // Debug only: `RELAY_DEBUG_SELECT_OPTION=<option text>` picks an option after a screenshot's time, as a
        // tap on it would (see RelayDebugScreens).
        if let wanted = ProcessInfo.processInfo.environment["RELAY_DEBUG_SELECT_OPTION"], !wanted.isEmpty, let option = options.first(where: { $0.text == wanted || $0.value == wanted }) {
            Queue.mainQueue().after(4.0, { [weak self, weak controller] in
                controller?.dismissAnimated()
                self?.mattermostPerformPostAction(message: message, action: action, selectedOption: option.value, progress: progress)
            })
        }
        #endif
    }

    private func mattermostPerformPostAction(message: Message, action: MattermostPostActionData, selectedOption: String?, progress: Promise<Bool>?) {
        progress?.set(.single(true))
        let _ = (MattermostPostActions.perform(accountId: self.context.account.id, messageId: message.id, action: action, selectedOption: selectedOption)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] result in
            progress?.set(.single(false))
            guard let self else {
                return
            }
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            switch result {
            case .done:
                break
            case let .message(author, text):
                self.present(UndoOverlayController(presentationData: presentationData, content: .info(title: author, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            case let .failed(text):
                self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
            }
        })
    }
}
