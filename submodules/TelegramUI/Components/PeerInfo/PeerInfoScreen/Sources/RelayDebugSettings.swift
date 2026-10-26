import Foundation

// MATTERMOST: debug only (`RELAY_DEBUG_OPEN_SCREEN=settings:add-account` in TelegramUI's RelayDebugScreens): runs
// the Settings screen's "Add Account" handler, as a tap on the row does. Release builds compile none of this.
public extension PeerInfoScreenImpl {
    func relayDebugOpenAddAccount() {
        #if DEBUG
        self.controllerNode.openSettings(section: .addAccount)
        #endif
    }
}
