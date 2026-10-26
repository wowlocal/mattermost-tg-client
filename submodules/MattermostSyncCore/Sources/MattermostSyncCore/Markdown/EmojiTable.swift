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
