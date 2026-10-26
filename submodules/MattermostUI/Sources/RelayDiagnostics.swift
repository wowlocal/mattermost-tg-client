import Foundation
import UIKit
import MetricKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import ItemListUI
import PresentationDataUtils
import OverlayStatusController
import MattermostKit
import MattermostSyncCore
import MattermostSync

/// Privacy-respecting diagnostics (Phase 4G, docs/release/privacy.md). No third-party SDK and nothing leaves the
/// device on its own:
/// - **MetricKit**: the reports iOS hands the app (daily metrics; crashes, hangs, disk writes, CPU exceptions) are
///   kept as JSON in the app's container, at most 30 days / 40 reports / 4 MB (`DiagnosticReportStore`).
/// - **Logs**: Telegram's file log ("Save Diagnostic Logs", off by default in release builds) with MattermostSync's
///   lines. They carry no message text, passwords or tokens; ids are pseudonymized on export.
/// - **Export** (Settings → About Relay → Diagnostics → Export Diagnostics): a zip with a summary (app and iOS
///   version, device model, each account's server and server version, passcode and managed configuration in
///   words), the stored reports and the redacted logs, handed to the system share sheet. The user decides
///   whether and where it goes.
public final class RelayDiagnostics: NSObject, MXMetricManagerSubscriber {
    public static let shared = RelayDiagnostics()

    let store: DiagnosticReportStore
    private var isStarted = false

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.store = DiagnosticReportStore(directory: support.appendingPathComponent("RelayDiagnostics/MetricKit", isDirectory: true))
        super.init()
    }

    /// Main app, once at launch: subscribes to MetricKit (iOS delivers pending reports right after).
    public func start() {
        guard !self.isStarted else {
            return
        }
        self.isStarted = true
        MXMetricManager.shared.add(self)
        DispatchQueue.global(qos: .utility).async {
            self.store.prune()
        }
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            self.store.store(payload.jsonRepresentation(), kind: .metrics, date: payload.timeStampEnd)
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            self.store.store(payload.jsonRepresentation(), kind: .diagnostics, date: payload.timeStampEnd)
        }
    }

    // MARK: Export

    /// Log directories under the app group's data root (`<root>/logs/…`): the app's and the extensions'.
    static let logDirectories = ["app-logs", "notification-logs", "share-logs"]
    static let maximumLogFiles = 30
    static let maximumLogBytes = 12 * 1024 * 1024

    struct ExportInput {
        let rootPath: String
        let appVersion: String
        let passcodeSet: Bool
        let autolockTimeout: Int32?
        let logsSaved: Bool
        let managed: MattermostManagedConfiguration
        let accounts: [MattermostDiagnosticsAccount]
    }

    /// Writes the bundle and zips it; the zip's URL, or nil when it couldn't be made.
    static func export(_ input: ExportInput, store: DiagnosticReportStore) -> URL? {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("relay-diagnostics", isDirectory: true)
        // Only one export at a time on disk: the previous one is gone once shared.
        try? fileManager.removeItem(at: base)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Relay-Diagnostics-\(formatter.string(from: Date()))"
        let folder = base.appendingPathComponent(name, isDirectory: true)
        let redactor = DiagnosticsRedactor()
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            let reports = store.reports()
            if !reports.isEmpty {
                let directory = folder.appendingPathComponent("metrickit", isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                for report in reports {
                    try? fileManager.copyItem(at: report.url, to: directory.appendingPathComponent(report.url.lastPathComponent))
                }
            }

            var logFiles: [(directory: String, url: URL, date: Date)] = []
            for directoryName in RelayDiagnostics.logDirectories {
                let directory = URL(fileURLWithPath: input.rootPath).appendingPathComponent("logs").appendingPathComponent(directoryName)
                let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
                for url in urls where url.lastPathComponent.hasPrefix("log-") {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    logFiles.append((directoryName, url, date))
                }
            }
            logFiles.sort { $0.date > $1.date }
            var exportedLogs = 0
            var logBytes = 0
            for file in logFiles.prefix(RelayDiagnostics.maximumLogFiles) {
                guard let data = try? Data(contentsOf: file.url), logBytes + data.count <= RelayDiagnostics.maximumLogBytes else {
                    continue
                }
                let directory = folder.appendingPathComponent("logs", isDirectory: true).appendingPathComponent(file.directory, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let text = redactor.redact(String(decoding: data, as: UTF8.self))
                let name = file.url.lastPathComponent.hasSuffix(".txt") ? file.url.lastPathComponent : file.url.lastPathComponent + ".txt"
                try Data(text.utf8).write(to: directory.appendingPathComponent(name))
                logBytes += data.count
                exportedLogs += 1
            }

            let summary = RelayDiagnostics.summary(input, reports: reports, logFiles: exportedLogs, redactor: redactor)
            try Data(summary.utf8).write(to: folder.appendingPathComponent("summary.txt"))
        } catch {
            return nil
        }

        // A zip of the folder (Foundation's own: a coordinated read "for uploading").
        var zipURL: URL?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError, byAccessor: { zipped in
            let destination = base.appendingPathComponent("\(name).zip")
            do {
                try fileManager.copyItem(at: zipped, to: destination)
                zipURL = destination
            } catch {
                zipURL = nil
            }
        })
        try? fileManager.removeItem(at: folder)
        return zipURL
    }

    static func summary(_ input: ExportInput, reports: [DiagnosticReportStore.Report], logFiles: Int, redactor: DiagnosticsRedactor) -> String {
        var lines: [String] = []
        let iso = ISO8601DateFormatter()
        lines.append("Relay diagnostics")
        lines.append("Created: \(iso.string(from: Date()))")
        lines.append("")
        lines.append("App: Relay \(input.appVersion)")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        lines.append("Device: \(model)")
        lines.append("Language: \(Locale.preferredLanguages.first ?? "?")")
        lines.append("")
        lines.append("Accounts: \(input.accounts.count)")
        for (index, account) in input.accounts.enumerated() {
            var state = account.isSyncing ? "syncing" : "not syncing"
            if account.isSessionExpired {
                state = "session expired"
            }
            lines.append("  \(index + 1). \(account.server), Mattermost \(account.serverVersion ?? "unknown"), \(state)")
        }
        lines.append("")
        lines.append("Passcode: \(input.passcodeSet ? "on" : "off")\(input.passcodeSet ? ", auto-lock \(input.autolockTimeout.map { "\($0) s" } ?? "off")" : "")")
        lines.append("Managed configuration: \(MattermostManagedSettings.summary(input.managed))")
        lines.append("Diagnostic logs saved: \(input.logsSaved ? "yes" : "no"); \(logFiles) log file(s) included, redacted (ids pseudonymized, credentials and email addresses removed)")
        lines.append("")
        lines.append("iOS reports (MetricKit): \(reports.count)")
        for report in reports {
            lines.append("  \(iso.string(from: report.date)) \(report.kind.rawValue) (\(report.size) bytes)")
        }
        return redactor.redact(lines.joined(separator: "\n")) + "\n"
    }
}

// MARK: - Settings → About Relay → Diagnostics

private final class RelayDiagnosticsArguments {
    let toggleLogs: (Bool) -> Void
    let export: () -> Void

    init(toggleLogs: @escaping (Bool) -> Void, export: @escaping () -> Void) {
        self.toggleLogs = toggleLogs
        self.export = export
    }
}

private enum RelayDiagnosticsSection: Int32 {
    case logs
    case export
}

private enum RelayDiagnosticsEntry: ItemListNodeEntry {
    case saveLogs(String, Bool)
    case logsInfo(String)
    case reports(String, String)
    case export(String, Bool)
    case exportInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .saveLogs, .logsInfo:
            return RelayDiagnosticsSection.logs.rawValue
        case .reports, .export, .exportInfo:
            return RelayDiagnosticsSection.export.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .saveLogs:
            return 0
        case .logsInfo:
            return 1
        case .reports:
            return 2
        case .export:
            return 3
        case .exportInfo:
            return 4
        }
    }

    static func <(lhs: RelayDiagnosticsEntry, rhs: RelayDiagnosticsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: RelayDiagnosticsEntry, rhs: RelayDiagnosticsEntry) -> Bool {
        switch lhs {
        case let .saveLogs(title, value):
            if case .saveLogs(title, value) = rhs {
                return true
            }
            return false
        case let .logsInfo(text):
            if case .logsInfo(text) = rhs {
                return true
            }
            return false
        case let .reports(title, value):
            if case .reports(title, value) = rhs {
                return true
            }
            return false
        case let .export(title, enabled):
            if case .export(title, enabled) = rhs {
                return true
            }
            return false
        case let .exportInfo(text):
            if case .exportInfo(text) = rhs {
                return true
            }
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! RelayDiagnosticsArguments
        switch self {
        case let .saveLogs(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleLogs(value)
            })
        case let .logsInfo(text), let .exportInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .reports(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .export(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.export()
            })
        }
    }
}

/// Settings → About Relay → Diagnostics: the diagnostic log switch and the export.
public func relayDiagnosticsController(context: AccountContext) -> ViewController {
    let isExporting = ValuePromise<Bool>(false, ignoreRepeated: true)
    var isExportingValue = false
    var presentControllerImpl: ((ViewController) -> Void)?
    var presentShareSheetImpl: ((URL) -> Void)?

    let arguments = RelayDiagnosticsArguments(toggleLogs: { value in
        let _ = updateLoggingSettings(accountManager: context.sharedContext.accountManager, { $0.withUpdatedLogToFile(value) }).start()
    }, export: {
        guard !isExportingValue else {
            return
        }
        isExportingValue = true
        isExporting.set(true)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        presentControllerImpl?(progress)
        let _ = (relayDiagnosticsExportInput(sharedContext: context.sharedContext)
        |> deliverOn(relayDiagnosticsQueue)
        |> map { input -> URL? in
            return RelayDiagnostics.export(input, store: RelayDiagnostics.shared.store)
        }
        |> deliverOnMainQueue).start(next: { url in
            isExportingValue = false
            isExporting.set(false)
            progress.dismiss()
            if let url {
                presentShareSheetImpl?(url)
            } else {
                presentControllerImpl?(textAlertController(context: context, title: nil, text: presentationData.strings.Relay_Diagnostics_Failed, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
            }
        })
    })

    let loggingSettings = context.sharedContext.accountManager.sharedData(keys: [SharedDataKeys.loggingSettings])
    |> map { view -> LoggingSettings in
        return view.entries[SharedDataKeys.loggingSettings]?.get(LoggingSettings.self) ?? LoggingSettings.defaultSettings
    }
    let reportCount = Signal<Int, NoError> { subscriber in
        subscriber.putNext(RelayDiagnostics.shared.store.reports().count)
        subscriber.putCompletion()
        return EmptyDisposable
    } |> runOn(Queue.concurrentDefaultQueue())

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, loggingSettings, reportCount, isExporting.get())
    |> map { presentationData, loggingSettings, reportCount, isExporting -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let entries: [RelayDiagnosticsEntry] = [
            .saveLogs(strings.Relay_Diagnostics_SaveLogs, loggingSettings.logToFile),
            .logsInfo(strings.Relay_Diagnostics_LogsFooter),
            .reports(strings.Relay_Diagnostics_Reports, "\(reportCount)"),
            .export(strings.Relay_Diagnostics_Export, !isExporting),
            .exportInfo(strings.Relay_Diagnostics_ExportFooter)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Relay_Diagnostics_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal, tabBarItem: nil)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentShareSheetImpl = { [weak controller] url in
        guard let controller else {
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1.0, height: 1.0)
        }
        #if DEBUG
        RelayDiagnosticsDebug.lastExport = url
        #endif
        context.sharedContext.mainWindow?.presentNative(activity)
    }
    return controller
}

/// The export's queue: serial, so the input's value and its completion arrive in order (a concurrent queue can
/// deliver the completion first and drop the value).
let relayDiagnosticsQueue = Queue(name: "org.relaychat.Relay.diagnostics")

/// What the export needs from the app, read on the main queue.
func relayDiagnosticsExportInput(sharedContext: SharedAccountContext) -> Signal<RelayDiagnostics.ExportInput, NoError> {
    return combineLatest(
        sharedContext.accountManager.accessChallengeData() |> take(1),
        sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.presentationPasscodeSettings, SharedDataKeys.loggingSettings]) |> take(1)
    )
    |> map { accessChallenge, sharedData -> RelayDiagnostics.ExportInput in
        var passcodeSet = true
        if case .none = accessChallenge.data {
            passcodeSet = false
        }
        let passcodeSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]?.get(PresentationPasscodeSettings.self) ?? .defaultSettings
        let loggingSettings = sharedData.entries[SharedDataKeys.loggingSettings]?.get(LoggingSettings.self) ?? LoggingSettings.defaultSettings
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?[kCFBundleVersionKey as String] as? String ?? ""
        return RelayDiagnostics.ExportInput(
            rootPath: sharedContext.basePath,
            appVersion: build.isEmpty ? version : "\(version) (\(build))",
            passcodeSet: passcodeSet,
            autolockTimeout: passcodeSettings.autolockTimeout,
            logsSaved: loggingSettings.logToFile,
            managed: MattermostManagedSettings.current,
            accounts: MattermostSync.diagnosticsAccounts()
        )
    }
}

#if DEBUG
/// **Debug builds only.** The debug remote's diagnostics commands (`RelaySecurityDebug`).
enum RelayDiagnosticsDebug {
    static var lastExport: URL?
}
#endif
