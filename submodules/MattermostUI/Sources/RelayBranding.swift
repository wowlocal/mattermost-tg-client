import Foundation
import UIKit
import Display
import TelegramPresentationData
import AppBundle

/// Relay's look on the login screens: the logo (the app icon's artwork, `Relay/Logo` in TelegramUI's assets; the
/// icon itself is `Telegram-iOS/Relay.icon`) and the transparent navigation bar of Telegram's own login.
enum RelayBranding {
    static let appName = "Relay"

    static func logoImage(size: CGFloat) -> UIImage? {
        guard let artwork = UIImage(bundleImageName: "Relay/Logo") else {
            return nil
        }
        return generateImage(CGSize(width: size, height: size), rotatedContext: { size, context in
            let bounds = CGRect(origin: CGPoint(), size: size)
            context.clear(bounds)
            context.addPath(UIBezierPath(roundedRect: bounds, cornerRadius: size.width * 0.225).cgPath)
            context.clip()
            UIGraphicsPushContext(context)
            artwork.draw(in: bounds)
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
