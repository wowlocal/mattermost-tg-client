import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import MattermostSync

/// MattermostUI's app-level hooks, installed once by `SharedAccountContextImpl` (main app).
public enum MattermostAppHooks {
    public static func sharedContextCreated(_ sharedContext: SharedAccountContext) {
        MattermostSessionExpiryPresenter.shared.start(sharedContext: sharedContext)
        #if DEBUG
        MattermostDebugRemote.shared.start(sharedContext: sharedContext)
        #endif
    }
}

/// Asks to log in again when an account's session expired (`MattermostSync.expiredSessions`): once per
/// expiry, and again each time the app becomes active while it stays expired ("Not Now").
final class MattermostSessionExpiryPresenter {
    static let shared = MattermostSessionExpiryPresenter()

    private var sharedContext: SharedAccountContext?
    private var sessions: [MattermostExpiredSession] = []
    private var hasPrimary = false
    private var prompted = Set<AccountRecordId>()
    private weak var currentAlert: ViewController?
    private weak var currentLogin: MattermostLoginController?
    private var currentAlertSession: MattermostExpiredSession?
    private let disposable = MetaDisposable()
    private let activeDisposable = MetaDisposable()

    func start(sharedContext: SharedAccountContext) {
        self.sharedContext = sharedContext
        let hasPrimary = sharedContext.activeAccountContexts
        |> map { primary, _, _ -> Bool in
            return primary != nil
        }
        |> distinctUntilChanged
        self.disposable.set((combineLatest(MattermostSync.expiredSessions, hasPrimary)
        |> deliverOnMainQueue).start(next: { [weak self] sessions, hasPrimary in
            guard let self else {
                return
            }
            self.sessions = sessions
            self.hasPrimary = hasPrimary
            let ids = Set(sessions.map { $0.accountId })
            self.prompted = self.prompted.intersection(ids)
            self.presentIfNeeded()
        }))
        self.activeDisposable.set((sharedContext.applicationBindings.applicationIsActive
        |> distinctUntilChanged
        |> filter { $0 }
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, self.currentAlert == nil, self.currentLogin == nil else {
                return
            }
            self.prompted.removeAll()
            self.presentIfNeeded()
        }))
    }

    private func presentIfNeeded() {
        guard let sharedContext = self.sharedContext, self.hasPrimary, self.currentAlert == nil, self.currentLogin == nil else {
            return
        }
        guard let session = self.sessions.first(where: { !self.prompted.contains($0.accountId) }) else {
            return
        }
        self.prompted.insert(session.accountId)
        let _ = (sharedContext.activeAccountsWithInfo
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] _, accounts in
            guard let self else {
                return
            }
            let username = accounts.first(where: { $0.account.id == session.accountId })?.peer.addressName
            self.presentAlert(session: session, username: username, sharedContext: sharedContext)
        })
    }

    private func presentAlert(session: MattermostExpiredSession, username: String?, sharedContext: SharedAccountContext) {
        let host = URL(string: session.serverURL).flatMap { url in url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } } ?? session.serverURL
        let site = (session.siteName?.isEmpty ?? true) ? host : "\(session.siteName!) (\(host))"
        let who = username.map { "@\($0)" } ?? session.loginId ?? "your account"
        let text = "Your session as \(who) on \(site) has ended. Log in again to keep your messages up to date. Until then, Relay shows what's already on this device."
        let alert = textAlertController(sharedContext: sharedContext, title: "Session Expired", text: text, actions: [
            TextAlertAction(type: .genericAction, title: "Not Now", action: { [weak self] in
                self?.currentAlertSession = nil
            }),
            TextAlertAction(type: .defaultAction, title: "Log In", action: { [weak self] in
                self?.currentAlertSession = nil
                self?.openLogin(session: session)
            })
        ])
        self.currentAlert = alert
        self.currentAlertSession = session
        sharedContext.mainWindow?.present(alert, on: .root)
    }

    private func openLogin(session: MattermostExpiredSession) {
        guard let sharedContext = self.sharedContext else {
            return
        }
        MattermostLoginController.presentRelogin(sharedContext: sharedContext, session: session, presented: { [weak self] controller in
            self?.currentLogin = controller
        })
    }

    /// Debug: "Log In" on the visible alert, or the re-login for the first expired session.
    func debugOpenLogin() -> Bool {
        if let alert = self.currentAlert, let session = self.currentAlertSession {
            alert.dismiss()
            self.currentAlert = nil
            self.currentAlertSession = nil
            self.openLogin(session: session)
            return true
        }
        if let session = self.sessions.first {
            self.openLogin(session: session)
            return true
        }
        return false
    }

    var debugState: [String: Any] {
        return [
            "expiredAccountIds": self.sessions.map { "\($0.accountId.int64)" },
            "alertVisible": self.currentAlert != nil,
            "reloginVisible": self.currentLogin != nil
        ]
    }
}
