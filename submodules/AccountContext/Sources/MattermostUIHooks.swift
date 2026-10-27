import Foundation
import Display
import TelegramCore

// MATTERMOST: Relay screens that upstream modules open without depending on MattermostUI (Phase 3F). Installed once
// by MattermostUI (`MattermostAppHooks.sharedContextCreated`); nil while the Mattermost backend is off.
public enum MattermostUIHooks {
    /// Settings → Notifications → Push and Mentions (the user's Mattermost notify props).
    public static var makeNotificationPreferencesController: ((AccountContext) -> ViewController)?
    /// Settings → About Relay → Diagnostics (Phase 4G: diagnostic logs, MetricKit reports, the export).
    public static var makeDiagnosticsController: ((AccountContext) -> ViewController)?
    /// 4H: the server an account is on (by the account's own peer id), shown under the user's name in the account
    /// switcher and the Settings account list, so the same user on two servers can be told apart.
    public static var accountServerLabel: ((EnginePeer.Id) -> String?)?
}
