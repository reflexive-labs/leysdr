// SPDX-License-Identifier: Apache-2.0

// The window's regions (docs/design/app-design-handoff.md, "The window"): chrome above and
// below a body of two panels, and a third on the right since M2, the inspector (docs/design/
// app-design-handoff-m2.md, "The panel"). The sidebar, the inspector and the transport bar are
// fixed; the waterfall takes what is left. The inspector can be closed, and the window works
// without it.

import LeylineClient
import SwiftUI

struct MainWindow: View {
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
        .background(Theme.ground)
        .toolbar {
            // The toolbar's glass is a capsule, a shape nothing else in the window has, so it
            // is hidden and each item draws the pop-ups' ground instead.
            ToolbarItem(placement: .primaryAction) { DeviceChip() }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { InspectorToggle() }
                .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(Theme.chrome, for: .windowToolbar)
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

    /// Band rail, spectrum and waterfall, or the message explaining why there is nothing to draw.
    /// While the sidebar's Recordings source shows with a row selected, that channel's page
    /// covers it (`RecordingsPage`, M3 handoff, 8c): an overlay, as the empty state is, so the
    /// Metal view and its subscription carry on underneath and come back as they were, and the
    /// transport bar below stays live.
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
        .overlay {
            if session.recordingsPageShown { RecordingsPage() }
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
