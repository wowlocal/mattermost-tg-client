import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore

/// Logging for MattermostSync: Telegram's log files plus, in debug builds, the unified log (`[Relay]`
/// prefix, so `log stream --predicate 'eventMessage CONTAINS "[Relay]"'` shows only our lines).
enum MMLog {
    static func log(_ message: @autoclosure () -> String) {
        let text = message()
        Logger.shared.log("Mattermost", text)
        #if DEBUG
        NSLog("[Relay] %@", text)
        #endif
    }
}

extension Postbox {
    /// Runs `f` in a Postbox transaction and returns its result. Postbox transactions run one at a time on
    /// Postbox's queue; MattermostSync also does all of its ID-map work inside them, which serializes every
    /// "ID map, then Postbox" unit of work without a lock of its own (see `MattermostAccountSync`).
    func mmTransaction<T>(_ f: @escaping (Transaction) -> T) async -> T {
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let _ = self.transaction({ transaction -> T in
                return f(transaction)
            }).start(next: { value in
                continuation.resume(returning: value)
            })
        }
    }
}

/// A value guarded by a lock.
final class MMLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func with<T>(_ f: (inout Value) -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return f(&self.value)
    }

    var current: Value {
        return self.with { $0 }
    }
}

/// Local peer ids of Mattermost objects.
///
/// - Users get `CloudUser` ids, channels and group messages `CloudChannel` ids, both allocated sequentially
///   from 1 per account (`SQLiteMattermostSyncStore.allocatePeer`). Phase 2: also skip `reservedIds`, the ids
///   Telegram's UI special-cases (only reachable on servers with more than 42,000 users).
/// - DMs are the other user's peer; the self-DM is the own user's peer (Saved Messages).
/// - The own user's id is a stable hash of (server URL, user id) in `[2^40, 2^41)`, far above the sequential
///   range: two servers must never give their own users the same `PeerId`, or `SharedAccountContextImpl`
///   deletes one of the accounts. `PeerId.Id` asserts positive payloads below 2^56 (`Postbox/Peer.swift`),
///   and the Int64 packing keeps 32 low + 29 high bits, so 41 bits are safe.
public enum MattermostPeerIds {
    /// Ids that Telegram code treats specially (service notifications, replies bot, anonymous admin, …).
    static let reservedIds: Set<Int64> = [42777, 333000, 489000, 708513, 777000, 2666000, 4244000, 92386307, 136817688, 1271266957]

    public static func ownUserIdValue(serverURL: String, userId: String) -> Int64 {
        var normalized = serverURL.lowercased()
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(normalized)|\(userId)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let low40 = hash & ((UInt64(1) << 40) - 1)
        return Int64(bitPattern: (UInt64(1) << 40) | low40)
    }

    public static func userPeerId(_ value: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(value))
    }

    public static func channelPeerId(_ value: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(value))
    }
}

/// Mattermost ms timestamps → Telegram seconds.
func mmSeconds(_ milliseconds: Int64) -> Int32 {
    return Int32(clamping: milliseconds / 1000)
}
