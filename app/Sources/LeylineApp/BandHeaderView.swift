// SPDX-License-Identifier: Apache-2.0

// Region 2: one strip naming the band, how much of it is on screen in `ley`'s words, and the
// zoom pair. Resolution, FFT size and rows per second are not here and not anywhere.

import LeylineClient
import SwiftUI

struct BandHeaderView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
            Text(range).font(Theme.Font.value).foregroundStyle(Theme.inkTertiary)
            Spacer()
            zoomButton("minus") { session.zoomOut() }.disabled(session.zoom <= 1)
            Text(session.zoom > 1 ? "\(session.zoom)×" : "")
                .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint).frame(width: 22)
            zoomButton("plus") { session.zoomIn() }.disabled(session.zoom >= 8)
        }
        .padding(.horizontal, 14)
        .background(Theme.panelHeader)
    }

    private var title: String {
        if let b = session.band { return b.name }
        if let hz = session.tunedHz { return Frequency.format(hz) }
        return "No band"
    }

    /// The slice on screen, and when the radio cannot capture the whole band, `ley`'s sentence
    /// shortened to fit: `2.4 of 4 MHz · centred on 146.000`.
    private var range: String {
        guard let r = session.visibleRange else { return "" }
        let shown = "\(mhz(r.lowerBound)) – \(mhz(r.upperBound))"
        guard let b = session.band, let cap = session.capture, session.zoom == 1, b.widthHz > cap.sampleRate else { return shown }
        return "\(Frequency.format(cap.sampleRate).replacingOccurrences(of: " MHz", with: "")) of \(Frequency.format(b.widthHz)) · centred on \(mhz(cap.centerHz))"
    }

    private func mhz(_ hz: UInt64) -> String { String(format: "%.3f", Double(hz) / 1e6) }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.inkTertiary)
    }
}
