import Foundation
import TelegramPresentationData
import UIKit
import AuthenticationServices
import MattermostKit

/// Mattermost's mobile SSO in an `ASWebAuthenticationSession` (MattermostKit `MobileSSO`).
///
/// **Unverified:** the dev server has no SSO provider, so this flow (paths, `redirect_to` with a custom
/// scheme, the `MMAUTHTOKEN` callback parameter) has not been run against a real server. The callback
/// scheme needs no `CFBundleURLTypes` entry: `ASWebAuthenticationSession` catches it itself.
final class MattermostSSOSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SSOError: Error {
        case cancelled
        case couldNotStart
        case callback(MobileSSO.CallbackError)
        case failed(String)

        func message(strings: PresentationStrings) -> String? {
            switch self {
            case .cancelled:
                return nil
            case .couldNotStart:
                return strings.Relay_Login_SSOCouldNotStart
            case let .callback(.missingToken(message)):
                return message ?? strings.Relay_Login_SSOIncomplete
            case .callback(.unexpectedCallback):
                return strings.Relay_Login_SSOUnexpected
            case let .failed(message):
                return message
            }
        }
    }

    static let callbackScheme = "relay"
    static let redirectURL = URL(string: "relay://sso")!

    private let window: UIWindow
    private var session: ASWebAuthenticationSession?

    init(window: UIWindow) {
        self.window = window
    }

    /// Opens the provider's sign-in page; completes with the session token from the callback.
    func start(serverURL: URL, provider: SSOProvider, completion: @escaping (Result<String, SSOError>) -> Void) {
        guard let url = MobileSSO.loginURL(serverURL: serverURL, provider: provider, redirectURL: MattermostSSOSession.redirectURL) else {
            completion(.failure(.couldNotStart))
            return
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: MattermostSSOSession.callbackScheme, completionHandler: { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                self?.session = nil
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    completion(.failure(.cancelled))
                    return
                }
                if let error = error {
                    completion(.failure(.failed(error.localizedDescription)))
                    return
                }
                guard let callbackURL = callbackURL else {
                    completion(.failure(.couldNotStart))
                    return
                }
                do {
                    let credentials = try MobileSSO.credentials(fromCallback: callbackURL, redirectURL: MattermostSSOSession.redirectURL)
                    completion(.success(credentials.token))
                } catch let error as MobileSSO.CallbackError {
                    completion(.failure(.callback(error)))
                } catch {
                    completion(.failure(.failed(error.localizedDescription)))
                }
            }
        })
        session.presentationContextProvider = self
        // A fresh browser session: the server's own cookies must not log a different user in.
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        if !session.start() {
            self.session = nil
            completion(.failure(.couldNotStart))
        }
    }

    func cancel() {
        self.session?.cancel()
        self.session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.window
    }
}
