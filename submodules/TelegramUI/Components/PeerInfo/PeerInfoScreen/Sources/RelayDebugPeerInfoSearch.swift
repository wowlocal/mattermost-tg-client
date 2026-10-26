import Foundation
import Display
import SwiftSignalKit
import PeerInfoPaneNode

// MATTERMOST: debug only (Phase 3C). The debug remote's `peerinfo-search` (TelegramUI `RelayDebugSearch.swift`):
// a media pane's search, as the pane's search button and the keyboard do, for checks without UI automation.
#if DEBUG
public extension PeerInfoScreenImpl {
    /// Switches to the pane (`files`, `links` or `music`), opens its search (the navigation bar's search button)
    /// and types `query`.
    func relayDebugSearchPane(_ pane: String, query: String) {
        let key: PeerInfoPaneKey
        switch pane {
        case "links":
            key = .links
        case "music":
            key = .music
        default:
            key = .files
        }
        let node = self.controllerNode
        node.paneContainerNode.pendingSwitchToPaneKey = key
        node.expandTabs(animated: false)
        if let (layout, navigationHeight) = node.validLayout {
            node.containerLayoutUpdated(layout: layout, navigationHeight: navigationHeight, transition: .immediate)
        }
        Queue.mainQueue().after(1.5) { [weak node] in
            guard let node else {
                return
            }
            node.activateSearch()
            Queue.mainQueue().after(0.8) { [weak node] in
                guard let contentNode = node?.searchDisplayController?.contentNode else {
                    return
                }
                contentNode.setQuery?(nil, [], query)
                contentNode.searchTextUpdated(text: query)
            }
        }
    }
}
#endif
