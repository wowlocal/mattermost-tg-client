import Foundation

// MATTERMOST: Mattermost statuses Telegram's presence can't express (Phase 3F). An `away` user is "recently"
// and a `dnd` user is online in `UserPresenceStatus`; this mark on `TelegramUserPresence` (and
// `EnginePeer.Presence`) lets the presence texts say "away" / "do not disturb" instead. Written by MattermostSync
// from `GET /users/status/ids` and `status_change` events. The raw values are stored in Postbox; never change them.
public enum MattermostPresenceStatus: Int32, Equatable {
    case away = 1
    case doNotDisturb = 2
}
