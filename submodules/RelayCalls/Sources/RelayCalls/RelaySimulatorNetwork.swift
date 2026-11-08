#if os(iOS) && targetEnvironment(simulator)
import Foundation
import ObjectiveC

/// The iOS Simulator only. LiveKit's WebRTC always runs Apple's network monitor (`LKRTCNetworkMonitor`, an
/// `NWPathMonitor`) on iOS, and WebRTC then offers ICE candidates only on the interfaces of the current path. With a
/// full-tunnel VPN on the Mac that is the VPN's `utun` alone, and a dev LiveKit published on `127.0.0.1` never answers
/// a check sent from the tunnel's address (a socket bound to loopback cannot reply to it), so every simulator call
/// stayed "connecting" until LiveKit gave up after 10 s. Without a monitor (WebRTC logs "Failed to create
/// RTCNetworkMonitor" and treats every adapter as available) the simulator gathers on every interface of the Mac, as
/// LiveKit's macOS and Python clients do. Devices keep the monitor (network handover).
enum RelaySimulatorNetwork {
    private static var isInstalled = false

    /// Before the first peer connection gathers candidates.
    static func install() {
        if self.isInstalled {
            return
        }
        self.isInstalled = true
        guard let monitorClass = NSClassFromString("LKRTCNetworkMonitor"), let method = class_getInstanceMethod(monitorClass, NSSelectorFromString("initWithObserver:")) else {
            return
        }
        let replacement: @convention(block) (AnyObject, UnsafeMutableRawPointer?) -> AnyObject? = { _, _ in
            return nil
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
#endif
