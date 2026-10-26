import Foundation
import Postbox
import TelegramCore
import MattermostKit

/// One of the user's Mattermost login sessions (Settings → Devices).
public struct MattermostDeviceSession: Equatable {
    public let id: String
    /// "Chrome", "Desktop App", "Mattermost Mobile", "Personal access token", …
    public let client: String
    /// Operating system / platform as the server parsed it from the user agent; empty when unknown.
    public let system: String
    /// Unix seconds.
    public let lastActivity: Int32
    public let created: Int32
    /// This app's session on this device.
    public let isCurrent: Bool
    public let isMobile: Bool
}

public enum MattermostSessionsError: Error, Equatable {
    /// The account's sync is not running (logged out, or the session expired).
    case notConnected
    /// The current session can't be told apart (the account logged in before Relay recorded it): revoking
    /// "all other" sessions could end this one.
    case currentSessionUnknown
    case server(String)
}

extension MattermostSync {
    /// The user's sessions (`GET /users/me/sessions`): the current one first, then by last activity.
    public static func deviceSessions(accountId: AccountRecordId) async throws -> [MattermostDeviceSession] {
        guard let sync = self.sync(accountId: accountId), !sync.isStopped else {
            throw MattermostSessionsError.notConnected
        }
        let csrf = sync.store.cursor(self.sessionCSRFCursor)
        let sessions: [Session]
        do {
            sessions = try await sync.client.sessions()
        } catch {
            throw MattermostSessionsError.server(describeError(error))
        }
        let result = sessions.map { session -> MattermostDeviceSession in
            let isCurrent = csrf != nil && session.csrfToken == csrf
            return MattermostDeviceSession(
                id: session.id,
                // The server parses Relay's user agent as "Desktop App"; this session is known to be Relay.
                client: isCurrent ? "Relay" : self.clientName(session),
                system: isCurrent ? "iOS" : self.systemName(session),
                lastActivity: Int32(clamping: max(session.lastActivityAt, session.createAt) / 1000),
                created: Int32(clamping: session.createAt / 1000),
                isCurrent: isCurrent,
                isMobile: session.isMobile
            )
        }
        return result.sorted(by: { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent {
                return lhs.isCurrent
            }
            return lhs.lastActivity > rhs.lastActivity
        })
    }

    /// Whether the current session is known (recorded at login), i.e. "Terminate all other sessions" is safe.
    public static func knowsCurrentDeviceSession(accountId: AccountRecordId) -> Bool {
        return self.sync(accountId: accountId)?.store.cursor(self.sessionCSRFCursor) != nil
    }

    /// Ends one session (`POST /users/me/sessions/revoke`): that device is logged out.
    public static func revokeDeviceSession(accountId: AccountRecordId, sessionId: String) async throws {
        guard let sync = self.sync(accountId: accountId), !sync.isStopped else {
            throw MattermostSessionsError.notConnected
        }
        do {
            try await sync.client.revokeSession(id: sessionId)
            MMLog.log("sessions: revoked \(sessionId)")
        } catch {
            throw MattermostSessionsError.server(describeError(error))
        }
    }

    /// Ends every session but the current one, one by one (Mattermost's `revoke/all` would end this one
    /// too). Returns how many were ended.
    @discardableResult
    public static func revokeOtherDeviceSessions(accountId: AccountRecordId) async throws -> Int {
        let sessions = try await self.deviceSessions(accountId: accountId)
        guard sessions.contains(where: { $0.isCurrent }) else {
            throw MattermostSessionsError.currentSessionUnknown
        }
        var count = 0
        for session in sessions where !session.isCurrent {
            try await self.revokeDeviceSession(accountId: accountId, sessionId: session.id)
            count += 1
        }
        return count
    }

    private static func clientName(_ session: Session) -> String {
        if session.isAccessToken {
            return "Personal access token"
        }
        if session.isOAuth {
            return "OAuth app"
        }
        let deviceId = session.deviceId.lowercased()
        if deviceId.hasPrefix("relay") {
            return "Relay"
        }
        if deviceId.hasPrefix("apple") || deviceId.hasPrefix("android") {
            return "Mattermost Mobile"
        }
        var browser = session.props["browser"] ?? ""
        if browser.hasSuffix("/0.0") {
            browser.removeLast(4)
        }
        if browser.isEmpty || browser == "Unknown" {
            return session.isMobile ? "Mobile app" : "Unknown client"
        }
        return browser.replacingOccurrences(of: "/", with: " ")
    }

    private static func systemName(_ session: Session) -> String {
        let deviceId = session.deviceId.lowercased()
        if deviceId.contains("apple") {
            return "iOS"
        }
        if deviceId.hasPrefix("android") {
            return "Android"
        }
        // "Mac OS" / "Windows 10" when known, else the platform ("Macintosh", "Linux").
        let os = session.props["os"] ?? ""
        let platform = session.props["platform"] ?? ""
        for value in [os, platform] where !value.isEmpty && value != "Unknown" {
            return value
        }
        return ""
    }
}
