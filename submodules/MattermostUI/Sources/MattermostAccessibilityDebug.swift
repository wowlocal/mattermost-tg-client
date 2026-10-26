#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file.
import Foundation
import UIKit

/// **Debug builds only.** Phase 4C: the accessibility elements VoiceOver can reach on screen, in its reading order,
/// for the debug remote's `ax-tree` command (`tools/relay-remote.py <udid> ax-tree`). It walks the visible windows the
/// way UIKit exposes them to assistive technologies: an element ends the walk of its subtree, otherwise a container's
/// `accessibilityElements` (or `accessibilityElement(at:)`), otherwise its subviews. AXe's `describe-ui` (from
/// outside the app) gives the same picture for most screens, but it skips elements that are plain NSObjects (the
/// ASDisplayNodes Telegram's lists and bars hand out) and so misses e.g. navigation bar buttons.
enum MattermostAccessibilityDebug {
    static func elements() -> [[String: Any]] {
        var result: [[String: Any]] = []
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .sorted(by: { $0.windowLevel.rawValue < $1.windowLevel.rawValue })
        // VoiceOver reads only a modal view's subtree (alerts, sheets) when one is shown.
        var roots: [NSObject] = windows
        for window in windows.reversed() {
            if let modal = self.modalView(in: window) {
                roots = [modal]
                break
            }
        }
        for root in roots {
            self.visit(root, depth: 0, into: &result)
        }
        return result
    }

    private static func modalView(in view: UIView) -> UIView? {
        if view.isHidden || view.alpha < 0.01 {
            return nil
        }
        for subview in view.subviews.reversed() {
            if let modal = self.modalView(in: subview) {
                return modal
            }
        }
        return view.accessibilityViewIsModal ? view : nil
    }

    private static func visit(_ object: NSObject, depth: Int, into result: inout [[String: Any]]) {
        if result.count > 600 || depth > 80 {
            return
        }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 {
            return
        }
        if object.accessibilityElementsHidden {
            return
        }
        if object.isAccessibilityElement {
            result.append(self.describe(object, depth: depth))
            return
        }
        if let elements = object.accessibilityElements, !elements.isEmpty {
            for element in elements {
                if let element = element as? NSObject {
                    self.visit(element, depth: depth + 1, into: &result)
                }
            }
            return
        }
        if !(object is UIView) {
            let count = object.accessibilityElementCount()
            if count > 0 && count != NSNotFound {
                for index in 0 ..< count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        self.visit(element, depth: depth + 1, into: &result)
                    }
                }
                return
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews {
                self.visit(subview, depth: depth + 1, into: &result)
            }
        }
    }

    private static func describe(_ object: NSObject, depth: Int) -> [String: Any] {
        let frame = object.accessibilityFrame
        var item: [String: Any] = [
            "depth": depth,
            "type": String(describing: type(of: object)),
            "label": object.accessibilityLabel ?? "",
            "traits": self.traitNames(object.accessibilityTraits),
            "frame": [Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)]
        ]
        if let value = object.accessibilityValue, !value.isEmpty {
            item["value"] = value
        }
        if let hint = object.accessibilityHint, !hint.isEmpty {
            item["hint"] = hint
        }
        if let actions = object.accessibilityCustomActions, !actions.isEmpty {
            item["actions"] = actions.map { $0.name }
        }
        return item
    }

    private static func traitNames(_ traits: UIAccessibilityTraits) -> [String] {
        let names: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.searchField, "search"), (.image, "image"),
            (.selected, "selected"), (.notEnabled, "disabled"), (.staticText, "text"), (.adjustable, "adjustable"),
            (.updatesFrequently, "updates"), (.summaryElement, "summary"), (.keyboardKey, "key"), (.tabBar, "tabbar")
        ]
        return names.filter { traits.contains($0.0) }.map { $0.1 }
    }
}
#endif
