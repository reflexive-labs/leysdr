// SPDX-License-Identifier: Apache-2.0

// Region 3: the spectrum. A live trace, a max-hold trace, a 10×4 grid, and the tuned channel as
// a vertical band. It is a peak display but carries no label saying so, because that label
// would be the detector's word (invariant 12). Every column is the loudest bin under it, so a
// carrier one bin wide is never lost between two pixels. The mouse works here as on the
// waterfall, through the same `ChartMouse`, and the pointer's hairline shows on both.

import LeylineClient
import LeylineProto
import SwiftUI

struct SpectrumView: View {
    @Environment(AppSession.self) private var session
    @State private var pointer: CGPoint?

    /// The trace's axis: this far under the floor at the bottom, this far over it at the top.
    static let belowFloorDB: Float = 10
    static let aboveFloorDB: Float = 70

    var body: some View {
        // Read here, in the body, so the canvas is redrawn on every row and on every retune: a
        // read inside the drawing closure alone is not tracked, so the capture, the visible range
        // and the tuned channel read there left the old band drawn until the next row arrived.
        let feed = session.spectrum
        let rows = Rows(
            latest: feed.latest,
            hold: session.maxHold ? feed.hold.levelsDB : [],
            floorDB: feed.floorDB,
            capture: session.capture,
            range: session.visibleRange,
            tunedHz: session.tunedHz,
            channel: session.channel
        )
        GeometryReader { geo in
            let columns = rows.columns(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    draw(in: &ctx, size: size, rows: rows)
                }
                ChartCatcher(
                    onPointer: { p in
                        pointer = p
                        session.pointerHz = p.flatMap { columns?.hz(atX: $0.x) }
                    },
                    onClick: { p in if let c = columns { session.tune(to: c.hz(atX: p.x)) } },
                    onDrag: { p, ended in
                        if let c = columns { session.chartDrag(to: c.hz(atX: p.x), ended: ended) }
                    },
                    onScroll: { dy in session.step(dy > 0 ? 1 : -1, fine: true) }
                )
                if let c = columns {
                    // The tuned channel, the same view the waterfall draws, so the two bands
                    // are one width and meet at the seam.
                    if let hz = rows.tunedHz, let ch = rows.channel {
                        TunedBand(
                            x0: c.x(of: hz - UInt64(ch.bandwidthHz) / 2),
                            x1: c.x(of: hz + UInt64(ch.bandwidthHz) / 2), height: geo.size.height)
                    }
                    PointerOverlay(columns: c, size: geo.size, point: pointer)
                }
                MaxHoldChip()
                    .padding(8)
            }
        }
        .background(Theme.ground)
        .clipped()
    }

    /// Everything one frame of the trace is drawn from, read in `body` where observation
    /// tracks it and handed to `draw` whole.
    struct Rows {
        var latest: [Float]
        var hold: [Float]
        var floorDB: Float
        var capture: Leyline_V1_Capture?
        var range: ClosedRange<UInt64>?
        var tunedHz: UInt64?
        var channel: Leyline_V1_Channel?

        func columns(width: CGFloat) -> Columns? {
            guard let cap = capture, let range, cap.sampleRate > 0 else { return nil }
            return Columns(
                range: range, captureCenterHz: cap.centerHz, captureSpanHz: cap.sampleRate,
                bins: Int(SpectrumFeed.bins), width: width)
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, rows: Rows) {
        // The grid is drawn whether or not there is a row, so the empty chart is recognisable.
        var grid = Path()
        for i in 1..<10 {
            let x = size.width * CGFloat(i) / 10
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for i in 1..<4 {
            let y = size.height * CGFloat(i) / 4
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(grid, with: .color(Theme.border.opacity(0.6)), lineWidth: 0.5)

        guard let cap = rows.capture, let range = rows.range, cap.sampleRate > 0 else { return }
        let latest = rows.latest
        guard !latest.isEmpty else { return }
        let floor = rows.floorDB.isNaN ? SpectrumFold.medianDB(latest) : rows.floorDB
        let bottom = floor - Self.belowFloorDB
        let top = floor + Self.aboveFloorDB
        let columns = Columns(
            range: range, captureCenterHz: cap.centerHz, captureSpanHz: cap.sampleRate,
            bins: latest.count, width: size.width)

        if rows.hold.count == latest.count {
            let path = trace(rows.hold, columns: columns, size: size, bottom: bottom, top: top)
            ctx.stroke(path, with: .color(Theme.good.opacity(0.5)), lineWidth: 1)
        }
        let live = trace(latest, columns: columns, size: size, bottom: bottom, top: top)
        ctx.stroke(live, with: .color(Theme.ink), lineWidth: 1.15)

        // The window's two ends, faintly, at the right edge: without them the trace has no
        // scale and the max-hold line means nothing quantitative.
        ctx.draw(
            Text(dbLabel(top, unit: true)).font(Theme.Font.valueSmall).foregroundStyle(
                Theme.inkFaint),
            at: CGPoint(x: size.width - 8, y: 6), anchor: .topTrailing)
        ctx.draw(
            Text(dbLabel(bottom, unit: false)).font(Theme.Font.valueSmall).foregroundStyle(
                Theme.inkFaint),
            at: CGPoint(x: size.width - 8, y: size.height - 5), anchor: .bottomTrailing)
    }

    /// `−18 dBFS`, `−104`: a real minus sign, the unit on the top label only.
    private func dbLabel(_ db: Float, unit: Bool) -> String {
        let n = String(format: "%.0f", db).replacingOccurrences(of: "-", with: "−")
        return unit ? "\(n) dBFS" : n
    }

    private func trace(_ levels: [Float], columns: Columns, size: CGSize, bottom: Float, top: Float)
        -> Path
    {
        var path = Path()
        let w = Int(size.width.rounded(.down))
        guard w > 1, top > bottom else { return path }
        for x in 0..<w {
            let v = columns.loudest(levels, column: x)
            let frac = CGFloat(((v - bottom) / (top - bottom)).clamped(to: 0...1))
            let p = CGPoint(x: CGFloat(x) + 0.5, y: size.height * (1 - frac))
            if x == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Pixel columns over a visible range of a capture: which bins a column covers and where a
/// frequency falls. Shared by the spectrum and the waterfall's overlays so the two line up.
struct Columns {
    let range: ClosedRange<UInt64>
    let captureCenterHz: UInt64
    let captureSpanHz: UInt64
    let bins: Int
    let width: CGFloat

    private var captureLo: Double { Double(captureCenterHz) - Double(captureSpanHz) / 2 }
    private var binWidth: Double { Double(captureSpanHz) / Double(max(bins, 1)) }
    private var visibleSpan: Double { Double(range.upperBound - range.lowerBound) }

    func x(of hz: UInt64) -> CGFloat {
        guard visibleSpan > 0 else { return 0 }
        return CGFloat((Double(hz) - Double(range.lowerBound)) / visibleSpan) * width
    }

    func hz(atX x: CGFloat) -> UInt64 {
        guard width > 0 else { return range.lowerBound }
        let f = Double(x / width).clamped(to: 0...1)
        return range.lowerBound + UInt64(f * visibleSpan)
    }

    /// The bins under column `x`, as a closed range clamped to the row.
    func binRange(column x: Int) -> ClosedRange<Int> {
        guard bins > 0, width > 0 else { return 0...0 }
        let hz0 = Double(range.lowerBound) + Double(x) / Double(width) * visibleSpan
        let hz1 = Double(range.lowerBound) + Double(x + 1) / Double(width) * visibleSpan
        let b0 = Int(((hz0 - captureLo) / binWidth).rounded(.down)).clamped(to: 0...(bins - 1))
        let b1 = Int(((hz1 - captureLo) / binWidth).rounded(.down)).clamped(to: 0...(bins - 1))
        return min(b0, b1)...max(b0, b1)
    }

    func loudest(_ levels: [Float], column x: Int) -> Float {
        let r = binRange(column: x)
        var m: Float = -.infinity
        for i in r where i < levels.count { m = max(m, levels[i]) }
        return m
    }
}

/// Max hold is a toggle, not a fixed trace: a chip with the trace's colour, its real name and a
/// separate clear action. Hiding the trace does not clear its accumulated history.
struct MaxHoldChip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 0) {
            Button {
                session.maxHold.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: session.maxHold ? "checkmark.square.fill" : "square")
                        .font(.system(size: 9))
                        .foregroundStyle(session.maxHold ? Theme.good : Theme.inkFaint)
                    Rectangle().fill(Theme.good.opacity(0.5)).frame(width: 10, height: 1.5)
                    Text("max hold").font(Theme.Font.valueSmall).foregroundStyle(
                        Theme.inkTertiary)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
            }
            .help(session.maxHold ? "Hide max hold" : "Show max hold")

            Rectangle().fill(Theme.border).frame(width: 1, height: 16)

            Button {
                session.clearMaxHold()
            } label: {
                Text("clear").font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
            }
            .disabled(session.spectrum.hold.rows == 0)
            .help("Clear max hold")
        }
        .background(Theme.ground.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        .buttonStyle(.plain)
    }
}
