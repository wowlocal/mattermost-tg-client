import Foundation

/// The names one Mattermost notification is drawn and donated with when several accounts are signed in:
/// the same rules as Telegram's notifications (`NotificationNames`, Telegram/NotificationService), so both
/// kinds look alike — the account follows the name after an arrow ("Town Square → alice"), pointing the
/// other way in a right-to-left name.
///
/// iOS draws a communication notification's title from the intent (the sender for a DM, the group for a
/// channel), not from `content.title`, so the account goes into that name too; the donated interaction
/// (Siri and share suggestions) keeps the plain names.
public struct MattermostPushNames: Equatable, Sendable {
    public var title: String
    /// The name the notification is drawn with: the sender (DM) or the group (channel), with the account.
    public var displayedName: String
    /// The same without the account.
    public var donatedName: String

    public init(title: String, recipientAccountName: String?) {
        self.title = MattermostPushNames.decorated(title, recipientAccountName: recipientAccountName)
        self.displayedName = self.title
        self.donatedName = title
    }

    static func decorated(_ name: String, recipientAccountName: String?) -> String {
        guard let recipientAccountName = recipientAccountName, !recipientAccountName.isEmpty, !name.isEmpty else {
            return name
        }
        // The arrow is not mirrored, and the system lays a title out in the direction of its first letter:
        // in a right-to-left title "→" would point from the account back to the name.
        let isRightToLeft = firstLetterIsRightToLeft(name) ?? firstLetterIsRightToLeft(recipientAccountName) ?? false
        return name + (isRightToLeft ? " ← " : " → ") + recipientAccountName
    }
}

/// Whether the first letter of `string` belongs to a right-to-left script, or nil when it has no letter
/// (Unicode's paragraph-direction rule, UAX #9 P2: digits, punctuation and emoji are skipped, and a leading
/// directional mark decides outright).
func firstLetterIsRightToLeft(_ string: String) -> Bool? {
    for scalar in string.unicodeScalars {
        switch scalar.value {
        case 0x200F, 0x061C:
            return true
        case 0x200E:
            return false
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            switch scalar.value {
            case 0x0590 ... 0x08FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF, 0x10800 ... 0x10FFF, 0x1E800 ... 0x1EFFF:
                return true
            default:
                return false
            }
        default:
            continue
        }
    }
    return nil
}
