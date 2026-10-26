import Foundation
import Display

// MATTERMOST: Relay screens that upstream modules open without depending on MattermostUI (Phase 3F). Installed once
// by MattermostUI (`MattermostAppHooks.sharedContextCreated`); nil while the Mattermost backend is off.
public enum MattermostUIHooks {
    /// Settings → Notifications → Push and Mentions (the user's Mattermost notify props).
    public static var makeNotificationPreferencesController: ((AccountContext) -> ViewController)?
    /// Settings → About Relay → Diagnostics (Phase 4G: diagnostic logs, MetricKit reports, the export).
    public static var makeDiagnosticsController: ((AccountContext) -> ViewController)?
}
