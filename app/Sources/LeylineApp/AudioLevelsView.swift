// SPDX-License-Identifier: Apache-2.0

// The inspector's audio ladder: the meter `ley levels --watch` draws in the terminal
// (docs/design/audio-meters.md), in the panel between the reading and the log. Nine octave bands
// off the channel's demod tap, then a gap, then the meter's rms and peak as two more bars, on `ley
// levels`' scale: 6 dB a step from 0 to −24 and 10 dB a step to −60, held, so a bar of a given
// height is always the same dB. The levels and their ballistics are `AudioLevelsFeed`'s; this view
// draws them in one Canvas and keeps nothing. No OVER: clipping is the radio's, and it is shown on
// the device chip.

import LeylineClient
import SwiftUI

struct AudioLevelsView: View {
    @Environment(AppSession.self) private var session

    /// The gutter's marks: full scale, the −18 dBFS alignment line, and the scale's floor.
    static let marksDB: [Double] = [LevelScale.topDB, LevelScale.alignmentDB, LevelScale.bottomDB]
    /// The −18 line's dash, in points: on, off.
    static let dash: [CGFloat] = [2, 3]
    /// The gap between the plot and the labels under it.
    static let labelGap: CGFloat = 3
    /// `63 125 250 500 1k 2k 4k 8k 16k`, then the pair.
    static let labels = BandLevels().bands.map(\.label) + ["rms", "peak"]

    /// Everything one frame of the ladder is drawn from, read in `body` where observation
    /// tracks it and handed to the Canvas whole (the same rule as `SpectrumView.Rows`).
    struct Frame {
        var bars: [LevelBar]
        var rmsDB: Double
        var peakDB: Double
    }

    var body: some View {
        let feed = session.audioLevels
        let frame = Frame(bars: feed.bars, rmsDB: feed.rmsDB, peakDB: feed.peakDB)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(text: "Audio")
                .padding(.bottom, 6)
            Canvas(rendersAsynchronously: false) { ctx, size in
                Self.draw(frame, in: &ctx, size: size)
            }
            .frame(height: Self.height)
            .help(
                "Octave bands of the channel's detector output, and the meter's rms and peak, in dBFS. Dark while the squelch is closed."
            )
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The plot, the labels under it and the numbers under the pair.
    static var height: CGFloat {
        Theme.Layout.audioPlotHeight + labelGap + Theme.Layout.audioLabelHeight
            + Theme.Layout.audioNumberHeight
    }

    /// The left edge of bar `i`'s slot: the nine bands from the gutter, rms and peak past a gap.
    static func slotX(_ i: Int, bands: Int) -> CGFloat {
        Theme.Layout.audioGutterWidth + CGFloat(i) * Theme.Layout.audioSlotWidth
            + (i >= bands ? Theme.Layout.audioPairGap : 0)
    }

    /// Where a level sits in the plot: the bottom at −60 dBFS and the top at full scale.
    static func y(_ db: Double) -> CGFloat {
        Theme.Layout.audioPlotHeight * (1 - CGFloat(LevelScale.fraction(db)))
    }

    static func draw(_ f: Frame, in ctx: inout GraphicsContext, size: CGSize) {
        let plotH = Theme.Layout.audioPlotHeight
        let bands = f.bars.count - 2
        let right = slotX(f.bars.count - 1, bands: bands) + Theme.Layout.audioSlotWidth

        // The gutter: 0 at the top, −18 on its line, −60 at the bottom, each kept inside the plot.
        for db in marksDB {
            let anchor: UnitPoint =
                db == LevelScale.topDB
                ? .topTrailing : db == LevelScale.bottomDB ? .bottomTrailing : .trailing
            ctx.draw(
                Text(Measure.bare(db)).font(Theme.Font.columnHead)
                    .foregroundStyle(Theme.inkFaintest),
                at: CGPoint(x: Theme.Layout.audioGutterWidth - 4, y: y(db)), anchor: anchor)
        }

        // Each slot: the unlit ladder in `border`, so the scale reads while nothing plays; the
        // lit part cut from one gradient over the whole plot, so a height has one colour; the cap.
        let ramp = GraphicsContext.Shading.linearGradient(
            Gradient(colors: Theme.levelStops), startPoint: CGPoint(x: 0, y: plotH),
            endPoint: CGPoint(x: 0, y: 0))
        for (i, bar) in f.bars.enumerated() {
            let x =
                slotX(i, bands: bands)
                + (Theme.Layout.audioSlotWidth - Theme.Layout.audioBarWidth) / 2
            let w = Theme.Layout.audioBarWidth
            ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: plotH)), with: .color(Theme.border))
            if bar.levelDB > LevelScale.bottomDB {
                let top = y(bar.levelDB)
                ctx.fill(Path(CGRect(x: x, y: top, width: w, height: plotH - top)), with: ramp)
            }
            if bar.capDB > LevelScale.bottomDB {
                let capY = min(y(bar.capDB), plotH - Theme.Layout.audioCapHeight)
                ctx.fill(
                    Path(CGRect(x: x, y: capY, width: w, height: Theme.Layout.audioCapHeight)),
                    with: .color(Theme.inkSecondary))
            }
        }

        // The −18 dBFS alignment line across the bars, over them so it reads through a lit one.
        var line = Path()
        line.move(to: CGPoint(x: Theme.Layout.audioGutterWidth, y: y(LevelScale.alignmentDB)))
        line.addLine(to: CGPoint(x: right, y: y(LevelScale.alignmentDB)))
        ctx.stroke(
            line, with: .color(Theme.borderStrong), style: StrokeStyle(lineWidth: 1, dash: dash))

        // Labels under the slots, and the meter's two numbers under the pair: `—` before the
        // first meter, because nothing was measured.
        let labelY = plotH + labelGap
        for (i, label) in labels.enumerated() where i < f.bars.count {
            let cx = slotX(i, bands: bands) + Theme.Layout.audioSlotWidth / 2
            ctx.draw(
                Text(label).font(Theme.Font.columnHead).foregroundStyle(Theme.inkFaintest),
                at: CGPoint(x: cx, y: labelY), anchor: .top)
        }
        let numberY = labelY + Theme.Layout.audioLabelHeight
        for (i, db) in [f.rmsDB, f.peakDB].enumerated() {
            let cx = slotX(bands + i, bands: bands) + Theme.Layout.audioSlotWidth / 2
            ctx.draw(
                Text(Measure.bare(db)).font(Theme.Font.valueSmall)
                    .foregroundStyle(Theme.inkTertiary),
                at: CGPoint(x: cx, y: numberY), anchor: .top)
        }
    }
}
