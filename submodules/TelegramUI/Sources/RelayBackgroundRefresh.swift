import Foundation
import UIKit
import BackgroundTasks
import SwiftSignalKit
import TelegramCore
import MattermostSync

// MATTERMOST: background catch-up (Phase 4B). A `BGAppRefreshTask` with the identifier `<bundle id>.refresh`
// (already in Info.plist's `BGTaskSchedulerPermittedIdentifiers`; `UIBackgroundModes` has `fetch`) catches every
// running account up (`MattermostSync.backgroundRefresh`), so the chat list and badges are current when the user
// opens the app even when no push woke it. Scheduled each time the app enters the background (earliest 15 minutes
// later; iOS decides when it runs), and again from the task itself.
//
// Trigger it on the simulator from lldb attached to the app, after the app was put in the background once (so a
// request is pending):
//   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"org.relaychat.Relay.refresh"]
enum RelayBackgroundRefresh {
    private static var identifier: String?

    /// Registers the task handler; must run before `application(_:didFinishLaunchingWithOptions:)` returns.
    static func register(baseAppBundleId: String) {
        let identifier = "\(baseAppBundleId).refresh"
        self.identifier = identifier
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: { task in
            self.run(task: task)
        })
        self.log("registered \(identifier): \(registered)")
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { _ in
            self.schedule()
        })
    }

    static func schedule() {
        guard let identifier = self.identifier else {
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15.0 * 60.0)
        do {
            try BGTaskScheduler.shared.submit(request)
            self.log("scheduled \(identifier)")
        } catch {
            // The simulator refuses requests unless background refresh is available; the task still runs from lldb.
            self.log("could not schedule \(identifier): \(error)")
        }
    }

    private static func run(task: BGTask) {
        self.log("running \(task.identifier)")
        self.schedule()
        let completed = Atomic<Bool>(value: false)
        let complete: (Bool) -> Void = { success in
            if !completed.swap(true) {
                task.setTaskCompleted(success: success)
                self.log("\(task.identifier) completed (success: \(success))")
            }
        }
        let work = Task {
            let ok = await MattermostSync.backgroundRefresh(timeout: 25.0)
            complete(ok)
        }
        task.expirationHandler = {
            work.cancel()
            complete(false)
        }
    }

    #if DEBUG
    /// Debug remote `background-refresh`: what the task runs, without the task (the simulator refuses
    /// `BGTaskScheduler.submit`, so `_simulateLaunchForTaskWithIdentifier:` has no pending request to launch).
    static func debugRun(completion: @escaping ([String: Any]) -> Void) {
        let started = CFAbsoluteTimeGetCurrent()
        let status = UIApplication.shared.backgroundRefreshStatus.rawValue
        let state = UIApplication.shared.applicationState.rawValue
        Task {
            let ok = await MattermostSync.backgroundRefresh(timeout: 25.0)
            DispatchQueue.main.async {
                completion(["caughtUp": ok, "ms": Int((CFAbsoluteTimeGetCurrent() - started) * 1000.0), "backgroundRefreshStatus": status, "applicationState": state])
            }
        }
    }
    #endif

    private static func log(_ text: String) {
        Logger.shared.log("Relay", "background refresh: \(text)")
        #if DEBUG
        NSLog("[Relay] background refresh: %@", text)
        #endif
    }
}
