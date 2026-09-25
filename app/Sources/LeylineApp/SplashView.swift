// SPDX-License-Identifier: Apache-2.0

// The first window's splash (docs/plans/app.md, APP-8): `docs/design/brand/leyline-splash.svg`
// drawn in code over the window, held until the daemon is live, then cleared in one 0.7 s
// ease-in-out. `MainWindow` owns the phase and its clock (`playSplash`); this file draws a
// phase. The steps and their durations are `Theme.Motion`, the sizes `Theme.Layout.splash*`.
//
// The spec's flight is one `matchedGeometryEffect` between this mark and the toolbar's. It is
// not used: a toolbar item is drawn by AppKit's toolbar in a hosting view of its own, outside
// the window content's view tree, so the two marks share no hierarchy for the effect to move a
// view between, and the destination would be clipped to the item's bounds. The mark here flies
// instead: both marks are measured in the window's coordinates (`WindowFrameProbe`, the one
// space the content and a toolbar item share), and this one is offset and scaled onto the other
// while the toolbar's stays hidden, then swapped for it when the splash is removed. A mark that
// could not be measured fades with the words, and the toolbar's fades in.
//
// The window is revealed by a sweep on the splash's own ground, from the top down, rather than a
// mask on the window's body as the spec has it: the body holds the waterfall's Metal view, and a
// SwiftUI mask over a hosted AppKit view is not something this app has seen work.

import AppKit
import SwiftUI

/// Where the first window's splash is. Later windows start at `done`.
enum SplashPhase {
    /// Drawn at zero opacity for the frame before the fade-in starts.
    case before
    /// Faded in and holding.
    case shown
    /// The exit is animating.
    case leaving
    /// Removed; the toolbar's mark is showing.
    case done
}

/// How the splash's mark moves onto the toolbar's: the distance between the two centres and the
/// ratio of their sizes, measured when the exit starts.
struct SplashFlight: Equatable {
    var offset: CGSize
    var scale: CGFloat

    /// nil unless both marks are in a window with a size.
    init?(from: CGRect?, to: CGRect?) {
        guard let from, let to, from.width > 0, to.width > 0 else { return nil }
        // Window coordinates run up from the bottom; SwiftUI's offset runs down.
        offset = CGSize(width: to.midX - from.midX, height: from.midY - to.midY)
        scale = to.width / from.width
    }
}

struct SplashView: View {
    let phase: SplashPhase
    let flight: SplashFlight?
    /// Where the splash's mark is, for `MainWindow` to measure the flight from.
    let markAnchor: WindowFrameAnchor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias L = Theme.Layout

    var body: some View {
        // Laid out in the content's safe area, so the toolbar's height is the top inset; each
        // layer then extends under the toolbar, whose own ground is hidden while this shows.
        GeometryReader { proxy in
            let top = proxy.safeAreaInsets.top
            let diagonal = hypot(proxy.size.width, proxy.size.height + top)
            ZStack {
                Theme.ground
                    .modifier(SweepMask(progress: sweeping ? 1 : 0))
                    .opacity(sweeping ? 0 : 1)
                    .ignoresSafeArea()
                // The toolbar's ground, faded in under its items as they appear, so the swap to
                // the toolbar's own ground when the splash goes does not show.
                VStack(spacing: 0) {
                    Theme.chrome.frame(height: top)
                    Spacer(minLength: 0)
                }
                .opacity(leaving ? 1 : 0)
                .ignoresSafeArea()
                composition(diagonal: diagonal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .opacity(reduceMotion && leaving ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leyline, software defined radio")
    }

    private var leaving: Bool { phase == .leaving }
    /// The ripple, the sweep and the flight; Reduce Motion has none of them.
    private var sweeping: Bool { leaving && !reduceMotion }
    private var flying: Bool { sweeping && flight != nil }
    private var wordsShown: Bool { phase == .shown || (leaving && reduceMotion) }
    private var markShown: Bool { phase == .shown || flying || (leaving && reduceMotion) }

    /// The SVG's 512×200: the mark and `leyline` on one baseline, the tagline between its rules
    /// on a second 43 pt below, both rows centred.
    private func composition(diagonal: CGFloat) -> some View {
        ZStack(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
            HStack(alignment: .firstTextBaseline, spacing: L.splashMarkGap) {
                markSlot(diagonal: diagonal)
                    .alignmentGuide(.firstTextBaseline) { d in
                        d[VerticalAlignment.center] + L.splashMarkRaise
                    }
                Text("leyline")
                    .font(Theme.Font.wordmark)
                    .tracking(Theme.wordmarkTracking)
                    .foregroundStyle(Theme.ink)
                    .opacity(wordsShown ? 1 : 0)
            }
            tagline
                .alignmentGuide(.firstTextBaseline) { d in
                    d[.firstTextBaseline] - L.splashLineDrop
                }
                .opacity(wordsShown ? 1 : 0)
        }
    }

    private var tagline: some View {
        // The SVG's rule colour is #2A3034, `borderStrong`.
        ZStack(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
            Text("SOFTWARE DEFINED RADIO")
                .font(Theme.Font.tagline)
                .tracking(Theme.taglineTracking)
                .foregroundStyle(Theme.inkMuted)
            ForEach([-1, 1] as [CGFloat], id: \.self) { side in
                Rectangle().fill(Theme.borderStrong)
                    .frame(width: L.splashRuleLength, height: 1)
                    .alignmentGuide(.firstTextBaseline) { d in
                        d[VerticalAlignment.center] + L.splashRuleRaise
                    }
                    .offset(x: side * L.splashRuleOffset)
            }
        }
    }

    /// The mark, and the ripple that leaves it: a second ring at the mark's size that grows to
    /// the window's diagonal while its line thins to nothing and it fades.
    private func markSlot(diagonal: CGFloat) -> some View {
        let size = L.splashMarkSize
        let line = L.splashMarkLine
        // The flying mark's line thickens as it shrinks, so it lands at the toolbar mark's 1.2.
        let landingLine = L.brandMarkLine / (flight?.scale ?? 1)
        return ZStack {
            Ring(
                radius: sweeping ? diagonal / 2 : (size - line) / 2,
                lineWidth: sweeping ? 0 : line
            )
            .fill(Theme.accent)
            .opacity(phase == .shown ? 1 : 0)
            BrandMark(size: size, lineWidth: flying ? landingLine : line)
                .background(WindowFrameProbe(anchor: markAnchor))
                .scaleEffect(flying ? flight?.scale ?? 1 : 1)
                .offset(flying ? flight?.offset ?? .zero : .zero)
                .opacity(markShown ? 1 : 0)
        }
        .frame(width: size, height: size)
    }
}

/// The ground's reveal: a gradient mask whose soft edge moves from above the top (all of the
/// ground showing) to below the bottom (none of it), so the window appears from the top down
/// the way a waterfall row lands. `progress` animates because the modifier is `Animatable`.
private struct SweepMask: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let edge = Theme.Layout.splashSweepEdge
        let clearTo = progress * (1 + edge) - edge
        content.mask {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: UnitPoint(x: 0.5, y: clearTo),
                endPoint: UnitPoint(x: 0.5, y: clearTo + edge))
        }
    }
}

/// Holds the AppKit view `WindowFrameProbe` lays under a SwiftUI one, so that view's frame can be
/// read in its window's coordinates when it is needed.
@MainActor
final class WindowFrameAnchor {
    weak var view: NSView?

    /// nil before the view is in a window.
    var frameInWindow: CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

/// An empty AppKit view as a SwiftUI view's background, sized to it. It never takes a click.
struct WindowFrameProbe: NSViewRepresentable {
    let anchor: WindowFrameAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
