// SPDX-License-Identifier: Apache-2.0

// A staged run draws the same frame twice (docs/dev/app.md, "Staged runs"), so two pictures of
// a still scene differ only where the radio moves them: the spectrum and the waterfall, which a
// check masks. Three things move otherwise. Animations: off, for SwiftUI by a transaction at the
// window's root (`MainWindow`) and for AppKit's window and view animations by the registration
// defaults below. The text caret: it blinks, so it is held on. The window's focus: a window
// drawn as the key one has coloured traffic lights and active controls, and one in the
// background has grey ones, and which it is depends on what the person at the Mac is doing; a
// staged window answers that it is key and main whatever the focus, so it always draws the
// same. The registration domain is never written to disk, so none of this outlives the run.

import AppKit
import LeylineClient
import ObjectiveC

@MainActor
enum DeterministicFrames {
    /// Whether this launch is staged; read once, as the environment does not change.
    static let staged = AppControl.isStaged()

    /// The defaults a staged run reads in place of the person's: no window animation, a resize
    /// that takes no time, and a caret on for longer than any run.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "NSAutomaticWindowAnimationsEnabled": false,
            "NSWindowResizeTime": 0.001,
            "NSScrollAnimationEnabled": false,
            "NSTextInsertionPointBlinkPeriodOn": 1e9,
            "NSTextInsertionPointBlinkPeriodOff": 0,
        ])
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
    }

    /// The getters a window's key and active appearance is read from.
    private static let keyGetters: [Selector] =
        [
            #selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.isMainWindow),
        ]
        + [
            "hasKeyAppearance", "_hasKeyAppearance", "_hasActiveAppearance",
            "_hasActiveAppearanceIgnoringKeyFocus", "_isKeyWindow", "_isKeyWindowIgnoringFocus",
        ].map(NSSelectorFromString)

    /// Classes whose windows already answer that they are key.
    private static var keyedClasses: Set<ObjectIdentifier> = []

    /// Makes `window` answer that it is key and main whatever the focus. SwiftUI's window class
    /// is not ours to subclass in source, and moving the window to a subclass made at run time
    /// crashed the Library's first layout (a Swift cast on the window traps on a class with no
    /// Swift metadata), so the getters are replaced on the window's own class: in a staged run
    /// every window of that class draws as key.
    static func drawAsKey(_ window: NSWindow) {
        let cls: AnyClass = type(of: window)
        guard keyedClasses.insert(ObjectIdentifier(cls)).inserted else { return }
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        let yesFor: @convention(block) (AnyObject, Int) -> Bool = { _, _ in true }
        // `isKeyWindow` alone leaves the traffic lights grey: the frame asks AppKit's own
        // appearance getters, which are private and so named by string, each replaced only
        // where this macOS has it.
        for sel in keyGetters where class_getInstanceMethod(cls, sel) != nil {
            class_replaceMethod(cls, sel, imp_implementationWithBlock(yes), "c@:")
        }
        let button = NSSelectorFromString("_hasActiveAppearanceForStandardWindowButton:")
        if class_getInstanceMethod(cls, button) != nil {
            class_replaceMethod(cls, button, imp_implementationWithBlock(yesFor), "c@:q")
        }
        // Views read the key state when told it changed, as a real focus change tells them.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        if let frame = window.contentView?.superview { redraw(frame) }
        log("stage", "window \(window.windowNumber) drawn as key whatever the focus")
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }
}
