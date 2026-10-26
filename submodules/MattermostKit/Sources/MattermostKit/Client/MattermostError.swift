import Foundation

public enum MattermostError: Error, Sendable, Equatable {
    /// HTTP 401: missing, invalid or expired session, or bad login credentials.
    case unauthorized(AppError?)
    /// HTTP 403.
    case forbidden(AppError?)
    /// HTTP 404.
    case notFound(AppError?)
    /// HTTP 429. `retryAfter` comes from `Retry-After` (or `X-RateLimit-Reset`).
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx response. If the body was not a Mattermost error (for
    /// example an HTML page from a proxy), an `AppError` is synthesised with the
    /// HTTP status code and an empty `id`.
    case server(AppError)
    /// Network-level failure (offline, DNS, TLS, timeout, bad URL, file access).
    case transport(URLError)
    /// A 2xx response whose body could not be interpreted.
    case decoding(String)
    /// The task or request was cancelled.
    case cancelled
}

extension MattermostError {
    /// Transport errors compare by `URLError.Code` only; URLSession attaches
    /// request-specific `userInfo` that is irrelevant for equality.
    public static func == (lhs: MattermostError, rhs: MattermostError) -> Bool {
        switch (lhs, rhs) {
        case let (.unauthorized(a), .unauthorized(b)), let (.forbidden(a), .forbidden(b)), let (.notFound(a), .notFound(b)):
            return a == b
        case let (.rateLimited(a), .rateLimited(b)):
            return a == b
        case let (.server(a), .server(b)):
            return a == b
        case let (.transport(a), .transport(b)):
            return a.code == b.code
        case let (.decoding(a), .decoding(b)):
            return a == b
        case (.cancelled, .cancelled):
            return true
        default:
            return false
        }
    }

    /// The HTTP status code, if the error came from an HTTP response.
    public var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .rateLimited: return 429
        case .server(let error): return error.statusCode
        case .transport, .decoding, .cancelled: return nil
        }
    }

    /// The server's error body, when there was one.
    public var appError: AppError? {
        switch self {
        case .unauthorized(let error), .forbidden(let error), .notFound(let error): return error
        case .server(let error): return error
        case .rateLimited, .transport, .decoding, .cancelled: return nil
        }
    }

    /// Whether retrying the same request later may succeed: network errors,
    /// rate limiting and 5xx responses. Never true for other 4xx responses.
    public var isTransient: Bool {
        switch self {
        case .transport, .rateLimited:
            return true
        case .server(let error):
            return error.statusCode >= 500 || error.statusCode == 408
        case .unauthorized, .forbidden, .notFound, .decoding, .cancelled:
            return false
        }
    }

    /// The login failed because an MFA token is required.
    ///
    /// Assumption: the server reports this as a 401 with one of these error IDs;
    /// verify against the minimum supported server version.
    public var isMFARequired: Bool {
        guard let id = appError?.id else { return false }
        return id == "mfa.validate_token.authenticate.app_error"
            || id == "ent.mfa.validate_token.authenticate.app_error"
    }

    /// The session token is no longer valid; the user must log in again.
    public var isSessionExpired: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

extension MattermostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let error):
            return error?.errorDescription ?? "Unauthorized"
        case .forbidden(let error):
            return error?.errorDescription ?? "Forbidden"
        case .notFound(let error):
            return error?.errorDescription ?? "Not found"
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Rate limited; retry after \(Int(retryAfter.rounded(.up))) s" }
            return "Rate limited"
        case .server(let error):
            return error.errorDescription
        case .transport(let error):
            return error.localizedDescription
        case .decoding(let description):
            return "Unexpected server response: \(description)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

// MARK: - Mapping

extension MattermostError {
    /// Maps a non-2xx HTTP response.
    static func from(response: HTTPURLResponse, body: Data, now: Date = Date()) -> MattermostError {
        let status = response.statusCode
        var appError = (try? JSONDecoder().decode(AppError.self, from: body)).flatMap { error -> AppError? in
            // A JSON body that isn't an AppError decodes to all-empty fields.
            (error.id.isEmpty && error.message.isEmpty) ? nil : error
        }
        if appError != nil, appError?.statusCode == 0 {
            appError?.statusCode = status
        }
        switch status {
        case 401:
            return .unauthorized(appError)
        case 403:
            return .forbidden(appError)
        case 404:
            return .notFound(appError)
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: response, now: now))
        default:
            if let appError {
                return .server(appError)
            }
            let snippet = String(decoding: body.prefix(512), as: UTF8.self)
            return .server(AppError(
                message: HTTPURLResponse.localizedString(forStatusCode: status),
                detailedError: snippet,
                statusCode: status
            ))
        }
    }

    /// Wraps a thrown error (URLSession, cancellation, decoding).
    static func wrap(_ error: Error) -> MattermostError {
        if let error = error as? MattermostError {
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .transport(error)
        }
        if error is DecodingError {
            return .decoding(String(describing: error))
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            return code == .cancelled ? .cancelled : .transport(URLError(code))
        }
        if nsError.domain == NSCocoaErrorDomain {
            return .transport(URLError(.cannotOpenFile))
        }
        return .transport(URLError(.unknown))
    }

    static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) {
            if let seconds = TimeInterval(value) {
                return max(0, seconds)
            }
            if let date = httpDateFormatter().date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        // Mattermost's rate limiter also reports seconds until reset.
        if let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        return nil
    }

    private static func httpDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }
}
