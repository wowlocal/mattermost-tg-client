import Foundation

/// `@channel`, `@here`, `@all`.
public enum SpecialMentionKind: String, Hashable, Sendable, CaseIterable {
    case channel
    case here
    case all
}

/// Entity types mirroring Telegram's `MessageTextEntityType`, plus the Mattermost-specific ones
/// the app maps onto custom entities.
public enum TextEntityType: Hashable, Sendable {
    case bold
    case italic
    case strikethrough
    /// Not produced by Mattermost markdown (it has no underline syntax); kept for parity.
    case underline
    case code
    case pre(language: String?)
    /// A link whose text differs from its target (`[text](url)`).
    case textUrl(url: String)
    /// A bare or `<…>` URL; the target is the covered text.
    case url
    /// An email address; the target is the covered text.
    case email
    /// `@username` (lowercased, without `@`). Resolve to a user peer when known.
    case mention(username: String)
    /// `~channel-name` (lowercased, without `~`).
    case channelMention(name: String)
    case specialMention(SpecialMentionKind)
    case blockQuote
    /// `#hashtag`; the tag is the covered text.
    case hashtag
    /// `:name:` with no built-in Unicode emoji; the text keeps `:name:` as a fallback.
    case customEmoji(name: String)
    /// A heading (`#`…`######`, setext `===`/`---`), level 1–6. Always paired with `.bold` over the same range, so
    /// renderers without heading sizes show bold text (Telegram: `MattermostCustomEntity.heading`).
    case heading(level: Int)

    /// Stable order used to sort entities that share a range (outer first).
    var sortRank: Int {
        switch self {
        case .blockQuote: return 0
        case .heading: return 1
        case .pre: return 2
        case .textUrl: return 3
        case .bold: return 4
        case .italic: return 5
        case .underline: return 6
        case .strikethrough: return 7
        case .code: return 8
        case .url: return 9
        case .email: return 10
        case .mention: return 11
        case .channelMention: return 12
        case .specialMention: return 13
        case .hashtag: return 14
        case .customEmoji: return 15
        }
    }
}

/// A formatting entity. `range` is in UTF-16 code units of the text (NSString indices), as in
/// Telegram's `MessageTextEntity`.
public struct TextEntity: Hashable, Sendable, CustomStringConvertible {
    public var range: Range<Int>
    public var type: TextEntityType

    public init(range: Range<Int>, type: TextEntityType) {
        self.range = range
        self.type = type
    }

    public var description: String {
        return "\(type)@\(range.lowerBound)..<\(range.upperBound)"
    }
}

/// Plain text plus entities.
public struct FormattedText: Hashable, Sendable, CustomStringConvertible {
    public var text: String
    /// Sorted by start, then longer first, then a fixed type order.
    public var entities: [TextEntity]

    public init(text: String, entities: [TextEntity] = []) {
        self.text = text
        self.entities = entities
    }

    /// The text covered by `entity`.
    public func substring(for entity: TextEntity) -> String {
        let utf16 = Array(text.utf16)
        let lower = max(0, min(entity.range.lowerBound, utf16.count))
        let upper = max(lower, min(entity.range.upperBound, utf16.count))
        return String(decoding: utf16[lower ..< upper], as: UTF16.self)
    }

    public var description: String {
        return "\(text.debugDescription) \(entities)"
    }

    static func sortedEntities(_ entities: [TextEntity]) -> [TextEntity] {
        return entities.sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.range.upperBound != rhs.range.upperBound {
                return lhs.range.upperBound > rhs.range.upperBound
            }
            if lhs.type.sortRank != rhs.type.sortRank {
                return lhs.type.sortRank < rhs.type.sortRank
            }
            return String(describing: lhs.type) < String(describing: rhs.type)
        }
    }
}
