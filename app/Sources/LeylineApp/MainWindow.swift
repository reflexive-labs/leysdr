// SPDX-License-Identifier: Apache-2.0

// The window's four regions (docs/design/app-design-handoff.md, "The window"): chrome above and
// below a two-panel body. The sidebar and the transport bar are fixed; the waterfall takes what
// is left. The right third of the window does not exist in M1.

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
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            TransportBarView()
                .frame(height: Theme.Layout.transportHeight)
        }
        .background(Theme.ground)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { DeviceChip() }
        }
        .toolbarBackground(Theme.chrome, for: .windowToolbar)
        .preferredColorScheme(.dark)
    }

    /// Band rail, spectrum and waterfall, or the words for why there is nothing to draw.
    private var canvas: some View {
        VStack(spacing: 0) {
            BandRailView()
                .frame(height: Theme.Layout.bandRailHeight)
            Rectangle().fill(Theme.border).frame(height: 1)
            ZStack {
                VStack(spacing: 0) {
                    SpectrumView()
                        .frame(height: Theme.Layout.spectrumHeight)
                    // The seam between them is drawn by the waterfall, over its Metal view: a
                    // line laid here sat under the hosted view's rounded-out frame.
                    WaterfallView()
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
}

/// Where the window stands when there is nothing to draw, in the guide's words: the daemon, a
/// radio, a capture, and the thing to type.
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

/// One line about the last thing that happened, the last thing that went wrong, a channel the
/// capture no longer covers, or what the band's numbers say is wrong (`FailureState`), over the
/// bottom of the waterfall; a click dismisses it. The last two are the quietest: named, not
/// alarmed.
struct NoticeStrip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if let e = session.lastError {
            line(e.message.isEmpty ? e.code : e.message, colour: Theme.recording) {
                session.clearError()
            }
        } else if let n = session.notice {
            line(n, colour: Theme.inkTertiary) { session.clearNotice() }
        } else if let words = session.outOfCaptureWords {
            line(words, colour: Theme.inkSecondary) { session.dismissOutOfCapture() }
        } else if let f = session.failureShown {
            line("\(f.headline). \(f.detail)", colour: Theme.inkSecondary) {
                session.dismissFailure()
            }
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
