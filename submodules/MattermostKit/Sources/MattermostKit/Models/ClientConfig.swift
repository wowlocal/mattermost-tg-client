import Foundation

/// `GET /config/client?format=old`: a flat string dictionary.
///
/// Logged-out clients receive a limited subset; fetch it again after login.
public struct ClientConfig: Codable, Sendable, Equatable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: JSONValue].self)
        values = raw.compactMapValues { $0.scalarString }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public subscript(key: String) -> String? {
        values[key]
    }

    /// `"true"` / `"false"` settings. Nil when the key is missing.
    public func bool(_ key: String) -> Bool? {
        guard let value = values[key] else { return nil }
        return value.lowercased() == "true"
    }

    public func int64(_ key: String) -> Int64? {
        values[key].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}

extension ClientConfig {
    /// e.g. `"9.11.1"`.
    public var version: String? { self["Version"] }
    public var serverVersion: ServerVersion? { version.flatMap(ServerVersion.init) }
    public var buildNumber: String? { self["BuildNumber"] }
    public var siteName: String? { self["SiteName"] }
    public var siteURL: String? { self["SiteURL"] }
    public var diagnosticId: String? { self["DiagnosticId"] }

    public var enableCustomEmoji: Bool { bool("EnableCustomEmoji") ?? false }

    /// Link previews (OpenGraph and image embeds) on the server.
    public var enableLinkPreviews: Bool { bool("EnableLinkPreviews") ?? false }
    /// Previews of permalinks to other posts (`permalink` embeds).
    public var enablePermalinkPreviews: Bool { bool("EnablePermalinkPreviews") ?? false }
    /// External images go through `GET /image?url=` (`ImageProxySettings`); clients build those URLs.
    public var hasImageProxy: Bool { bool("HasImageProxy") ?? false }
    /// LaTeX code blocks and, with `EnableInlineLatex` too, `$inline$` LaTeX.
    public var enableLatex: Bool { bool("EnableLatex") ?? false }
    public var enableInlineLatex: Bool { bool("EnableInlineLatex") ?? false }

    /// Bytes. Only in the logged-in config.
    public var maxFileSize: Int64? { int64("MaxFileSize") }

    /// Team invitations by email can be sent (`POST /teams/{id}/invite/email`).
    public var enableEmailInvitations: Bool { bool("EnableEmailInvitations") ?? false }
    /// New accounts can be created (sign-up, including through a team's invite link).
    public var enableUserCreation: Bool { bool("EnableUserCreation") ?? true }
    /// Anyone can sign up, not only people with an invitation.
    public var enableOpenServer: Bool { bool("EnableOpenServer") ?? false }

    /// Missing on servers without collapsed reply threads; treated as `.disabled`.
    public var collapsedThreads: CollapsedThreadsSetting {
        guard let raw = self["CollapsedThreads"], !raw.isEmpty else { return .disabled }
        return CollapsedThreadsSetting(rawValue: raw)
    }

    public var teammateNameDisplay: TeammateNameDisplay? {
        self["TeammateNameDisplay"].flatMap(TeammateNameDisplay.init(rawValue:))
    }

    public var enableSignInWithEmail: Bool { bool("EnableSignInWithEmail") ?? false }
    public var enableSignInWithUsername: Bool { bool("EnableSignInWithUsername") ?? false }
    public var enableSignUpWithEmail: Bool { bool("EnableSignUpWithEmail") ?? false }
    public var enableSignUpWithGitLab: Bool { bool("EnableSignUpWithGitLab") ?? false }
    public var enableSignUpWithGoogle: Bool { bool("EnableSignUpWithGoogle") ?? false }
    public var enableSignUpWithOffice365: Bool { bool("EnableSignUpWithOffice365") ?? false }
    public var enableSignUpWithOpenId: Bool { bool("EnableSignUpWithOpenId") ?? false }
    public var enableSaml: Bool { bool("EnableSaml") ?? false }
    public var enableLdap: Bool { bool("EnableLdap") ?? false }
    public var enableMultifactorAuthentication: Bool { bool("EnableMultifactorAuthentication") ?? false }
    public var enforceMultifactorAuthentication: Bool { bool("EnforceMultifactorAuthentication") ?? false }

    /// SSO providers enabled on the server, in a stable order. SAML and some
    /// OAuth providers additionally require a license on the server side; the
    /// server only reports them as enabled when they are usable.
    public var enabledSSOProviders: [SSOProvider] {
        var result: [SSOProvider] = []
        if enableSignUpWithGitLab { result.append(.gitlab) }
        if enableSignUpWithGoogle { result.append(.google) }
        if enableSignUpWithOffice365 { result.append(.office365) }
        if enableSignUpWithOpenId { result.append(.openid) }
        if enableSaml { result.append(.saml) }
        return result
    }
}

/// The `CollapsedThreads` server setting.
public enum CollapsedThreadsSetting: Sendable, Hashable, RawRepresentable {
    case disabled
    case defaultOff
    case defaultOn
    case alwaysOn
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "default_off": self = .defaultOff
        case "default_on": self = .defaultOn
        case "always_on": self = .alwaysOn
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .disabled: return "disabled"
        case .defaultOff: return "default_off"
        case .defaultOn: return "default_on"
        case .alwaysOn: return "always_on"
        case .unknown(let value): return value
        }
    }

    /// Whether users can have collapsed reply threads at all.
    public var isAvailable: Bool {
        switch self {
        case .defaultOff, .defaultOn, .alwaysOn: return true
        case .disabled, .unknown: return false
        }
    }
}

/// `GET /license/client?format=old`: a flat string dictionary.
public struct ClientLicense: Codable, Sendable, Equatable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: JSONValue].self)
        values = raw.compactMapValues { $0.scalarString }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public subscript(key: String) -> String? {
        values[key]
    }

    public var isLicensed: Bool { values["IsLicensed"]?.lowercased() == "true" }
    /// e.g. `"professional"`, `"enterprise"`, `"E20"`.
    public var skuShortName: String? { values["SkuShortName"] }
    public var isCloud: Bool { values["Cloud"]?.lowercased() == "true" }
}

/// A `major.minor.patch` server version, parsed leniently from strings such as
/// `"9.11.1"`, `"10.0.0-rc2"` or the WebSocket `hello` value
/// `"9.11.1.12345.abcdef.true"`.
public struct ServerVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        let components = string.split(separator: ".", omittingEmptySubsequences: false).prefix(3).map { component -> Int? in
            let digits = component.prefix(while: { $0.isASCII && $0.isNumber })
            return digits.isEmpty ? nil : Int(digits)
        }
        guard let first = components.first, let major = first else { return nil }
        self.major = major
        self.minor = components.count > 1 ? (components[1] ?? 0) : 0
        self.patch = components.count > 2 ? (components[2] ?? 0) : 0
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
