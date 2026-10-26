import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import AvatarNode
import MattermostSync

// MATTERMOST: collapsed reply threads (Phase 3B). The threads screen: a team's followed threads (Mattermost's
// "Threads" view), newest reply first, with the root post, its channel, reply count, participants, last reply
// time and unread replies / mentions. A row opens the thread view; a long press offers Mark as Read and Unfollow.
// Opened from the chat list's threads button (ChatListUI), which shows the team's unread threads as its badge.

/// The chat location of a Mattermost thread: a Postbox thread view of the root's local id, filled by
/// MattermostSync (`ChatReplyThreadMessage.isForumPost`, so nothing asks Telegram's server).
public func mattermostThreadLocation(peerId: EnginePeer.Id, threadId: Int64) -> ChatReplyThreadMessage {
    return ChatReplyThreadMessage(peerId: peerId, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false)
}

/// Opens a Mattermost thread view, at `messageId` when given.
public func mattermostOpenThread(context: AccountContext, navigationController: NavigationController, peerId: EnginePeer.Id, threadId: Int64, messageId: EngineMessage.Id?) {
    let subject: ChatControllerSubject? = messageId.map { .message(id: .id($0), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false) }
    context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .replyThread(mattermostThreadLocation(peerId: peerId, threadId: threadId)), subject: subject, keepStack: .always))
}

private final class ThreadsArguments {
    let context: AccountContext
    let open: (MattermostThreadListItem) -> Void
    let longTap: (MattermostThreadListItem) -> Void

    init(context: AccountContext, open: @escaping (MattermostThreadListItem) -> Void, longTap: @escaping (MattermostThreadListItem) -> Void) {
        self.context = context
        self.open = open
        self.longTap = longTap
    }
}

private enum ThreadsEntry: ItemListNodeEntry {
    case header(String)
    case thread(index: Int32, item: MattermostThreadListItem, version: String)
    case info(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: String {
        switch self {
        case .header:
            return "header"
        case let .thread(_, item, _):
            return "thread:" + item.rootPostId
        case .info:
            return "info"
        }
    }

    var sortIndex: Int32 {
        switch self {
        case .header:
            return 0
        case let .thread(index, _, _):
            return 1 + index
        case .info:
            return Int32.max
        }
    }

    static func <(lhs: ThreadsEntry, rhs: ThreadsEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    static func ==(lhs: ThreadsEntry, rhs: ThreadsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a), .header(b)), let (.info(a), .info(b)):
            return a == b
        case let (.thread(lIndex, lItem, lVersion), .thread(rIndex, rItem, rVersion)):
            return lIndex == rIndex && lItem.rootPostId == rItem.rootPostId && lVersion == rVersion
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ThreadsArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .thread(_, item, _):
            return MattermostThreadItem(presentationData: presentationData, context: arguments.context, thread: item, sectionId: self.section, action: {
                arguments.open(item)
            }, longTapAction: {
                arguments.longTap(item)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// What changes a row: everything shown in it.
private func threadVersion(_ item: MattermostThreadListItem) -> String {
    return "\(item.threadId ?? 0)|\(item.replyCount)|\(item.unreadReplies)|\(item.unreadMentions)|\(item.lastReplyAt)|\(item.rootText.hashValue)|\(item.participants.map { "\($0.id.toInt64())" }.joined(separator: ","))|\(item.channelTitle)"
}

private func threadsEntries(list: MattermostThreadList?, strings: PresentationStrings) -> [ThreadsEntry] {
    guard let list = list else {
        return [.info(strings.Relay_Threads_Off)]
    }
    if !list.isLoaded {
        return [.info(strings.Relay_Threads_Loading)]
    }
    if list.items.isEmpty {
        return [.info(strings.Relay_Threads_EmptyTitle + "\n" + strings.Relay_Threads_EmptyText)]
    }
    var entries: [ThreadsEntry] = []
    let unread = list.unreadThreadCount
    let mentions = list.unreadMentionCount
    var summary = list.teamName
    if unread > 0 {
        summary += " · " + strings.Relay_Threads_Unread("\(unread)").string
        if mentions > 0 {
            summary += " · " + strings.Relay_Threads_Mentions(Int32(mentions))
        }
    } else {
        summary += " · " + strings.Relay_Threads_AllRead
    }
    entries.append(.header(summary.uppercased()))
    for (index, item) in list.items.enumerated() {
        entries.append(.thread(index: Int32(index), item: item, version: threadVersion(item)))
    }
    return entries
}

/// The threads screen for a team (`teamId`), with tabs for the account's other teams.
public func mattermostThreadsController(context: AccountContext, teamId: String) -> ViewController {
    let accountId = context.account.id
    let teams = MattermostSync.teams(accountId: accountId)
    let selectedTeam = ValuePromise<String>(teamId, ignoreRepeated: true)
    var selectedTeamValue = teamId
    var navigationControllerImpl: (() -> NavigationController?)?
    var presentControllerImpl: ((ViewController) -> Void)?

    let openThread: (MattermostThreadListItem) -> Void = { item in
        guard let navigationController = navigationControllerImpl?() else {
            return
        }
        if let threadId = item.threadId {
            mattermostOpenThread(context: context, navigationController: navigationController, peerId: item.peerId, threadId: threadId, messageId: nil)
            return
        }
        // The root isn't stored yet: map and load it first.
        let _ = (MattermostSync.threadDestination(accountId: accountId, rootPostId: item.rootPostId)
        |> deliverOnMainQueue).startStandalone(next: { destination in
            guard let destination = destination else {
                return
            }
            mattermostOpenThread(context: context, navigationController: navigationController, peerId: destination.peerId, threadId: destination.threadId, messageId: nil)
        })
    }

    let arguments = ThreadsArguments(context: context, open: openThread, longTap: { item in
        guard let threadId = item.threadId else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: item.rootText)]
        items.append(ActionSheetButtonItem(title: presentationData.strings.Relay_Threads_Unfollow, color: .destructive, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            let _ = MattermostSync.setFollowingThread(accountId: accountId, peerId: item.peerId, threadId: threadId, following: false).startStandalone()
        }))
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    })

    let list = selectedTeam.get()
    |> mapToSignal { teamId -> Signal<MattermostThreadList?, NoError> in
        return MattermostSync.threadList(accountId: accountId, teamId: teamId)
    }

    let signal = combineLatest(context.sharedContext.presentationData, list, selectedTeam.get())
    |> deliverOnMainQueue
    |> map { presentationData, list, teamId -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let title: ItemListControllerTitle
        if teams.count > 1 && teams.count <= 4 {
            title = .textWithTabs(strings.Relay_Threads_Title, teams.map { $0.name }, teams.firstIndex(where: { $0.id == teamId }) ?? 0)
        } else {
            title = .text(strings.Relay_Threads_Title)
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: title, leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: threadsEntries(list: list, strings: strings), style: .plain, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal, tabBarItem: nil)
    controller.titleControlValueChanged = { index in
        if index >= 0 && index < teams.count {
            selectedTeamValue = teams[index].id
            selectedTeam.set(teams[index].id)
            MattermostSync.reloadThreads(accountId: accountId, teamId: teams[index].id)
        }
    }
    navigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }
    controller.didAppear = { firstTime in
        if !firstTime {
            MattermostSync.reloadThreads(accountId: accountId, teamId: selectedTeamValue)
        }
    }
    MattermostSync.reloadThreads(accountId: accountId, teamId: teamId)
    MattermostThreadsDebug.controllerAppeared(open: { index in
        let _ = (list |> take(1) |> deliverOnMainQueue).startStandalone(next: { list in
            if let list = list, index < list.items.count {
                openThread(list.items[index])
            }
        })
    })
    return controller
}

/// Debug only: lets the debug remote open a row of the visible threads screen (no UI automation).
enum MattermostThreadsDebug {
    static var openRow: ((Int) -> Void)?

    static func controllerAppeared(open: @escaping (Int) -> Void) {
        #if DEBUG
        self.openRow = open
        #endif
    }
}

// MARK: - Row

private final class MattermostThreadItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let context: AccountContext
    let thread: MattermostThreadListItem
    let sectionId: ItemListSectionId
    let action: () -> Void
    let longTapAction: () -> Void

    init(presentationData: ItemListPresentationData, context: AccountContext, thread: MattermostThreadListItem, sectionId: ItemListSectionId, action: @escaping () -> Void, longTapAction: @escaping () -> Void) {
        self.presentationData = presentationData
        self.context = context
        self.thread = thread
        self.sectionId = sectionId
        self.action = action
        self.longTapAction = longTapAction
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = MattermostThreadItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? MattermostThreadItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply()
                        })
                    }
                }
            }
        }
    }

    var selectable: Bool = true

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action()
    }
}

private let avatarFont = avatarPlaceholderFont(size: 16.0)
private let participantFont = avatarPlaceholderFont(size: 9.0)

private final class MattermostThreadItemNode: ListViewItemNode, ItemListItemNode {
    private let separatorNode: ASDisplayNode
    private let highlightedBackgroundNode: ASDisplayNode
    private let avatarNode: AvatarNode
    private let authorNode: TextNode
    private let dateNode: TextNode
    private let channelNode: TextNode
    private let textNode: TextNode
    private let footerNode: TextNode
    private let unreadDotNode: ASImageNode
    private var participantNodes: [AvatarNode] = []
    private var item: MattermostThreadItem?

    var tag: ItemListItemTag? {
        return nil
    }

    init() {
        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true
        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true
        self.avatarNode = AvatarNode(font: avatarFont)
        self.authorNode = TextNode()
        self.dateNode = TextNode()
        self.channelNode = TextNode()
        self.textNode = TextNode()
        self.footerNode = TextNode()
        self.unreadDotNode = ASImageNode()
        self.unreadDotNode.displaysAsynchronously = false
        for node in [self.authorNode, self.dateNode, self.channelNode, self.textNode, self.footerNode] {
            node.isUserInteractionEnabled = false
            node.contentsScale = UIScreen.main.scale
        }
        super.init(layerBacked: false)
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.authorNode)
        self.addSubnode(self.dateNode)
        self.addSubnode(self.channelNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.footerNode)
        self.addSubnode(self.unreadDotNode)
    }

    func asyncLayout() -> (_ item: MattermostThreadItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeAuthor = TextNode.asyncLayout(self.authorNode)
        let makeDate = TextNode.asyncLayout(self.dateNode)
        let makeChannel = TextNode.asyncLayout(self.channelNode)
        let makeText = TextNode.asyncLayout(self.textNode)
        let makeFooter = TextNode.asyncLayout(self.footerNode)

        return { [weak self] item, params, neighbors in
            let theme = item.presentationData.theme
            let strings = item.presentationData.strings
            let thread = item.thread
            let isUnread = thread.unreadReplies > 0
            let leftInset: CGFloat = params.leftInset + 16.0 + 44.0 + 12.0
            let rightInset: CGFloat = params.rightInset + 16.0
            let width = params.width - leftInset - rightInset

            let dateText = stringForThreadDate(thread.lastReplyAt)
            let (dateLayout, dateApply) = makeDate(TextNodeLayoutArguments(attributedString: NSAttributedString(string: dateText, font: Font.regular(14.0), textColor: isUnread ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width, height: 100.0)))
            let authorName = thread.author.map { EnginePeer($0).displayTitle(strings: strings, displayOrder: item.presentationData.nameDisplayOrder) } ?? ""
            let (authorLayout, authorApply) = makeAuthor(TextNodeLayoutArguments(attributedString: NSAttributedString(string: authorName, font: Font.semibold(16.0), textColor: theme.list.itemPrimaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width - dateLayout.size.width - 8.0, height: 100.0)))
            let (channelLayout, channelApply) = makeChannel(TextNodeLayoutArguments(attributedString: NSAttributedString(string: thread.channelTitle, font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width, height: 100.0)))
            let (textLayout, textApply) = makeText(TextNodeLayoutArguments(attributedString: NSAttributedString(string: thread.rootText, font: Font.regular(15.0), textColor: theme.list.itemPrimaryTextColor), maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: width, height: 100.0)))

            let footer = NSMutableAttributedString(string: strings.Relay_Threads_Replies(Int32(thread.replyCount)), font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)
            if thread.unreadReplies > 0 {
                footer.append(NSAttributedString(string: " · " + strings.Relay_Threads_NewReplies(Int32(thread.unreadReplies)), font: Font.semibold(13.0), textColor: theme.list.itemAccentColor))
            }
            if thread.unreadMentions > 0 {
                footer.append(NSAttributedString(string: " · @" + strings.Relay_Threads_Mentions(Int32(thread.unreadMentions)), font: Font.semibold(13.0), textColor: theme.list.itemAccentColor))
            }
            let participantCount = min(3, thread.participants.count)
            let participantsWidth: CGFloat = participantCount == 0 ? 0.0 : 20.0 + CGFloat(participantCount - 1) * 14.0 + 6.0
            let (footerLayout, footerApply) = makeFooter(TextNodeLayoutArguments(attributedString: footer, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width - participantsWidth, height: 100.0)))

            let topInset: CGFloat = 10.0
            var height = topInset + authorLayout.size.height + 1.0 + channelLayout.size.height + 3.0
            height += textLayout.size.height + 6.0 + max(20.0, footerLayout.size.height) + 10.0
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: itemListNeighborsPlainInsets(neighbors))

            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                self.item = item
                self.separatorNode.backgroundColor = theme.list.itemPlainSeparatorColor
                self.highlightedBackgroundNode.backgroundColor = theme.list.itemHighlightedBackgroundColor
                let _ = authorApply()
                let _ = dateApply()
                let _ = channelApply()
                let _ = textApply()
                let _ = footerApply()

                self.avatarNode.frame = CGRect(x: params.leftInset + 16.0, y: topInset + 2.0, width: 44.0, height: 44.0)
                self.avatarNode.setPeer(context: item.context, theme: theme, peer: thread.author.map(EnginePeer.init), displayDimensions: CGSize(width: 44.0, height: 44.0))

                var y = topInset
                self.authorNode.frame = CGRect(origin: CGPoint(x: leftInset, y: y), size: authorLayout.size)
                self.dateNode.frame = CGRect(origin: CGPoint(x: params.width - rightInset - dateLayout.size.width, y: y + 1.0), size: dateLayout.size)
                y += authorLayout.size.height + 1.0
                self.channelNode.frame = CGRect(origin: CGPoint(x: leftInset, y: y), size: channelLayout.size)
                y += channelLayout.size.height + 3.0
                self.textNode.frame = CGRect(origin: CGPoint(x: leftInset, y: y), size: textLayout.size)
                y += textLayout.size.height + 6.0

                while self.participantNodes.count < participantCount {
                    let node = AvatarNode(font: participantFont)
                    self.participantNodes.append(node)
                    self.addSubnode(node)
                }
                for (index, node) in self.participantNodes.enumerated() {
                    if index < participantCount {
                        node.isHidden = false
                        node.frame = CGRect(x: leftInset + CGFloat(index) * 14.0, y: y, width: 20.0, height: 20.0)
                        node.setPeer(context: item.context, theme: theme, peer: EnginePeer(thread.participants[index]), displayDimensions: CGSize(width: 20.0, height: 20.0))
                    } else {
                        node.isHidden = true
                    }
                }
                self.footerNode.frame = CGRect(origin: CGPoint(x: leftInset + participantsWidth, y: y + floor((20.0 - footerLayout.size.height) / 2.0)), size: footerLayout.size)

                if isUnread || thread.unreadMentions > 0 {
                    self.unreadDotNode.image = generateFilledCircleImage(diameter: 8.0, color: theme.list.itemAccentColor)
                    self.unreadDotNode.isHidden = false
                    self.unreadDotNode.frame = CGRect(x: params.leftInset + 4.0, y: topInset + 20.0, width: 8.0, height: 8.0)
                } else {
                    self.unreadDotNode.isHidden = true
                }

                let separatorHeight = UIScreenPixel
                self.separatorNode.frame = CGRect(x: leftInset, y: height - separatorHeight, width: params.width - leftInset, height: separatorHeight)
                self.highlightedBackgroundNode.frame = CGRect(x: 0.0, y: -UIScreenPixel, width: params.width, height: height + UIScreenPixel)
            })
        }
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        if highlighted {
            self.highlightedBackgroundNode.alpha = 1.0
            if self.highlightedBackgroundNode.supernode == nil {
                self.insertSubnode(self.highlightedBackgroundNode, at: 0)
            }
        } else if self.highlightedBackgroundNode.supernode != nil {
            if animated {
                self.highlightedBackgroundNode.layer.animateAlpha(from: self.highlightedBackgroundNode.alpha, to: 0.0, duration: 0.4, completion: { [weak self] completed in
                    if completed {
                        self?.highlightedBackgroundNode.removeFromSupernode()
                    }
                })
                self.highlightedBackgroundNode.alpha = 0.0
            } else {
                self.highlightedBackgroundNode.removeFromSupernode()
            }
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }

    override func longTapped() {
        self.item?.longTapAction()
    }

    override var canBeLongTapped: Bool {
        return true
    }
}

/// "14:05" today, the weekday this week, else the date (as the chat list shows times).
private func stringForThreadDate(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
    let calendar = Calendar.current
    let formatter = DateFormatter()
    if calendar.isDateInToday(date) {
        formatter.timeStyle = .short
        formatter.dateStyle = .none
    } else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        formatter.setLocalizedDateFormatFromTemplate("EEE")
    } else {
        formatter.dateStyle = .short
        formatter.timeStyle = .none
    }
    return formatter.string(from: date)
}
