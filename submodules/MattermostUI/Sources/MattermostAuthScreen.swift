import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import SolidRoundedButtonNode

/// One text field of an auth screen.
struct MattermostAuthField {
    enum Kind {
        case serverAddress
        case loginId
        case password
    }

    let id: String
    let kind: Kind
    let placeholder: String
    var text: String
}

/// What an auth screen shows, top to bottom.
struct MattermostAuthScreenContent {
    var showsLogo: Bool
    var title: String
    var text: String
    var fields: [MattermostAuthField]
    /// The main button ("Connect", "Log In"); nil hides it (SSO-only servers).
    var primaryTitle: String?
    /// Further ways in (SSO providers), below an "or" divider: (id, title).
    var alternatives: [(id: String, title: String)]
    var footer: String?
}

/// A screen in the look of Telegram's own login (title, short text, fields, a big button), used for the
/// server and credentials steps. Everything sits in a scroll view that keeps the focused field and the
/// button above the keyboard.
final class MattermostAuthScreen: ViewController {
    #if DEBUG
    let debugScreenName: String
    #endif
    private let sharedContext: SharedAccountContext
    private let presentationData: PresentationData
    private let content: MattermostAuthScreenContent

    var primaryAction: (() -> Void)?
    var alternativeAction: ((String) -> Void)?
    var cancelAction: (() -> Void)? {
        didSet {
            self.updateCancelButton()
        }
    }

    private var screenNode: MattermostAuthScreenNode {
        return self.displayNode as! MattermostAuthScreenNode
    }

    private var validLayout: ContainerViewLayout?
    private var didActivateInput = false

    var inProgress: Bool = false {
        didSet {
            if self.isNodeLoaded {
                self.screenNode.inProgress = self.inProgress
            }
            self.navigationItem.leftBarButtonItem?.isEnabled = !self.inProgress
        }
    }

    init(debugScreenName: String, sharedContext: SharedAccountContext, presentationData: PresentationData, content: MattermostAuthScreenContent) {
        #if DEBUG
        self.debugScreenName = debugScreenName
        #endif
        self.sharedContext = sharedContext
        self.presentationData = presentationData
        self.content = content

        super.init(navigationBarPresentationData: RelayBranding.navigationBarPresentationData(presentationData))

        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.statusBar.statusBarStyle = presentationData.theme.intro.statusBarStyle.style
        self.hasActiveInput = true
        self.attemptNavigation = { [weak self] _ in
            return !(self?.inProgress ?? false)
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateCancelButton() {
        if self.cancelAction != nil {
            let item = UIBarButtonItem(title: self.presentationData.strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
            item.accessibilityLabel = self.presentationData.strings.Common_Cancel
            self.navigationItem.leftBarButtonItem = item
        } else {
            self.navigationItem.leftBarButtonItem = nil
        }
    }

    @objc private func cancelPressed() {
        if !self.inProgress {
            self.view.endEditing(true)
            self.cancelAction?()
        }
    }

    override func loadDisplayNode() {
        self.displayNode = MattermostAuthScreenNode(presentationData: self.presentationData, content: self.content)
        self.displayNodeDidLoad()
        self.screenNode.view.disableAutomaticKeyboardHandling = [.forward, .backward]
        self.screenNode.primaryAction = { [weak self] in
            self?.primaryAction?()
        }
        self.screenNode.alternativeAction = { [weak self] id in
            self?.alternativeAction?(id)
        }
        self.screenNode.inProgress = self.inProgress
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        MattermostDebugRemote.screenAppeared(self)
        #endif
        if !self.didActivateInput {
            self.didActivateInput = true
            self.screenNode.activateInput()
        }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        self.screenNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }

    func text(field id: String) -> String {
        return self.screenNode.text(field: id)
    }

    func setText(_ text: String, field id: String) {
        self.screenNode.setText(text, field: id)
    }

    func focus(field id: String) {
        self.screenNode.focus(field: id)
    }

    func animateError(field id: String?) {
        self.screenNode.animateError(field: id)
        HapticFeedback().error()
    }

    private weak var presentedAlert: ViewController?

    func presentAlert(title: String?, text: String) {
        let alert = textAlertController(sharedContext: self.sharedContext, title: title, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})])
        self.presentedAlert = alert
        self.present(alert, in: .window(.root))
    }

    /// Presents a confirmation alert whose default action the debug remote can press (`press button=confirm`).
    func presentConfirmation(_ alert: ViewController, confirm: @escaping () -> Void) {
        #if DEBUG
        self.debugConfirmation = (alert, confirm)
        #endif
        self.present(alert, in: .window(.root))
    }

    /// After a successful login: empties password fields the debug remote filled, so iOS doesn't offer to
    /// save the password (that sheet would cover scripted screenshots). Typed passwords stay untouched.
    func clearDebugFilledPasswords() {
        #if DEBUG
        for field in self.debugFilledPasswordFields {
            self.setText("", field: field)
        }
        self.debugFilledPasswordFields.removeAll()
        #endif
    }

    // MARK: MattermostDebugDrivable (debug builds only, Phase 4A)

    #if DEBUG
    private var debugConfirmation: (alert: ViewController, action: () -> Void)?
    private var debugFilledPasswordFields = Set<String>()

    func debugDismissAlerts() -> Bool {
        guard let alert = self.presentedAlert else {
            return false
        }
        alert.dismiss()
        self.presentedAlert = nil
        return true
    }

    func debugFill(field: String, text: String) -> Bool {
        guard let fieldDescription = self.content.fields.first(where: { $0.id == field }) else {
            return false
        }
        if case .password = fieldDescription.kind {
            self.debugFilledPasswordFields.insert(field)
        }
        self.setText(text, field: field)
        return true
    }

    func debugPress(button: String) -> Bool {
        switch button {
        case "primary":
            guard self.content.primaryTitle != nil, !self.inProgress else {
                return false
            }
            self.view.endEditing(true)
            self.primaryAction?()
            return true
        case "cancel":
            guard self.cancelAction != nil else {
                return false
            }
            self.cancelPressed()
            return true
        case "back":
            guard !self.inProgress, let navigationController = self.navigationController, navigationController.viewControllers.count > 1 else {
                return false
            }
            navigationController.popViewController(animated: true)
            return true
        case "confirm":
            guard let confirmation = self.debugConfirmation else {
                return false
            }
            self.debugConfirmation = nil
            confirmation.alert.dismiss()
            confirmation.action()
            return true
        default:
            guard self.content.alternatives.contains(where: { $0.id == button }) else {
                return false
            }
            self.alternativeAction?(button)
            return true
        }
    }
    #endif
}

#if DEBUG
extension MattermostAuthScreen: MattermostDebugDrivable {
}
#endif

private final class MattermostDividerNode: ASDisplayNode {
    private let titleNode: ImmediateTextNode
    private let leftLineNode: ASDisplayNode
    private let rightLineNode: ASDisplayNode

    init(theme: PresentationTheme) {
        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.attributedText = NSAttributedString(string: "or", font: Font.regular(15.0), textColor: theme.list.itemSecondaryTextColor)
        self.leftLineNode = ASDisplayNode()
        self.leftLineNode.backgroundColor = theme.list.itemPlainSeparatorColor
        self.rightLineNode = ASDisplayNode()
        self.rightLineNode.backgroundColor = theme.list.itemPlainSeparatorColor
        super.init()
        self.isAccessibilityElement = false
        self.addSubnode(self.titleNode)
        self.addSubnode(self.leftLineNode)
        self.addSubnode(self.rightLineNode)
    }

    func updateLayout(width: CGFloat) -> CGSize {
        let height: CGFloat = 36.0
        let spacing: CGFloat = 10.0
        let titleSize = self.titleNode.updateLayout(CGSize(width: width, height: height))
        let titleFrame = CGRect(origin: CGPoint(x: floor((width - titleSize.width) / 2.0), y: floor((height - titleSize.height) / 2.0)), size: titleSize)
        self.titleNode.frame = titleFrame
        let lineY = floorToScreenPixels(height / 2.0)
        self.leftLineNode.frame = CGRect(x: 0.0, y: lineY, width: max(0.0, titleFrame.minX - spacing), height: UIScreenPixel)
        self.rightLineNode.frame = CGRect(x: titleFrame.maxX + spacing, y: lineY, width: max(0.0, width - titleFrame.maxX - spacing), height: UIScreenPixel)
        return CGSize(width: width, height: height)
    }
}

final class MattermostAuthScreenNode: ASDisplayNode, UITextFieldDelegate {
    private let presentationData: PresentationData
    private let content: MattermostAuthScreenContent

    private let scrollNode: ASScrollNode
    private let logoNode: ASImageNode
    private let titleNode: ImmediateTextNode
    private let textNode: ImmediateTextNode
    private let fieldBackgroundNodes: [ASDisplayNode]
    private let fieldNodes: [TextFieldNode]
    private let primaryButton: SolidRoundedButtonNode?
    private let dividerNode: MattermostDividerNode?
    private let alternativeButtons: [SolidRoundedButtonNode]
    private let footerNode: ImmediateTextNode

    var primaryAction: (() -> Void)?
    var alternativeAction: ((String) -> Void)?

    private var layoutArguments: (ContainerViewLayout, CGFloat)?

    var inProgress: Bool = false {
        didSet {
            guard self.inProgress != oldValue else {
                return
            }
            for fieldNode in self.fieldNodes {
                fieldNode.textField.isEnabled = !self.inProgress
                fieldNode.alpha = self.inProgress ? 0.6 : 1.0
            }
            for button in self.alternativeButtons {
                button.isEnabled = !self.inProgress
            }
            if self.inProgress {
                self.primaryButton?.transitionToProgress()
            } else {
                self.primaryButton?.transitionFromProgress()
            }
        }
    }

    init(presentationData: PresentationData, content: MattermostAuthScreenContent) {
        self.presentationData = presentationData
        self.content = content
        let theme = presentationData.theme

        self.scrollNode = ASScrollNode()

        self.logoNode = ASImageNode()
        self.logoNode.displaysAsynchronously = false
        self.logoNode.image = content.showsLogo ? RelayBranding.logoImage(size: 76.0) : nil
        self.logoNode.isAccessibilityElement = true
        self.logoNode.accessibilityLabel = RelayBranding.appName
        self.logoNode.accessibilityTraits = .image

        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 2
        self.titleNode.textAlignment = .center
        self.titleNode.attributedText = NSAttributedString(string: content.title, font: Font.bold(28.0), textColor: theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        self.titleNode.isAccessibilityElement = true
        self.titleNode.accessibilityLabel = content.title
        self.titleNode.accessibilityTraits = .header

        self.textNode = ImmediateTextNode()
        self.textNode.maximumNumberOfLines = 0
        self.textNode.textAlignment = .center
        self.textNode.lineSpacing = 0.1
        self.textNode.attributedText = NSAttributedString(string: content.text, font: Font.regular(16.0), textColor: theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        self.textNode.isAccessibilityElement = true
        self.textNode.accessibilityLabel = content.text

        var fieldBackgroundNodes: [ASDisplayNode] = []
        var fieldNodes: [TextFieldNode] = []
        for _ in content.fields {
            let background = ASDisplayNode()
            background.backgroundColor = theme.list.itemInputField.backgroundColor
            background.cornerRadius = 12.0
            background.isLayerBacked = true
            fieldBackgroundNodes.append(background)

            let fieldNode = TextFieldNode()
            fieldNodes.append(fieldNode)
        }
        self.fieldBackgroundNodes = fieldBackgroundNodes
        self.fieldNodes = fieldNodes

        let buttonTheme = SolidRoundedButtonTheme(theme: theme)
        if let primaryTitle = content.primaryTitle {
            let button = SolidRoundedButtonNode(title: primaryTitle, theme: buttonTheme, glass: false, height: 50.0, cornerRadius: 25.0)
            button.progressType = .embedded
            button.accessibilityLabel = primaryTitle
            self.primaryButton = button
        } else {
            self.primaryButton = nil
        }

        if !content.alternatives.isEmpty {
            self.dividerNode = content.primaryTitle != nil ? MattermostDividerNode(theme: theme) : nil
            let alternativeTheme = SolidRoundedButtonTheme(backgroundColor: theme.list.itemInputField.backgroundColor, foregroundColor: theme.list.itemAccentColor)
            self.alternativeButtons = content.alternatives.map { alternative in
                let button = SolidRoundedButtonNode(title: alternative.title, theme: alternativeTheme, glass: false, font: .regular, height: 50.0, cornerRadius: 25.0)
                button.accessibilityLabel = alternative.title
                return button
            }
        } else {
            self.dividerNode = nil
            self.alternativeButtons = []
        }

        self.footerNode = ImmediateTextNode()
        self.footerNode.maximumNumberOfLines = 0
        self.footerNode.textAlignment = .center
        self.footerNode.attributedText = content.footer.flatMap { NSAttributedString(string: $0, font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor, paragraphAlignment: .center) }
        self.footerNode.isAccessibilityElement = content.footer != nil
        self.footerNode.accessibilityLabel = content.footer

        super.init()

        self.setViewBlock({
            return UITracingLayerView()
        })
        self.backgroundColor = theme.list.plainBackgroundColor

        self.addSubnode(self.scrollNode)
        self.scrollNode.addSubnode(self.logoNode)
        self.scrollNode.addSubnode(self.titleNode)
        self.scrollNode.addSubnode(self.textNode)
        for background in self.fieldBackgroundNodes {
            self.scrollNode.addSubnode(background)
        }
        for fieldNode in self.fieldNodes {
            self.scrollNode.addSubnode(fieldNode)
        }
        if let primaryButton = self.primaryButton {
            self.scrollNode.addSubnode(primaryButton)
            primaryButton.pressed = { [weak self] in
                self?.primaryPressed()
            }
        }
        if let dividerNode = self.dividerNode {
            self.scrollNode.addSubnode(dividerNode)
        }
        for (index, button) in self.alternativeButtons.enumerated() {
            self.scrollNode.addSubnode(button)
            let id = content.alternatives[index].id
            button.pressed = { [weak self] in
                guard let self, !self.inProgress else {
                    return
                }
                self.view.endEditing(true)
                self.alternativeAction?(id)
            }
        }
        self.scrollNode.addSubnode(self.footerNode)
    }

    override func didLoad() {
        super.didLoad()

        let theme = self.presentationData.theme
        self.scrollNode.view.alwaysBounceVertical = true
        self.scrollNode.view.keyboardDismissMode = .onDrag
        self.scrollNode.view.contentInsetAdjustmentBehavior = .never
        self.scrollNode.view.showsHorizontalScrollIndicator = false

        for (index, field) in self.content.fields.enumerated() {
            let textField = self.fieldNodes[index].textField
            textField.font = Font.regular(17.0)
            textField.textColor = theme.list.itemPrimaryTextColor
            textField.tintColor = theme.list.itemAccentColor
            textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
            textField.attributedPlaceholder = NSAttributedString(string: field.placeholder, font: Font.regular(17.0), textColor: theme.list.itemInputField.placeholderColor)
            textField.accessibilityLabel = field.placeholder
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            textField.spellCheckingType = .no
            textField.clearButtonMode = .whileEditing
            textField.disableAutomaticKeyboardHandling = [.forward, .backward]
            textField.text = field.text
            switch field.kind {
            case .serverAddress:
                textField.keyboardType = .URL
                textField.textContentType = .URL
                textField.returnKeyType = .go
            case .loginId:
                textField.keyboardType = .emailAddress
                textField.textContentType = .username
                textField.returnKeyType = index + 1 < self.content.fields.count ? .next : .go
            case .password:
                textField.isSecureTextEntry = true
                textField.textContentType = .password
                textField.returnKeyType = .go
            }
            textField.delegate = self
        }
    }

    func text(field id: String) -> String {
        guard let index = self.content.fields.firstIndex(where: { $0.id == id }) else {
            return ""
        }
        return self.fieldNodes[index].textField.text ?? ""
    }

    func setText(_ text: String, field id: String) {
        guard let index = self.content.fields.firstIndex(where: { $0.id == id }) else {
            return
        }
        self.fieldNodes[index].textField.text = text
    }

    func focus(field id: String) {
        guard let index = self.content.fields.firstIndex(where: { $0.id == id }) else {
            return
        }
        self.fieldNodes[index].textField.becomeFirstResponder()
    }

    func activateInput() {
        if let index = self.content.fields.firstIndex(where: { $0.text.isEmpty }) ?? (self.fieldNodes.isEmpty ? nil : 0) {
            self.fieldNodes[index].textField.becomeFirstResponder()
        }
    }

    func animateError(field id: String?) {
        if let id = id, let index = self.content.fields.firstIndex(where: { $0.id == id }) {
            self.fieldBackgroundNodes[index].layer.addShakeAnimation()
            self.fieldNodes[index].layer.addShakeAnimation()
        }
    }

    private func primaryPressed() {
        guard !self.inProgress else {
            return
        }
        self.primaryAction?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let index = self.fieldNodes.firstIndex(where: { $0.textField === textField }) else {
            return false
        }
        if index + 1 < self.fieldNodes.count {
            self.fieldNodes[index + 1].textField.becomeFirstResponder()
        } else {
            self.primaryPressed()
        }
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let (layout, navigationHeight) = self.layoutArguments {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .animated(duration: 0.3, curve: .spring))
        }
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let previousInputHeight = self.layoutArguments?.0.inputHeight ?? 0.0
        self.layoutArguments = (layout, navigationHeight)

        let size = layout.size
        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: size))

        let sideInset: CGFloat = 24.0 + max(layout.safeInsets.left, layout.safeInsets.right)
        let contentWidth = min(size.width - sideInset * 2.0, 420.0)
        let originX = floor((size.width - contentWidth) / 2.0)

        // Measure.
        let logoSize = self.content.showsLogo ? CGSize(width: 76.0, height: 76.0) : CGSize()
        let titleSize = self.titleNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let textSize = self.textNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let fieldHeight: CGFloat = 52.0
        let fieldSpacing: CGFloat = 12.0
        let primaryHeight = self.primaryButton?.updateLayout(width: contentWidth, transition: transition) ?? 0.0
        let dividerSize = self.dividerNode?.updateLayout(width: contentWidth) ?? CGSize()
        let alternativeHeights = self.alternativeButtons.map { $0.updateLayout(width: contentWidth, transition: transition) }
        let footerSize = self.footerNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))

        var contentHeight: CGFloat = 0.0
        if self.content.showsLogo {
            contentHeight += logoSize.height + 20.0
        }
        contentHeight += titleSize.height + 10.0 + textSize.height + 28.0
        if !self.fieldNodes.isEmpty {
            contentHeight += CGFloat(self.fieldNodes.count) * (fieldHeight + fieldSpacing) + 8.0
        }
        if self.primaryButton != nil {
            contentHeight += primaryHeight
        }
        if !alternativeHeights.isEmpty {
            contentHeight += (self.dividerNode != nil ? 12.0 + dividerSize.height + 12.0 : 0.0)
            contentHeight += alternativeHeights.reduce(0.0, +) + CGFloat(alternativeHeights.count - 1) * 12.0
        }
        if footerSize.height > 0.0 {
            contentHeight += 24.0 + footerSize.height
        }

        let inputHeight = layout.inputHeight ?? 0.0
        let bottomInset = max(layout.intrinsicInsets.bottom, inputHeight)
        let topInset = navigationHeight + 8.0
        let availableHeight = size.height - topInset - bottomInset - 16.0
        // Without the keyboard, the content sits a little above the middle; with it, at the top.
        let extraTop = inputHeight > 0.0 ? 0.0 : max(0.0, floor((availableHeight - contentHeight) * 0.4))

        // Place.
        var y = topInset + extraTop
        if self.content.showsLogo {
            transition.updateFrame(node: self.logoNode, frame: CGRect(origin: CGPoint(x: floor((size.width - logoSize.width) / 2.0), y: y), size: logoSize))
            y += logoSize.height + 20.0
        }
        transition.updateFrame(node: self.titleNode, frame: CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: y), size: titleSize))
        y += titleSize.height + 10.0
        transition.updateFrame(node: self.textNode, frame: CGRect(origin: CGPoint(x: floor((size.width - textSize.width) / 2.0), y: y), size: textSize))
        y += textSize.height + 28.0

        var focusedFrame: CGRect?
        for (index, fieldNode) in self.fieldNodes.enumerated() {
            let backgroundFrame = CGRect(x: originX, y: y, width: contentWidth, height: fieldHeight)
            transition.updateFrame(node: self.fieldBackgroundNodes[index], frame: backgroundFrame)
            transition.updateFrame(node: fieldNode, frame: backgroundFrame.insetBy(dx: 16.0, dy: 0.0))
            if fieldNode.textField.isFirstResponder {
                focusedFrame = backgroundFrame
            }
            y += fieldHeight + fieldSpacing
        }
        if !self.fieldNodes.isEmpty {
            y += 8.0
        }
        var primaryFrame: CGRect?
        if let primaryButton = self.primaryButton {
            let frame = CGRect(x: originX, y: y, width: contentWidth, height: primaryHeight)
            transition.updateFrame(node: primaryButton, frame: frame)
            primaryFrame = frame
            y += primaryHeight
        }
        if !alternativeHeights.isEmpty {
            if let dividerNode = self.dividerNode {
                y += 12.0
                transition.updateFrame(node: dividerNode, frame: CGRect(origin: CGPoint(x: originX, y: y), size: dividerSize))
                y += dividerSize.height + 12.0
            }
            for (index, button) in self.alternativeButtons.enumerated() {
                transition.updateFrame(node: button, frame: CGRect(x: originX, y: y, width: contentWidth, height: alternativeHeights[index]))
                y += alternativeHeights[index] + 12.0
            }
            y -= 12.0
        }
        if footerSize.height > 0.0 {
            y += 24.0
            transition.updateFrame(node: self.footerNode, frame: CGRect(origin: CGPoint(x: floor((size.width - footerSize.width) / 2.0), y: y), size: footerSize))
            y += footerSize.height
        }
        y += 16.0

        let scrollView = self.scrollNode.view
        scrollView.contentSize = CGSize(width: size.width, height: y)
        scrollView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: bottomInset, right: 0.0)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: navigationHeight, left: 0.0, bottom: bottomInset, right: 0.0)

        // Keep the focused field and the button visible above the keyboard.
        if inputHeight > 0.0, let focusedFrame = focusedFrame {
            let visibleBottom = size.height - bottomInset - 12.0
            var targetMaxY = focusedFrame.maxY
            if let primaryFrame = primaryFrame, primaryFrame.maxY - focusedFrame.minY < visibleBottom - topInset {
                targetMaxY = primaryFrame.maxY
            }
            let offset = max(0.0, targetMaxY - visibleBottom)
            if abs(scrollView.contentOffset.y - offset) > 1.0 && (offset > scrollView.contentOffset.y || inputHeight != previousInputHeight) {
                transition.updateBounds(node: self.scrollNode, bounds: CGRect(origin: CGPoint(x: 0.0, y: offset), size: size))
            }
        } else if inputHeight == 0.0 && previousInputHeight > 0.0 {
            let maxOffset = max(0.0, y - size.height + bottomInset)
            if scrollView.contentOffset.y > maxOffset {
                transition.updateBounds(node: self.scrollNode, bounds: CGRect(origin: CGPoint(x: 0.0, y: maxOffset), size: size))
            }
        }
    }
}
