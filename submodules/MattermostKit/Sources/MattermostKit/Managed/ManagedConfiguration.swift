import Foundation

/// Managed app configuration (AppConfig, delivered by an MDM/EMM to `UserDefaults.standard` under
/// `com.apple.configuration.managed`), Phase 4G.
///
/// The keys are the ones the official Mattermost mobile app documents for EMM providers
/// (docs.mattermost.com, "Deploy using an EMM provider"), so existing profiles keep working; Relay adds
/// `relayCertificatePins`. Mattermost declares every key as a string (`"true"`/`"false"` for switches); booleans
/// and numbers are accepted too. Unknown keys are ignored. See docs/release/managed-configuration.md.
public struct MattermostManagedConfiguration: Equatable, Sendable, Codable {
    /// The `UserDefaults.standard` key iOS stores the managed configuration under.
    public static let userDefaultsKey = "com.apple.configuration.managed"
    /// The app group copy for Relay's extensions (`<root>/relay-managed-configuration.json`).
    public static let sharedFileName = "relay-managed-configuration.json"

    public enum Key {
        public static let serverURL = "serverUrl"
        public static let serverName = "serverName"
        public static let allowOtherServers = "allowOtherServers"
        public static let username = "username"
        public static let inAppPinCode = "inAppPinCode"
        public static let blurApplicationScreen = "blurApplicationScreen"
        public static let copyAndPasteProtection = "copyAndPasteProtection"
        public static let jailbreakDetection = "jailbreakDetection"
        public static let vendor = "vendor"
        public static let certificatePins = "relayCertificatePins"
        /// Documented by Mattermost, not applicable to Relay (see the configuration guide).
        public static let notApplicable: [String] = ["useVPN", "timeoutVPN", "inAppSessionAuth"]
        public static let supported: [String] = [serverURL, serverName, allowOtherServers, username, inAppPinCode, blurApplicationScreen, copyAndPasteProtection, jailbreakDetection, vendor, certificatePins]
    }

    /// The server address as configured (trimmed); `managedServerURL` is the normalized form.
    public var serverURL: String?
    /// Display name for the managed server.
    public var serverName: String?
    /// False: only the managed server may be used (needs `serverURL`). Mattermost's default is true.
    public var allowOtherServers: Bool
    /// Login id to prefill on the managed server's login.
    public var username: String?
    /// The app must be protected by a passcode, locking after at most five minutes away.
    public var inAppPinCode: Bool
    /// Hide the app's content in the app switcher.
    public var blurApplicationScreen: Bool
    /// Keep copied content inside the app.
    public var copyAndPasteProtection: Bool
    /// Refuse to run on a jailbroken device.
    public var jailbreakDetection: Bool
    /// The organisation's name for messages ("required by …").
    public var vendor: String?
    public var certificatePins: MattermostCertificatePins
    /// Keys present in the configuration that Relay doesn't use (documented as not applicable, or unknown).
    public var ignoredKeys: [String]

    public init(serverURL: String? = nil, serverName: String? = nil, allowOtherServers: Bool = true, username: String? = nil, inAppPinCode: Bool = false, blurApplicationScreen: Bool = false, copyAndPasteProtection: Bool = false, jailbreakDetection: Bool = false, vendor: String? = nil, certificatePins: MattermostCertificatePins = .empty, ignoredKeys: [String] = []) {
        self.serverURL = serverURL
        self.serverName = serverName
        self.allowOtherServers = allowOtherServers
        self.username = username
        self.inAppPinCode = inAppPinCode
        self.blurApplicationScreen = blurApplicationScreen
        self.copyAndPasteProtection = copyAndPasteProtection
        self.jailbreakDetection = jailbreakDetection
        self.vendor = vendor
        self.certificatePins = certificatePins
        self.ignoredKeys = ignoredKeys
    }

    /// No managed configuration.
    public static let none = MattermostManagedConfiguration()

    /// Reads the managed dictionary; nil gives `.none`.
    public init(dictionary: [String: Any]?) {
        let dictionary = dictionary ?? [:]
        self.init(
            serverURL: MattermostManagedConfiguration.string(dictionary[Key.serverURL]),
            serverName: MattermostManagedConfiguration.string(dictionary[Key.serverName]),
            allowOtherServers: MattermostManagedConfiguration.bool(dictionary[Key.allowOtherServers]) ?? true,
            username: MattermostManagedConfiguration.string(dictionary[Key.username]),
            inAppPinCode: MattermostManagedConfiguration.bool(dictionary[Key.inAppPinCode]) ?? false,
            blurApplicationScreen: MattermostManagedConfiguration.bool(dictionary[Key.blurApplicationScreen]) ?? false,
            copyAndPasteProtection: MattermostManagedConfiguration.bool(dictionary[Key.copyAndPasteProtection]) ?? false,
            jailbreakDetection: MattermostManagedConfiguration.bool(dictionary[Key.jailbreakDetection]) ?? false,
            vendor: MattermostManagedConfiguration.string(dictionary[Key.vendor]),
            certificatePins: MattermostCertificatePins.parse(dictionary[Key.certificatePins]),
            ignoredKeys: dictionary.keys.filter { !Key.supported.contains($0) }.sorted()
        )
    }

    /// Whether anything is managed (an empty or absent configuration is not).
    public var isManaged: Bool {
        var settings = self
        settings.ignoredKeys = []
        return settings != .none
    }

    // MARK: Servers

    /// The managed server, normalized like a typed address (`https://` added when there is no scheme). Local
    /// `http://` addresses are kept here; the login's own rules still decide whether they may be used.
    public var managedServerURL: URL? {
        guard let serverURL = self.serverURL else {
            return nil
        }
        return try? ServerAddress.normalize(serverURL, allowInsecureLocal: true)
    }

    /// The only server that may be used, when other servers are not allowed; nil when any server may be used.
    /// `allowOtherServers = false` without a usable `serverUrl` restricts nothing (there is no server to keep to).
    public var restrictedServerURL: URL? {
        guard !self.allowOtherServers else {
            return nil
        }
        return self.managedServerURL
    }

    /// Whether `url` (a stored or typed server address) may be used.
    public func allowsServer(_ url: URL) -> Bool {
        guard let restricted = self.restrictedServerURL else {
            return true
        }
        return MattermostManagedConfiguration.isSameServer(url, restricted)
    }

    public func allowsServer(_ address: String) -> Bool {
        guard self.restrictedServerURL != nil else {
            return true
        }
        guard let url = try? ServerAddress.normalize(address, allowInsecureLocal: true) else {
            return false
        }
        return self.allowsServer(url)
    }

    /// Whether `url` is the managed server (for its display name and the prefilled username).
    public func isManagedServer(_ url: URL) -> Bool {
        guard let managed = self.managedServerURL else {
            return false
        }
        return MattermostManagedConfiguration.isSameServer(url, managed)
    }

    /// Same host (case-insensitive), port (default ports by scheme) and path (without trailing slashes). The
    /// scheme itself is not compared: a managed `chat.example.com` is `https://`, and the login decides between
    /// `https://` and a local `http://`.
    public static func isSameServer(_ lhs: URL, _ rhs: URL) -> Bool {
        func parts(_ url: URL) -> (String, Int, String)? {
            guard let host = url.host?.lowercased() else {
                return nil
            }
            let scheme = url.scheme?.lowercased() ?? "https"
            let port = url.port ?? (scheme == "http" ? 80 : 443)
            var path = url.path
            while path.hasSuffix("/") {
                path.removeLast()
            }
            return (host, port, path)
        }
        guard let a = parts(lhs), let b = parts(rhs) else {
            return false
        }
        return a == b
    }

    // MARK: The app group copy

    /// The configuration as the app shares it with its extensions (only what they use: pins and the server
    /// restriction; nothing else of the managed dictionary).
    public var sharedWithExtensions: MattermostManagedConfiguration {
        return MattermostManagedConfiguration(serverURL: self.serverURL, allowOtherServers: self.allowOtherServers, certificatePins: self.certificatePins)
    }

    public static func readShared(directory: URL) -> MattermostManagedConfiguration? {
        let url = directory.appendingPathComponent(self.sharedFileName)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(MattermostManagedConfiguration.self, from: data)
    }

    /// Writes (or, for an unmanaged configuration, removes) the extensions' copy.
    public func writeShared(directory: URL) throws {
        let url = directory.appendingPathComponent(MattermostManagedConfiguration.sharedFileName)
        let shared = self.sharedWithExtensions
        if shared == .none {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(shared).write(to: url, options: .atomic)
    }

    // MARK: Values

    static func string(_ value: Any?) -> String? {
        let text: String?
        switch value {
        case let value as String:
            text = value
        case let value as NSNumber:
            text = value.stringValue
        default:
            text = nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on":
                return true
            case "false", "no", "0", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
