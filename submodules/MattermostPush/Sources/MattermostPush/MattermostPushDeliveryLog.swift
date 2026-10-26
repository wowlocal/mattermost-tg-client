import Foundation

/// Which accounts the extension already notified of which posts (a small JSON file in the app group), so
/// that two pushes for one post on one server go to two different accounts (`MattermostPushRouter`).
///
/// Entries older than `maxAge` are dropped; the file is read and written under an advisory lock, because
/// the system may run several extension instances at once.
public final class MattermostPushDeliveryLog {
    public struct Entry: Codable, Equatable {
        public var postId: String
        public var accountId: Int64
        /// Seconds since 1970.
        public var time: Double
    }

    public static let maxAge: Double = 60 * 60
    public static let maxEntries = 500

    public let path: String

    public init(directory: String) {
        self.path = directory + "/delivered.json"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// The accounts already notified of `postId`.
    public func accounts(postId: String, now: Double = Date().timeIntervalSince1970) -> Set<Int64> {
        return self.locked {
            let entries = self.read(now: now)
            return Set(entries.filter { $0.postId == postId }.map { $0.accountId })
        }
    }

    public func record(postId: String, accountId: Int64, now: Double = Date().timeIntervalSince1970) {
        self.locked {
            var entries = self.read(now: now)
            entries.append(Entry(postId: postId, accountId: accountId, time: now))
            if entries.count > MattermostPushDeliveryLog.maxEntries {
                entries.removeFirst(entries.count - MattermostPushDeliveryLog.maxEntries)
            }
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: URL(fileURLWithPath: self.path), options: .atomic)
            }
        }
    }

    private func read(now: Double) -> [Entry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.path)), let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries.filter { now - $0.time < MattermostPushDeliveryLog.maxAge }
    }

    private func locked<T>(_ f: () -> T) -> T {
        let lockPath = self.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if descriptor >= 0 {
            flock(descriptor, LOCK_EX)
        }
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        return f()
    }
}
