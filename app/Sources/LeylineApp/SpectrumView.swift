// SPDX-License-Identifier: Apache-2.0

// Region 3: the spectrum. A live trace, a max-hold trace, a 10×4 grid, and the tuned channel as
// a vertical band. It is a peak display and says so nowhere, because the label would be the
// detector's word (invariant 12). Every column is the loudest bin under it, so a carrier one
// bin wide is never lost between two pixels.

import LeylineClient
import SwiftUI

struct SpectrumView: View {
    @Environment(AppSession.self) private var session

    /// The trace's axis: this far under the floor at the bottom, this far over it at the top.
    static let belowFloorDB: Float = 10
    static let aboveFloorDB: Float = 70

    var body: some View {
        // Read here, in the body, so the canvas is redrawn on every row: a read inside the
        // drawing closure alone is not tracked.
        let feed = session.spectrum
        let rows = Rows(latest: feed.latest, hold: session.maxHold ? feed.hold.levelsDB : [], floorDB: feed.floorDB)
        ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(in: &ctx, size: size, rows: rows)
            }
            MaxHoldChip()
                .padding(8)
        }
        .background(Theme.ground)
    }

    struct Rows {
        var latest: [Float]
        var hold: [Float]
        var floorDB: Float
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, rows: Rows) {
        // The grid is drawn whether or not there is a row: it is the shape to recognise.
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

        guard let cap = session.capture, let range = session.visibleRange, cap.sampleRate > 0 else { return }
        let latest = rows.latest
        guard !latest.isEmpty else { return }
        let floor = rows.floorDB.isNaN ? SpectrumFold.medianDB(latest) : rows.floorDB
        let bottom = floor - Self.belowFloorDB
        let top = floor + Self.aboveFloorDB
        let columns = Columns(range: range, captureCenterHz: cap.centerHz, captureSpanHz: cap.sampleRate, bins: latest.count, width: size.width)

        // The tuned channel first, under the traces.
        if let hz = session.tunedHz, let ch = session.channel {
            let x0 = columns.x(of: hz - UInt64(ch.bandwidthHz) / 2)
            let x1 = columns.x(of: hz + UInt64(ch.bandwidthHz) / 2)
            let band = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)
            ctx.fill(Path(band), with: .color(Theme.accent.opacity(0.11)))
            var edges = Path()
            edges.move(to: CGPoint(x: band.minX, y: 0)); edges.addLine(to: CGPoint(x: band.minX, y: size.height))
            edges.move(to: CGPoint(x: band.maxX, y: 0)); edges.addLine(to: CGPoint(x: band.maxX, y: size.height))
            ctx.stroke(edges, with: .color(Theme.accent.opacity(0.8)), lineWidth: 1)
        }

        if rows.hold.count == latest.count {
            let path = trace(rows.hold, columns: columns, size: size, bottom: bottom, top: top)
            ctx.stroke(path, with: .color(Theme.good.opacity(0.5)), lineWidth: 1)
        }
        let live = trace(latest, columns: columns, size: size, bottom: bottom, top: top)
        ctx.stroke(live, with: .color(Theme.ink), lineWidth: 1.15)
    }

    private func trace(_ levels: [Float], columns: Columns, size: CGSize, bottom: Float, top: Float) -> Path {
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

/// Max hold is a toggle, not furniture: a chip with the trace's colour and its real name.
struct MaxHoldChip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Button { session.maxHold.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: session.maxHold ? "checkmark.square.fill" : "square")
                    .font(.system(size: 9))
                    .foregroundStyle(session.maxHold ? Theme.good : Theme.inkFaint)
                Rectangle().fill(Theme.good.opacity(0.5)).frame(width: 10, height: 1.5)
                Text("max hold").font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Theme.ground.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        }
        .buttonStyle(.plain)
    }
}
