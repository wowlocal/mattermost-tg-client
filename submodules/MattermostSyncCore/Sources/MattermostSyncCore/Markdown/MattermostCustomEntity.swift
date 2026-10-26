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
}
