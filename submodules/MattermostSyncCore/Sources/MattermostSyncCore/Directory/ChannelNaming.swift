import Foundation

/// Channel names as Mattermost's clients make and check them (Phase 3D-2, "New Channel" and channel settings).
///
/// A channel has a display name (what the user types) and a URL name (lowercase, unique in its team). The URL
/// name is derived from the display name as the web and mobile apps do (`cleanUpUrlable`): dashes become spaces,
/// characters other than ASCII letters, digits, `_` and whitespace are dropped, the rest is lowercased, whitespace
/// becomes `-`, runs of `-` collapse and leading/trailing `-` are trimmed. A display name with nothing left (only
/// non-Latin letters, emoji) gets a generated name, as in the mobile app.
public enum ChannelNaming {
    /// Server limits (`model.ChannelNameMaxLength`, `ChannelDisplayNameMaxRunes`, `ChannelPurposeMaxRunes`,
    /// `ChannelHeaderMaxRunes`).
    public static let urlNameMinLength = 2
    public static let urlNameMaxLength = 64
    public static let displayNameMaxLength = 64
    public static let purposeMaxLength = 250
    public static let headerMaxLength = 1024

    public enum URLNameError: Equatable {
        case tooShort
        case tooLong
        /// Characters other than `a-z`, `0-9`, `-` and `_`.
        case invalidCharacters
        /// Must start and end with a letter or digit.
        case badEdges
        /// `__` is reserved for direct message channel names.
        case doubleUnderscore
    }

    public enum DisplayNameError: Equatable {
        case empty
        case tooLong
    }

    /// The URL name the apps propose for a display name; `fallback` (e.g. a generated id) when nothing usable
    /// is left.
    public static func urlName(fromDisplayName displayName: String, fallback: () -> String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in displayName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: " ").unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingDash = !result.isEmpty
                continue
            }
            let isASCIIWord = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            guard isASCIIWord else {
                continue
            }
            if pendingDash {
                result.append("-")
                pendingDash = false
            }
            result.append(String(scalar).lowercased())
        }
        if result.count > self.urlNameMaxLength {
            result = String(result.prefix(self.urlNameMaxLength))
            while result.hasSuffix("-") {
                result.removeLast()
            }
        }
        if result.count < self.urlNameMinLength || self.validate(urlName: result) != nil {
            return fallback()
        }
        return result
    }

    /// Why the server would reject this URL name, or nil.
    public static func validate(urlName name: String) -> URLNameError? {
        if name.count < self.urlNameMinLength {
            return .tooShort
        }
        if name.count > self.urlNameMaxLength {
            return .tooLong
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        if name.contains(where: { !allowed.contains($0) }) {
            return .invalidCharacters
        }
        let alphanumeric = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        guard let first = name.first, let last = name.last, alphanumeric.contains(first), alphanumeric.contains(last) else {
            return .badEdges
        }
        if name.contains("__") {
            return .doubleUnderscore
        }
        return nil
    }

    public static func validate(displayName: String) -> DisplayNameError? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }
        if trimmed.count > self.displayNameMaxLength {
            return .tooLong
        }
        return nil
    }

    /// A random 26-character lowercase id, the shape of Mattermost ids (the fallback URL name).
    public static func generatedName() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var result = String(alphabet[Int.random(in: 0 ..< 26)])
        for _ in 1 ..< 26 {
            result.append(alphabet[Int.random(in: 0 ..< alphabet.count)])
        }
        return result
    }
}
