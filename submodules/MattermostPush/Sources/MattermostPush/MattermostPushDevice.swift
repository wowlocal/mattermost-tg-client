import Foundation

/// The APNs environment a device token belongs to. It follows the `aps-environment` entitlement:
/// development builds (and the simulator) get sandbox tokens, App Store, TestFlight and ad-hoc builds
/// production tokens. Sending a token to the other environment fails with `BadDeviceToken`.
public enum MattermostPushEnvironment: String, Equatable, Sendable {
    case sandbox
    case production
}

/// Device ids for `PUT /users/sessions/device` (`"<platform>:<APNs token in hex>"`).
///
/// The server splits the id at the first `:` and hands the platform to the push proxy, which sends the push
/// with the `ApplePushSettings` entry whose `Type` equals the platform (`infra/push-proxy`): `relay_apple`
/// (production APNs) and `relay_apple_sandbox` (sandbox APNs), both with topic `org.relaychat.Relay`. The
/// official Mattermost apps use `apple_rn` / `apple_rnbeta` with their own topics, so Relay can't use
/// Mattermost's hosted push proxy. No `-v<N>` suffix: the proxy reads one as an app version and strips
/// it; version 1 (the default) keeps the server's badge on `clear` pushes.
public enum MattermostPushDevice {
    public static let productionPlatform = "relay_apple"
    public static let sandboxPlatform = "relay_apple_sandbox"
    /// `platform` of `POST /notifications/ack`. The server special-cases `"ios"` (it re-enables pushes for a
    /// session whose device had them turned off).
    public static let ackPlatform = "ios"

    public static func platform(_ environment: MattermostPushEnvironment) -> String {
        switch environment {
        case .sandbox:
            return self.sandboxPlatform
        case .production:
            return self.productionPlatform
        }
    }

    public static func hexToken(_ token: Data) -> String {
        return token.map { String(format: "%02x", $0) }.joined()
    }

    public static func deviceId(token: Data, environment: MattermostPushEnvironment) -> String {
        return "\(self.platform(environment)):\(self.hexToken(token))"
    }

    /// The environment from the `aps-environment` of an embedded provisioning profile. Without a profile
    /// (App Store builds have none) the token is a production one; the simulator always gets sandbox tokens.
    public static func environment(isSimulator: Bool, embeddedProfile: Data?) -> MattermostPushEnvironment {
        if isSimulator {
            return .sandbox
        }
        guard let embeddedProfile = embeddedProfile else {
            return .production
        }
        // The profile is a CMS envelope around an XML plist; the plist is readable in place.
        let text = String(decoding: embeddedProfile, as: UTF8.self)
        guard let keyRange = text.range(of: "<key>aps-environment</key>") else {
            return .production
        }
        let rest = text[keyRange.upperBound...]
        guard let open = rest.range(of: "<string>"), let close = rest.range(of: "</string>", range: open.upperBound ..< rest.endIndex) else {
            return .production
        }
        let value = rest[open.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "development" ? .sandbox : .production
    }

    /// The environment of the running app.
    public static func currentEnvironment(bundle: Bundle = .main) -> MattermostPushEnvironment {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        return self.environment(isSimulator: isSimulator, embeddedProfile: profile)
    }
}

/// What was last registered for one account, kept in the account's sync store. A registration is repeated
/// when the token, the environment or the app version changes (and after a new login: the cursor goes with
/// the old session's store row only if the store is reused, so `MattermostSync` clears it on re-login).
public struct MattermostPushRegistrationRecord: Codable, Equatable, Sendable {
    public var deviceId: String
    public var appVersion: String
    /// Seconds since 1970.
    public var registeredAt: Double

    public init(deviceId: String, appVersion: String, registeredAt: Double) {
        self.deviceId = deviceId
        self.appVersion = appVersion
        self.registeredAt = registeredAt
    }

    /// Re-register at least this often, so a session the server dropped the device from (an APNs
    /// "unregistered" answer clears it) gets it back.
    public static let refreshInterval: Double = 7 * 24 * 60 * 60

    public func needsRegistration(deviceId: String, appVersion: String, now: Double) -> Bool {
        return self.deviceId != deviceId || self.appVersion != appVersion || now - self.registeredAt > MattermostPushRegistrationRecord.refreshInterval
    }

    public var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    public init?(encoded: String?) {
        guard let encoded = encoded, let value = try? JSONDecoder().decode(MattermostPushRegistrationRecord.self, from: Data(encoded.utf8)) else {
            return nil
        }
        self = value
    }
}
