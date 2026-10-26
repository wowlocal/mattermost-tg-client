import Foundation
import UIKit
import Display
import TelegramCore

// MATTERMOST: Mattermost's away and do-not-disturb statuses as status dots (4F), where Telegram shows its green online
// dot: chat list rows and the avatar in a DM's header. Mattermost's colours: away yellow, do not disturb red with a
// white bar. (Telegram's presence can't express either: an away user is "recently", a DND user online.)
private let mattermostStatusIconKeyBase: Int32 = 0x4D53_0000 // "MS": outside `PresentationResourceKey`'s range

public extension PresentationResourcesChatList {
    /// A status dot like `recentStatusOnlineIcon` (14 pt, ringed in the row's background) in the status's colour.
    static func mattermostStatusIcon(_ theme: PresentationTheme, state: RecentStatusOnlineIconState, status: MattermostPresenceStatus) -> UIImage? {
        let stateIndex: Int32
        switch state {
        case .regular:
            stateIndex = 0
        case .highlighted:
            stateIndex = 1
        case .pinned:
            stateIndex = 2
        case .panel:
            stateIndex = 3
        }
        return theme.image(mattermostStatusIconKeyBase + stateIndex * 16 + status.rawValue, { theme in
            return generateImage(CGSize(width: 14.0, height: 14.0), rotatedContext: { size, context in
                let bounds = CGRect(origin: CGPoint(), size: size)
                context.clear(bounds)
                switch state {
                case .regular:
                    context.setFillColor(theme.chatList.itemBackgroundColor.cgColor)
                case .highlighted:
                    context.setFillColor(theme.chatList.itemHighlightedBackgroundColor.cgColor)
                case .pinned:
                    context.setFillColor(theme.chatList.pinnedItemBackgroundColor.cgColor)
                case .panel:
                    context.setFillColor(theme.actionSheet.itemBackgroundColor.withAlphaComponent(1.0).cgColor)
                }
                context.fillEllipse(in: bounds)
                let dot = bounds.insetBy(dx: 2.0, dy: 2.0)
                switch status {
                case .away:
                    context.setFillColor(UIColor(rgb: 0xFFBC1F).cgColor)
                    context.fillEllipse(in: dot)
                case .doNotDisturb:
                    context.setFillColor(UIColor(rgb: 0xD24B4E).cgColor)
                    context.fillEllipse(in: dot)
                    context.setFillColor(UIColor.white.cgColor)
                    let bar = CGRect(x: dot.minX + 2.5, y: dot.midY - 0.75, width: dot.width - 5.0, height: 1.5)
                    context.fill(bar)
                }
            })
        })
    }

    /// The chat list's online dot, or the Mattermost status dot of a user who is away or doesn't want to be disturbed.
    static func mattermostRecentStatusIcon(_ theme: PresentationTheme, state: RecentStatusOnlineIconState, voiceChat: Bool, status: MattermostPresenceStatus?) -> UIImage? {
        if !voiceChat, let status = status {
            return self.mattermostStatusIcon(theme, state: state, status: status)
        }
        return self.recentStatusOnlineIcon(theme, state: state, voiceChat: voiceChat)
    }
}
