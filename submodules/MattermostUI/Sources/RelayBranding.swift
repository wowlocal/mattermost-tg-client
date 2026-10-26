import Foundation
import UIKit
import Display
import TelegramPresentationData

/// Relay's look on the login screens: the logo (the app icon's placeholder artwork, drawn here so no asset
/// is needed: tools/relay-icon) and the transparent navigation bar of Telegram's own login.
enum RelayBranding {
    static let appName = "Relay"

    static func logoImage(size: CGFloat) -> UIImage? {
        return generateImage(CGSize(width: size, height: size), rotatedContext: { size, context in
            let bounds = CGRect(origin: CGPoint(), size: size)
            context.clear(bounds)
            let path = UIBezierPath(roundedRect: bounds, cornerRadius: size.width * 0.225)
            context.addPath(path.cgPath)
            context.clip()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                UIColor(red: 0.16, green: 0.62, blue: 0.62, alpha: 1.0).cgColor,
                UIColor(red: 0.20, green: 0.33, blue: 0.70, alpha: 1.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: size.height), end: CGPoint(x: size.width, y: 0.0), options: [])
            }
            UIGraphicsPushContext(context)
            let font = UIFont(name: "HelveticaNeue-Bold", size: size.width * 0.62) ?? UIFont.boldSystemFont(ofSize: size.width * 0.62)
            let text = NSAttributedString(string: "R", attributes: [.font: font, .foregroundColor: UIColor.white])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2.0, y: (size.height - textSize.height) / 2.0))
            UIGraphicsPopContext()
        })
    }

    /// Copy of `AuthorizationSequenceController.navigationBarTheme` (internal there).
    static func navigationBarTheme(_ theme: PresentationTheme) -> NavigationBarTheme {
        return NavigationBarTheme(overallDarkAppearance: theme.overallDarkAppearance, buttonColor: theme.chat.inputPanel.panelControlColor, disabledButtonColor: theme.intro.disabledTextColor, primaryTextColor: theme.intro.primaryTextColor, backgroundColor: .clear, opaqueBackgroundColor: .clear, enableBackgroundBlur: false, separatorColor: .clear, badgeBackgroundColor: theme.rootController.navigationBar.badgeBackgroundColor, badgeStrokeColor: theme.rootController.navigationBar.badgeStrokeColor, badgeTextColor: theme.rootController.navigationBar.badgeTextColor, edgeEffectColor: .clear, accentButtonColor: theme.list.itemCheckColors.fillColor, accentDisabledButtonColor: theme.chat.inputPanel.panelControlDisabledColor, accentForegroundColor: theme.list.itemCheckColors.foregroundColor, style: .glass)
    }

    static func navigationBarPresentationData(_ presentationData: PresentationData) -> NavigationBarPresentationData {
        return NavigationBarPresentationData(theme: self.navigationBarTheme(presentationData.theme), strings: NavigationBarStrings(presentationStrings: presentationData.strings))
    }

    /// Whether `http://` is accepted for local servers: debug builds only (the dev server is
    /// `http://localhost:8065`). Matches App Transport Security (Telegram/BUILD, Phase 4A): debug builds allow local
    /// networking, release builds allow no plain HTTP for the app's own connections; a server needs HTTPS there.
    static var allowsInsecureLocalServers: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
