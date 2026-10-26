import Foundation
import os

// MATTERMOST: cold-start timing in every build (Phase 4B in debug builds, release builds since 4E). One unified-log
// line when the first chat list is ready, so a release build can be timed from outside:
// `log stream --style compact --predicate 'eventMessage CONTAINS "[Relay] perf:"'`. It carries two numbers and nothing
// about the user.

/// Seconds since this process was started (the kernel's start time of the process, so dyld and static
/// initializers count).
func relayProcessAge() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
        return 0.0
    }
    let start = info.kp_proc.p_starttime
    return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000.0)
}

/// `[Relay] perf: chat list ready <ms> after didFinishLaunching, <ms> after process start`.
func relayLogChatListReady(launchStartTime: CFAbsoluteTime) {
    let sinceLaunch = (CFAbsoluteTimeGetCurrent() - launchStartTime) * 1000.0
    let sinceProcessStart = relayProcessAge() * 1000.0
    os_log("[Relay] perf: chat list ready %.0f ms after didFinishLaunching, %.0f ms after process start", log: .default, type: .default, sinceLaunch, sinceProcessStart)
}
