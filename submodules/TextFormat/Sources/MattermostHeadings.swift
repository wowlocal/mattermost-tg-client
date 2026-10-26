import Foundation
import UIKit
import Display
import TelegramCore
import MattermostSyncCore

// MATTERMOST: Mattermost markdown headings (Phase 3E). MattermostSync writes a heading as `.Bold` plus a custom
// entity (`MattermostCustomEntity.heading(level:)`) over the same range; Telegram has no heading entity, so the
// custom one scales the fonts already applied there (bold, and monospace or italic inside the heading). Other
// renderers (chat list snippets, notifications, reply previews) ignore it and show bold text.
func mattermostApplyHeadingSizes(_ string: NSMutableAttributedString, entities: [MessageTextEntity], adjustedRanges: [NSRange?]) {
    for (index, entity) in entities.enumerated() {
        guard case let .Custom(type) = entity.type, let level = MattermostCustomEntity.headingLevel(type), index < adjustedRanges.count, var range = adjustedRanges[index] else {
            continue
        }
        let scale = CGFloat(MattermostCustomEntity.headingScale(level: level))
        if scale == 1.0 || range.location >= string.length {
            continue
        }
        range.length = min(range.length, string.length - range.location)
        var replacements: [(NSRange, UIFont)] = []
        string.enumerateAttribute(.font, in: range, options: [], using: { value, subrange, _ in
            if let font = value as? UIFont {
                replacements.append((subrange, font.withSize(round(font.pointSize * scale))))
            }
        })
        for (subrange, font) in replacements {
            string.addAttribute(.font, value: font, range: subrange)
        }
    }
}

// MATTERMOST: a Slack-style attachment's colour (4F). MattermostSync puts a custom entity
// (`MattermostCustomEntity.quoteColor(rgb:)`) over an attachment's block quote; its bar and background take that colour
// instead of the theme's quote colour, as Mattermost draws the attachment's colour bar.
func mattermostApplyQuoteColors(_ string: NSMutableAttributedString, entities: [MessageTextEntity], adjustedRanges: [NSRange?]) {
    let key = NSAttributedString.Key(rawValue: "Attribute__Blockquote")
    for (index, entity) in entities.enumerated() {
        guard case let .Custom(type) = entity.type, let rgb = MattermostCustomEntity.quoteColorRGB(type), index < adjustedRanges.count, var range = adjustedRanges[index] else {
            continue
        }
        if range.location >= string.length {
            continue
        }
        range.length = min(range.length, string.length - range.location)
        let color = UIColor(rgb: rgb)
        var replacements: [(NSRange, TextNodeBlockQuoteData)] = []
        string.enumerateAttribute(key, in: range, options: [], using: { value, subrange, _ in
            guard let value = value as? TextNodeBlockQuoteData, case .quote = value.kind else {
                return
            }
            replacements.append((subrange, TextNodeBlockQuoteData(kind: value.kind, title: value.title, color: color, secondaryColor: nil, tertiaryColor: nil, backgroundColor: color.withAlphaComponent(0.1), isCollapsible: value.isCollapsible)))
        })
        for (subrange, data) in replacements {
            string.addAttribute(key, value: data, range: subrange)
        }
    }
}
