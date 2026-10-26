import Foundation

/// Where a Mattermost link leads inside a server (Phase 3E). Team names are nil for `/_redirect/…` links, which
/// Mattermost resolves to the user's team.
public enum MattermostLinkRoute: Equatable, Sendable {
    /// `/<team>/pl/<post id>` (a permalink), `/_redirect/pl/<post id>`.
    case post(teamName: String?, postId: String)
    /// `/<team>/channels/<channel name>`, `/_redirect/channels/<channel name>` (channel mentions).
    case channel(teamName: String?, channelName: String)
    /// `/<team>/messages/@<username>`.
    case directMessage(teamName: String?, username: String)
    /// `/<team>/messages/<group message channel name>`.
    case groupMessage(teamName: String?, channelName: String)
    /// `/<team>/threads/<root post id>` (collapsed reply threads).
    case thread(teamName: String?, rootId: String)
}

/// A link into one of the given Mattermost servers.
public struct MattermostLink: Equatable, Sendable {
    /// Index into the `servers` the link was parsed against.
    public var serverIndex: Int
    public var route: MattermostLinkRoute

    public init(serverIndex: Int, route: MattermostLinkRoute) {
        self.serverIndex = serverIndex
        self.route = route
    }

    /// The app's own URL schemes. `relay://<host>[:<port>][/<server path>]/<route>` names the server by host (and
    /// port, and the path a server is installed under), e.g. `relay://chat.example.com/eng/pl/<post id>`;
    /// `mattermost://` links (Mattermost's mobile app, same layout) are understood when they are opened inside the
    /// app.
    public static let appSchemes = ["relay", "mattermost"]

    /// Parses `string` as a link into one of `servers` (base URLs such as `https://chat.example.com` or
    /// `https://example.com/mattermost`; a server's `SiteURL` may be listed as a separate entry): web links on the
    /// server's scheme-independent host, port and path, and app-scheme links. Nil for anything else (other hosts,
    /// paths that aren't a post, channel, DM, group message or thread).
    public static func parse(_ string: String, servers: [String]) -> MattermostLink? {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let isWeb = scheme == "http" || scheme == "https"
        let isApp = appSchemes.contains(scheme)
        guard isWeb || isApp else {
            return nil
        }
        let linkPath = components.percentEncodedPath
        var best: (index: Int, prefixLength: Int, exactPort: Bool)?
        for (index, server) in servers.enumerated() {
            guard let base = ServerBase(server), base.host == host else {
                continue
            }
            var exactPort = true
            if let port = components.port {
                guard port == base.port else {
                    continue
                }
            } else if isWeb {
                guard base.port == defaultPort(scheme: scheme) else {
                    continue
                }
            } else {
                // An app link without a port: the server on the default port of its own scheme comes first.
                exactPort = base.port == defaultPort(scheme: base.scheme)
            }
            guard base.path.isEmpty || linkPath == base.path || linkPath.hasPrefix(base.path + "/") else {
                continue
            }
            let candidate = (index, base.path.count, exactPort)
            if let current = best {
                if (candidate.2 && !current.exactPort) || (candidate.2 == current.exactPort && candidate.1 > current.prefixLength) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        guard let match = best, let base = ServerBase(servers[match.index]) else {
            return nil
        }
        let rest = String(linkPath.dropFirst(base.path.count))
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map { $0.removingPercentEncoding ?? String($0) }
        guard let route = self.route(parts) else {
            return nil
        }
        return MattermostLink(serverIndex: match.index, route: route)
    }

    /// The web permalink of a post, as Mattermost's "Copy Link" makes it: `<server>/<team>/pl/<post id>`.
    public static func permalink(serverURL: String, teamName: String, postId: String) -> String {
        return trimmedBase(serverURL) + "/" + teamName + "/pl/" + postId
    }

    /// The `relay://` form of a web link into `serverURL` (same path, the server named by host and port).
    public static func appLink(webLink: String, scheme: String = "relay") -> String? {
        guard var components = URLComponents(string: webLink), let webScheme = components.scheme?.lowercased(), webScheme == "http" || webScheme == "https" else {
            return nil
        }
        if components.port == defaultPort(scheme: webScheme) {
            components.port = nil
        }
        components.scheme = scheme
        return components.string
    }

    static func route(_ parts: [String]) -> MattermostLinkRoute? {
        guard parts.count >= 3 else {
            return nil
        }
        let team = parts[0]
        let teamName: String? = team == "_redirect" ? nil : team
        if let teamName = teamName, !isTeamName(teamName) {
            return nil
        }
        let value = parts[2]
        switch parts[1] {
        case "pl":
            return isId(value) ? .post(teamName: teamName, postId: value) : nil
        case "threads":
            return isId(value) ? .thread(teamName: teamName, rootId: value) : nil
        case "channels":
            return isChannelName(value) ? .channel(teamName: teamName, channelName: value) : nil
        case "messages":
            if value.hasPrefix("@") {
                let username = String(value.dropFirst()).lowercased()
                return username.isEmpty ? nil : .directMessage(teamName: teamName, username: username)
            }
            return isChannelName(value) ? .groupMessage(teamName: teamName, channelName: value) : nil
        default:
            return nil
        }
    }

    /// Mattermost ids: 26 characters of `[a-z0-9]`.
    static func isId(_ value: String) -> Bool {
        return value.count == 26 && value.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
    }

    static func isTeamName(_ value: String) -> Bool {
        return !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_" }
    }

    static func isChannelName(_ value: String) -> Bool {
        return !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_" }
    }

    static func defaultPort(scheme: String) -> Int {
        return scheme == "https" ? 443 : 80
    }

    static func trimmedBase(_ serverURL: String) -> String {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    private struct ServerBase {
        var scheme: String
        var host: String
        var port: Int
        /// Percent-encoded path without a trailing slash ("" for a server at the root).
        var path: String

        init?(_ serverURL: String) {
            guard let components = URLComponents(string: MattermostLink.trimmedBase(serverURL)), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty else {
                return nil
            }
            self.scheme = scheme
            self.host = host
            self.port = components.port ?? MattermostLink.defaultPort(scheme: scheme)
            var path = components.percentEncodedPath
            while path.hasSuffix("/") {
                path.removeLast()
            }
            self.path = path
        }
    }
}
