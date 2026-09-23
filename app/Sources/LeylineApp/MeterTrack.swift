// SPDX-License-Identifier: Apache-2.0

// The inspector's one meter: a capsule track with an optional fill, ticks and a needle, all
// placed on one scale by `Scale.x`. Signal, Tuning and Deviation are all drawn with it, so the
// three rows share a height, a width and a tick, and differ only in what they fill. Each used to
// be its own view (`SignalBar`, `CentreMeter`, `DeviationMeter`), with the Tuning track 4 pt
// taller than the other two and Deviation borrowing Signal's level ramp, which painted ordinary
// speech in the tuned channel's orange. The squelch track in the transport bar stays its own
// view: it is a control with a drag, not a reading.

import SwiftUI

struct MeterTrack: View {
    enum Fill: Equatable {
        /// No fill: a needle meter (Tuning).
        case none
        /// The level ramp over the whole track, cut off at the level, so the colour at the end
        /// matches the strength word beside it (Signal).
        case ramp
        /// `inkTertiary` up to `cautionAbove` and `caution` past it (Deviation): only the part
        /// over the limit is coloured. A fully caution-coloured fill was tried and read as a
        /// yellow background (the owner, 2026-09-21).
        case neutral(cautionAbove: Double?)
    }

    let range: ClosedRange<Double>
    var fill: Fill = .none
    /// Where the fill ends; NaN draws none.
    var level: Double = .nan
    /// Thin marks in `borderStrong`: a nominal, a centre, the squelch. NaN entries are skipped.
    var ticks: [Double] = []
    /// A 3 pt mark in `needleInk`; NaN draws none.
    var needle: Double = .nan
    var needleInk: Color = Theme.inkSecondary

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.border)
                    fillLayer(width: w)
                }
                .frame(height: Theme.Layout.meterTrackHeight)
                .clipShape(Capsule())
                ForEach(ticks.filter(\.isFinite), id: \.self) { t in
                    Rectangle().fill(Theme.borderStrong)
                        .frame(width: 1, height: Theme.Layout.meterMarkHeight)
                        .offset(x: (x(t, w) - 0.5).clamped(to: 0...max(0, w - 1)))
                }
                if needle.isFinite {
                    Capsule().fill(needleInk)
                        .frame(width: 3, height: Theme.Layout.meterMarkHeight)
                        .offset(x: (x(needle, w) - 1.5).clamped(to: 0...max(0, w - 3)))
                }
            }
            .frame(width: w, height: Theme.Layout.meterMarkHeight, alignment: .leading)
        }
        .frame(height: Theme.Layout.meterMarkHeight)
    }

    @ViewBuilder
    private func fillLayer(width w: CGFloat) -> some View {
        let end = level.isFinite ? x(level, w) : 0
        switch fill {
        case .none:
            EmptyView()
        case .ramp:
            LinearGradient(colors: Theme.levelStops, startPoint: .leading, endPoint: .trailing)
                .mask(alignment: .leading) { Rectangle().frame(width: end) }
        case .neutral(let cautionAbove):
            // The caution fill runs to the level and the neutral one over it to the limit, so
            // only the part past the limit shows as caution.
            let knee = cautionAbove.map { x($0, w) } ?? w
            Rectangle().fill(Theme.caution).frame(width: end)
            Rectangle().fill(Theme.inkTertiary).frame(width: min(end, knee))
        }
    }

    private func x(_ v: Double, _ w: CGFloat) -> CGFloat { Scale.x(of: v, in: range, width: w) }
}
