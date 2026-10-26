import Foundation

/// Scrubs text that leaves the device in an exported diagnostics bundle (Phase 4G, docs/release/privacy.md):
/// Relay's logs never carry message text, passwords or session tokens (checked when this was written), but they
/// do carry Mattermost ids and may carry what a server or the system put into an error. Before export:
///
/// - credentials: `Bearer …`, `token=…`, `"password": "…"`, `MMAUTHTOKEN=…` and similar key/value pairs → `<redacted>`;
/// - Mattermost ids (26 lowercase letters and digits: users, channels, posts, teams, files) → `<id:xxxxxx>`, a
///   salted hash that is the same for the same id within one export (so a log can still be followed) but
///   can't be matched across exports or with the server;
/// - email addresses → `<email>`;
/// - APNs device tokens (64 hex digits) → `<device-token>`.
public struct DiagnosticsRedactor {
    private let salt: Data

    /// - Parameter salt: Random per export by default; fixed in tests.
    public init(salt: Data? = nil) {
        if let salt {
            self.salt = salt
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0 ... 255)
            }
            self.salt = Data(bytes)
        }
    }

    private static let credentialPatterns: [NSRegularExpression] = [
        // Authorization: Bearer <token>
        try! NSRegularExpression(pattern: "(?i)\\b(bearer|token)\\s+[A-Za-z0-9._~+/=-]{8,}"),
        // key=value / "key": "value" for secret-looking keys
        try! NSRegularExpression(pattern: "(?i)([\"']?\\b(?:[a-z_-]*token|password|passwd|secret|csrf|authorization|cookie|mmauthtoken|mmcsrf)\\b[\"']?\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s&,;)\\]}]+)")
    ]
    private static let emailPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let deviceTokenPattern = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{64}\\b")
    private static let mattermostIdPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])[a-z0-9]{26}(?![A-Za-z0-9])")

    /// Redacts a whole log: line by line (every pattern is within a line), which keeps it linear in the size of
    /// the log (NSRange ↔ String.Index conversions on a multi-megabyte string are not).
    public func redact(_ text: String) -> String {
        guard text.utf8.count > 4096 else {
            return self.redactLine(text)
        }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var isFirst = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !isFirst {
                result.append("\n")
            }
            isFirst = false
            result.append(self.redactLine(String(line)))
        }
        return result
    }

    private func redactLine(_ text: String) -> String {
        var result = text
        for pattern in DiagnosticsRedactor.credentialPatterns {
            result = Self.replace(pattern, in: result) { match, string in
                if match.numberOfRanges >= 3, let key = Range(match.range(at: 1), in: string) {
                    return String(string[key]) + "<redacted>"
                }
                if let all = Range(match.range, in: string), let space = string[all].firstIndex(where: { $0.isWhitespace }) {
                    return String(string[all.lowerBound ..< space]) + " <redacted>"
                }
                return "<redacted>"
            }
        }
        result = Self.replace(DiagnosticsRedactor.emailPattern, in: result) { _, _ in "<email>" }
        result = Self.replace(DiagnosticsRedactor.deviceTokenPattern, in: result) { _, _ in "<device-token>" }
        result = Self.replace(DiagnosticsRedactor.mattermostIdPattern, in: result) { match, string in
            guard let range = Range(match.range, in: string) else {
                return "<id>"
            }
            let id = String(string[range])
            // Plain words of 26 letters don't occur in the logs; ids always contain digits or look random.
            return "<id:\(self.pseudonym(id))>"
        }
        return result
    }

    /// Six hex digits of a salted FNV-1a hash: stable within this redactor, meaningless outside it.
    public func pseudonym(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self.salt + Data(value.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%06x", hash & 0xFFFFFF)
    }

    private static func replace(_ pattern: NSRegularExpression, in string: String, with replacement: (NSTextCheckingResult, String) -> String) -> String {
        let matches = pattern.matches(in: string, range: NSRange(string.startIndex..., in: string))
        guard !matches.isEmpty else {
            return string
        }
        var result = ""
        var last = string.startIndex
        for match in matches {
            guard let range = Range(match.range, in: string) else {
                continue
            }
            result += string[last ..< range.lowerBound]
            result += replacement(match, string)
            last = range.upperBound
        }
        result += string[last...]
        return result
    }
}
