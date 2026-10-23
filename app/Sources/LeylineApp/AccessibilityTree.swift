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
// VoiceOver reads it: SwiftUI builds its elements only for a client of that API, and an
// `NSAccessibility` walk from the window before any client had asked found the AppKit views and
// none of the SwiftUI text, buttons or rows inside them. The API answers a process only when
// macOS allows it accessibility: otherwise every element it returns is the application's, and
// `text(of:)` says so rather than writing that tree.
//
// While the screen is locked AppKit vends no element of a window under the lock's shield
// (`_NSAccessibilitySafeToVendElement` reads `com.apple.sessionagent.screenLockUIIsShown`), so
// the API answers the application wherever a window should be, for as long as the lock lasts:
// the "no window, for minutes" of ML-9a's runs. The same objects are then asked directly, in
// the process, through the attributes the API would have read from them (`ObjectNode`), which
// gives the same tree.

import AppKit
import ApplicationServices
import LeylineClient
import SwiftUI

extension View {
    /// One element named `identifier` holding the view's elements as its children. An identifier
    /// on a stack that is not an element of its own is given to every element inside it instead,
    /// over their own, so a region or a row the checks name is made an element first. It changes
    /// the tree and nothing drawn.
    func identifiedGroup(_ identifier: String) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }

    /// `identifiedGroup` for a row whose click is a tap gesture, made a button whose press runs
    /// `action`, the tap's own closure: an accessibility press (VoiceOver's, or the command
    /// file's `press`) does not reach a tap gesture.
    func pressableGroup(_ identifier: String, action: @escaping () -> Void) -> some View {
        identifiedGroup(identifier).pressable(action: action)
    }

    /// A button to accessibility, whose press runs `action`; for a view clicked through a tap
    /// gesture.
    func pressable(action: @escaping () -> Void) -> some View {
        accessibilityAddTraits(.isButton).accessibilityAction(.default, action)
    }
}

/// A window as the walk finds it among the application's: its title and size, read before the
/// walk starts, and the window itself for a walk of its objects.
struct TreeTarget {
    let title: String
    let size: CGSize
    /// The role of the element under the window whose subtree is read, `AXPopover` or `AXSheet`;
    /// nil for the whole window.
    var part: String?
    let window: NSWindow

    @MainActor
    init(_ window: NSWindow, part: String? = nil) {
        title = window.title
        size = window.frame.size
        self.part = part
        self.window = window
    }
}

/// One element as `elements(withPrefix:in:)` reports it.
struct AXElementInfo {
    let identifier: String
    let role: String
    /// The description, else the title.
    let label: String
    let value: String?
    let enabled: Bool
}

@MainActor
enum AccessibilityTree {
    /// Waits, up to `readySeconds`, for the window's objects to answer with SwiftUI's elements
    /// when the accessibility API answers no window: SwiftUI builds its elements only once
    /// asked, and later than the asking, so the first walk of a fresh window's objects found
    /// none.
    static func ready(_ window: NSWindow) async {
        guard !AXWalk.apiAnswers(TreeTarget(window)) else { return }
        let deadline = Date().addingTimeInterval(readySeconds)
        while Date() < deadline {
            if !(window.contentView?.accessibilityChildren() ?? []).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log(
            "control",
            "accessibility: the window's objects gave no elements within \(readySeconds) s")
    }

    /// How long `ready` waits at most.
    static let readySeconds: Double = 5

    /// The tree under `window`, one element per line; with `part`, only the first element of that
    /// role under it (`AXPopover`, `AXSheet`) and its subtree, framed from the window's corner.
    static func text(of window: NSWindow, part: String? = nil) throws -> String {
        try AXWalk.text(TreeTarget(window, part: part))
    }

    /// Presses the first element, depth first, whose identifier is `identifier`, as VoiceOver's
    /// press does. Answers why not when there is no such element or it refused the press.
    static func press(_ identifier: String, in window: NSWindow) -> String? {
        // A text field takes the focus as a click gives it, its window's first responder: the
        // API's focus is answered as set without the field editor moving in, and the keys that
        // follow would reach no field.
        if let field = AXWalk.textField(identifier, ObjectNode(object: window)) {
            guard field.isEnabled else { return "\(identifier) is disabled" }
            return window.makeFirstResponder(field) ? nil : "\(identifier) refused the focus"
        }
        return AXWalk.press(identifier, TreeTarget(window))
    }

    /// Chooses `item` by its title in the pop-up or segmented control with that identifier, as
    /// a person's choice from its menu would, without opening the menu (whose tracking loop
    /// would hold the command file until it closed). Answers why not.
    static func pick(_ identifier: String, item: String, in window: NSWindow) -> String? {
        AXWalk.pick(identifier, item: item, ObjectNode(object: window))
    }

    /// Every element under `window` whose identifier starts with `prefix`, in tree order.
    static func elements(withPrefix prefix: String, in window: NSWindow) -> [AXElementInfo] {
        AXWalk.elements(withPrefix: prefix, TreeTarget(window))
    }

    /// The frame, in points from the window's top-left corner, of the first element with the
    /// identifier; nil when none has it.
    static func frame(of identifier: String, in window: NSWindow) -> CGRect? {
        AXWalk.frame(of: identifier, TreeTarget(window))
    }

    /// The help (the tooltip) of the deepest element at `point`, in points from the window's
    /// top-left corner, that has one.
    static func help(at point: CGPoint, in window: NSWindow) -> String? {
        AXWalk.help(at: point, TreeTarget(window))
    }

    /// The identifier of the text field element over `view`, for a focus the API names no element
    /// for (while the screen is locked, or in the moment a field editor moves in).
    static func textFieldIdentifier(over view: NSView, in window: NSWindow) -> String? {
        let target = TreeTarget(window)
        let want = view.convert(view.bounds, to: nil)
        let top = window.frame.height
        // In points from the window's top-left corner, as the walk's frames are.
        let centre = CGPoint(x: want.midX, y: top - want.midY)
        return AXWalk.identifiedTextField(at: centre, target)
    }

    /// The identifier of the element that has the keyboard focus, as the accessibility API
    /// answers it: a SwiftUI field's identifier is on its element, not on the AppKit view that
    /// holds the focus.
    static func focusedIdentifier() -> String? {
        let app = AXWalk.application()
        var id = ""
        if let focused = AXNode.attribute(app, kAXFocusedUIElementAttribute),
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        {
            id = AXNode(focused as! AXUIElement).string(kAXIdentifierAttribute) ?? ""
        } else if let focused = NSApp.accessibilityApplicationFocusedUIElement() {
            // The API answers nothing while the screen is locked; the object it would have
            // vended is asked instead.
            // SwiftUI's identifier is on the element around the AppKit field that holds the
            // focus, a parent or two up.
            var e: AnyObject? = focused as AnyObject
            for _ in 0..<3 where id.isEmpty {
                guard let current = e else { break }
                id = ObjectNode(object: current).string(kAXIdentifierAttribute) ?? ""
                e = current.accessibilityParent?() as AnyObject?
            }
        }
        return id.isEmpty ? nil : id
    }
}

/// An element of the tree, read either through the accessibility API (`AXNode`) or from the
/// object that answers it (`ObjectNode`).
@MainActor
protocol TreeNode {
    func attribute(_ name: String) -> Any?
    var children: [Self] { get }
    /// The element's top-left corner in screen points, origin at the top of the main display.
    var point: CGPoint? { get }
    var size: CGSize? { get }
    func perform(_ action: String) -> Bool
    func focus() -> Bool
}

extension TreeNode {
    func string(_ name: String) -> String? { attribute(name) as? String }
    func bool(_ name: String) -> Bool? { (attribute(name) as? NSNumber)?.boolValue }
    var value: String? {
        switch attribute(kAXValueAttribute) {
        case let s as String: s
        case let a as NSAttributedString: a.string
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }
}

/// An element through the accessibility API, as VoiceOver reads it.
struct AXNode: TreeNode {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
        // The timeout is the element's own, not inherited from the application's.
        AXUIElementSetMessagingTimeout(element, AXWalk.messagingSeconds)
    }

    static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else {
            return nil
        }
        return v
    }

    func attribute(_ name: String) -> Any? { Self.attribute(element, name) }

    var children: [AXNode] {
        ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(AXNode.init)
    }

    private func axValue(_ name: String) -> AXValue? {
        guard let v = Self.attribute(element, name), CFGetTypeID(v) == AXValueGetTypeID() else {
            return nil
        }
        // The type id was checked, so the cast holds.
        return (v as! AXValue)
    }

    var point: CGPoint? {
        var p = CGPoint.zero
        guard let v = axValue(kAXPositionAttribute), AXValueGetValue(v, .cgPoint, &p) else {
            return nil
        }
        return p
    }

    var size: CGSize? {
        var s = CGSize.zero
        guard let v = axValue(kAXSizeAttribute), AXValueGetValue(v, .cgSize, &s) else {
            return nil
        }
        return s
    }

    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    func focus() -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            == .success
    }
}

/// An element as the object that answers the accessibility API for it, asked directly through
/// the `NSAccessibility` protocol, children unignored as the API unignores them.
struct ObjectNode: TreeNode {
    /// SwiftUI's elements answer the protocol's messages without declaring that they conform
    /// to it, so they are sent as messages to any object rather than through the protocol.
    let object: AnyObject

    func attribute(_ name: String) -> Any? {
        let o = object
        switch name {
        case kAXRoleAttribute: return o.accessibilityRole?()?.rawValue
        case kAXIdentifierAttribute:
            // An AppKit window or view answers with its own identifier, as the API reads it.
            let id = o.accessibilityIdentifier?() ?? ""
            guard id.isEmpty else { return id }
            return ((o as? NSWindow)?.identifier ?? (o as? NSView)?.identifier)?.rawValue ?? id
        case kAXDescriptionAttribute: return o.accessibilityLabel?() ?? nil
        case kAXTitleAttribute: return o.accessibilityTitle?() ?? nil
        case kAXValueAttribute: return o.accessibilityValue?() ?? nil
        case kAXHelpAttribute: return o.accessibilityHelp?() ?? nil
        case kAXEnabledAttribute:
            // The API gives an enabled state only for the roles that have one; the others read
            // enabled in the tree, as they do through it.
            guard let role = o.accessibilityRole?() ?? nil, Self.enablable.contains(role),
                let enabled = o.isAccessibilityEnabled?()
            else { return nil }
            return NSNumber(value: enabled)
        default: return nil
        }
    }

    /// The roles whose elements say whether they are enabled.
    private static let enablable: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .slider, .textField,
        .comboBox, .incrementor, .disclosureTriangle, .link, .menuItem,
        .textArea, .colorWell,
    ]

    /// The children the API would list: an element that is not one of its own (an ignored
    /// container) gives way to its children.
    var children: [ObjectNode] {
        var out = Self.unignored((object.accessibilityChildren?() ?? nil) ?? [])
        // A popover's window is the child of the element it opened from, as the API lists it.
        for w in Self.overlying where (w.accessibilityParent() as AnyObject?) === object {
            out.append(w)
        }
        return out.map(ObjectNode.init)
    }

    /// The windows over the one being walked (an open popover's), set for the length of a walk.
    @MainActor static var overlying: [NSWindow] = []

    private static func unignored(_ raw: [Any]) -> [AnyObject] {
        raw.flatMap { child -> [AnyObject] in
            let e = child as AnyObject
            if e.isAccessibilityElement?() ?? false { return [e] }
            return unignored((e.accessibilityChildren?() ?? nil) ?? [])
        }
    }

    /// The frame in the screen's own points from the bottom of the main display. The cell of an
    /// AppKit control that SwiftUI hosts (a text field's, a selectable text's, a slider's, a
    /// pop-up's, a segmented control's) answers a point outside the control on each side, while
    /// the API gives the control's frame less its alignment insets (a text field's two points
    /// either side), the rectangle SwiftUI lays it out by; that is taken here too, so the two
    /// readings agree. AppKit's own windows (an alert's, the title bar's buttons) answer as the
    /// API does.
    private var screenFrame: CGRect? {
        if let cell = object as? NSCell, let view = cell.controlView, let window = view.window,
            Self.hostedBySwiftUI(view)
        {
            let f = window.convertToScreen(view.convert(view.bounds, to: nil))
            let i = view.alignmentRectInsets
            return CGRect(
                x: f.minX + i.left, y: f.minY + i.bottom,
                width: f.width - i.left - i.right, height: f.height - i.top - i.bottom)
        }
        return object.accessibilityFrame?()
    }

    /// Whether a view sits inside a SwiftUI hosting view.
    private static func hostedBySwiftUI(_ view: NSView) -> Bool {
        var v = view.superview
        while let s = v {
            if String(describing: type(of: s)).contains("Hosting") { return true }
            v = s.superview
        }
        return false
    }

    var point: CGPoint? {
        // The object answers from the bottom of the main display; the API turns that into the
        // top-left corner from its top.
        guard let top = NSScreen.screens.first?.frame.maxY, let f = screenFrame else {
            return nil
        }
        return CGPoint(x: f.minX, y: top - f.maxY)
    }

    var size: CGSize? { screenFrame?.size }

    func perform(_ action: String) -> Bool {
        // A text field has no press (its focus stands for one); anything else that answers the
        // message has been pressed, whatever it answers: an AppKit button answers false.
        guard action == kAXPressAction,
            attribute(kAXRoleAttribute) as? String != kAXTextFieldRole
        else { return false }
        return object.accessibilityPerformPress?() != nil
    }

    func focus() -> Bool {
        if object.isAccessibilityFocused?() == true { return true }
        object.setAccessibilityFocused?(true)
        if object.isAccessibilityFocused?() == true { return true }
        // An AppKit field (a SecureField's among them) that does not take the focus this way
        // takes it as a click gives it, as its window's first responder.
        if let view = object as? NSView, view.acceptsFirstResponder, let window = view.window {
            return window.makeFirstResponder(view)
        }
        return false
    }
}

/// The walk itself.
@MainActor
enum AXWalk {
    /// Deeper than any tree the window builds; a cycle in what an element reports as its
    /// children stops here rather than recursing until the stack runs out.
    static let maxDepth = 64
    /// How long one question to the app's own elements may take before it is given up. The
    /// walk runs on the main actor, which also answers the questions, so a slow one freezes
    /// the window for this long.
    static let messagingSeconds: Float = 0.25
    /// The whole walk, after which `text` and `press` give up rather than hold the main actor
    /// any longer.
    static let walkSeconds: Double = 5
    /// The prefix `press` reads as a sheet's button by its title.
    static let alertPrefix = "alert."

    struct Failure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    static func application() -> AXUIElement {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, messagingSeconds)
        return app
    }

    /// Runs `body` on the window's element through the accessibility API, or, when the API
    /// answers no window (the screen is locked, the header says), on the window's own object.
    private static func withRoot<T>(
        _ target: TreeTarget, _ body: (any TreeNode) throws -> T
    ) throws -> T {
        if let root = element(target), root.string(kAXRoleAttribute) == kAXWindowRole {
            fallbackLogged = nil
            return try body(root)
        }
        guard AXIsProcessTrusted() else {
            throw Failure(
                reason:
                    "the accessibility API answered with no window: \(Bundle.main.bundlePath) is not allowed to read it; add it in System Settings > Privacy & Security > Accessibility"
            )
        }
        ObjectNode.overlying = WindowPicture.overlying(target.window)
        defer { ObjectNode.overlying = [] }
        let why = screenLocked ? "the screen is locked" : "the screen is not locked"
        if why != fallbackLogged {
            log(
                "control",
                "accessibility: the API answered no window (\(why)); reading the window's objects")
            fallbackLogged = why
        }
        return try body(ObjectNode(object: target.window))
    }

    /// Why the last walk read the window's objects, so the log says it once a stretch.
    private static var fallbackLogged: String?

    /// Whether the accessibility API answers the target's window.
    static func apiAnswers(_ target: TreeTarget) -> Bool {
        element(target)?.string(kAXRoleAttribute) == kAXWindowRole
    }

    /// Whether the screen is locked now, as the session reports it.
    static var screenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    static func text(_ target: TreeTarget) throws -> String {
        try withRoot(target) { root in try text(root, target) }
    }

    private static func text<N: TreeNode>(_ root: N, _ target: TreeTarget) throws -> String {
        let origin = root.point ?? .zero
        var start = root
        if let part = target.part {
            guard let found = first(role: part, under: root) else {
                throw Failure(reason: "the window has no \(part) open")
            }
            start = found
        }
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(walkSeconds)
        var late = false
        func print(_ e: N, _ depth: Int, under parent: String?) {
            guard depth <= maxDepth, !late else { return }
            if Date() > deadline {
                late = true
                return
            }
            // A window's title is listed by the API but not by the window's objects, so it is
            // left out; the title bar shows it, and the window is named by its own line.
            if parent == kAXWindowRole, e.string(kAXRoleAttribute) == kAXStaticTextRole { return }
            let l = line(e, origin: origin, under: parent)
            lines.append(String(repeating: "  ", count: depth) + l)
            // A scroll bar's parts and the insides of the window's own buttons are left out: they
            // change with the pointer and the scroll, and the window's objects list them otherwise
            // than the API does, so a tree read either way is the same.
            let role = e.string(kAXRoleAttribute)
            if role == kAXScrollBarRole { return }
            if role == kAXButtonRole, parent == kAXWindowRole { return }
            for child in e.children { print(child, depth + 1, under: role) }
        }
        print(start, 0, under: nil)
        if late {
            throw Failure(
                reason:
                    "the tree took longer than \(Int(walkSeconds)) s to read; \(lines.count) elements were read"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func press(_ identifier: String, _ target: TreeTarget) -> String? {
        do {
            return try withRoot(target) { root in press(identifier, root) }
        } catch {
            return "\(error)"
        }
    }

    private static func press<N: TreeNode>(_ identifier: String, _ root: N) -> String? {
        // `alert.<title>` is a button of the sheet over the window, by its title slugged: an
        // alert's buttons carry no identifier of the app's.
        var start = root
        var button: String?
        if identifier.hasPrefix(alertPrefix) {
            guard let sheet = first(role: kAXSheetRole, under: root) else {
                return "the window has no sheet open for \(identifier)"
            }
            start = sheet
            button = String(identifier.dropFirst(alertPrefix.count))
        }
        var found: N?
        let deadline = Date().addingTimeInterval(walkSeconds)
        var late = false
        walk(start, depth: 0) { e, _ in
            if Date() > deadline {
                late = true
                return true
            }
            if let button {
                // A destructive button is named by its description rather than its title.
                let name = e.string(kAXTitleAttribute) ?? e.string(kAXDescriptionAttribute) ?? ""
                guard e.string(kAXRoleAttribute) == kAXButtonRole,
                    ViewIdentifier.slug(name) == button
                else { return false }
            } else {
                guard e.string(kAXIdentifierAttribute) == identifier else { return false }
            }
            found = e
            return true
        }
        if late {
            return "no element with the identifier \(identifier) within \(Int(walkSeconds)) s"
        }
        guard let found else { return "no element has the identifier \(identifier)" }
        // A disabled element answers a press as if it took it, through either reading, so a
        // check that presses a dead button is told so rather than passing.
        if found.bool(kAXEnabledAttribute) == false { return "\(identifier) is disabled" }
        // A text field is focused rather than pressed, through either reading: the API may
        // answer a press on one as done without focusing it.
        let field = [kAXTextFieldRole, kAXTextAreaRole].contains(found.string(kAXRoleAttribute))
        if !field, found.perform(kAXPressAction) { return nil }
        // A text field has no press; a click there gives it the focus, and so does this.
        if found.focus() { return nil }
        return "\(identifier) refused the press"
    }

    /// The AppKit text field with that identifier among the window's objects, if it is one.
    static func textField(_ identifier: String, _ root: ObjectNode) -> NSTextField? {
        var found: NSTextField?
        walk(root, depth: 0) { e, _ in
            guard e.string(kAXIdentifierAttribute) == identifier else { return false }
            found = (e.object as? NSTextField) ?? ((e.object as? NSCell)?.controlView as? NSTextField)
            return true
        }
        return found
    }

    /// `pick` on the window's own objects, which are the AppKit controls themselves.
    static func pick(_ identifier: String, item: String, _ root: ObjectNode) -> String? {
        var found: ObjectNode?
        walk(root, depth: 0) { e, _ in
            guard e.string(kAXIdentifierAttribute) == identifier else { return false }
            found = e
            return true
        }
        guard let found else { return "no element has the identifier \(identifier)" }
        if found.bool(kAXEnabledAttribute) == false { return "\(identifier) is disabled" }
        guard let control = Self.control(in: found.object) else {
            return "\(identifier) is a \(type(of: found.object)), not a pop-up or segmented control"
        }
        switch control {
        case let popUp as NSPopUpButton:
            guard let index = popUp.itemTitles.firstIndex(of: item) else {
                return "\(identifier) has no item \(item); it has \(popUp.itemTitles)"
            }
            // SwiftUI's pop-up hears a choice through the item's own action, as a menu sends
            // it; an AppKit one through the button's.
            popUp.selectItem(at: index)
            if let menu = popUp.menu, menu.items[index].action != nil {
                menu.performActionForItem(at: index)
            } else {
                popUp.sendAction(popUp.action, to: popUp.target)
            }
        case let segments as NSSegmentedControl:
            let labels = (0..<segments.segmentCount).map { segments.label(forSegment: $0) ?? "" }
            guard let index = labels.firstIndex(of: item) else {
                return "\(identifier) has no segment \(item); it has \(labels)"
            }
            segments.selectedSegment = index
            segments.sendAction(segments.action, to: segments.target)
        default:
            return "\(identifier) is not a pop-up or segmented control"
        }
        return nil
    }

    /// The pop-up or segmented control an element is, or holds.
    private static func control(in object: AnyObject) -> NSControl? {
        if let cell = object as? NSCell, let view = cell.controlView {
            return control(in: view)
        }
        guard let view = object as? NSView else { return nil }
        if view is NSPopUpButton || view is NSSegmentedControl { return view as? NSControl }
        for sub in view.subviews {
            if let c = control(in: sub) { return c }
        }
        return nil
    }

    static func elements(withPrefix prefix: String, _ target: TreeTarget) -> [AXElementInfo] {
        (try? withRoot(target) { root in elements(withPrefix: prefix, root) }) ?? []
    }

    private static func elements<N: TreeNode>(withPrefix prefix: String, _ root: N)
        -> [AXElementInfo]
    {
        var out: [AXElementInfo] = []
        let deadline = Date().addingTimeInterval(walkSeconds)
        walk(root, depth: 0) { e, _ in
            if Date() > deadline { return true }
            guard let id = e.string(kAXIdentifierAttribute), id.hasPrefix(prefix) else {
                return false
            }
            let label = e.string(kAXDescriptionAttribute) ?? ""
            out.append(
                AXElementInfo(
                    identifier: id, role: e.string(kAXRoleAttribute) ?? "",
                    label: label.isEmpty ? e.string(kAXTitleAttribute) ?? "" : label,
                    value: e.value, enabled: e.bool(kAXEnabledAttribute) != false))
            return false
        }
        return out
    }

    static func frame(of identifier: String, _ target: TreeTarget) -> CGRect? {
        (try? withRoot(target) { root in frame(of: identifier, root) }) ?? nil
    }

    private static func frame<N: TreeNode>(of identifier: String, _ root: N) -> CGRect? {
        let origin = root.point ?? .zero
        var found: CGRect?
        let deadline = Date().addingTimeInterval(walkSeconds)
        walk(root, depth: 0) { e, _ in
            if Date() > deadline { return true }
            guard e.string(kAXIdentifierAttribute) == identifier, let p = e.point,
                let s = e.size
            else { return false }
            found = CGRect(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)
            return true
        }
        return found
    }

    static func help(at point: CGPoint, _ target: TreeTarget) -> String? {
        (try? withRoot(target) { root in help(at: point, root) }) ?? nil
    }

    private static func help<N: TreeNode>(at: CGPoint, _ root: N) -> String? {
        let origin = root.point ?? .zero
        // The deepest element holding the point with help wins.
        var best: (depth: Int, help: String)?
        let deadline = Date().addingTimeInterval(walkSeconds)
        walk(root, depth: 0) { e, depth in
            if Date() > deadline { return true }
            guard let p = e.point, let s = e.size,
                CGRect(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)
                    .contains(at),
                let help = e.string(kAXHelpAttribute), !help.isEmpty
            else { return false }
            if best.map({ depth >= $0.depth }) ?? true { best = (depth, help) }
            return false
        }
        return best?.help
    }

    static func identifiedTextField(at point: CGPoint, _ target: TreeTarget) -> String? {
        (try? withRoot(target) { root in identifiedTextField(at: point, root) }) ?? nil
    }

    private static func identifiedTextField<N: TreeNode>(at point: CGPoint, _ root: N) -> String? {
        let origin = root.point ?? .zero
        var found: String?
        walk(root, depth: 0) { e, _ in
            guard e.string(kAXRoleAttribute) == kAXTextFieldRole,
                let id = e.string(kAXIdentifierAttribute), !id.isEmpty, let p = e.point,
                let s = e.size,
                CGRect(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)
                    .insetBy(dx: -2, dy: -2).contains(point)
            else { return false }
            found = id
            return true
        }
        return found
    }

    /// The first element of `role` under `root`, depth first.
    private static func first<N: TreeNode>(role: String, under root: N) -> N? {
        var found: N?
        let deadline = Date().addingTimeInterval(walkSeconds)
        walk(root, depth: 0) { e, _ in
            if Date() > deadline { return true }
            guard e.string(kAXRoleAttribute) == role else { return false }
            found = e
            return true
        }
        return found
    }

    /// The application's element for the target: the one of its windows with the target's title
    /// and size, else the first; nil when it lists none.
    private static func element(_ target: TreeTarget) -> AXNode? {
        let windows =
            ((AXNode.attribute(application(), kAXWindowsAttribute) as? [AXUIElement]) ?? [])
            .map(AXNode.init)
        let want = target.size
        let match = windows.first { w in
            guard let s = w.size else { return false }
            return abs(s.width - want.width) < 1 && abs(s.height - want.height) < 1
                && w.string(kAXTitleAttribute) == target.title
        }
        return match ?? windows.first
    }

    /// Visits `element` and everything under it until `visit` returns true.
    @discardableResult
    private static func walk<N: TreeNode>(
        _ element: N, depth: Int, _ visit: (N, Int) -> Bool
    ) -> Bool {
        guard depth <= maxDepth else { return false }
        if visit(element, depth) { return true }
        for child in element.children {
            if walk(child, depth: depth + 1, visit) { return true }
        }
        return false
    }

    private static func line<N: TreeNode>(_ e: N, origin: CGPoint, under parent: String?)
        -> String
    {
        var parts = [e.string(kAXRoleAttribute) ?? "AXUnknown"]
        // AppKit numbers the views it names itself (`_NS:87`) from run to run, and an alert's
        // buttons (`action-button-1`) are named through the API in some runs and not in others,
        // with the sheet's key state; `press` takes a sheet's button by its title.
        if let id = e.string(kAXIdentifierAttribute), !id.isEmpty, !id.hasPrefix("_NS:"),
            !id.hasPrefix("action-button-")
        {
            parts.append("id=\(id)")
        }
        let label = e.string(kAXDescriptionAttribute) ?? ""
        parts.append(quoted(label.isEmpty ? e.string(kAXTitleAttribute) ?? "" : label))
        if let value = e.value { parts.append("value=" + quoted(value)) }
        let p = e.point ?? .zero
        let s = e.size ?? .zero
        let rect = CGRect(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)
        // An AppKit text field's height follows its text (14 pt empty, 13 with text in the
        // inspector's fields) while the row it sits in keeps its own, so its top and height are
        // left out.
        // A slider's knob is placed to a fraction of a point that the two ways of reading it
        // round apart, so it gives its value and no frame.
        let role = parts[0]
        if role == kAXValueIndicatorRole, parent == kAXSliderRole {
            parts.append("(–)")
        } else {
            parts.append(role == kAXTextFieldRole ? horizontal(rect) : frame(rect))
        }
        parts.append(e.bool(kAXEnabledAttribute) == false ? "disabled" : "enabled")
        return parts.joined(separator: " ")
    }

    /// In double quotes, with backslashes, quotes and newlines escaped, so a reader of the line
    /// finds where the text ends.
    private static func quoted(_ s: String) -> String {
        "\""
            + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// `(38,– 161×–)`: the frame's left edge and width only.
    private static func horizontal(_ r: CGRect) -> String {
        let nums = [r.minX, r.width].map { abs($0) < 1e9 ? Int($0.rounded()) : 0 }
        return "(\(nums[0]),– \(nums[1])×–)"
    }

    /// A rectangle in whole points, `(x,y w×h)`.
    private static func frame(_ r: CGRect) -> String {
        let nums = [r.minX, r.minY, r.width, r.height].map {
            abs($0) < 1e9 ? Int($0.rounded()) : 0
        }
        return "(\(nums[0]),\(nums[1]) \(nums[2])×\(nums[3]))"
    }
}
