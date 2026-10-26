import Foundation

/// Mattermost post search terms (Phase 3C): the user's query as typed (Mattermost modifiers included) plus the
/// scope Telegram's search UI asks for (a chat, an author, a date range), the words to highlight in results,
/// and the terms of the "Recent Mentions" search.
///
/// Modifiers the server understands and that are passed through unchanged: `from:<username>`,
/// `in:<channel name | @username | channel id>`, `before:`/`after:`/`on:` `YYYY-MM-DD`, `"quoted phrases"`,
/// `-excluded` words and `#hashtags`. Several `in:`/`from:` values widen the search (the server ORs them).
public enum SearchQuery {
    public enum Token: Equatable {
        /// `name:value` with a known modifier name (lowercased).
        case modifier(name: String, value: String)
        /// A quoted phrase, without the quotes.
        case phrase(String)
        /// `-word` or `-"phrase"`.
        case excluded(String)
        /// `#tag` (without `#`).
        case hashtag(String)
        /// `@name` (without `@`).
        case mention(String)
        case word(String)
    }

    public static let modifierNames: Set<String> = ["from", "in", "channel", "before", "after", "on", "ext"]

    /// Splits a query into tokens; an unterminated quote runs to the end.
    public static func tokenize(_ query: String) -> [Token] {
        var tokens: [Token] = []
        var index = query.startIndex
        while index < query.endIndex {
            let character = query[index]
            if character.isWhitespace {
                index = query.index(after: index)
                continue
            }
            var excluded = false
            var start = index
            if character == "-" {
                let next = query.index(after: index)
                if next < query.endIndex, !query[next].isWhitespace {
                    excluded = true
                    start = next
                }
            }
            if query[start] == "\"" {
                let contentStart = query.index(after: start)
                let end = query[contentStart...].firstIndex(of: "\"") ?? query.endIndex
                let phrase = String(query[contentStart ..< end]).trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty {
                    tokens.append(excluded ? .excluded(phrase) : .phrase(phrase))
                }
                index = end < query.endIndex ? query.index(after: end) : end
                continue
            }
            let end = query[start...].firstIndex(where: { $0.isWhitespace }) ?? query.endIndex
            let word = String(query[start ..< end])
            index = end
            if excluded {
                tokens.append(.excluded(word))
                continue
            }
            if let colon = word.firstIndex(of: ":"), colon != word.startIndex {
                let name = word[..<colon].lowercased()
                let value = String(word[word.index(after: colon)...])
                if self.modifierNames.contains(name), !value.isEmpty {
                    tokens.append(.modifier(name: name, value: value))
                    continue
                }
            }
            if word.hasPrefix("#"), word.count > 1 {
                tokens.append(.hashtag(String(word.dropFirst())))
            } else if word.hasPrefix("@"), word.count > 1 {
                tokens.append(.mention(String(word.dropFirst())))
            } else {
                tokens.append(.word(word))
            }
        }
        return tokens
    }

    /// Whether the query asks for anything (a scope modifier alone, e.g. `from:bob`, is a search too).
    public static func isEmpty(_ query: String) -> Bool {
        return self.tokenize(query).isEmpty
    }

    /// The words and phrases of the query to highlight in results (no modifiers, no excluded words; a trailing
    /// `*` wildcard is dropped). Hashtags and mentions keep their `#`/`@`.
    public static func highlightTerms(_ query: String) -> [String] {
        var result: [String] = []
        for token in self.tokenize(query) {
            switch token {
            case let .word(word):
                let trimmed = word.hasSuffix("*") ? String(word.dropLast()) : word
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
            case let .phrase(phrase):
                result.append(phrase)
            case let .hashtag(tag):
                result.append("#" + tag)
            case let .mention(name):
                result.append("@" + name)
            case .modifier, .excluded:
                break
            }
        }
        return result
    }

    /// The query with modifiers and excluded words removed, joined with spaces (for UIs that highlight a plain
    /// string's words).
    public static func highlightText(_ query: String) -> String {
        return self.highlightTerms(query).joined(separator: " ")
    }

    /// `YYYY-MM-DD` of a Unix time in the time zone `secondsFromGMT` east of UTC (the search's `time_zone_offset`).
    public static func day(_ unixTime: Int64, secondsFromGMT: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT) ?? TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(unixTime)))
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    /// The server terms: the user's query plus the scope. `inChannels` are channel ids (the server takes ids
    /// as well as names), `fromUsernames` usernames. `minDate`/`maxDate` (Unix seconds, inclusive) become
    /// `after:`/`before:` of the neighbouring days, since both are exclusive on the server.
    public static func terms(query: String, inChannels: [String] = [], fromUsernames: [String] = [], minDate: Int64? = nil, maxDate: Int64? = nil, secondsFromGMT: Int = 0) -> String {
        var parts: [String] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        for channel in inChannels {
            parts.append("in:" + channel)
        }
        for username in fromUsernames {
            parts.append("from:" + username)
        }
        if let minDate = minDate, minDate > 0 {
            parts.append("after:" + self.day(minDate - 24 * 60 * 60, secondsFromGMT: secondsFromGMT))
        }
        if let maxDate = maxDate, maxDate > 0, maxDate < Int64(Int32.max) {
            parts.append("before:" + self.day(maxDate + 24 * 60 * 60, secondsFromGMT: secondsFromGMT))
        }
        return parts.joined(separator: " ")
    }

    /// The keys that mention the user, as Mattermost's "Recent Mentions" searches them (an OR search): `@username`,
    /// the first name when `first_name` is on, and the custom `mention_keys`. `@channel`, `@all` and `@here` are
    /// left out, as in Mattermost's clients.
    public static func mentionKeys(username: String, firstName: String, notifyProps: [String: String]) -> [String] {
        var keys: [String] = []
        func add(_ key: String) {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return
            }
            let lowered = trimmed.lowercased()
            if ["@channel", "@all", "@here"].contains(lowered) {
                return
            }
            if !keys.contains(where: { $0.lowercased() == lowered }) {
                keys.append(trimmed)
            }
        }
        if !username.isEmpty {
            add("@" + username)
        }
        if notifyProps["first_name"] == "true" {
            add(firstName)
        }
        for key in (notifyProps["mention_keys"] ?? "").split(separator: ",") {
            add(String(key))
        }
        return keys
    }

    /// Terms of the mention search (`is_or_search: true`); multi-word keys are quoted.
    public static func mentionTerms(username: String, firstName: String, notifyProps: [String: String]) -> String {
        return self.mentionKeys(username: username, firstName: firstName, notifyProps: notifyProps).map { key in
            return key.contains(" ") ? "\"\(key)\"" : key
        }.joined(separator: " ")
    }
}
