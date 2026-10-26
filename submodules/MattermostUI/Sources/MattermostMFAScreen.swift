import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import CodeInputView

/// The MFA step: six digits from the user's authenticator app, submitted as soon as all are entered.
final class MattermostMFAScreen: ViewController, MattermostDebugDrivable {
    static let codeLength = 6

    let debugScreenName = "mfa"
    private let sharedContext: SharedAccountContext
    private let presentationData: PresentationData
    private let subtitle: String

    /// Called with the full code.
    var codeEntered: ((String) -> Void)?

    private var screenNode: MattermostMFAScreenNode {
        return self.displayNode as! MattermostMFAScreenNode
    }

    var inProgress: Bool = false {
        didSet {
            if self.isNodeLoaded {
                self.screenNode.inProgress = self.inProgress
            }
        }
    }

    init(sharedContext: SharedAccountContext, presentationData: PresentationData, subtitle: String) {
        self.sharedContext = sharedContext
        self.presentationData = presentationData
        self.subtitle = subtitle

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

    override func loadDisplayNode() {
        self.displayNode = MattermostMFAScreenNode(presentationData: self.presentationData, subtitle: self.subtitle)
        self.displayNodeDidLoad()
        self.screenNode.view.disableAutomaticKeyboardHandling = [.forward, .backward]
        self.screenNode.codeEntered = { [weak self] code in
            self?.codeEntered?(code)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MattermostDebugRemote.screenAppeared(self)
        self.screenNode.activateInput()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.screenNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }

    /// Shakes and clears the code, and shows `text` under it.
    func reportError(_ text: String) {
        HapticFeedback().error()
        self.screenNode.reportError(text)
    }

    private weak var presentedAlert: ViewController?

    func presentAlert(title: String?, text: String) {
        let alert = textAlertController(sharedContext: self.sharedContext, title: title, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})])
        self.presentedAlert = alert
        self.present(alert, in: .window(.root))
    }

    // MARK: MattermostDebugDrivable

    func debugFill(field: String, text: String) -> Bool {
        guard field == "code" else {
            return false
        }
        self.screenNode.setCode(text)
        return true
    }

    func debugPress(button: String) -> Bool {
        guard button == "back", !self.inProgress, let navigationController = self.navigationController else {
            return false
        }
        navigationController.popViewController(animated: true)
        return true
    }

    func debugDismissAlerts() -> Bool {
        guard let alert = self.presentedAlert else {
            return false
        }
        alert.dismiss()
        self.presentedAlert = nil
        return true
    }
}

final class MattermostMFAScreenNode: ASDisplayNode {
    private let presentationData: PresentationData
    private let titleNode: ImmediateTextNode
    private let textNode: ImmediateTextNode
    private let codeInputView: CodeInputView
    private let errorNode: ImmediateTextNode
    private let activityIndicator: UIActivityIndicatorView

    var codeEntered: ((String) -> Void)?
    private var layoutArguments: (ContainerViewLayout, CGFloat)?

    var inProgress: Bool = false {
        didSet {
            self.codeInputView.alpha = self.inProgress ? 0.6 : 1.0
            self.codeInputView.isUserInteractionEnabled = !self.inProgress
            if self.inProgress {
                self.activityIndicator.startAnimating()
            } else {
                self.activityIndicator.stopAnimating()
            }
        }
    }

    init(presentationData: PresentationData, subtitle: String) {
        self.presentationData = presentationData
        let theme = presentationData.theme

        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 2
        self.titleNode.textAlignment = .center
        let title = presentationData.strings.Relay_Login_MFATitle
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.bold(28.0), textColor: theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        self.titleNode.isAccessibilityElement = true
        self.titleNode.accessibilityLabel = title
        self.titleNode.accessibilityTraits = .header

        self.textNode = ImmediateTextNode()
        self.textNode.maximumNumberOfLines = 0
        self.textNode.textAlignment = .center
        let text = presentationData.strings.Relay_Login_MFAText(subtitle).string
        self.textNode.attributedText = NSAttributedString(string: text, font: Font.regular(16.0), textColor: theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        self.textNode.isAccessibilityElement = true
        self.textNode.accessibilityLabel = text

        self.codeInputView = CodeInputView()
        self.codeInputView.textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.codeInputView.textField.accessibilityLabel = presentationData.strings.Relay_Login_MFACodeField
        self.codeInputView.textField.accessibilityIdentifier = "Relay.MFA.CodeField"

        self.errorNode = ImmediateTextNode()
        self.errorNode.maximumNumberOfLines = 0
        self.errorNode.textAlignment = .center

        self.activityIndicator = UIActivityIndicatorView(style: .medium)
        self.activityIndicator.color = theme.list.itemSecondaryTextColor
        self.activityIndicator.hidesWhenStopped = true

        super.init()

        self.setViewBlock({
            return UITracingLayerView()
        })
        self.backgroundColor = theme.list.plainBackgroundColor

        self.addSubnode(self.titleNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.codeInputView)
        self.addSubnode(self.errorNode)

        self.codeInputView.updated = { [weak self] in
            guard let self else {
                return
            }
            if !self.codeInputView.text.isEmpty {
                self.setErrorText(nil)
            }
            if self.codeInputView.text.count == MattermostMFAScreen.codeLength && !self.inProgress {
                self.codeEntered?(self.codeInputView.text)
            }
        }
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.activityIndicator)
    }

    func activateInput() {
        let _ = self.codeInputView.becomeFirstResponder()
    }

    func setCode(_ code: String) {
        self.codeInputView.text = String(code.prefix(MattermostMFAScreen.codeLength))
        self.codeInputView.updated?()
        if let (layout, navigationHeight) = self.layoutArguments {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .immediate)
        }
    }

    func reportError(_ text: String) {
        self.codeInputView.animateError()
        self.codeInputView.layer.addShakeAnimation(amplitude: -30.0, duration: 0.5, count: 6, decay: true)
        self.setErrorText(text)
    }

    private func setErrorText(_ text: String?) {
        self.errorNode.attributedText = text.flatMap { NSAttributedString(string: $0, font: Font.regular(14.0), textColor: self.presentationData.theme.list.itemDestructiveColor, paragraphAlignment: .center) }
        self.errorNode.accessibilityLabel = text
        self.errorNode.isAccessibilityElement = text != nil
        if let (layout, navigationHeight) = self.layoutArguments {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .immediate)
        }
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.layoutArguments = (layout, navigationHeight)
        let theme = self.presentationData.theme
        let size = layout.size
        let sideInset: CGFloat = 24.0 + max(layout.safeInsets.left, layout.safeInsets.right)
        let contentWidth = min(size.width - sideInset * 2.0, 420.0)

        var y = navigationHeight + 24.0
        let titleSize = self.titleNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        transition.updateFrame(node: self.titleNode, frame: CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: y), size: titleSize))
        y += titleSize.height + 10.0
        let textSize = self.textNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        transition.updateFrame(node: self.textNode, frame: CGRect(origin: CGPoint(x: floor((size.width - textSize.width) / 2.0), y: y), size: textSize))
        y += textSize.height + 32.0

        let codeSize = self.codeInputView.update(
            theme: CodeInputView.Theme(
                inactiveBorder: theme.list.itemPlainSeparatorColor.argb,
                activeBorder: theme.list.itemAccentColor.argb,
                succeedBorder: theme.list.itemDisclosureActions.constructive.fillColor.argb,
                failedBorder: theme.list.itemDestructiveColor.argb,
                foreground: theme.list.itemPrimaryTextColor.argb,
                isDark: theme.overallDarkAppearance
            ),
            prefix: "",
            count: MattermostMFAScreen.codeLength,
            width: contentWidth,
            compact: size.width <= 375.0
        )
        transition.updateFrame(node: self.codeInputView, frame: CGRect(origin: CGPoint(x: floor((size.width - codeSize.width) / 2.0), y: y), size: codeSize))
        y += codeSize.height + 16.0

        let errorSize = self.errorNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        transition.updateFrame(node: self.errorNode, frame: CGRect(origin: CGPoint(x: floor((size.width - errorSize.width) / 2.0), y: y), size: errorSize))
        y += max(errorSize.height, 20.0) + 12.0

        self.activityIndicator.frame = CGRect(x: floor((size.width - 24.0) / 2.0), y: y, width: 24.0, height: 24.0)
    }
}
