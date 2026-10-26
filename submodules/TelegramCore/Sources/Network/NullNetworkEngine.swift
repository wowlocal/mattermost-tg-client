import Foundation
import SwiftSignalKit
import MtProtoKit

// MATTERMOST: the engine of every `Network` while `MattermostBackend.isEnabled` (see
// `resolveNetworkEngine`). Nothing it does reaches Telegram:
// - Requests are parked: they never complete and never fail, like requests waiting for a connection in
//   airplane mode, which every Telegram code path already handles. Completing them with an error would
//   be worse: most callers wrap requests in `retryRequest`, which retries forever. The returned disposable
//   is a real one (an `EmptyDisposable` would mean "refused"); the request itself is not kept (Phase 4B).
// - Nothing should reach it in normal use: the Telegram managers and fetchers that would are switched off
//   at their start sites (docs/PROGRESS.md, 4B). `NullNetworkStatistics` counts what still does.
// - The main session reports itself connected, so `Network.connectionStatus` is `.online`. Later the
//   Mattermost WebSocket state drives it.
// - `activate()` takes over what `MTContext` would do on the network by itself (making auth keys,
//   transferring authorizations, discovering backup addresses) with actions that never complete.
// - `kind` is `.mtProtoKit`, so no Rust-only branch runs.
final class NullNetworkEngine: NetworkEngine {
    let kind: NetworkEngineKind = .mtProtoKit

    private weak var context: MTContext?
    private let parkedRequests = NullNetworkParkedRequests()

    init(context: MTContext) {
        self.context = context
    }

    func makeSession(datacenterId: Int, role: NetworkEngineSessionRole, usageCalculationInfo: MTNetworkUsageCalculationInfo?, delegate: NetworkEngineSessionDelegate?) -> NetworkEngineSession {
        let session = NullNetworkEngineSession(datacenterId: datacenterId, requestService: NullNetworkEngineRequestService(requests: self.parkedRequests))
        if case .main = role {
            delegate?.networkSessionConnectionStateChanged(NetworkEngineConnectionState(
                isNetworkAvailable: true,
                isConnected: true,
                isUpdatingConnectionContext: false,
                isPerformingServiceTasks: false,
                proxyAddress: nil,
                proxyHasConnectionIssues: false
            ))
        }
        return session
    }

    func activate() {
        guard let context = self.context else {
            return
        }
        // `initializedNetwork` installed Telegram's backup-address discovery (DNS-over-HTTPS and friends)
        // just before; it would only start after a transport failure or an explicit discovery, but replace
        // it anyway.
        context.setDiscoverBackupAddressListSignal(MTSignal.never())
        MTContext.contextQueue().dispatch(onQueue: { [weak context] in
            guard let context = context else {
                return
            }
            context.authActionFactory = { selector, isCdn, skipBind, completion in
                return NullDatacenterAuthAction(authKeyInfoSelector: selector, isCdn: isCdn, skipBind: skipBind, completion: { action, success in
                    if let action = action {
                        completion(action, success)
                    }
                })
            }
            context.transferAuthActionFactory = {
                return NullDatacenterTransferAuthAction()
            }
        }, synchronous: false)
    }
}

/// MATTERMOST: what reached the null engines of this process, per API function: every request parked so far
/// and how many of them their callers have not disposed ("live": a screen still waiting, or a fire-and-forget
/// caller that never will; the requests themselves are not kept). Read by the debug remote (`runtime`) for the
/// parked-request audit (docs/PROGRESS.md, 4B).
public struct NullNetworkParkedFunction {
    public let function: String
    public let total: Int
    public let live: Int
    /// Debug builds: the call stack of the first request of this function (where it was started).
    public let firstStack: [String]
}

public enum NullNetworkStatistics {
    fileprivate struct Entry {
        var total: Int = 0
        var live: Int = 0
        var firstStack: [String] = []
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    public static func snapshot() -> [NullNetworkParkedFunction] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries.map { NullNetworkParkedFunction(function: $0.key, total: $0.value.total, live: $0.value.live, firstStack: $0.value.firstStack) }.sorted(by: { $0.total > $1.total })
    }

    /// Records a parked request; returns its number among the requests of its function (1 for the first).
    fileprivate static func parked(_ function: String) -> (count: Int, live: Int) {
        #if DEBUG
        self.lock.lock()
        let needsStack = self.entries[function] == nil
        self.lock.unlock()
        let stack = needsStack ? Array(Thread.callStackSymbols.dropFirst(3).prefix(40)) : []
        #else
        let stack: [String] = []
        #endif
        self.lock.lock()
        var entry = self.entries[function] ?? Entry()
        entry.total += 1
        entry.live += 1
        if entry.firstStack.isEmpty {
            entry.firstStack = stack
        }
        self.entries[function] = entry
        self.lock.unlock()
        return (entry.total, entry.live)
    }

    fileprivate static func dropped(_ function: String) {
        self.lock.lock()
        if var entry = self.entries[function] {
            entry.live = max(0, entry.live - 1)
            self.entries[function] = entry
        }
        self.lock.unlock()
    }
}

/// Requests of all sessions of one engine. A parked request is not kept (Phase 4B): it can never complete, and
/// holding it would hold its subscriber chain (closures, the caller's state) until the caller disposes it, which
/// fire-and-forget callers (`let _ = signal.start()`) never do. Its caller sees exactly what a kept request gives:
/// no value, no error, no completion. Only its function name is kept, for the statistics.
private final class NullNetworkParkedRequests {
    private let lock = NSLock()
    private var nextId: Int = 0
    private var requests: [Int: String] = [:]

    func park(_ request: NetworkEngineRequest) -> Disposable {
        let name = request.shortMetadata.functionName ?? "unknown"
        self.lock.lock()
        let id = self.nextId
        self.nextId += 1
        self.requests[id] = name
        let totalParked = self.nextId
        self.lock.unlock()

        let (count, live) = NullNetworkStatistics.parked(name)
        // The first request of each function, then every tenfold: a function that keeps being called shows up.
        if count == 1 || count == 10 || count == 100 || count == 1000 || count == 10000 {
            Logger.shared.log("NullNetworkEngine", "parked \(name) (#\(count) of its kind, \(live) of them live, \(totalParked) parked in total)")
            #if DEBUG
            NSLog("[NullNetworkEngine] parked %@ (#%d of its kind, %d of them live, %d parked in total)", name, count, live, totalParked)
            #endif
        }

        return ActionDisposable { [weak self] in
            self?.drop(id: id)
        }
    }

    private func drop(id: Int) {
        self.lock.lock()
        let function = self.requests.removeValue(forKey: id)
        self.lock.unlock()
        if let function = function {
            NullNetworkStatistics.dropped(function)
        }
    }
}

private final class NullNetworkEngineRequestService: NetworkEngineRequestService {
    private let requests: NullNetworkParkedRequests

    init(requests: NullNetworkParkedRequests) {
        self.requests = requests
    }

    func add(_ request: NetworkEngineRequest) -> Disposable {
        return self.requests.park(request)
    }
}

private final class NullNetworkEngineSession: NetworkEngineSession {
    let datacenterId: Int
    let requestService: NetworkEngineRequestService

    init(datacenterId: Int, requestService: NetworkEngineRequestService) {
        self.datacenterId = datacenterId
        self.requestService = requestService
    }

    func setPaused(_ paused: Bool) {
    }

    func setOnline(_ online: Bool) {
    }

    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
    }

    func stop() {
    }

    func movePendingRequests(to service: NetworkEngineRequestService, deadline: Double, completion: @escaping () -> Void) {
        // Only live engine switching (macOS) moves requests; nothing here ever runs, so there is nothing
        // to hand over.
        completion()
    }
}

/// An auth-key action that never runs: `MTContext` keeps it as the pending action for its datacenter and
/// never asks again, so it never opens an MTProto connection to make a key.
private final class NullDatacenterAuthAction: MTDatacenterAuthAction {
    override func execute(_ context: MTContext!, datacenterId: Int) {
    }

    override func cancel() {
    }
}

/// An authorization transfer that never runs (see `NullDatacenterAuthAction`).
private final class NullDatacenterTransferAuthAction: MTDatacenterTransferAuthAction {
    override func execute(_ context: MTContext!, masterDatacenterId: Int, destinationDatacenterId: Int, authToken: Any!) {
    }

    override func cancel() {
    }
}
