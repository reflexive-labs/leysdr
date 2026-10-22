// SPDX-License-Identifier: Apache-2.0

// The window's accessibility tree, read from inside the process for the command file's `ax` and
// `press` (docs/dev/app.md, "The command file"). One element per line, two spaces of indent per
// depth, so a scene's tree diffs as text against its golden:
//
//     AXButton id=transport.play "Play" value="0" (812,770 24×24) enabled
//
// role, the identifier when there is one, the label (the description, else the title), the
// value when there is one, the frame in points from the window's top-left corner as
// `regions.json` measures, and whether the element is enabled.
//
// The tree is read through the accessibility API (`AXUIElement`) on the app's own process, as
// VoiceOver reads it, and not through `NSAccessibility` on the window: SwiftUI builds its
// elements only for a client of that API, and the `NSAccessibility` walk from the window found
// the AppKit views and none of the SwiftUI text, buttons or rows inside them. The API answers a
// process only when macOS allows it accessibility: otherwise every element it returns is the
// application's, and `text(of:)` says so rather than writing that tree.

import AppKit
import ApplicationServices

@MainActor
enum AccessibilityTree {
    /// Deeper than any tree the window builds; a cycle in what an element reports as its
    /// children stops here rather than recursing until the stack runs out.
    static let maxDepth = 64
    /// How long one question to the app's own elements may take before it is given up. The
    /// walk runs on the main actor, which also answers the questions, so a slow one freezes
    /// the window for this long.
    static let messagingSeconds: Float = 0.25
    /// The whole walk, after which `text(of:)` and `press(_:in:)` give up rather than hold the
    /// main actor any longer.
    static let walkSeconds: Double = 5

    struct Failure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// The tree under `window`, one element per line.
    static func text(of window: NSWindow) throws -> String {
        guard let root = element(of: window) else {
            throw Failure(reason: "the window has no accessibility element")
        }
        // A process macOS does not trust for accessibility is answered with the application's
        // element wherever a window or a view should be, a tree of thousands of menu items.
        guard string(root, kAXRoleAttribute) == kAXWindowRole else {
            throw Failure(
                reason:
                    "the accessibility API answered with no window: \(Bundle.main.bundlePath) is not allowed to read it; add it in System Settings > Privacy & Security > Accessibility"
            )
        }
        let origin = point(root) ?? .zero
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(walkSeconds)
        var late = false
        walk(root, depth: 0) { e, depth in
            if Date() > deadline {
                late = true
                return true
            }
            lines.append(String(repeating: "  ", count: depth) + line(e, origin: origin))
            return false
        }
        if late {
            throw Failure(
                reason:
                    "the tree took longer than \(Int(walkSeconds)) s to read; \(lines.count) elements were read"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Presses the first element, depth first, whose identifier is `identifier`, as VoiceOver's
    /// press does. Answers why not when there is no such element or it refused the press.
    static func press(_ identifier: String, in window: NSWindow) -> String? {
        guard let root = element(of: window) else {
            return "the window has no accessibility element"
        }
        var found: AXUIElement?
        let deadline = Date().addingTimeInterval(walkSeconds)
        var late = false
        walk(root, depth: 0) { e, _ in
            if Date() > deadline {
                late = true
                return true
            }
            guard string(e, kAXIdentifierAttribute) == identifier else { return false }
            found = e
            return true
        }
        if late {
            return "no element with the identifier \(identifier) within \(Int(walkSeconds)) s"
        }
        guard let found else { return "no element has the identifier \(identifier)" }
        let err = AXUIElementPerformAction(found, kAXPressAction as CFString)
        return err == .success ? nil : "\(identifier) refused the press (AXError \(err.rawValue))"
    }

    /// The app's element for `window`: the one of its windows with the window's title and
    /// size, else the first.
    private static func element(of window: NSWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, messagingSeconds)
        let windows = children(app, kAXWindowsAttribute)
        let want = window.frame.size
        let match = windows.first { w in
            guard let s = size(w) else { return false }
            return abs(s.width - want.width) < 1 && abs(s.height - want.height) < 1
                && string(w, kAXTitleAttribute) == window.title
        }
        return match ?? windows.first
    }

    /// Visits `element` and everything under it until `visit` returns true.
    @discardableResult
    private static func walk(
        _ element: AXUIElement, depth: Int, _ visit: (AXUIElement, Int) -> Bool
    ) -> Bool {
        guard depth <= maxDepth else { return false }
        // The timeout is the element's own, not inherited from the application's.
        AXUIElementSetMessagingTimeout(element, messagingSeconds)
        if visit(element, depth) { return true }
        for child in children(element, kAXChildrenAttribute) {
            if walk(child, depth: depth + 1, visit) { return true }
        }
        return false
    }

    private static func line(_ e: AXUIElement, origin: CGPoint) -> String {
        var parts = [string(e, kAXRoleAttribute) ?? "AXUnknown"]
        if let id = string(e, kAXIdentifierAttribute), !id.isEmpty { parts.append("id=\(id)") }
        let label = string(e, kAXDescriptionAttribute) ?? ""
        parts.append(quoted(label.isEmpty ? string(e, kAXTitleAttribute) ?? "" : label))
        if let value = value(e) { parts.append("value=" + quoted(value)) }
        let p = point(e) ?? .zero
        let s = size(e) ?? .zero
        parts.append(
            frame(CGRect(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)))
        parts.append(bool(e, kAXEnabledAttribute) == false ? "disabled" : "enabled")
        return parts.joined(separator: " ")
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else {
            return nil
        }
        return v
    }

    private static func children(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(e, name) as? [AXUIElement]) ?? []
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        attribute(e, name) as? String
    }

    private static func bool(_ e: AXUIElement, _ name: String) -> Bool? {
        (attribute(e, name) as? NSNumber)?.boolValue
    }

    private static func value(_ e: AXUIElement) -> String? {
        switch attribute(e, kAXValueAttribute) {
        case let s as String: s
        case let a as NSAttributedString: a.string
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    private static func axValue(_ e: AXUIElement, _ name: String) -> AXValue? {
        guard let v = attribute(e, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        // The type id was checked, so the cast holds.
        return (v as! AXValue)
    }

    /// The element's top-left corner in screen points, origin at the top of the main display.
    private static func point(_ e: AXUIElement) -> CGPoint? {
        var p = CGPoint.zero
        guard let v = axValue(e, kAXPositionAttribute), AXValueGetValue(v, .cgPoint, &p) else {
            return nil
        }
        return p
    }

    private static func size(_ e: AXUIElement) -> CGSize? {
        var s = CGSize.zero
        guard let v = axValue(e, kAXSizeAttribute), AXValueGetValue(v, .cgSize, &s) else {
            return nil
        }
        return s
    }

    /// In double quotes, with backslashes, quotes and newlines escaped, so a reader of the line
    /// finds where the text ends.
    private static func quoted(_ s: String) -> String {
        "\""
            + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// A rectangle in whole points, `(x,y w×h)`.
    private static func frame(_ r: CGRect) -> String {
        let nums = [r.minX, r.minY, r.width, r.height].map {
            abs($0) < 1e9 ? Int($0.rounded()) : 0
        }
        return "(\(nums[0]),\(nums[1]) \(nums[2])×\(nums[3]))"
    }
}
