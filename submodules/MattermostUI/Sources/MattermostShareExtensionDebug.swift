import Foundation
import UIKit
import ObjectiveC
import UniformTypeIdentifiers

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

/// **Debug builds only** (Phase 3F). Hosts the app's own share extension (`<bundle id>.Share`) with real input items,
/// as `UIActivityViewController` does for another app: `NSExtension` loads the extension and hands back its remote
/// view controller, which is presented here. Simulator taps don't reach the extension's windows on this setup, so the
/// extension's debug auto-send (`<root>/relay-debug/share-auto.json`) posts after a few seconds; its outcome is in
/// `share-result.json`. The extension process, its Keychain access, account loading and uploads are the real ones;
/// only the host is this app instead of Photos or Safari.
enum MattermostShareExtensionDebug {
    static func present(text: String?, url: URL?, imageCount: Int, fileCount: Int, completion: @escaping (Bool, String?) -> Void) {
        #if DEBUG
        guard let bundleId = Bundle.main.bundleIdentifier, let extensionClass = NSClassFromString("NSExtension") else {
            completion(false, "no NSExtension")
            return
        }
        let lookup = NSSelectorFromString("extensionWithIdentifier:error:")
        guard let lookupMethod = class_getClassMethod(extensionClass, lookup) else {
            completion(false, "no extensionWithIdentifier:error:")
            return
        }
        typealias Lookup = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        var lookupError: NSError?
        guard let shareExtension = unsafeBitCast(method_getImplementation(lookupMethod), to: Lookup.self)(extensionClass, lookup, (bundleId + ".Share") as NSString, &lookupError) else {
            completion(false, "extension not found: \(lookupError?.localizedDescription ?? "nil")")
            return
        }

        var attachments: [NSItemProvider] = []
        if let text {
            attachments.append(NSItemProvider(item: text as NSString, typeIdentifier: UTType.plainText.identifier))
        }
        if let url {
            attachments.append(NSItemProvider(item: url as NSURL, typeIdentifier: UTType.url.identifier))
        }
        for index in 0 ..< imageCount {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 480.0, height: 320.0)).image { context in
                UIColor(hue: CGFloat(index) * 0.27, saturation: 0.6, brightness: 0.85, alpha: 1.0).setFill()
                context.fill(CGRect(x: 0.0, y: 0.0, width: 480.0, height: 320.0))
                NSAttributedString(string: "Share \(index + 1)", attributes: [.font: UIFont.boldSystemFont(ofSize: 64.0), .foregroundColor: UIColor.white]).draw(at: CGPoint(x: 90.0, y: 120.0))
            }
            if let data = image.jpegData(compressionQuality: 0.8) {
                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("relay-share-\(index + 1).jpg")
                try? data.write(to: fileURL)
                attachments.append(NSItemProvider(item: fileURL as NSURL, typeIdentifier: UTType.fileURL.identifier))
            }
        }
        for index in 0 ..< fileCount {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("relay-share-notes-\(index + 1).txt")
            try? Data("Notes \(index + 1), shared through the share extension.\n".utf8).write(to: fileURL)
            attachments.append(NSItemProvider(item: fileURL as NSURL, typeIdentifier: UTType.fileURL.identifier))
        }
        let item = NSExtensionItem()
        item.attachments = attachments

        let instantiate = NSSelectorFromString("instantiateViewControllerWithInputItems:connectionHandler:")
        typealias Handler = @convention(block) (NSUUID?, UIViewController?, NSError?) -> Void
        typealias Instantiate = @convention(c) (AnyObject, Selector, NSArray, Handler) -> Void
        guard let implementation = class_getMethodImplementation(type(of: shareExtension), instantiate) else {
            completion(false, "no instantiateViewControllerWithInputItems:connectionHandler:")
            return
        }
        // The extension completes or cancels its request: close the sheet, as the system share sheet does.
        typealias RequestBlock = @convention(block) (NSUUID?, NSArray?) -> Void
        typealias SetRequestBlock = @convention(c) (AnyObject, Selector, RequestBlock) -> Void
        var presentedController: UIViewController?
        let finished: RequestBlock = { _, _ in
            DispatchQueue.main.async {
                presentedController?.dismiss(animated: true)
                presentedController = nil
            }
        }
        let setCompletion = NSSelectorFromString("setRequestCompletionBlock:")
        if (shareExtension as? NSObject)?.responds(to: setCompletion) == true, let setter = class_getMethodImplementation(type(of: shareExtension), setCompletion) {
            unsafeBitCast(setter, to: SetRequestBlock.self)(shareExtension, setCompletion, finished)
        }
        let handler: Handler = { _, viewController, error in
            DispatchQueue.main.async {
                guard let viewController else {
                    completion(false, "no view controller: \(error?.localizedDescription ?? "nil")")
                    return
                }
                var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
                while let presented = top?.presentedViewController {
                    top = presented
                }
                viewController.modalPresentationStyle = .formSheet
                presentedController = viewController
                top?.present(viewController, animated: true)
                completion(true, nil)
            }
        }
        unsafeBitCast(implementation, to: Instantiate.self)(shareExtension, instantiate, [item] as NSArray, handler)
        #else
        completion(false, "debug builds only")
        #endif
    }
}
#endif
