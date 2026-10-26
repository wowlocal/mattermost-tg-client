import Foundation
import UIKit
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
