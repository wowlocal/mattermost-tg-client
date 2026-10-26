import Foundation

// MATTERMOST: process-wide switch of the Mattermost fork ("Relay").
//
// While it is set, TelegramCore never talks to Telegram:
// - every `Network` runs on `NullNetworkEngine` (`resolveNetworkEngine`), which parks requests forever
//   and reports the main session connected; network telemetry does not record;
// - `Account.networkState` reads "updating" from `Account.externalIsUpdating` instead of the MTProto
//   state manager, which never starts;
// - `Account` does not start Telegram's hole management (`managedServiceViews`); MattermostSync fills
//   holes instead.
// TelegramUI additionally skips `Account.resetStateManagement()` and Telegram's phone login.
//
// Every guarded hook in upstream code is marked `// MATTERMOST:`.
public enum MattermostBackend {
    /// Set once at launch, before the first account is created. Defaults to true in this fork.
    public static var isEnabled: Bool = true
}
