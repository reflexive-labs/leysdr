// SPDX-License-Identifier: Apache-2.0

// The window's regions (docs/design/app-design-handoff.md, "The window"): chrome above and
// below a body of two panels, and a third on the right since M2, the inspector (docs/design/
// app-design-handoff-m2.md, "The panel"). The sidebar, the inspector and the transport bar are
// fixed; the waterfall takes what is left. The inspector can be closed, and the window works
// without it. Two places share the toolbar (docs/design/app-design-handoff-m3.md, "Decided
// 2026-09-25: the Library"): the Radio is that window, and the Library replaces the whole body
// under the toolbar with what has been kept (`LibraryView.swift`) while the radio keeps running,
// because the capture, the channel and the feeds are the session's, not the body's. The first
// window opens under a splash (APP-8, `SplashView.swift`) that clears into it, its mark landing
// on the toolbar's.

import LeylineClient
import SwiftUI

struct MainWindow: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether no window has played the splash yet this launch. The first window's `playSplash`
    /// clears it; a window opened later starts with the splash `done`. A launch by URL would skip
    /// it too (the spec's clause), but the app opens no URLs yet.
    private static var splashPending = true
    @State private var splash: SplashPhase = MainWindow.splashPending ? .before : .done
    @State private var flight: SplashFlight?
    @State private var splashMark = WindowFrameAnchor()
    @State private var toolbarMark = WindowFrameAnchor()

    /// The toolbar's items appear as the splash leaves.
    private var chromeShown: Bool { splash == .leaving || splash == .done }
    /// The toolbar's mark appears when the splash's has landed on it and been removed, or with
    /// the rest when the splash's mark does not fly.
    private var toolbarMarkShown: Bool {
        splash == .done || (splash == .leaving && (reduceMotion || flight == nil))
    }

    var body: some View {
        // One container for both places, so the toolbar and the alert stay put across a switch.
        VStack(spacing: 0) {
            switch session.place {
            case .radio: RadioBody()
            case .library: LibraryBody()
            }
        }
        .background(Theme.ground)
        .overlay {
            if splash != .done {
                SplashView(phase: splash, flight: flight, markAnchor: splashMark)
            }
        }
        .task { await playSplash() }
        .toolbar {
            // The toolbar's glass is a capsule, a shape nothing else in the window has, so it
            // is hidden and each item draws the pop-ups' ground instead. The items are hidden
            // while the splash covers the window and fade in as it leaves.
            ToolbarItem(placement: .navigation) {
                BrandTitle(
                    markShown: toolbarMarkShown, wordShown: chromeShown, markAnchor: toolbarMark)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .navigation) { PlaceSwitch().shown(chromeShown) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { DeviceChip().shown(chromeShown) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { InspectorToggle().shown(chromeShown) }
                .sharedBackgroundVisibility(.hidden)
        }
        // `Leyline` is drawn by `BrandTitle`, so the window's own title is removed from the
        // toolbar. The window keeps its title (`WindowGroup("Leyline")`), which the Window menu
        // and the Dock's menu list; an empty `navigationTitle` would have left them blank.
        .toolbar(removing: .title)
        .toolbarBackground(Theme.chrome, for: .windowToolbar)
        // Hidden under the splash, so its ground and its flying mark reach the top of the window;
        // the splash draws `chrome` there as it leaves. Reduce Motion's cross-fade has no flight
        // and leaves the ground alone.
        .toolbarBackgroundVisibility(
            splash == .done || reduceMotion ? .visible : .hidden, for: .windowToolbar
        )
        .preferredColorScheme(.dark)
        // Before a band switch, a rail drag's release or a narrower width moves the radio off a
        // running recording (docs/design/app-design-handoff-m3.md, 8b). The buttons answer it;
        // the binding's setter does nothing, because SwiftUI may set it before or after the
        // button's action runs, and an answer given there would pre-empt Move anyway.
        .alert(
            "Move the radio?",
            isPresented: Binding(get: { session.retuneQuestion != nil }, set: { _ in }),
            presenting: session.retuneQuestion
        ) { _ in
            Button("Cancel", role: .cancel) { session.answerRetune(moveAnyway: false) }
            Button("Move anyway", role: .destructive) { session.answerRetune(moveAnyway: true) }
        } message: { q in
            Text(q.words)
        }
    }

    /// The splash's clock (APP-8): fade in, hold until the daemon is live or `splashMinHold` has
    /// passed, whichever is later and `splashMaxHold` at most, then the exit and removal. Every
    /// step's length is `Theme.Motion`'s.
    private func playSplash() async {
        guard splash == .before else { return }
        // Two windows restored together are both made before either appears.
        guard MainWindow.splashPending else {
            splash = .done
            return
        }
        MainWindow.splashPending = false
        let clock = ContinuousClock()
        let start = clock.now
        let fadeIn = Animation.easeOut(duration: Theme.Motion.splashFadeIn)
        withAnimation(reduceMotion ? nil : fadeIn) {
            splash = .shown
        }
        try? await Task.sleep(for: .seconds(Theme.Motion.splashMinHold))
        while !session.isLive, !Task.isCancelled,
            clock.now - start < .seconds(Theme.Motion.splashMaxHold)
        {
            try? await Task.sleep(for: .seconds(Theme.Motion.splashLivePoll))
        }
        let exitSeconds = reduceMotion ? Theme.Motion.splashReducedFade : Theme.Motion.splashExit
        withAnimation(.easeInOut(duration: exitSeconds)) {
            flight =
                reduceMotion
                ? nil
                : SplashFlight(from: splashMark.frameInWindow, to: toolbarMark.frameInWindow)
            splash = .leaving
        }
        try? await Task.sleep(for: .seconds(exitSeconds))
        splash = .done
    }
}

/// The toolbar's first item: the mark and `Leyline` (APP-8), in place of the window's title.
/// The mark is measured for the splash's flight and stays hidden until that mark has landed.
struct BrandTitle: View {
    let markShown: Bool
    let wordShown: Bool
    let markAnchor: WindowFrameAnchor

    var body: some View {
        HStack(spacing: Theme.Layout.brandTitleGap) {
            BrandMark()
                .background(WindowFrameProbe(anchor: markAnchor))
                .opacity(markShown ? 1 : 0)
            Text("Leyline").font(Theme.Font.label).foregroundStyle(Theme.ink)
                .opacity(wordShown ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A toolbar item under the splash: invisible and not clickable until it leaves.
    fileprivate func shown(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown)
    }
}

/// The Radio: bands and bookmarks, the canvas, the inspector and the transport bar, as M1 and
/// M2 built them with 8a and 8b. Switching to the Library and back makes the Metal view again;
/// the waterfall's rows are the feed's, so it comes back with its history.
struct RadioBody: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: Theme.Layout.sidebarWidth)
                Rectangle().fill(Theme.border).frame(width: 1)
                canvas
                if session.inspectorShown {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    InspectorView()
                        .frame(width: Theme.Layout.inspectorWidth)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            TransportBarView()
                .frame(height: Theme.Layout.transportHeight)
        }
    }

    /// Band rail, spectrum and waterfall, or the message explaining why there is nothing to draw.
    private var canvas: some View {
        VStack(spacing: 0) {
            BandRailView()
                .frame(height: Theme.Layout.bandRailHeight)
            Rectangle().fill(Theme.border).frame(height: 1)
            ZStack {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SpectrumView()
                            .frame(height: Theme.Layout.spectrumHeight)
                        // The seam between them is drawn by the waterfall, over its Metal view:
                        // a line laid here sat under the hosted view's rounded-out frame.
                        WaterfallView()
                    }
                    gutterColumn
                }
                if let words = session.emptyWords {
                    EmptyWords(headline: words.headline, detail: words.detail)
                }
                VStack {
                    Spacer()
                    NoticeStrip()
                }
            }
        }
    }

    /// The waterfall's time gutter, on the right of both charts: beside the waterfall it is the
    /// gutter, beside the spectrum the spectrum's ground, so the spectrum narrows with the
    /// waterfall and the two keep one frequency axis (the tuned band, the pointer's hairline and
    /// a peak line up across the seam). The screens draw the spectrum full width over a narrower
    /// waterfall; with one axis that would put every frequency at two x positions.
    private var gutterColumn: some View {
        VStack(spacing: 0) {
            Theme.ground.frame(height: Theme.Layout.spectrumHeight)
            HStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                WaterfallGutter()
            }
            // The seam the waterfall draws over its Metal view, continued across the gutter.
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(width: Theme.Layout.waterfallGutterWidth + 1)
    }
}

/// The toolbar's `Radio | Library` switch, a segmented control beside the traffic lights at the
/// toolbar's `navigation` placement (M3 handoff, "Decided 2026-09-25: the Library", restyled by
/// "10a · The Library, revised", which follows 9a): two segments in `label` on the toolbar's own
/// dark ground (`chrome`) inside a 1 pt `border` stroke with 6 pt corners. The place showing is
/// raised on a `border` ground `placeSwitchInset` inside the stroke, in `ink`; the other has no
/// ground and `inkTertiary` text. Until the owner's second run (2026-09-25) the whole control
/// sat on `border`, so the unselected segment was as light as the selected one and only the ink
/// told them apart. ⌘1 and ⌘2 are the View menu's. Two plain buttons rather than a segmented
/// `Picker`, because the system draws a segmented control's selected segment and its text in
/// its own colours, which `Theme`'s inks cannot set.
struct PlaceSwitch: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let outer = Theme.Layout.placeSwitchRadius
        let inset = Theme.Layout.placeSwitchInset
        HStack(spacing: 0) {
            ForEach(WindowPlace.allCases) { p in
                let shown = session.place == p
                Button {
                    session.place = p
                } label: {
                    Text(p.title).font(Theme.Font.label)
                        .foregroundStyle(shown ? Theme.ink : Theme.inkTertiary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(
                            shown ? Theme.border : Color.clear,
                            in: RoundedRectangle(cornerRadius: outer - inset)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(p.title) (⌘\(p.shortcut))")
                .accessibilityAddTraits(shown ? .isSelected : [])
            }
        }
        .padding(inset)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: outer))
        .overlay(
            RoundedRectangle(cornerRadius: outer).strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// The empty-state message, worded as in the guide, when there is nothing to draw: no daemon, no
/// radio, no capture, and what to type.
struct EmptyWords: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(headline).font(Theme.Font.title).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(Theme.raised.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

/// One line about the last thing that happened or the last thing that went wrong, over the
/// bottom of the waterfall; a click dismisses it. The band's failure state and a channel the
/// capture no longer covers were shown here in M1; since M2-6 clipping is on the device chip
/// and in its menu, and out of capture is a line in the inspector's identity
/// (docs/plans/app.md, M2-6).
struct NoticeStrip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if let e = session.lastError {
            line(e.message.isEmpty ? e.code : e.message, colour: Theme.recording) {
                session.clearError()
            }
        } else if let n = session.notice {
            line(n, colour: Theme.inkTertiary) { session.clearNotice() }
        }
    }

    private func line(_ text: String, colour: Color, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(Theme.Font.label).foregroundStyle(colour).lineLimit(2)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.chrome.opacity(0.94))
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
