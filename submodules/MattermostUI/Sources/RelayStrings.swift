import Foundation
import TelegramPresentationData
import MattermostKit
import MattermostSync

/// User-facing texts for MattermostSync's errors, from the presentation strings (`Relay.strings`). MattermostSync
/// keeps English `message`s for logs and callers without strings.
extension PresentationStrings {
    func relayProbeError(_ error: Error) -> String {
        guard let error = error as? MattermostServerProbeError else {
            return error.localizedDescription
        }
        switch error {
        case .invalidAddress(.empty):
            return self.Relay_Login_Error_EmptyAddress
        case .invalidAddress(.invalid):
            return self.Relay_Login_Error_InvalidAddress
        case .invalidAddress(.insecureNotAllowed):
            return self.Relay_Login_Error_InsecureNotAllowed
        case let .unreachable(host, reason):
            return self.Relay_Login_Error_Unreachable(host, reason).string
        case let .notMattermost(host):
            return self.Relay_Login_Error_NotMattermost(host).string
        case let .tooOld(version, minimum):
            return self.Relay_Login_Error_TooOld("\(version)", "\(minimum.major).\(minimum.minor)").string
        case .unknownVersion:
            return self.Relay_Login_Error_UnknownVersion
        }
    }

    func relayLoginError(_ error: Error) -> String {
        if let error = error as? MattermostAccountSetupError {
            switch error {
            case let .alreadyLoggedIn(username):
                return self.Relay_Login_Error_AlreadyLoggedIn(username).string
            case let .storage(reason):
                return self.Relay_Login_Error_Storage(reason).string
            }
        }
        if let error = error as? MattermostRenewSessionError {
            switch error {
            case .unknownAccount:
                return self.Relay_Login_Error_UnknownAccount
            case .differentUser:
                return self.Relay_Login_Error_DifferentUser
            case .storage:
                return self.Relay_Login_Error_SessionStorage
            }
        }
        guard let error = error as? MattermostError else {
            return error.localizedDescription
        }
        switch error {
        case let .unauthorized(appError), let .forbidden(appError):
            // The server's own message names the problem (wrong password, locked account, …).
            if let appError = appError, !appError.message.isEmpty {
                return appError.message
            }
            return self.Relay_Login_Error_Credentials
        case let .transport(urlError):
            return self.Relay_Login_Error_Offline(urlError.localizedDescription).string
        case .rateLimited:
            return self.Relay_Login_Error_RateLimited
        default:
            return error.errorDescription ?? self.Relay_Login_Error_Failed
        }
    }

    /// The login id field's placeholder, as the official clients word it (`MattermostServerDescription.loginIdPlaceholder`
    /// is the English original, kept for logs).
    func relayLoginIdPlaceholder(_ server: MattermostServerDescription) -> String {
        var kinds: [String] = []
        if server.allowsEmailLogin {
            kinds.append(self.Relay_Login_Id_Email)
        }
        if server.allowsUsernameLogin {
            kinds.append(kinds.isEmpty ? self.Relay_Login_Id_Username : self.Relay_Login_Id_UsernameInList)
        }
        if server.allowsLdapLogin {
            // The server's own name for the field comes as configured (its language).
            let field = server.config["LdapLoginFieldName"].flatMap { $0.isEmpty ? nil : $0 } ?? self.Relay_Login_Id_Ldap
            kinds.append(field)
        }
        switch kinds.count {
        case 0:
            return self.Relay_Login_Id_EmailOrUsername
        case 1:
            return kinds[0]
        case 2:
            return self.Relay_Login_Id_Two(kinds[0], kinds[1]).string
        default:
            return self.Relay_Login_Id_Three(kinds[0], kinds[1], kinds[2]).string
        }
    }

    func relaySSOTitle(_ provider: SSOProvider, config: ClientConfig) -> String {
        switch provider {
        case .gitlab:
            return self.Relay_Login_ContinueWith("GitLab").string
        case .google:
            return self.Relay_Login_ContinueWith("Google").string
        case .office365:
            return self.Relay_Login_ContinueWith("Entra ID").string
        case .openid:
            let text = config["OpenIdButtonText"].flatMap { $0.isEmpty ? nil : $0 }
            return text ?? self.Relay_Login_ContinueWith("OpenID").string
        case .saml:
            let text = config["SamlLoginButtonText"].flatMap { $0.isEmpty ? nil : $0 }
            return text ?? self.Relay_Login_ContinueWith("SAML").string
        }
    }
}
