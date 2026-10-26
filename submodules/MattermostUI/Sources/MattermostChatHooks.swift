import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TemporaryCachedPeerDataManager
import MattermostSync

/// Per-account app hooks of Phase 3D, for every logged-in account (`activeAccountContexts`):
/// - interactive dialogs (`open_dialog`, from a slash command or a message button) open as a modal form
///   (`MattermostDialogController`) on the main window;
/// - members joining and leaving channels update the open member lists
///   (`PeerChannelMemberCategoriesContextsManager.externallyAdded/Removed`; the lists also refresh their head
///   every 30 seconds from the server).
final class MattermostChatHooks {
    static let shared = MattermostChatHooks()

    private var sharedContext: SharedAccountContext?
    private let contextsDisposable = MetaDisposable()
    private var accountDisposables: [AccountRecordId: Disposable] = [:]
    private(set) weak var currentDialog: MattermostDialogController?

    func start(sharedContext: SharedAccountContext) {
        self.sharedContext = sharedContext
        self.contextsDisposable.set((sharedContext.activeAccountContexts
        |> deliverOnMainQueue).start(next: { [weak self] _, accounts, _ in
            guard let self else {
                return
            }
            var current = Set<AccountRecordId>()
            for (id, context, _) in accounts {
                current.insert(id)
                if self.accountDisposables[id] == nil {
                    self.accountDisposables[id] = self.observe(context: context)
                }
            }
            for (id, disposable) in self.accountDisposables where !current.contains(id) {
                disposable.dispose()
                self.accountDisposables[id] = nil
            }
        }))
    }

    private func observe(context: AccountContext) -> Disposable {
        let disposables = DisposableSet()
        let accountId = context.account.id
        disposables.add((MattermostComposer.dialogs(accountId: accountId)
        |> deliverOnMainQueue).start(next: { [weak self, weak context] dialog in
            guard let self, let context else {
                return
            }
            self.present(dialog: dialog, context: context)
        }))
        disposables.add((MattermostSync.memberChanges(accountId: accountId)
        |> deliverOnMainQueue).start(next: { [weak context] change in
            guard let context else {
                return
            }
            switch change {
            case let .added(channelPeerId, participant):
                context.peerChannelMemberCategoriesContextsManager.externallyAdded(peerId: channelPeerId, participant: participant)
            case let .removed(channelPeerId, memberPeerId):
                context.peerChannelMemberCategoriesContextsManager.externallyRemoved(peerId: channelPeerId, memberId: memberPeerId)
            }
        }))
        return disposables
    }

    private func present(dialog: MattermostDialogRequest, context: AccountContext) {
        guard let navigationController = self.sharedContext?.mainWindow?.viewController as? NavigationController else {
            return
        }
        // A new dialog replaces the one on screen (Mattermost shows one at a time).
        self.currentDialog?.dismiss()
        let controller = MattermostDialogController(context: context, dialog: dialog)
        self.currentDialog = controller
        navigationController.view.window?.endEditing(true)
        navigationController.pushViewController(controller)
    }
}
