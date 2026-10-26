import Foundation

/// Built-in Mattermost emoji short names → Unicode. Names not in the table are treated as
/// (possibly custom) emoji and get a `customEmoji` entity.
///
/// The rows are generated from emoji-datasource, the dataset Mattermost's own emoji names come from
/// (`EmojiTableData.swift`, MIT License; see its header). Each row lists one or more space-separated
/// names; the first is the one Mattermost clients send (`+1` for 👍, `thinking_face` for 🤔).
public enum EmojiTable {
    public static func unicode(forName name: String) -> String? {
        return table[name]
    }

    /// Every known short name (including aliases and skin tone variants).
    public static var allNames: [String] {
        return Array(table.keys)
    }

    /// The short name Mattermost clients send for an emoji: the first name of its row (`+1` for 👍).
    /// Also matches the emoji without its variation selector (U+FE0F).
    public static func name(forUnicode emoji: String) -> String? {
        if let name = names[emoji] {
            return name
        }
        let stripped = String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0 != "\u{FE0F}" }))
        return names[stripped]
    }

    /// Every distinct emoji (without skin tone variants) with its primary short name, in the dataset's order.
    public static var allEmoji: [(name: String, emoji: String)] {
        var seen = Set<String>()
        var result: [(name: String, emoji: String)] = []
        for (aliases, emoji) in rows where seen.insert(emoji).inserted {
            if let name = aliases.split(separator: " ").first {
                result.append((String(name), emoji))
            }
        }
        return result
    }

    /// Autocomplete for `:query`: built-in emoji with a short name containing `query` (case-insensitive), one
    /// entry per emoji with its first matching name. Exact names first, then names starting with the query,
    /// then the rest, alphabetically within each group (as Mattermost's own clients rank them). Skin tone
    /// variants are left out.
    public static func search(_ query: String, limit: Int = 50) -> [(name: String, emoji: String)] {
        let query = query.lowercased()
        if query.isEmpty || limit <= 0 {
            return []
        }
        var matches: [(rank: Int, name: String, emoji: String)] = []
        var seen = Set<String>()
        for (aliases, emoji) in rows where !seen.contains(emoji) {
            var best: (rank: Int, name: String)?
            for alias in aliases.split(separator: " ") {
                let name = String(alias)
                let rank: Int
                if name == query {
                    rank = 0
                } else if name.hasPrefix(query) {
                    rank = 1
                } else if name.contains(query) {
                    rank = 2
                } else {
                    continue
                }
                if best == nil || rank < best!.rank {
                    best = (rank, name)
                }
            }
            if let best {
                seen.insert(emoji)
                matches.append((best.rank, best.name, emoji))
            }
        }
        matches.sort(by: { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return lhs.name < rhs.name
        })
        return matches.prefix(limit).map { ($0.name, $0.emoji) }
    }

    private static let names: [String: String] = {
        var result: [String: String] = [:]
        for (aliases, emoji) in rows + skinToneRows {
            guard let name = aliases.split(separator: " ").first else {
                continue
            }
            if result[emoji] == nil {
                result[emoji] = String(name)
            }
            let stripped = String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0 != "\u{FE0F}" }))
            if result[stripped] == nil {
                result[stripped] = String(name)
            }
        }
        return result
    }()

    private static let table: [String: String] = {
        var result: [String: String] = [:]
        result.reserveCapacity((rows.count + skinToneRows.count) * 2)
        for (names, emoji) in rows + skinToneRows {
            for name in names.split(separator: " ") {
                result[String(name)] = emoji
            }
        }
        return result
    }()
}
