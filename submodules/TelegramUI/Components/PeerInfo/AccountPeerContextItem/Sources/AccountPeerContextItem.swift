import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ContextUI
import AvatarNode
import EmojiStatusComponent
import AccountContext

public final class AccountPeerContextItem: ContextMenuCustomItem {
    let context: AccountContext
    let account: Account
    let peer: EnginePeer
    let action: (ContextControllerProtocol, @escaping (ContextMenuActionResult) -> Void) -> Void
    
    public  init(context: AccountContext, account: Account, peer: EnginePeer, action: @escaping (ContextControllerProtocol, @escaping (ContextMenuActionResult) -> Void) -> Void) {
        self.context = context
        self.account = account
        self.peer = peer
        self.action = action
    }
    
    public func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        return AccountPeerContextItemNode(presentationData: presentationData, item: self, getController: getController, actionSelected: actionSelected)
    }
}

private final class AccountPeerContextItemNode: ASDisplayNode, ContextMenuCustomNode {
    private let item: AccountPeerContextItem
    private let presentationData: PresentationData
    private let getController: () -> ContextControllerProtocol?
    private let actionSelected: (ContextMenuActionResult) -> Void
    
    private let buttonNode: HighlightTrackingButtonNode
    private let textNode: ImmediateTextNode
    // MATTERMOST: the account's server under the name (4H).
    private let subtitleNode: ImmediateTextNode?
    private let avatarNode: AvatarNode
    private let emojiStatusView: ComponentView<Empty>
    
    init(presentationData: PresentationData, item: AccountPeerContextItem, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.item = item
        self.presentationData = presentationData
        self.getController = getController
        self.actionSelected = actionSelected
        
        let textFont = Font.regular(presentationData.listsFontSize.baseDisplaySize * 17.0 / 17.0)
        
        self.textNode = ImmediateTextNode()
        self.textNode.isAccessibilityElement = false
        self.textNode.isUserInteractionEnabled = false
        self.textNode.displaysAsynchronously = false
        let peerTitle = item.peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        self.textNode.attributedText = NSAttributedString(string: peerTitle, font: textFont, textColor: presentationData.theme.contextMenu.primaryColor)
        self.textNode.maximumNumberOfLines = 1
        
        // MATTERMOST: the account's server under the name (4H), so the same user on two servers can be told apart.
        let serverLabel = MattermostUIHooks.accountServerLabel?(item.account.peerId)
        if let serverLabel {
            let subtitleNode = ImmediateTextNode()
            subtitleNode.isAccessibilityElement = false
            subtitleNode.isUserInteractionEnabled = false
            subtitleNode.displaysAsynchronously = false
            subtitleNode.attributedText = NSAttributedString(string: serverLabel, font: Font.regular(presentationData.listsFontSize.baseDisplaySize * 13.0 / 17.0), textColor: presentationData.theme.contextMenu.secondaryColor)
            subtitleNode.maximumNumberOfLines = 1
            self.subtitleNode = subtitleNode
        } else {
            self.subtitleNode = nil
        }
        
        self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 14.0))
        
        self.emojiStatusView = ComponentView<Empty>()
        
        self.buttonNode = HighlightTrackingButtonNode()
        self.buttonNode.isAccessibilityElement = true
        self.buttonNode.accessibilityLabel = serverLabel.flatMap { peerTitle + ", " + $0 } ?? peerTitle
        
        super.init()
        
        self.addSubnode(self.textNode)
        if let subtitleNode = self.subtitleNode {
            self.addSubnode(subtitleNode)
        }
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.buttonNode)
        
        self.buttonNode.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let sideInset: CGFloat = 18.0
        let iconSideInset: CGFloat = 20.0
        let verticalInset: CGFloat = 11.0
        
        let iconSize = CGSize(width: 28.0, height: 28.0)
        
        let standardIconWidth: CGFloat = 32.0
        var rightTextInset: CGFloat = sideInset
        if !iconSize.width.isZero {
            rightTextInset = max(iconSize.width, standardIconWidth) + iconSideInset + sideInset - 12.0
        }
        
        self.avatarNode.setPeer(context: self.item.context, account: self.item.account, theme: self.presentationData.theme, peer: self.item.peer)
        
        if self.item.peer.emojiStatus != nil {
            rightTextInset += 32.0
        }
    
        let textSize = self.textNode.updateLayout(CGSize(width: constrainedWidth - sideInset - rightTextInset, height: .greatestFiniteMagnitude))
        // MATTERMOST: the server line (4H).
        let subtitleSize = self.subtitleNode?.updateLayout(CGSize(width: constrainedWidth - sideInset - rightTextInset + (self.item.peer.emojiStatus != nil ? 32.0 : 0.0), height: .greatestFiniteMagnitude)) ?? .zero
        let subtitleSpacing: CGFloat = self.subtitleNode != nil ? 1.0 : 0.0
        let contentHeight = textSize.height + subtitleSpacing + subtitleSize.height
        
        return (CGSize(width: max(textSize.width, subtitleSize.width) + sideInset + rightTextInset, height: verticalInset * 2.0 + contentHeight), { size, transition in
            let verticalOrigin = floor((size.height - contentHeight) / 2.0)
            let textFrame = CGRect(origin: CGPoint(x: iconSideInset + 40.0, y: verticalOrigin), size: textSize)
            transition.updateFrameAdditive(node: self.textNode, frame: textFrame)
            if let subtitleNode = self.subtitleNode {
                transition.updateFrameAdditive(node: subtitleNode, frame: CGRect(origin: CGPoint(x: textFrame.minX, y: textFrame.maxY + subtitleSpacing), size: subtitleSize))
            }
            
            var iconContent: EmojiStatusComponent.Content?
            if case let .user(user) = self.item.peer {
                if let emojiStatus = user.emojiStatus {
                    iconContent = .animation(content: .customEmoji(fileId: emojiStatus.fileId), size: CGSize(width: 28.0, height: 28.0), placeholderColor: self.presentationData.theme.list.mediaPlaceholderColor, themeColor: self.presentationData.theme.list.itemAccentColor, loopMode: .forever)
                } else if user.isPremium {
                    iconContent = .premium(color: self.presentationData.theme.list.itemAccentColor)
                }
            } else if case let .channel(channel) = self.item.peer {
                if let emojiStatus = channel.emojiStatus {
                    iconContent = .animation(content: .customEmoji(fileId: emojiStatus.fileId), size: CGSize(width: 28.0, height: 28.0), placeholderColor: self.presentationData.theme.list.mediaPlaceholderColor, themeColor: self.presentationData.theme.list.itemAccentColor, loopMode: .forever)
                }
            }
            if let iconContent {
                let emojiStatusSize = self.emojiStatusView.update(
                    transition: .immediate,
                    component: AnyComponent(EmojiStatusComponent(
                        context: self.item.context,
                        animationCache: self.item.context.animationCache,
                        animationRenderer: self.item.context.animationRenderer,
                        content: iconContent,
                        isVisibleForAnimations: true,
                        action: nil
                    )),
                    environment: {},
                    containerSize: CGSize(width: 24.0, height: 24.0)
                )
                if let view = self.emojiStatusView.view {
                    if view.superview == nil {
                        self.view.addSubview(view)
                    }
                    transition.updateFrame(view: view, frame: CGRect(origin: CGPoint(x: textFrame.maxX + 2.0, y: textFrame.minY + floor((textFrame.height - emojiStatusSize.height) / 2.0)), size: emojiStatusSize))
                }
            }
            
            transition.updateFrame(node: self.avatarNode, frame: CGRect(origin: CGPoint(x: iconSideInset + floor((standardIconWidth - iconSize.width) / 2.0), y: floor((size.height - iconSize.height) / 2.0)), size: iconSize))
            
            transition.updateFrame(node: self.buttonNode, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: size.width, height: size.height)))
        })
    }
    
    func updateTheme(presentationData: PresentationData) {
        if let attributedText = self.textNode.attributedText {
            let updatedAttributedText = NSMutableAttributedString(attributedString: attributedText)
            updatedAttributedText.addAttribute(.foregroundColor, value: presentationData.theme.contextMenu.primaryColor.cgColor, range: NSRange(location: 0, length: updatedAttributedText.length))
            self.textNode.attributedText = updatedAttributedText
        }
        // MATTERMOST: the server line (4H).
        if let subtitleNode = self.subtitleNode, let attributedText = subtitleNode.attributedText {
            let updatedAttributedText = NSMutableAttributedString(attributedString: attributedText)
            updatedAttributedText.addAttribute(.foregroundColor, value: presentationData.theme.contextMenu.secondaryColor, range: NSRange(location: 0, length: updatedAttributedText.length))
            subtitleNode.attributedText = updatedAttributedText
        }
    }
    
    @objc private func buttonPressed() {
        self.performAction()
    }
    
    func canBeHighlighted() -> Bool {
        return true
    }
    
    func setIsHighlighted(_ value: Bool) {
    }
    
    func updateIsHighlighted(isHighlighted: Bool) {
        self.setIsHighlighted(isHighlighted)
    }
    
    func performAction() {
        guard let controller = self.getController() else {
            return
        }
        self.item.action(controller, { [weak self] result in
            self?.actionSelected(result)
        })
    }
}
