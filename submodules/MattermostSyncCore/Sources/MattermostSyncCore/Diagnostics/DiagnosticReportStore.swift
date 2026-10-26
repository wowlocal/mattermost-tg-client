import Foundation

/// Local store of the reports iOS hands the app through MetricKit (Phase 4G): `MXMetricPayload` (daily metrics)
/// and `MXDiagnosticPayload` (crashes, hangs, disk writes, CPU) as the JSON MetricKit produces. They stay on the
/// device, in the app's own container, until the user exports diagnostics. The store is bounded by age, count
/// and total size; the oldest reports go first.
public final class DiagnosticReportStore {
    public enum Kind: String, CaseIterable {
        case metrics
        case diagnostics
    }

    public struct Limits: Equatable {
        public var maximumAge: TimeInterval
        public var maximumCount: Int
        public var maximumTotalBytes: Int
        /// A single report larger than this is not kept (a runaway payload must not evict everything else).
        public var maximumReportBytes: Int

        public init(maximumAge: TimeInterval = 30 * 24 * 60 * 60, maximumCount: Int = 40, maximumTotalBytes: Int = 4 * 1024 * 1024, maximumReportBytes: Int = 1024 * 1024) {
            self.maximumAge = maximumAge
            self.maximumCount = maximumCount
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumReportBytes = maximumReportBytes
        }
    }

    public struct Report: Equatable {
        public let url: URL
        public let kind: Kind
        public let date: Date
        public let size: Int
    }

    public let directory: URL
    public let limits: Limits
    private let lock = NSLock()

    public init(directory: URL, limits: Limits = Limits()) {
        self.directory = directory
        self.limits = limits
    }

    /// Stores one report (MetricKit's `jsonRepresentation()`), dated by the end of the period it covers.
    @discardableResult
    public func store(_ json: Data, kind: Kind, date: Date, now: Date = Date()) -> Bool {
        guard !json.isEmpty, json.count <= self.limits.maximumReportBytes else {
            return false
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let name = "\(DiagnosticReportStore.timestamp(date))-\(kind.rawValue)-\(UUID().uuidString.prefix(8).lowercased()).json"
            try json.write(to: self.directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return false
        }
        self.pruneLocked(now: now)
        return true
    }

    /// The stored reports, oldest first.
    public func reports() -> [Report] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.reportsLocked()
    }

    public func prune(now: Date = Date()) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pruneLocked(now: now)
    }

    public func removeAll() {
        self.lock.lock()
        defer { self.lock.unlock() }
        for report in self.reportsLocked() {
            try? FileManager.default.removeItem(at: report.url)
        }
    }

    private func reportsLocked() -> [Report] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: self.directory.path) else {
            return []
        }
        var result: [Report] = []
        for name in names where name.hasSuffix(".json") {
            // <yyyyMMdd'T'HHmmss'Z'>-<kind>-<id>.json
            let parts = name.dropLast(".json".count).split(separator: "-")
            guard parts.count >= 3, let date = DiagnosticReportStore.date(String(parts[0])), let kind = Kind(rawValue: String(parts[1])) else {
                continue
            }
            let url = self.directory.appendingPathComponent(name)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            result.append(Report(url: url, kind: kind, date: date, size: size))
        }
        return result.sorted { ($0.date, $0.url.lastPathComponent) < ($1.date, $1.url.lastPathComponent) }
    }

    private func pruneLocked(now: Date) {
        var reports = self.reportsLocked()
        var removed: [Report] = []
        reports.removeAll { report in
            if now.timeIntervalSince(report.date) > self.limits.maximumAge {
                removed.append(report)
                return true
            }
            return false
        }
        var total = reports.reduce(0) { $0 + $1.size }
        while !reports.isEmpty && (reports.count > self.limits.maximumCount || total > self.limits.maximumTotalBytes) {
            let oldest = reports.removeFirst()
            total -= oldest.size
            removed.append(oldest)
        }
        for report in removed {
            try? FileManager.default.removeItem(at: report.url)
        }
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    static func timestamp(_ date: Date) -> String {
        return self.formatter().string(from: date)
    }

    static func date(_ timestamp: String) -> Date? {
        return self.formatter().date(from: timestamp)
    }
}
