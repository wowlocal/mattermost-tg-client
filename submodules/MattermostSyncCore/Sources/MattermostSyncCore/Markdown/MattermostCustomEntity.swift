import Foundation

/// Raw values of the app-specific text entities that carry Mattermost formatting Telegram has no entity for
/// (`MessageTextEntityType.Custom(type:)`). MattermostSync writes them, TextFormat renders them; both read the
/// values from here so they cannot drift apart. Telegram's own custom entities use small numbers (1, 2), so these
/// sit in a range of their own ("MH" = Mattermost heading).
public enum MattermostCustomEntity {
    private static let headingBase: Int32 = 0x4D48_0000

    /// The custom entity type of a heading of `level` (1–6, clamped).
    public static func heading(level: Int) -> Int32 {
        return headingBase + Int32(min(6, max(1, level)))
    }

    /// The heading level of a custom entity type, nil for other types.
    public static func headingLevel(_ type: Int32) -> Int? {
        let level = Int(type - headingBase)
        return (1 ... 6).contains(level) ? level : nil
    }

    /// Font size of a heading relative to the message font (the text is bold as well). Mattermost's web app scales
    /// h1…h6 from about 1.7× down to 1×; a chat bubble is narrow, so the steps here are smaller.
    public static func headingScale(level: Int) -> Double {
        switch level {
        case 1:
            return 1.4
        case 2:
            return 1.28
        case 3:
            return 1.16
        case 4:
            return 1.08
        default:
            return 1.0
        }
    }

    // MARK: Attachment colours (4F)

    /// Colours sit in a range of their own: `0x6D` ("m") in the top byte, the RGB value below.
    private static let quoteColorBase: Int32 = 0x6D00_0000

    /// The custom entity type that colours a block quote over the same range: a Slack-style attachment's `color`,
    /// drawn as the quote's bar (Mattermost's colour bar).
    public static func quoteColor(rgb: UInt32) -> Int32 {
        return quoteColorBase | Int32(bitPattern: rgb & 0xFF_FFFF)
    }

    /// The RGB value of a quote colour entity type, nil for other types.
    public static func quoteColorRGB(_ type: Int32) -> UInt32? {
        guard type & ~0xFF_FFFF == quoteColorBase else {
            return nil
        }
        return UInt32(bitPattern: type & 0xFF_FFFF)
    }

    /// An attachment's `color`: `#rrggbb`, `#rgb` (with or without `#`), or the names Mattermost's mobile app knows
    /// (`good`, `warning`, `danger`, `primary`, `success`). Nil for anything else (no colour: the theme's quote).
    public static func attachmentColor(_ value: String) -> UInt32? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "good":
            return 0x00C100
        case "warning":
            return 0xDEDE01
        case "danger":
            return 0xE40303
        case "primary":
            return 0x166DE0
        case "success":
            return 0x339970
        default:
            break
        }
        var hex = Substring(trimmed)
        if hex.hasPrefix("#") {
            hex = hex.dropFirst()
        }
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        if hex.count == 3 {
            hex = Substring(hex.map { "\($0)\($0)" }.joined())
        }
        return UInt32(hex, radix: 16)
    }
}
