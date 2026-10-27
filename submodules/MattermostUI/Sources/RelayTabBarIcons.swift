import Foundation
import UIKit
import TelegramPresentationData

// MATTERMOST: icons of Relay's own root tabs (Threads, Mentions; TelegramRootController). Telegram's tabs have
// Lottie icons tinted by the tab bar; a tab with a static image is drawn as is (TabBarComponent passes no tint),
// so these come pre-tinted in the tab bar's title colours, one image per state.

public enum RelayTabBarIcon {
    case threads
    case mentions

    fileprivate var symbolName: String {
        switch self {
        case .threads:
            return "bubble.left.and.bubble.right"
        case .mentions:
            return "at"
        }
    }
}

/// The tab's (image, selectedImage) for `theme`.
public func relayTabBarIcons(_ icon: RelayTabBarIcon, theme: PresentationTheme) -> (image: UIImage?, selectedImage: UIImage?) {
    return (
        relayTabBarIcon(icon, color: theme.rootController.tabBar.textColor),
        relayTabBarIcon(icon, color: theme.rootController.tabBar.selectedTextColor)
    )
}

private func relayTabBarIcon(_ icon: RelayTabBarIcon, color: UIColor) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: 19.0, weight: .medium)
    guard let symbol = UIImage(systemName: icon.symbolName, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal) else {
        return nil
    }
    // Telegram's tab icons are 30x30 points (`Chat List/Tabs/*`): the symbol is centred in the same box, so the
    // titles under all tabs line up.
    let size = CGSize(width: 30.0, height: 30.0)
    return UIGraphicsImageRenderer(size: size).image { _ in
        symbol.draw(in: CGRect(origin: CGPoint(x: floor((size.width - symbol.size.width) * 0.5), y: floor((size.height - symbol.size.height) * 0.5)), size: symbol.size))
    }
}
