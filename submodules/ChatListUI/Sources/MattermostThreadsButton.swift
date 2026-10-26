import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ComponentFlow
import ChatListHeaderComponent
import MattermostSync
import MattermostUI

// MATTERMOST: the chat list's threads button (collapsed reply threads, Phase 3B), in the stories button's place
// next to compose. It opens the threads screen of the selected team folder's team; its badge counts that team's
// unread followed threads ("@" in front when one of them mentions the user). Shown while collapsed reply threads
// are on for the account.
//
// Why a button and not a "Threads" row at the top of each folder (as Mattermost's sidebar has): Telegram's chat
// list only has rows for chats (and the archive), so a row would need a new entry kind through ChatListNode's
// entries, sorting and item factory; the header button is a contained change and reachable from every folder.
final class MattermostThreadsButtonState {
    private let context: AccountContext
    private var filterId: Int32?
    private var hasFilterId = false
    private var current: (teamId: String, badge: MattermostThreadsBadge)?
    private let disposable = MetaDisposable()
    /// The badge changed: the owner rebuilds its buttons.
    var updated: (() -> Void)?
    var open: ((ViewController) -> Void)?

    init(context: AccountContext) {
        self.context = context
    }

    deinit {
        self.disposable.dispose()
    }

    /// The button for the selected folder (`filterId`; nil: all chats, the first team), or nil while collapsed
    /// reply threads are off.
    func button(filterId: Int32?) -> AnyComponentWithIdentity<NavigationButtonComponentEnvironment>? {
        if !self.hasFilterId || self.filterId != filterId {
            self.hasFilterId = true
            self.filterId = filterId
            self.current = nil
            self.disposable.set((MattermostSync.threadsBadge(accountId: self.context.account.id, chatListFilterId: filterId)
            |> deliverOnMainQueue).startStrict(next: { [weak self] value in
                guard let self else {
                    return
                }
                if self.current?.teamId != value?.teamId || self.current?.badge != value?.badge {
                    self.current = value
                    self.updated?()
                }
            }))
        }
        guard let (teamId, badge) = self.current else {
            return nil
        }
        let context = self.context
        let badgeText: String? = badge.unreadThreads > 0 ? (badge.unreadMentions > 0 ? "@\(badge.unreadThreads)" : "\(badge.unreadThreads)") : nil
        return AnyComponentWithIdentity(id: "threads", component: AnyComponent(NavigationButtonComponent(
            content: .iconWithBadge(imageName: "Chat/Context Menu/Replies", badge: badgeText),
            pressed: { [weak self] _ in
                self?.open?(mattermostThreadsController(context: context, teamId: teamId))
            }
        )))
    }
}
