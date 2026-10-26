import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import OverlayStatusController
import MattermostKit
import MattermostSync

protocol MattermostLoginStep: AnyObject {
    var inProgress: Bool { get set }
    func presentAlert(title: String?, text: String)
}

extension MattermostAuthScreen: MattermostLoginStep {}
extension MattermostMFAScreen: MattermostLoginStep {}

/// Relay's login: server address → credentials (or SSO) → MFA code when the account uses it.
///
/// Two uses:
/// - the root of `UnauthorizedApplicationContext` for Telegram's auth record (first launch, "Add Account"),
///   docs/research/ui-inventory.md §4.3 option (a). Success creates the account in the auth record's
///   postbox (`MattermostAccountSetup`), which removes the auth record; the AppDelegate then dismisses this
///   controller once the new account's UI is ready. Cancel (only with other accounts) removes the auth record.
/// - re-login after a session expired (`presentRelogin`): credentials for that server only.
public final class MattermostLoginController: NavigationController {
    enum Mode {
        case authorization(UnauthorizedAccount)
        case relogin(MattermostExpiredSession)
    }

    private let sharedContext: SharedAccountContext
    private let mode: Mode
    private let presentationData: PresentationData
    private var strings: PresentationStrings {
        return self.presentationData.strings
    }
    private let authorizationCompleted: () -> Void

    private let _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    private var didSetReady = false
    private var didPlayPresentationAnimation = false

    private var hasOtherAccounts = false
    private var server: MattermostServerDescription?
    private var ssoSession: MattermostSSOSession?

    /// Telegram's login root for an auth record.
    public init(sharedContext: SharedAccountContext, account: UnauthorizedAccount, presentationData: PresentationData, authorizationCompleted: @escaping () -> Void) {
        self.sharedContext = sharedContext
        self.mode = .authorization(account)
        self.presentationData = presentationData
        self.authorizationCompleted = authorizationCompleted

        super.init(mode: .single, theme: MattermostLoginController.navigationControllerTheme(presentationData), isFlat: true)

        // `activeAccountContexts` is a promise with a value by now, so this runs synchronously.
        var hasOtherAccounts = false
        let _ = (sharedContext.activeAccountContexts |> take(1)).start(next: { _, accounts, _ in
            hasOtherAccounts = !accounts.isEmpty
        })
        self.hasOtherAccounts = hasOtherAccounts
        self.setViewControllers([self.makeServerScreen()], animated: false)
    }

    private init(sharedContext: SharedAccountContext, expiredSession: MattermostExpiredSession, server: MattermostServerDescription, presentationData: PresentationData) {
        self.sharedContext = sharedContext
        self.mode = .relogin(expiredSession)
        self.presentationData = presentationData
        self.authorizationCompleted = {}
        self.server = server
        self.hasOtherAccounts = true

        super.init(mode: .single, theme: MattermostLoginController.navigationControllerTheme(presentationData), isFlat: true)

        self.setViewControllers([self.makeCredentialsScreen(server: server)], animated: false)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func navigationControllerTheme(_ presentationData: PresentationData) -> NavigationControllerTheme {
        let statusBar: NavigationStatusBarStyle
        switch presentationData.theme.rootController.statusBarStyle {
        case .black:
            statusBar = .black
        case .white:
            statusBar = .white
        }
        return NavigationControllerTheme(statusBar: statusBar, navigationBar: RelayBranding.navigationBarTheme(presentationData.theme), emptyAreaColor: .black)
    }

    override public func loadView() {
        super.loadView()
        self.view.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
    }

    override public func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        super.setViewControllers(viewControllers, animated: animated)
        if !self.didSetReady {
            self.didSetReady = true
            self._ready.set(.single(true))
        }
    }

    // MARK: Presentation (same as AuthorizationSequenceController)

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !self.didPlayPresentationAnimation {
            self.didPlayPresentationAnimation = true
            if self.hasOtherAccounts {
                self.view.layer.animatePosition(from: CGPoint(x: self.view.layer.position.x, y: self.view.layer.position.y + self.view.layer.bounds.size.height), to: self.view.layer.position, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
            } else {
                self.view.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            }
        }
    }

    public func dismiss() {
        self.ssoSession?.cancel()
        self.view.endEditing(true)
        self.view.layer.animatePosition(from: self.view.layer.position, to: CGPoint(x: self.view.layer.position.x, y: self.view.layer.position.y + self.view.layer.bounds.size.height), duration: 0.2, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, completion: { [weak self] _ in
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        })
    }

    /// Telegram's login takes codes from `tg://login` links; Mattermost has none.
    public func applyConfirmationCode(_ code: Int) {
    }

    private func cancel() {
        switch self.mode {
        case .authorization:
            let _ = (self.sharedContext.accountManager.transaction { transaction -> Void in
                transaction.removeAuth()
            }).start()
        case .relogin:
            self.dismiss()
        }
    }

    // MARK: Server

    private func makeServerScreen() -> MattermostAuthScreen {
        let minimum = ServerCompatibility.minimumVersion
        let content = MattermostAuthScreenContent(
            showsLogo: true,
            title: self.hasOtherAccounts ? self.strings.Relay_Login_AddAccountTitle : RelayBranding.appName,
            text: self.hasOtherAccounts ? self.strings.Relay_Login_AddAccountText : self.strings.Relay_Login_WelcomeText,
            fields: [MattermostAuthField(id: "url", kind: .serverAddress, placeholder: self.strings.Relay_Login_ServerPlaceholder, text: "")],
            primaryTitle: self.strings.Relay_Login_Connect,
            alternatives: [],
            footer: self.strings.Relay_Login_MinimumVersion("\(minimum.major).\(minimum.minor)").string
        )
        let screen = MattermostAuthScreen(debugScreenName: "server", sharedContext: self.sharedContext, presentationData: self.presentationData, content: content)
        screen.primaryAction = { [weak self, weak screen] in
            guard let self, let screen else {
                return
            }
            self.connect(screen: screen)
        }
        if self.hasOtherAccounts {
            screen.cancelAction = { [weak self] in
                self?.cancel()
            }
        }
        return screen
    }

    private func connect(screen: MattermostAuthScreen) {
        let address = screen.text(field: "url")
        screen.inProgress = true
        Task {
            do {
                let server = try await MattermostAccountSetup.probe(address: address, allowInsecureLocal: RelayBranding.allowsInsecureLocalServers)
                await MainActor.run {
                    screen.inProgress = false
                    screen.setText(server.url.absoluteString, field: "url")
                    self.server = server
                    self.pushViewController(self.makeCredentialsScreen(server: server), animated: true)
                }
            } catch {
                let message = self.strings.relayProbeError(error)
                await MainActor.run {
                    screen.inProgress = false
                    screen.animateError(field: "url")
                    screen.presentAlert(title: self.strings.Relay_Login_CantConnect, text: message)
                }
            }
        }
    }

    // MARK: Credentials

    private static func hostDisplay(_ url: URL) -> String {
        var text = url.host ?? url.absoluteString
        if let port = url.port {
            text += ":\(port)"
        }
        if !url.path.isEmpty && url.path != "/" {
            text += url.path
        }
        return text
    }

    private func makeCredentialsScreen(server: MattermostServerDescription) -> MattermostAuthScreen {
        let host = MattermostLoginController.hostDisplay(server.url)
        var fields: [MattermostAuthField] = []
        var prefilledLoginId = ""
        let title: String
        var text: String
        if case let .relogin(session) = self.mode {
            prefilledLoginId = session.loginId ?? ""
            title = self.strings.Relay_Login_ReloginTitle
            text = self.strings.Relay_Login_ReloginText(server.displayName).string
        } else {
            title = server.displayName
            text = self.strings.Relay_Login_CredentialsText(host).string
        }
        if server.allowsPasswordLogin {
            fields.append(MattermostAuthField(id: "login", kind: .loginId, placeholder: self.strings.relayLoginIdPlaceholder(server), text: prefilledLoginId))
            fields.append(MattermostAuthField(id: "password", kind: .password, placeholder: self.strings.Relay_Login_Password, text: ""))
        } else if server.ssoProviders.isEmpty {
            text = self.strings.Relay_Login_NoSupportedLogin
        }
        let content = MattermostAuthScreenContent(
            showsLogo: false,
            title: title,
            text: text,
            fields: fields,
            primaryTitle: server.allowsPasswordLogin ? self.strings.Relay_Login_LogIn : nil,
            alternatives: server.ssoProviders.map { (id: $0.rawValue, title: self.strings.relaySSOTitle($0, config: server.config)) },
            footer: "\(host) · Mattermost \(server.version)"
        )
        let screen = MattermostAuthScreen(debugScreenName: "credentials", sharedContext: self.sharedContext, presentationData: self.presentationData, content: content)
        screen.primaryAction = { [weak self, weak screen] in
            guard let self, let screen else {
                return
            }
            self.logIn(screen: screen, server: server)
        }
        screen.alternativeAction = { [weak self, weak screen] id in
            guard let self, let screen, let provider = SSOProvider(rawValue: id) else {
                return
            }
            self.startSSO(provider: provider, screen: screen, server: server)
        }
        if case .relogin = self.mode {
            screen.cancelAction = { [weak self] in
                self?.cancel()
            }
        }
        return screen
    }

    private func logIn(screen: MattermostAuthScreen, server: MattermostServerDescription) {
        let loginId = screen.text(field: "login").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = screen.text(field: "password")
        if loginId.isEmpty {
            screen.animateError(field: "login")
            screen.focus(field: "login")
            return
        }
        if password.isEmpty {
            screen.animateError(field: "password")
            screen.focus(field: "password")
            return
        }
        screen.inProgress = true
        Task {
            do {
                let result = try await MattermostAccountSetup.login(server: server.url, loginId: loginId, password: password, mfaToken: nil)
                await MainActor.run {
                    self.finish(login: result, loginId: loginId, server: server, step: screen)
                }
            } catch let error as MattermostError where error.isMFARequired {
                await MainActor.run {
                    screen.inProgress = false
                    // Leaving the form counts as a submitted login for iOS's Save Password sheet.
                    screen.clearDebugFilledPasswords()
                    self.pushMFAScreen(loginId: loginId, password: password, server: server)
                }
            } catch {
                let message = self.strings.relayLoginError(error)
                await MainActor.run {
                    screen.inProgress = false
                    screen.animateError(field: "password")
                    screen.presentAlert(title: self.strings.Relay_Login_CantLogIn, text: message)
                }
            }
        }
    }

    // MARK: MFA

    private func pushMFAScreen(loginId: String, password: String, server: MattermostServerDescription) {
        let screen = MattermostMFAScreen(sharedContext: self.sharedContext, presentationData: self.presentationData, subtitle: loginId)
        screen.codeEntered = { [weak self, weak screen] code in
            guard let self, let screen else {
                return
            }
            screen.inProgress = true
            Task {
                do {
                    let result = try await MattermostAccountSetup.login(server: server.url, loginId: loginId, password: password, mfaToken: code)
                    await MainActor.run {
                        self.finish(login: result, loginId: loginId, server: server, step: screen)
                    }
                } catch let error as MattermostError where error.isInvalidMFAToken || error.isMFARequired {
                    await MainActor.run {
                        screen.inProgress = false
                        screen.reportError(self.strings.Relay_Login_WrongCode)
                    }
                } catch {
                    let message = self.strings.relayLoginError(error)
                    await MainActor.run {
                        screen.inProgress = false
                        screen.reportError(message)
                    }
                }
            }
        }
        self.pushViewController(screen, animated: true)
    }

    // MARK: SSO (unverified: no SSO provider on the dev server)

    private func startSSO(provider: SSOProvider, screen: MattermostAuthScreen, server: MattermostServerDescription) {
        guard let window = screen.view.window else {
            return
        }
        let session = MattermostSSOSession(window: window)
        self.ssoSession = session
        screen.inProgress = true
        session.start(serverURL: server.url, provider: provider, completion: { [weak self, weak screen] result in
            guard let self, let screen else {
                return
            }
            self.ssoSession = nil
            switch result {
            case let .success(token):
                Task {
                    do {
                        let login = try await MattermostAccountSetup.ssoLogin(server: server.url, token: token)
                        await MainActor.run {
                            self.finish(login: login, loginId: nil, server: server, step: screen)
                        }
                    } catch {
                        let message = self.strings.relayLoginError(error)
                        await MainActor.run {
                            screen.inProgress = false
                            screen.presentAlert(title: self.strings.Relay_Login_CantLogIn, text: message)
                        }
                    }
                }
            case let .failure(error):
                screen.inProgress = false
                if let message = error.message(strings: self.strings) {
                    screen.presentAlert(title: self.strings.Relay_Login_CantLogIn, text: message)
                }
            }
        })
    }

    // MARK: Completion

    private func finish(login: LoginResult, loginId: String?, server: MattermostServerDescription, step: MattermostLoginStep) {
        step.inProgress = true
        for controller in self.viewControllers {
            (controller as? MattermostAuthScreen)?.clearDebugFilledPasswords()
        }
        switch self.mode {
        case let .authorization(account):
            // Before the auth record goes away: the AppDelegate then waits for the new account's UI.
            self.authorizationCompleted()
            let accountManager = self.sharedContext.accountManager
            Task {
                do {
                    try await MattermostAccountSetup.createAccount(server: server, serverURL: server.url, login: login, loginId: loginId, target: .authorization(account), accountManager: accountManager)
                } catch {
                    let message = self.strings.relayLoginError(error)
                    await MainActor.run {
                        step.inProgress = false
                        step.presentAlert(title: self.strings.Relay_Login_CantLogIn, text: message)
                    }
                }
            }
        case let .relogin(session):
            if login.user.id == session.userId {
                do {
                    try MattermostSync.renewSession(accountId: session.accountId, login: login, loginId: loginId)
                    self.dismiss()
                } catch {
                    step.inProgress = false
                    step.presentAlert(title: self.strings.Relay_Login_CantLogIn, text: self.strings.relayLoginError(error))
                }
            } else {
                let username = login.user.username
                let replace: () -> Void = { [weak self] in
                    Task {
                        do {
                            try await MattermostSync.replaceAccount(accountId: session.accountId, server: server, serverURL: server.url, login: login, loginId: loginId)
                            await MainActor.run {
                                self?.dismiss()
                            }
                        } catch {
                            let strings = self?.strings
                            let message = strings?.relayLoginError(error) ?? error.localizedDescription
                            await MainActor.run {
                                step.inProgress = false
                                step.presentAlert(title: strings?.Relay_Login_CantLogIn ?? "", text: message)
                            }
                        }
                    }
                }
                let alert = textAlertController(sharedContext: self.sharedContext, title: self.strings.Relay_Login_ReplaceTitle(username).string, text: self.strings.Relay_Login_ReplaceText(username).string, actions: [
                    TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {
                        step.inProgress = false
                    }),
                    TextAlertAction(type: .defaultAction, title: self.strings.Relay_Login_Continue, action: replace)
                ])
                if let screen = step as? MattermostAuthScreen {
                    screen.presentConfirmation(alert, confirm: replace)
                } else {
                    (step as? ViewController)?.present(alert, in: .window(.root))
                }
            }
        }
    }

    // MARK: Re-login

    /// Asks the server for its login options, then presents the credentials step for `session`'s server
    /// over the current UI.
    static func presentRelogin(sharedContext: SharedAccountContext, session: MattermostExpiredSession, presented: @escaping (MattermostLoginController) -> Void) {
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        let status = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        sharedContext.mainWindow?.present(status, on: .root)
        Task {
            do {
                // The address was accepted at the first login.
                let server = try await MattermostAccountSetup.probe(address: session.serverURL, allowInsecureLocal: true)
                await MainActor.run {
                    status.dismiss()
                    let controller = MattermostLoginController(sharedContext: sharedContext, expiredSession: session, server: server, presentationData: presentationData)
                    sharedContext.mainWindow?.present(controller, on: .root)
                    presented(controller)
                }
            } catch {
                let message = presentationData.strings.relayProbeError(error)
                await MainActor.run {
                    status.dismiss()
                    let alert = textAlertController(sharedContext: sharedContext, title: presentationData.strings.Relay_Login_CantConnect, text: message, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})])
                    sharedContext.mainWindow?.present(alert, on: .root)
                }
            }
        }
    }
}
