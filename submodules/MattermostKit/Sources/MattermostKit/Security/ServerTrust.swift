import Foundation
import Security

/// The process-wide certificate pinning policy (Phase 4G) of every connection MattermostKit makes: REST requests,
/// uploads, downloads and WebSocket connections of the default session (`MattermostURLSession.current`). Off (no
/// pins) by default; the app sets the pins from managed configuration, the extensions from the app group copy the
/// app writes. After a change, `MattermostURLSession.renew()` so no connection opened under the old pins is reused.
///
/// Fail-closed only for pinned hosts: a pinned host's connection fails when the system doesn't trust the chain
/// or no certificate in it has a pinned key; other hosts are evaluated by the system as usual.
public final class MattermostServerTrust: @unchecked Sendable {
    public static let shared = MattermostServerTrust()

    public enum Decision: Equatable, Sendable {
        /// The host is not pinned: the system decides.
        case systemDefault
        /// Trusted by the system, and a certificate of the chain has a pinned key.
        case accept
        /// Pinned, and the system doesn't trust the chain or no key matches.
        case reject
    }

    private let lock = NSLock()
    private var pinsValue = MattermostCertificatePins.empty
    private var rejections: [String: Date] = [:]

    public init(pins: MattermostCertificatePins = .empty) {
        self.pinsValue = pins
    }

    public var pins: MattermostCertificatePins {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pinsValue
    }

    public func setPins(_ pins: MattermostCertificatePins) {
        self.lock.lock()
        self.pinsValue = pins
        self.rejections.removeAll()
        self.lock.unlock()
    }

    /// Evaluates a server trust for `host`. Rejections are remembered for a moment, so the failed request can
    /// report a pin mismatch instead of the cancellation URLSession reports (`wasRecentlyRejected`).
    public func evaluate(_ trust: SecTrust, host: String) -> Decision {
        guard let pins = self.pins.pins(forHost: host) else {
            return .systemDefault
        }
        let decision = MattermostServerTrust.evaluate(trust, pins: pins)
        if decision == .reject {
            self.lock.lock()
            self.rejections[host.lowercased()] = Date()
            self.lock.unlock()
        }
        return decision
    }

    /// The decision for a chain against a host's pins (`pins` empty: nothing can match).
    public static func evaluate(_ trust: SecTrust, pins: Set<String>) -> Decision {
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return .reject
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        for certificate in chain {
            if let digest = MattermostCertificatePins.spkiSHA256(certificate: certificate), pins.contains(digest) {
                return .accept
            }
        }
        return .reject
    }

    /// Whether a connection to `host` was refused by its pins in the last few seconds.
    public func wasRecentlyRejected(host: String?, within interval: TimeInterval = 10.0) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let date = self.rejections[host] else {
            return false
        }
        return Date().timeIntervalSince(date) < interval
    }

    /// The `URLError` a request to `host` fails with when its pins refused the server. Its `userInfo` carries
    /// `pinMismatchHostKey`, so callers can tell it from other certificate errors.
    public static func pinMismatchError(host: String) -> URLError {
        return URLError(.serverCertificateUntrusted, userInfo: [
            MattermostServerTrust.pinMismatchHostKey: host,
            NSLocalizedDescriptionKey: "The certificate of \(host) doesn't match the pinned certificates."
        ])
    }

    public static let pinMismatchHostKey = "MattermostPinMismatchHost"

    /// The URLSession answer to a server trust challenge under `policy`.
    public static func handle(_ challenge: URLAuthenticationChallenge, policy: MattermostServerTrust, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch policy.evaluate(trust, host: challenge.protectionSpace.host) {
        case .systemDefault:
            completionHandler(.performDefaultHandling, nil)
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .reject:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

extension URLError {
    /// The host whose pins refused the server, when this error is a pin mismatch (`MattermostServerTrust`).
    public var mattermostPinMismatchHost: String? {
        return self.userInfo[MattermostServerTrust.pinMismatchHostKey] as? String
    }
}

/// A session delegate that applies `MattermostServerTrust` to server trust challenges.
public final class MattermostServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: MattermostServerTrust

    public init(policy: MattermostServerTrust = .shared) {
        self.policy = policy
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        MattermostServerTrust.handle(challenge, policy: self.policy, completionHandler: completionHandler)
    }
}

/// The URLSession MattermostKit uses unless one is injected (REST and WebSocket): `URLSession.shared`'s
/// configuration with `MattermostServerTrust.shared` applied to every server trust challenge.
///
/// URLSession evaluates a server's certificate when it opens a connection, not for every request: a kept-alive
/// connection, or a TLS session it resumes, is reused without asking again (measured in 4G: a login probe went
/// through after wrong pins were set, on the connection opened before). `renew()` therefore replaces the session when
/// the pins change: new requests open new connections in a new session (nothing to resume), the old session finishes
/// what it is doing and is invalidated. Open WebSockets keep their connection until they reconnect.
public enum MattermostURLSession {
    private static let lock = NSLock()
    private static var session = MattermostURLSession.makeSession()

    public static var current: URLSession {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.session
    }

    public static func renew() {
        self.lock.lock()
        let previous = self.session
        self.session = MattermostURLSession.makeSession()
        self.lock.unlock()
        previous.finishTasksAndInvalidate()
    }

    private static func makeSession() -> URLSession {
        return URLSession(configuration: .default, delegate: MattermostServerTrustDelegate(), delegateQueue: nil)
    }
}

extension MattermostError {
    /// Wraps an error of a request to `url`: a cancellation that the request's task didn't ask for, right after
    /// the host's pins refused the server, is the pin mismatch (URLSession reports a refused challenge as a
    /// cancellation).
    static func wrap(_ error: Error, url: URL?) -> MattermostError {
        let wrapped = MattermostError.wrap(error)
        if wrapped == .cancelled, !Task.isCancelled, let host = url?.host, MattermostServerTrust.shared.wasRecentlyRejected(host: host) {
            return .transport(MattermostServerTrust.pinMismatchError(host: host))
        }
        return wrapped
    }
}
