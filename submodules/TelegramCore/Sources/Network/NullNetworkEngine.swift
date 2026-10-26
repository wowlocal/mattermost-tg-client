import Foundation
import SwiftSignalKit
import MtProtoKit

// MATTERMOST: the engine of every `Network` while `MattermostBackend.isEnabled` (see
// `resolveNetworkEngine`). Nothing it does reaches Telegram:
// - Requests are parked: they never complete and never fail, like requests waiting for a connection in
//   airplane mode, which every Telegram code path already handles. Completing them with an error would
//   be worse: most callers wrap requests in `retryRequest`, which retries forever. Disposing the returned
//   disposable drops the request (an `EmptyDisposable` would mean "refused").
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

/// Requests of all sessions of one engine, kept until their callers dispose them.
private final class NullNetworkParkedRequests {
    private let lock = NSLock()
    private var nextId: Int = 0
    private var requests: [Int: NetworkEngineRequest] = [:]
    private var seenFunctions = Set<String>()

    func park(_ request: NetworkEngineRequest) -> Disposable {
        let name = request.shortMetadata.functionName ?? "unknown"
        self.lock.lock()
        let id = self.nextId
        self.nextId += 1
        self.requests[id] = request
        let isFirstOfKind = self.seenFunctions.insert(name).inserted
        let totalParked = self.nextId
        self.lock.unlock()

        if isFirstOfKind {
            Logger.shared.log("NullNetworkEngine", "parked \(name) (first of its kind, \(totalParked) parked in total)")
            #if DEBUG
            NSLog("[NullNetworkEngine] parked %@ (first of its kind, %d parked in total)", name, totalParked)
            #endif
        }

        return ActionDisposable { [weak self] in
            self?.drop(id: id)
        }
    }

    private func drop(id: Int) {
        self.lock.lock()
        let request = self.requests.removeValue(forKey: id)
        self.lock.unlock()
        // Released outside the lock: its closures may hold the last references to their subscribers.
        let _ = request
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
