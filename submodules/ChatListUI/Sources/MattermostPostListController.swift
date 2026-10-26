import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import MergeLists
import ContextUI
import UndoUI
import AnimationCache
import MultiAnimationRenderer
import AppBundle
import MattermostSync

// MATTERMOST: finding things (Phase 3C). "Saved Posts" (Mattermost's flagged posts, not Telegram's Saved Messages)
// and "Recent Mentions", opened from Settings. Rows are Telegram's search result rows (`ChatListItem` showing a
// message: chat avatar and name, snippet, date; mentions highlighted); a tap opens the chat at the post (its thread
// with collapsed reply threads), a long press previews it with "Show in Chat" and Save / Remove from Saved. The
// saved list follows saves and unsaves from this device and other clients live.

private enum MattermostPostListEntry: Comparable, Identifiable {
    case message(index: Int, message: EngineMessage, presentationData: ChatListPresentationData)

    var stableId: EngineMessage.Id {
        switch self {
        case let .message(_, message, _):
            return message.id
        }
    }

    static func ==(lhs: MattermostPostListEntry, rhs: MattermostPostListEntry) -> Bool {
        switch lhs {
        case let .message(lhsIndex, lhsMessage, lhsPresentationData):
            guard case let .message(rhsIndex, rhsMessage, rhsPresentationData) = rhs else {
                return false
            }
            return lhsIndex == rhsIndex && lhsMessage.id == rhsMessage.id && lhsMessage.stableVersion == rhsMessage.stableVersion && lhsPresentationData === rhsPresentationData
        }
    }

    static func <(lhs: MattermostPostListEntry, rhs: MattermostPostListEntry) -> Bool {
        switch lhs {
        case let .message(lhsIndex, _, _):
            switch rhs {
            case let .message(rhsIndex, _, _):
                return lhsIndex < rhsIndex
            }
        }
    }

    func item(context: AccountContext, interaction: ChatListNodeInteraction) -> ListViewItem {
        switch self {
        case let .message(_, message, presentationData):
            return ChatListItem(
                presentationData: presentationData,
                context: context,
                chatListLocation: .chatList(groupId: .root),
                filterData: nil,
                index: .chatList(EngineChatList.Item.Index.ChatList(pinningIndex: nil, messageIndex: message.index)),
                content: .peer(ChatListItemContent.PeerData(
                    messages: [message],
                    peer: EngineRenderedPeer(message: message),
                    threadInfo: nil,
                    combinedReadState: nil,
                    isRemovedFromTotalUnreadCount: false,
                    presence: nil,
                    hasUnseenMentions: false,
                    hasUnseenReactions: false,
                    hasUnseenPollVotes: false,
                    draftState: nil,
                    mediaDraftContentType: nil,
                    inputActivities: nil,
                    promoInfo: nil,
                    ignoreUnreadBadge: true,
                    displayAsMessage: false,
                    hasFailedMessages: false,
                    forumTopicData: nil,
                    topForumTopicItems: [],
                    autoremoveTimeout: nil,
                    storyState: nil,
                    requiresPremiumForMessaging: false,
                    displayAsTopicList: false,
                    tags: []
                )),
                editing: false,
                hasActiveRevealControls: false,
                selected: false,
                header: nil,
                enabledContextActions: nil,
                hiddenOffset: false,
                interaction: interaction
            )
        }
    }
}

/// The Settings rows' screen: saved posts or recent mentions of the account.
public final class MattermostPostListController: ViewController {
    private let context: AccountContext
    public let kind: MattermostPostListKind
    public let list: MattermostPostList
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?

    private var controllerNode: MattermostPostListControllerNode {
        return self.displayNode as! MattermostPostListControllerNode
    }

    public init(context: AccountContext, kind: MattermostPostListKind) {
        self.context = context
        self.kind = kind
        self.list = MattermostSync.postList(accountId: context.account.id, kind: kind)
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.title = kind == .saved ? self.presentationData.strings.Relay_Saved_Title : self.presentationData.strings.Relay_Mentions_Title
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)

        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).startStrict(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            self.presentationData = presentationData
            self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
            self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: presentationData), transition: .immediate)
            if self.isNodeLoaded {
                self.controllerNode.updatePresentationData(presentationData)
            }
        })

        self.scrollToTop = { [weak self] in
            self?.controllerNode.scrollToTop()
        }
        self.list.reload()
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
    }

    override public func loadDisplayNode() {
        self.displayNode = MattermostPostListControllerNode(context: self.context, controller: self, presentationData: self.presentationData)
        self.displayNodeDidLoad()
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }

    /// Opens the chat (or thread) at the post of `message`.
    func open(message: EngineMessage) {
        guard let navigationController = self.navigationController as? NavigationController, let peer = message.peers[message.id.peerId] else {
            return
        }
        self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(EnginePeer(peer)), subject: .message(id: .id(message.id), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false), keepStack: .always))
    }

    func setSaved(message: EngineMessage, saved: Bool) {
        let context = self.context
        let _ = (MattermostSync.setPostSaved(accountId: context.account.id, messageId: message.id, saved: saved)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] done in
            guard let self, done else {
                return
            }
            let text = saved ? self.presentationData.strings.Relay_Saved_Saved : self.presentationData.strings.Relay_Saved_Removed
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
        })
    }

    /// Debug: what the list shows (`RelayDebugSearch`).
    public var debugMessages: [EngineMessage] {
        return self.isNodeLoaded ? self.controllerNode.currentMessages : []
    }

    public var debugIsLoading: Bool {
        return self.isNodeLoaded ? self.controllerNode.isLoading : true
    }

    /// Debug: a row's tap.
    public func debugOpen(index: Int) -> Bool {
        let messages = self.debugMessages
        guard index >= 0, index < messages.count else {
            return false
        }
        self.open(message: messages[index])
        return true
    }
}

private final class MattermostPostListControllerNode: ASDisplayNode {
    private let context: AccountContext
    private weak var controller: MattermostPostListController?
    private var presentationData: PresentationData
    private let presentationDataPromise: Promise<ChatListPresentationData>

    private let listNode: ListView
    private let emptyTitleNode: ImmediateTextNode
    private let emptyTextNode: ImmediateTextNode
    private var interaction: ChatListNodeInteraction?

    private var validLayout: (ContainerViewLayout, CGFloat)?
    private var enqueuedTransitions: [(deletions: [ListViewDeleteItem], insertions: [ListViewInsertItem], updates: [ListViewUpdateItem])] = []
    private var previousEntries: [MattermostPostListEntry]?
    private let disposable = MetaDisposable()

    private(set) var currentMessages: [EngineMessage] = []
    private(set) var isLoading = true
    private var listState: MattermostPostListState?

    init(context: AccountContext, controller: MattermostPostListController, presentationData: PresentationData) {
        self.context = context
        self.controller = controller
        self.presentationData = presentationData
        self.presentationDataPromise = Promise(MattermostPostListControllerNode.listPresentationData(presentationData))

        self.listNode = ListViewImpl()
        self.listNode.verticalScrollIndicatorColor = presentationData.theme.list.scrollIndicatorColor
        self.emptyTitleNode = ImmediateTextNode()
        self.emptyTitleNode.textAlignment = .center
        self.emptyTitleNode.maximumNumberOfLines = 2
        self.emptyTextNode = ImmediateTextNode()
        self.emptyTextNode.textAlignment = .center
        self.emptyTextNode.maximumNumberOfLines = 0

        super.init()

        self.setViewBlock({
            return UITracingLayerView()
        })
        self.backgroundColor = presentationData.theme.chatList.backgroundColor
        self.addSubnode(self.listNode)
        self.addSubnode(self.emptyTitleNode)
        self.addSubnode(self.emptyTextNode)

        let interaction = self.makeInteraction()
        // Rows are laid out as search results (chat, then author and snippet) while a highlight is set; mentions
        // highlight the user's mention keys, as Mattermost does.
        if controller.kind == .mentions {
            interaction.searchTextHighightState = MattermostSync.mentionHighlightText(accountId: context.account.id) ?? ""
        } else {
            interaction.searchTextHighightState = ""
        }
        self.interaction = interaction

        let messages: Signal<(MattermostPostListState, [EngineMessage]), NoError> = controller.list.state
        |> mapToSignal { state -> Signal<(MattermostPostListState, [EngineMessage]), NoError> in
            if state.messageIds.isEmpty {
                return .single((state, []))
            }
            return context.engine.data.subscribe(EngineDataMap(state.messageIds.map { TelegramEngine.EngineData.Item.Messages.Message(id: $0) }))
            |> map { messages -> (MattermostPostListState, [EngineMessage]) in
                return (state, state.messageIds.compactMap { messages[$0] ?? nil })
            }
        }
        self.disposable.set((combineLatest(messages, self.presentationDataPromise.get())
        |> deliverOnMainQueue).startStrict(next: { [weak self] value, presentationData in
            guard let self else {
                return
            }
            let (state, messages) = value
            self.update(state: state, messages: messages, presentationData: presentationData)
        }))

        self.listNode.visibleBottomContentOffsetChanged = { [weak self] offset in
            guard let self, case let .known(value) = offset, value < 200.0, let state = self.listState, state.hasMore, !state.isLoading else {
                return
            }
            self.controller?.list.loadMore()
        }
    }

    deinit {
        self.disposable.dispose()
    }

    private static func listPresentationData(_ presentationData: PresentationData) -> ChatListPresentationData {
        return ChatListPresentationData(theme: presentationData.theme, fontSize: presentationData.listsFontSize, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameSortOrder: presentationData.nameSortOrder, nameDisplayOrder: presentationData.nameDisplayOrder, disableAnimations: true)
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.backgroundColor = presentationData.theme.chatList.backgroundColor
        self.presentationDataPromise.set(.single(MattermostPostListControllerNode.listPresentationData(presentationData)))
        self.updateEmptyState()
    }

    func scrollToTop() {
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
    }

    private func update(state: MattermostPostListState, messages: [EngineMessage], presentationData: ChatListPresentationData) {
        self.listState = state
        self.isLoading = state.isLoading
        self.currentMessages = messages
        guard let interaction = self.interaction else {
            return
        }
        var entries: [MattermostPostListEntry] = []
        for (index, message) in messages.enumerated() {
            entries.append(.message(index: index, message: message, presentationData: presentationData))
        }
        let previous = self.previousEntries ?? []
        self.previousEntries = entries
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: previous, rightList: entries)
        let context = self.context
        self.enqueuedTransitions.append((
            deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(context: context, interaction: interaction), directionHint: nil) },
            updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(context: context, interaction: interaction), directionHint: nil) }
        ))
        self.dequeueTransitions()
        self.updateEmptyState()
    }

    private func dequeueTransitions() {
        guard self.validLayout != nil else {
            return
        }
        while !self.enqueuedTransitions.isEmpty {
            let transition = self.enqueuedTransitions.removeFirst()
            var options = ListViewDeleteAndInsertOptions()
            options.insert(.PreferSynchronousDrawing)
            options.insert(.PreferSynchronousResourceLoading)
            self.listNode.transaction(deleteIndices: transition.deletions, insertIndicesAndItems: transition.insertions, updateIndicesAndItems: transition.updates, options: options, updateSizeAndInsets: nil, updateOpaqueState: nil, completion: { _ in })
        }
    }

    private func updateEmptyState() {
        guard let controller = self.controller else {
            return
        }
        let strings = self.presentationData.strings
        let theme = self.presentationData.theme
        var title = ""
        var text = ""
        if self.currentMessages.isEmpty {
            if let state = self.listState, !state.isLoading {
                if state.failed {
                    title = strings.Relay_PostList_FailedTitle
                    text = strings.Relay_PostList_FailedText
                } else if controller.kind == .saved {
                    title = strings.Relay_Saved_EmptyTitle
                    text = strings.Relay_Saved_EmptyText
                } else {
                    title = strings.Relay_Mentions_EmptyTitle
                    text = strings.Relay_Mentions_EmptyText
                }
            } else {
                text = strings.Relay_PostList_Loading
            }
        }
        // Follows the app's text size like the result rows (17 pt is the default).
        let textScale = self.presentationData.listsFontSize.baseDisplaySize / 17.0
        self.emptyTitleNode.attributedText = NSAttributedString(string: title, font: Font.semibold(floor(17.0 * textScale)), textColor: theme.list.freeTextColor)
        self.emptyTextNode.attributedText = NSAttributedString(string: text, font: Font.regular(floor(15.0 * textScale)), textColor: theme.list.freeTextColor)
        if let (layout, navigationBarHeight) = self.validLayout {
            self.layoutEmptyState(layout: layout, navigationBarHeight: navigationBarHeight)
        }
    }

    private func layoutEmptyState(layout: ContainerViewLayout, navigationBarHeight: CGFloat) {
        let width = layout.size.width - layout.safeInsets.left - layout.safeInsets.right - 64.0
        let titleSize = self.emptyTitleNode.updateLayout(CGSize(width: width, height: 100.0))
        let textSize = self.emptyTextNode.updateLayout(CGSize(width: width, height: 400.0))
        let spacing: CGFloat = titleSize.height > 0.0 && textSize.height > 0.0 ? 8.0 : 0.0
        let totalHeight = titleSize.height + spacing + textSize.height
        let top = navigationBarHeight + floor((layout.size.height - navigationBarHeight - totalHeight) / 2.0)
        self.emptyTitleNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - titleSize.width) / 2.0), y: top), size: titleSize)
        self.emptyTextNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - textSize.width) / 2.0), y: top + titleSize.height + spacing), size: textSize)
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationBarHeight)
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: UIEdgeInsets(top: navigationBarHeight, left: layout.safeInsets.left, bottom: layout.intrinsicInsets.bottom, right: layout.safeInsets.right), duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
        self.layoutEmptyState(layout: layout, navigationBarHeight: navigationBarHeight)
        self.dequeueTransitions()
    }

    private func contextItems(message: EngineMessage) -> [ContextMenuItem] {
        guard let controller = self.controller else {
            return []
        }
        let strings = self.presentationData.strings
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: strings.Relay_PostList_ShowInChat, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/GoToMessage"), color: theme.contextMenu.primaryColor)
        }, action: { [weak controller] _, f in
            f(.dismissWithoutContent)
            controller?.open(message: message)
        })))
        if let saved = MattermostSync.isPostSaved(accountId: self.context.account.id, messageId: message.id) {
            items.append(.action(ContextMenuActionItem(text: saved ? strings.Relay_Saved_Unsave : strings.Relay_Saved_Save, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: saved ? "Chat/Context Menu/Unfave" : "Chat/Context Menu/Fave"), color: theme.contextMenu.primaryColor)
            }, action: { [weak controller] _, f in
                f(.default)
                controller?.setSaved(message: message, saved: !saved)
            })))
        }
        return items
    }

    private func makeInteraction() -> ChatListNodeInteraction {
        return ChatListNodeInteraction(context: self.context, animationCache: self.context.animationCache, animationRenderer: self.context.animationRenderer, activateSearch: {
        }, peerSelected: { _, _, _, _, _ in
        }, disabledPeerSelected: { _, _, _ in
        }, togglePeerSelected: { _, _ in
        }, togglePeersSelection: { _, _ in
        }, additionalCategorySelected: { _ in
        }, messageSelected: { [weak self] _, _, message, _ in
            guard let self else {
                return
            }
            self.listNode.clearHighlightAnimated(true)
            self.controller?.open(message: message)
        }, groupSelected: { _ in
        }, addContact: { _ in
        }, setPeerIdWithRevealedOptions: { _, _ in
        }, setItemPinned: { _, _ in
        }, setPeerMuted: { _, _ in
        }, setPeerThreadMuted: { _, _, _ in
        }, deletePeer: { _, _ in
        }, deletePeerThread: { _, _ in
        }, setPeerThreadStopped: { _, _, _ in
        }, setPeerThreadPinned: { _, _, _ in
        }, setPeerThreadHidden: { _, _, _ in
        }, updatePeerGrouping: { _, _ in
        }, togglePeerMarkedUnread: { _, _ in
        }, toggleArchivedFolderHiddenByDefault: {
        }, toggleThreadsSelection: { _, _ in
        }, hidePsa: { _ in
        }, activateChatPreview: { [weak self] item, _, node, gesture, _ in
            guard let self, let controller = self.controller, case let .peer(peerData) = item.content, let message = peerData.messages.first else {
                gesture?.cancel()
                return
            }
            let chatController = self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(id: peerData.peer.peerId), subject: .message(id: .id(message.id), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false), botStart: nil, mode: .standard(.previewing), params: nil)
            chatController.canReadHistory.set(false)
            let contextController = makeContextController(presentationData: self.presentationData, source: .controller(MattermostPostListPreviewSource(controller: chatController, sourceNode: node)), items: .single(ContextController.Items(content: .list(self.contextItems(message: message)))), gesture: gesture)
            controller.presentInGlobalOverlay(contextController)
        }, present: { _ in
        }, openForumThread: { _, _ in
        }, openStorageManagement: {
        }, openPasswordSetup: {
        }, openPremiumIntro: {
        }, openPremiumGift: { _, _ in
        }, openPremiumManagement: {
        }, openActiveSessions: {
        }, openBirthdaySetup: {
        }, performActiveSessionAction: { _, _ in
        }, performBotConnectionReviewAction: { _, _ in
        }, openChatFolderUpdates: {
        }, hideChatFolderUpdates: {
        }, openStories: { _, _ in
        }, openStarsTopup: { _ in
        }, editPeer: { _ in
        }, openWebApp: { _ in
        }, openPhotoSetup: {
        }, openAdInfo: { _, _ in
        }, openAccountFreezeInfo: {
        }, openUrl: { _ in
        })
    }
}

private final class MattermostPostListPreviewSource: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceNode: ASDisplayNode?
    let navigationController: NavigationController? = nil
    let passthroughTouches: Bool = true

    init(controller: ViewController, sourceNode: ASDisplayNode?) {
        self.controller = controller
        self.sourceNode = sourceNode
    }

    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceNode = self.sourceNode
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceNode] in
            if let sourceNode = sourceNode {
                return (sourceNode.view, sourceNode.bounds)
            } else {
                return nil
            }
        })
    }

    func animatedIn() {
    }
}
