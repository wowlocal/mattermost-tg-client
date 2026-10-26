import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import AccountContext
import Postbox
import TelegramCore
import ChatListUI
import MattermostUI

// MATTERMOST: debug only (Phase 4B). Scroll smoothness probes of the debug remote (`tools/relay-remote.py`):
// - `chatlist-scroll` (`folder`: a folder title to select first; `seconds`, default 5; `speed` in points per second, default 2400): scrolls the visible chat list
//   down (then back up for the same time) one display frame at a time through `ListView.scrollWithDirection`, the
//   path accessibility scrolling takes, and reports the frame intervals measured by the same display link: frames,
//   average, 95th percentile and worst interval, and hitches (intervals over 1.5 and 3 expected frames).
// The simulator renders on the Mac's GPU, so absolute numbers say little about a device; compare runs.
// - `background-refresh`: what the BGAppRefreshTask runs (`RelayBackgroundRefresh.debugRun`);
// - `storage` (`do`: stats, clear, evict, reset): Telegram's storage usage and cache eviction for Mattermost media
//   (see `relayDebugStorage`).
#if DEBUG
extension TelegramRootController {
    func relayDebugInstallPerfCommands() {
        let previous = MattermostDebugChatCommands.handler
        MattermostDebugChatCommands.handler = { [weak self] action, command, completion in
            if let self, self.relayDebugRunPerfCommand(action: action, command: command, completion: completion) {
                return true
            }
            return previous?(action, command, completion) ?? false
        }
    }

    private func relayDebugRunPerfCommand(action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let seconds = (command["seconds"] as? String).flatMap(Double.init) ?? 5.0
        let speed = (command["speed"] as? String).flatMap(Double.init) ?? 2400.0
        switch action {
        case "chatlist-scroll":
            guard let chatList = self.chatListController as? ChatListControllerImpl else {
                completion(false, "no chat list", [:])
                return true
            }
            if let rootTabController = self.rootTabController, let index = rootTabController.controllers.firstIndex(where: { $0 is ChatListController }) {
                self.popToRoot(animated: false)
                rootTabController.selectedIndex = index
            }
            // `folder`: a folder's title (a team), selected first.
            var selectFolder: Signal<Void, NoError> = .single(Void())
            if let folder = command["folder"] as? String {
                selectFolder = chatList.context.engine.peers.currentChatListFilters()
                |> take(1)
                |> deliverOnMainQueue
                |> mapToSignal { filters -> Signal<Void, NoError> in
                    guard let id = filters.first(where: { filter in
                        if case let .filter(_, title, _, _) = filter {
                            return title.text == folder
                        }
                        return false
                    })?.id else {
                        return .single(Void())
                    }
                    return Signal { subscriber in
                        chatList.navigateToFolder(folderId: id, completion: {
                            subscriber.putNext(Void())
                            subscriber.putCompletion()
                        })
                        return EmptyDisposable
                    }
                }
            }
            let _ = (selectFolder |> take(1) |> deliverOnMainQueue).startStandalone(next: { _ in
            Queue.mainQueue().after(1.0) {
                // The visible list of the selected folder (ChatListUI keeps its node private): the largest on-screen
                // `ChatListNode` under the controller's node.
                var lists: [ChatListNode] = []
                func collect(_ node: ASDisplayNode) {
                    if let list = node as? ChatListNode, !list.isHidden, list.view.window != nil {
                        lists.append(list)
                    }
                    for subnode in node.subnodes ?? [] {
                        collect(subnode)
                    }
                }
                collect(chatList.displayNode)
                guard let listView = lists.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
                    completion(false, "no visible chat list node", [:])
                    return
                }
                RelayDebugScrollProbe.run(listView: listView, seconds: seconds, speed: speed, completion: { result in
                    completion(true, nil, result)
                })
            }
            })
            return true
        case "background-refresh":
            RelayBackgroundRefresh.debugRun(completion: { result in
                completion(true, nil, result)
            })
            return true
        case "storage":
            guard let context = self.chatListController?.context else {
                completion(false, "no account", [:])
                return true
            }
            self.relayDebugStorage(context: context, command: command, completion: completion)
            return true
        default:
            return false
        }
    }

    /// `storage` (Phase 4B, cache eviction of Mattermost media): `do=stats` (default) Telegram's storage usage
    /// statistics as the Storage Usage screen shows them, plus the Mattermost resources on disk; `do=clear` (`peer`:
    /// `PeerId.toInt64()`, or all chats) what the screen's Clear runs; `do=evict` (`peer`, `seconds`) an automatic
    /// eviction: a "keep media" exception of `seconds` for the chat, as Telegram's per-chat setting writes it,
    /// which makes `AutomaticCacheEvictionContext` remove the chat's resources unused for longer; `do=reset` removes
    /// the exceptions again.
    private func relayDebugStorage(context: AccountContext, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) {
        let mediaBox = context.account.postbox.mediaBox
        let diskScan: () -> [String: Any] = {
            var result: [String: [String: Int64]] = [:]
            let names = (try? FileManager.default.contentsOfDirectory(atPath: mediaBox.basePath)) ?? []
            for name in names {
                let kind: String
                if name.hasPrefix("mm-file-") {
                    kind = "file"
                } else if name.hasPrefix("mm-avatar-") {
                    kind = "avatar"
                } else if name.hasPrefix("mm-url-") {
                    kind = "url"
                } else {
                    kind = "other"
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: mediaBox.basePath + "/" + name))?[.size] as? NSNumber)?.int64Value ?? 0
                result[kind, default: ["count": 0, "bytes": 0]]["count"]! += 1
                result[kind, default: ["count": 0, "bytes": 0]]["bytes"]! += size
            }
            return ["disk": result]
        }
        let peerId = (command["peer"] as? String).flatMap(Int64.init).map { EnginePeer.Id($0) }
        switch command["do"] as? String ?? "stats" {
        case "clear":
            let categories: [StorageUsageStats.CategoryKey] = [.photos, .videos, .files, .music, .stickers, .avatars, .misc, .stories]
            let _ = (context.engine.resources.clearStorage(peerId: peerId, categories: categories, includeMessages: [], excludeMessages: [])
            |> deliverOnMainQueue).startStandalone(completed: {
                completion(true, nil, diskScan())
            })
        case "evict", "reset":
            let seconds = (command["seconds"] as? String).flatMap(Int32.init) ?? 60
            let isReset = (command["do"] as? String) == "reset"
            let _ = (updateAccountSpecificCacheStorageSettingsInteractively(postbox: context.account.postbox, { settings in
                var settings = settings
                if isReset {
                    settings.peerStorageTimeoutExceptions = []
                } else if let peerId = peerId {
                    settings.peerStorageTimeoutExceptions.removeAll(where: { $0.key == peerId })
                    settings.peerStorageTimeoutExceptions.append(AccountSpecificCacheStorageSettings.Value(key: peerId, value: seconds))
                }
                return settings
            })
            |> deliverOnMainQueue).startStandalone(completed: {
                // The eviction context restarts on the settings change and works on a background queue.
                Queue.mainQueue().after(5.0) {
                    completion(true, nil, diskScan())
                }
            })
        default:
            let _ = (context.engine.resources.collectStorageUsageStats()
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { stats in
                var result = diskScan()
                var total: [String: Int64] = [:]
                for (key, value) in stats.totalStats.categories {
                    total["\(key)"] = value.size
                }
                result["total"] = total
                var peers: [[String: Any]] = []
                for (id, peerStats) in stats.peers {
                    var categories: [String: Int64] = [:]
                    for (key, value) in peerStats.stats.categories {
                        categories["\(key)"] = value.size
                    }
                    peers.append(["peer": "\(id.toInt64())", "title": peerStats.peer.debugDisplayTitle, "categories": categories, "bytes": categories.values.reduce(0, +)])
                }
                result["peers"] = peers.sorted(by: { ($0["bytes"] as? Int64 ?? 0) > ($1["bytes"] as? Int64 ?? 0) })
                completion(true, nil, result)
            })
        }
    }
}

private final class RelayDebugScrollProbe: NSObject {
    private static var running: RelayDebugScrollProbe?

    private weak var listView: ListViewImpl?
    private let seconds: Double
    private let speed: Double
    private let completion: ([String: Any]) -> Void
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var distance: Double = 0
    private var goingDown = true
    private var reachedEnd = false

    static func run(listView: ListViewImpl, seconds: Double, speed: Double, completion: @escaping ([String: Any]) -> Void) {
        let probe = RelayDebugScrollProbe(listView: listView, seconds: seconds, speed: speed, completion: completion)
        self.running = probe
        probe.start()
    }

    private init(listView: ListViewImpl, seconds: Double, speed: Double, completion: @escaping ([String: Any]) -> Void) {
        self.listView = listView
        self.seconds = seconds
        self.speed = speed
        self.completion = completion
    }

    private func start() {
        let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if self.startTime == 0 {
            self.startTime = link.timestamp
            self.lastTimestamp = link.timestamp
            return
        }
        let dt = link.timestamp - self.lastTimestamp
        self.lastTimestamp = link.timestamp
        self.intervals.append(dt)
        let elapsed = link.timestamp - self.startTime
        if self.goingDown && elapsed > self.seconds {
            self.goingDown = false
        }
        if elapsed > self.seconds * 2.0 {
            self.finish(expected: link.duration)
            return
        }
        guard let listView = self.listView else {
            self.finish(expected: link.duration)
            return
        }
        let step = CGFloat(self.speed * dt)
        let moved = listView.scrollWithDirection(self.goingDown ? .down : .up, distance: step)
        if moved {
            self.distance += Double(step)
        } else if self.goingDown {
            self.reachedEnd = true
        }
    }

    private func finish(expected: CFTimeInterval) {
        self.displayLink?.invalidate()
        self.displayLink = nil
        let frame = expected > 0 ? expected : 1.0 / 60.0
        let sorted = self.intervals.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let result: [String: Any] = [
            "frames": self.intervals.count,
            "expectedFrameMs": frame * 1000.0,
            "averageMs": self.intervals.isEmpty ? 0 : self.intervals.reduce(0, +) / Double(self.intervals.count) * 1000.0,
            "p95Ms": p95 * 1000.0,
            "worstMs": (sorted.last ?? 0) * 1000.0,
            "hitches": self.intervals.filter { $0 > frame * 1.5 }.count,
            "longHitches": self.intervals.filter { $0 > frame * 3.0 }.count,
            "droppedFrames": self.intervals.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) },
            "scrolledPoints": self.distance,
            "reachedEnd": self.reachedEnd
        ]
        NSLog("[Relay] perf: scroll probe %@", "\(result)")
        self.completion(result)
        RelayDebugScrollProbe.running = nil
    }
}
#endif
