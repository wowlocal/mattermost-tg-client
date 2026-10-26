import Foundation

/// Turns what a user types into the server field into a server URL.
public enum ServerAddress {
    public enum NormalizationError: Error, Sendable, Equatable {
        /// Nothing (or only whitespace) was entered.
        case empty
        /// Not a URL with a host, or a scheme other than http/https.
        case invalid
        /// `http://` for a host that is not local, or `http://` while insecure connections are off.
        case insecureNotAllowed
    }

    /// Normalizes user input to a server URL:
    /// - trims whitespace and adds `https://` when no scheme is given;
    /// - lowercases the scheme and host, drops user info, query and fragment, and trailing slashes of the
    ///   path (a subpath such as `https://example.com/mattermost` stays);
    /// - accepts `http://` only when `allowInsecureLocal` is set and the host is local (see `isLocalHost`).
    public static func normalize(_ input: String, allowInsecureLocal: Bool) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw NormalizationError.empty
        }
        if text.contains(where: { $0.isWhitespace }) {
            throw NormalizationError.invalid
        }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty else {
            throw NormalizationError.invalid
        }
        switch scheme {
        case "https":
            break
        case "http":
            if !allowInsecureLocal || !isLocalHost(host) {
                throw NormalizationError.insecureNotAllowed
            }
        default:
            throw NormalizationError.invalid
        }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        guard let url = components.url else {
            throw NormalizationError.invalid
        }
        return url
    }

    /// `localhost`, `*.local`, loopback and private-network IPv4 addresses (10/8, 172.16/12, 192.168/16,
    /// 169.254/16), IPv6 loopback and unique-local addresses.
    public static func isLocalHost(_ host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return host.contains(":")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254):
            return true
        case (172, let second):
            return (16...31).contains(second)
        default:
            return false
        }
    }
}

/// Which Mattermost servers the app supports.
public enum ServerCompatibility {
    /// The oldest supported server: the current Extended Support Release (docs/plan/09, decision D2).
    /// Change this one value to move the minimum.
    public static let minimumVersion = ServerVersion(major: 11, minor: 7)

    public enum Result: Sendable, Equatable {
        case supported(ServerVersion)
        case tooOld(ServerVersion, minimum: ServerVersion)
        /// The server reported no (parsable) version.
        case unknown
    }

    /// Checks a version string such as the client config's `Version` (`"11.7.14"`).
    public static func check(version: String?, minimum: ServerVersion = ServerCompatibility.minimumVersion) -> Result {
        guard let version = version.flatMap(ServerVersion.init) else {
            return .unknown
        }
        if version < minimum {
            return .tooOld(version, minimum: minimum)
        }
        return .supported(version)
    }
}
