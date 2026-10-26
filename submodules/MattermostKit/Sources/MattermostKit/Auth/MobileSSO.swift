import Foundation

public enum SSOProvider: String, Sendable, CaseIterable {
    case gitlab
    case google
    case office365
    case openid
    case saml
}

/// Helpers for Mattermost's mobile SSO flow, intended for use with
/// `ASWebAuthenticationSession`.
///
/// - Important: **Unverified assumptions.** This follows the flow the official
///   mobile app is understood to use and has not been checked against a real
///   server yet:
///   1. Open `<server>/oauth/<provider>/mobile_login?redirect_to=<callback>` (or
///      `<server>/login/sso/saml?action=mobile&redirect_to=<callback>` for SAML).
///   2. After authentication the server redirects to
///      `<callback>?MMAUTHTOKEN=<session token>&MMCSRF=<csrf token>`.
///   3. The app uses `MMAUTHTOKEN` as the bearer token.
///
///   Older servers may not honour `redirect_to` with a custom URL scheme, and
///   may only set the token as a cookie. Verify the exact paths, parameter
///   names and minimum server version (docs/plan/09, "Mobile SSO flow").
public enum MobileSSO {
    public struct Credentials: Sendable, Equatable {
        /// Session token to use as the bearer token.
        public var token: String
        /// CSRF token; only needed for cookie-based auth.
        public var csrfToken: String?

        public init(token: String, csrfToken: String? = nil) {
            self.token = token
            self.csrfToken = csrfToken
        }
    }

    public enum CallbackError: Error, Sendable, Equatable {
        /// The callback URL does not start with the expected redirect URL.
        case unexpectedCallback
        /// The callback has no `MMAUTHTOKEN`. `message` carries any `error` /
        /// `error_description` parameter the server added.
        case missingToken(message: String?)
    }

    /// The URL that starts SSO for `provider`.
    /// - Parameter redirectURL: The app's callback URL (custom scheme), e.g.
    ///   `mmclient://sso`. Pass its scheme as `callbackURLScheme` to
    ///   `ASWebAuthenticationSession`.
    public static func loginURL(serverURL: URL, provider: SSOProvider, redirectURL: URL) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        var queryItems: [URLQueryItem] = []
        switch provider {
        case .saml:
            components.path = basePath + "/login/sso/saml"
            queryItems.append(URLQueryItem(name: "action", value: "mobile"))
        case .gitlab, .google, .office365, .openid:
            components.path = basePath + "/oauth/\(provider.rawValue)/mobile_login"
        }
        queryItems.append(URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString))
        components.percentEncodedQuery = queryItems.map { item in
            percentEncodeQueryComponent(item.name) + "=" + percentEncodeQueryComponent(item.value ?? "")
        }.joined(separator: "&")
        components.fragment = nil
        return components.url
    }

    /// Extracts the session token from the callback URL the server redirected to.
    /// - Parameter redirectURL: If given, the callback must match its scheme,
    ///   host and path.
    public static func credentials(fromCallback callbackURL: URL, redirectURL: URL? = nil) throws -> Credentials {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw CallbackError.unexpectedCallback
        }
        if let redirectURL {
            guard let expected = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
                  expected.scheme?.lowercased() == components.scheme?.lowercased(),
                  (expected.host ?? "") == (components.host ?? ""),
                  normalizedPath(expected.path) == normalizedPath(components.path)
            else {
                throw CallbackError.unexpectedCallback
            }
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let token = value("MMAUTHTOKEN") else {
            throw CallbackError.missingToken(message: value("error_description") ?? value("error"))
        }
        return Credentials(token: token, csrfToken: value("MMCSRF"))
    }

    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
