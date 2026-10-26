import Foundation
import Postbox
import TelegramCore
import MattermostSyncCore

/// Composer output (plain text + Telegram entities) → Mattermost markdown.
enum OutgoingText {
    /// Mentions of users without a typed `@username` (`TextMention` entities) become `@username`; the
    /// formatting entities the composer produces become markdown (`MattermostMarkdown.markdown(from:)`).
    /// Typed markdown passes through unchanged.
    static func markdown(text: String, entities: [MessageTextEntity], username: (PeerId) -> String?) -> String {
        var units = Array(text.utf16)
        var mapped: [TextEntity] = []
        // Replace mention ranges back to front so earlier ranges stay valid; remember the shift per offset.
        var shifts: [(offset: Int, delta: Int)] = []
        for entity in entities.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard case let .TextMention(peerId) = entity.type, let name = username(peerId) else {
                continue
            }
            let lower = max(0, min(units.count, entity.range.lowerBound))
            let upper = max(lower, min(units.count, entity.range.upperBound))
            let replacement = Array("@\(name)".utf16)
            units.replaceSubrange(lower ..< upper, with: replacement)
            shifts.append((upper, replacement.count - (upper - lower)))
        }
        func shifted(_ offset: Int) -> Int {
            var result = offset
            for shift in shifts where offset >= shift.offset {
                result += shift.delta
            }
            return result
        }
        for entity in entities {
            let type: TextEntityType
            switch entity.type {
            case .Bold:
                type = .bold
            case .Italic:
                type = .italic
            case .Strikethrough:
                type = .strikethrough
            case .Code:
                type = .code
            case let .Pre(language):
                type = .pre(language: language)
            case let .TextUrl(url):
                type = .textUrl(url: url)
            case .BlockQuote:
                type = .blockQuote
            default:
                // Mentions were replaced above; links, hashtags and the rest are plain text in markdown.
                continue
            }
            let lower = shifted(entity.range.lowerBound)
            let upper = shifted(entity.range.upperBound)
            if lower < upper {
                mapped.append(TextEntity(range: lower ..< upper, type: type))
            }
        }
        let resultText = String(utf16CodeUnits: units, count: units.count)
        return MattermostMarkdown.markdown(from: FormattedText(text: resultText, entities: mapped))
    }
}
