import Foundation
import AppBundle
import TelegramCore
import PresentationStrings

// MATTERMOST: bundled translations (docs/design/localization.md). Telegram's languages other than English were
// language packs from Telegram's servers (`LocalizationSettings`), which Relay never reaches. Relay ships its
// translations in the app instead: `<lang>.lproj/Localizable.strings`, merged at build time from
// `Telegram-iOS/<lang>.lproj/Relay.strings` and an optional full translation of upstream's strings
// (Telegram/BUILD `RelayLocalizableStrings_<lang>`). The app uses the one the system prefers for it: the per-app
// language in iOS Settings → Relay → Language, else the device's languages. A key the translation lacks falls back
// to English (`getSingle` in the generated PresentationStrings). Debug builds also bundle the `en-XA`
// pseudo-language (launch with `-AppleLanguages "(en-XA)"`).
public enum RelayBundledLocalization {
    /// The bundled localizations with strings of their own ("en" first). upstream's other `.lproj` folders hold
    /// empty files: they only let iOS show its own UI (pickers, share sheets) in the user's language.
    public static let available: [String] = {
        let bundle = getAppBundle()
        var result = ["en"]
        for localization in bundle.localizations where localization != "en" && localization != "Base" {
            guard let path = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization) else {
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 {
                result.append(localization)
            }
        }
        return result
    }()

    /// The localization the app shows: the user's preferred one among `available` ("en" when none matches).
    public static let current: String = {
        return Bundle.preferredLocalizations(from: RelayBundledLocalization.available, forPreferences: nil).first ?? "en"
    }()
}

/// The strings of the bundled translation the user prefers, or nil for English (upstream's
/// `defaultPresentationStrings`). Only for the Mattermost backend: Telegram's own builds keep their server packs.
func relayBundledPresentationStrings() -> PresentationStrings? {
    guard MattermostBackend.isEnabled else {
        return nil
    }
    let code = RelayBundledLocalization.current
    guard code != "en", let path = getAppBundle().path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: code), let dict = NSDictionary(contentsOf: URL(fileURLWithPath: path)) as? [String: String], !dict.isEmpty else {
        return nil
    }
    let localizedName = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    return PresentationStrings(primaryComponent: PresentationStrings.Component(languageCode: code, localizedName: localizedName, pluralizationRulesCode: nil, dict: dict), secondaryComponent: nil, groupingSeparator: "")
}
