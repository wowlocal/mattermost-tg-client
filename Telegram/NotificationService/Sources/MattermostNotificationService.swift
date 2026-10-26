import Foundation
import UserNotifications
import MattermostPush
import MattermostPushService

// MATTERMOST: Relay's notification service for Mattermost pushes (Phase 3A, docs/plan/04). The work is in
// MattermostPushService (`MattermostPushServiceHandler`), which debug builds of the app also run to deliver
// pushes on a simulator; Telegram's handler (`NotificationServiceHandler`) stays for Telegram payloads and
// for `MattermostBackend.isEnabled == false`.
final class MattermostNotificationServiceHandler {
    static func isMattermostPush(_ request: UNNotificationRequest) -> Bool {
        return MattermostPushPayload.isMattermostPush(request.content.userInfo)
    }

    private let handler: MattermostPushServiceHandler

    init(request: UNNotificationRequest, contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.handler = MattermostPushServiceHandler(request: request, contentHandler: contentHandler)
    }

    func start() {
        self.handler.start()
    }

    func timeWillExpire() {
        self.handler.timeWillExpire()
    }
}
