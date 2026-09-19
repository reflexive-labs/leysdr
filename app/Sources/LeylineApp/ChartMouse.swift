// SPDX-License-Identifier: Apache-2.0

// The mouse on a chart, once: the cursor teaches the gesture, a press that travels is a drag,
// one that does not is a click, a notch of the wheel is a fine step. The waterfall's Metal view
// and the spectrum's transparent catcher both forward their events here, so the two panels
// answer the hand the same way and the pointer's hairline, kept in `AppSession`, shows on both.

import AppKit
import SwiftUI

@MainActor
final class ChartMouse {
    var onPointer: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint, Bool) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    private var downAt: CGPoint?
    private var dragged = false
    private var scrolled: CGFloat = 0

    /// How far the wheel or the fingers travel for one fine step.
    static let scrollNotch: CGFloat = 20

    static let trackingOptions: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate]

    func cursorUpdate() {
        (downAt == nil ? NSCursor.crosshair : NSCursor.resizeLeftRight).set()
    }

    func moved(_ p: CGPoint) { onPointer?(p) }

    func exited() { onPointer?(nil) }

    func down(_ p: CGPoint) {
        downAt = p
        dragged = false
        NSCursor.resizeLeftRight.set()
    }

    func dragged(_ p: CGPoint) {
        guard let start = downAt else { return }
        if !dragged, abs(p.x - start.x) < 3 { return }
        dragged = true
        onPointer?(p)
        onDrag?(p, false)
    }

    func up(_ p: CGPoint) {
        if dragged { onDrag?(p, true) } else { onClick?(p) }
        downAt = nil
        dragged = false
        NSCursor.crosshair.set()
    }

    // One fine step per notch of travel, because a trackpad reports precise deltas of a point
    // or two and keeps reporting them after the fingers lift: a step per event ran the frequency
    // away on one flick. Momentum is not a hand on the wheel, so it is ignored, and a mouse
    // wheel's line counts as a whole notch.
    func scroll(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) { scrolled = 0 }
        scrolled += event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * Self.scrollNotch
        guard abs(scrolled) >= Self.scrollNotch else { return }
        let travel = scrolled
        scrolled = 0
        onScroll?(travel)
    }
}

/// A transparent view over the spectrum that owns the mouse the way the waterfall's Metal view
/// does, with the same point convention (origin top-left, points).
final class ChartCatcherView: NSView {
    let mouse = ChartMouse()
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: ChartMouse.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { mouse.cursorUpdate() }
    override func mouseMoved(with event: NSEvent) { mouse.moved(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { mouse.exited() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouse.down(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) { mouse.dragged(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { mouse.up(convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) { mouse.scroll(event) }
}

struct ChartCatcher: NSViewRepresentable {
    let onPointer: (CGPoint?) -> Void
    let onClick: (CGPoint) -> Void
    let onDrag: (CGPoint, Bool) -> Void
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ChartCatcherView {
        let view = ChartCatcherView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ChartCatcherView, context: Context) { apply(to: view) }

    private func apply(to view: ChartCatcherView) {
        view.mouse.onPointer = onPointer
        view.mouse.onClick = onClick
        view.mouse.onDrag = onDrag
        view.mouse.onScroll = onScroll
    }
}

/// The pointer's hairline at its frequency, on whichever chart, and on the chart the pointer
/// is over, a badge with the value, not the verb.
struct PointerOverlay: View {
    @Environment(AppSession.self) private var session
    let columns: Columns
    let size: CGSize
    /// The pointer's place on this chart, or nil when it is over the other one.
    let point: CGPoint?

    var body: some View {
        if let hz = session.pointerHz {
            Rectangle().fill(Theme.ink.opacity(0.35)).frame(width: 1, height: size.height)
                .offset(x: columns.x(of: hz))
                .allowsHitTesting(false)
            if let p = point {
                PointerBadge(text: session.pointerWords(hz))
                    .offset(x: min(max(p.x + 12, 0), size.width - 130), y: min(max(p.y + 14, 0), max(size.height - 28, 0)))
                    .allowsHitTesting(false)
            }
        }
    }
}

struct PointerBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Font.value)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.ground.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

/// The tuned channel as the two charts draw it: `accent` at 11 % with 1.5 pt edges inside the
/// band, the same width on both so the spectrum's band meets the waterfall's.
struct TunedBand: View {
    let x0: CGFloat
    let x1: CGFloat
    let height: CGFloat

    var body: some View {
        // The edges are overlaid before the offset: an overlay added after it is placed on the
        // un-shifted frame, at the left of the panel.
        Rectangle().fill(Theme.accent.opacity(0.11))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.8)).frame(width: 1.5) }
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.accent.opacity(0.8)).frame(width: 1.5) }
            .frame(width: max(2, x1 - x0), height: height)
            .offset(x: x0)
            .allowsHitTesting(false)
    }
}
