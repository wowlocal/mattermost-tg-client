import Foundation
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

        var message: String? {
            switch self {
            case .cancelled:
                return nil
            case .couldNotStart:
                return "Relay couldn't open the sign-in page."
            case let .callback(.missingToken(message)):
                return message ?? "The server didn't complete the sign-in."
            case .callback(.unexpectedCallback):
                return "The server returned an unexpected sign-in response."
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

    static func title(for provider: SSOProvider, config: ClientConfig) -> String {
        switch provider {
        case .gitlab:
            return "Continue with GitLab"
        case .google:
            return "Continue with Google"
        case .office365:
            return "Continue with Entra ID"
        case .openid:
            let text = config["OpenIdButtonText"].flatMap { $0.isEmpty ? nil : $0 }
            return text ?? "Continue with OpenID"
        case .saml:
            let text = config["SamlLoginButtonText"].flatMap { $0.isEmpty ? nil : $0 }
            return text ?? "Continue with SAML"
        }
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
