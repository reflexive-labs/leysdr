// SPDX-License-Identifier: Apache-2.0

// Region 2: the band rail (docs/design/app-design-handoff.md). The radio is one dial, revealed a
// band at a time: the band's name, its neighbours named at the end caps, a track from one edge
// of the band to the other with the bounds numbered beneath the caps, a pill for the slice on
// screen, the tuned frequency as an accent tick and every bookmark in the band as a `good` one.
// A click or a drag along the track tunes; a drag past a cap crosses into the neighbour at its
// near edge. The one number the rail states is what a column of the spectrum covers.

import LeylineClient
import SwiftUI

struct BandRailView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 10) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).fixedSize()
                if let rail = railRange {
                    let neighbours = Bands.neighbours(of: rail, in: session.bands)
                    NeighbourButton(band: neighbours.below, side: .below)
                    BandRail(range: rail, neighbours: neighbours)
                    NeighbourButton(band: neighbours.above, side: .above)
                    Text(perColumn(width: geo.size.width))
                        .font(Theme.Font.value).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1).fixedSize()
                } else {
                    Spacer()
                }
                HStack(spacing: 2) {
                    zoomButton("minus") { session.zoomOut() }.disabled(session.zoom <= 1)
                    zoomButton("plus") { session.zoomIn() }.disabled(session.zoom >= 8)
                }
            }
            .padding(.horizontal, 14)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.panelHeader)
    }

    private var title: String {
        if let b = session.band { return b.name }
        if let hz = session.displayHz { return Frequency.format(hz) }
        return "No band"
    }

    /// The band's edges; between bands, the capture's, so the rail still has ends to cross.
    private var railRange: ClosedRange<UInt64>? {
        if let b = session.band { return b.minHz...b.maxHz }
        guard let cap = session.capture, cap.sampleRate > 0 else { return nil }
        let half = cap.sampleRate / 2
        return (cap.centerHz > half ? cap.centerHz - half : 0)...(cap.centerHz + half)
    }

    /// `24 kHz per column`: the spectrum spans the same width as this strip, so a column is the
    /// visible span over that many points.
    private func perColumn(width: CGFloat) -> String {
        guard let r = session.visibleRange, width > 0 else { return "" }
        let hz = Double(r.upperBound - r.lowerBound) / Double(width)
        let text: String
        if hz >= 1_000 {
            let k = hz / 1_000
            text = k >= 10 ? String(format: "%.0f kHz", k) : String(format: "%.1f kHz", k)
        } else {
            text = String(format: "%.0f Hz", hz)
        }
        return "\(text) per column"
    }

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

enum RailSide { case below, above }

/// The neighbour's name at an end cap, faint, pointing the way; a click crosses into it at the
/// near edge, the same place a scrub past the cap lands. Nothing there when there is no band
/// that way.
struct NeighbourButton: View {
    @Environment(AppSession.self) private var session
    let band: Band?
    let side: RailSide

    var body: some View {
        if let band {
            Button {
                Task { await session.select(band: band, at: side == .below ? band.maxHz : band.minHz) }
            } label: {
                HStack(spacing: 4) {
                    if side == .below { arrow("arrowtriangle.left.fill") }
                    Text(band.name).font(Theme.Font.value).lineLimit(1).fixedSize()
                    if side == .above { arrow("arrowtriangle.right.fill") }
                }
                .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
            .help("\(band.name), \(side == .below ? "below" : "above") this band")
        }
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 6))
    }
}

/// The track itself: end caps with the bounds numbered beneath, the pill for what is on screen,
/// bookmark ticks, the tuned tick, and the gesture.
struct BandRail: View {
    @Environment(AppSession.self) private var session
    let range: ClosedRange<UInt64>
    let neighbours: (below: Band?, above: Band?)
    /// Set once a drag has left the track past a cap: the crossing happens once per gesture and
    /// the rest of that gesture is ignored, because the rail under the pointer is now another
    /// band's.
    @State private var crossed = false

    private static let trackY: CGFloat = 13
    private static let capHeight: CGFloat = 10
    private static let pillHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                // Track and caps.
                Rectangle().fill(Theme.border).frame(width: w, height: 2).offset(y: Self.trackY - 1)
                cap(x: 0)
                cap(x: w)
                // The slice on screen.
                if let vis = session.visibleRange {
                    let lo = x(of: max(vis.lowerBound, range.lowerBound), width: w)
                    let hi = x(of: min(vis.upperBound, range.upperBound), width: w)
                    if hi > lo {
                        RoundedRectangle(cornerRadius: Self.pillHeight / 2)
                            .fill(Theme.raised)
                            .overlay(RoundedRectangle(cornerRadius: Self.pillHeight / 2).stroke(Theme.borderStrong))
                            .frame(width: max(hi - lo, Self.pillHeight), height: Self.pillHeight)
                            .offset(x: lo, y: Self.trackY - Self.pillHeight / 2)
                    }
                }
                // Bookmarks in the band.
                ForEach(session.bookmarks.list.filter { range.contains($0.hz) }) { b in
                    Rectangle().fill(Theme.good).frame(width: 1.5, height: 8)
                        .offset(x: x(of: b.hz, width: w) - 0.75, y: Self.trackY - 4)
                        .help(b.name)
                }
                // The tuned frequency.
                if let hz = session.displayHz, range.contains(hz) {
                    Rectangle().fill(Theme.accent).frame(width: 2, height: 14)
                        .offset(x: x(of: hz, width: w) - 1, y: Self.trackY - 7)
                }
                // The bounds, beneath the caps.
                HStack {
                    Text(bound(range.lowerBound))
                    Spacer()
                    Text(bound(range.upperBound))
                }
                .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                .frame(width: w)
                .offset(y: Self.trackY + Self.capHeight / 2 + 3)
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in moved(to: v.location.x, width: w) }
                .onEnded { v in ended(at: v.location.x, width: w) })
        }
    }

    private func cap(x: CGFloat) -> some View {
        Rectangle().fill(Theme.borderStrong).frame(width: 1, height: Self.capHeight)
            .offset(x: x - 0.5, y: Self.trackY - Self.capHeight / 2)
    }

    private func x(of hz: UInt64, width: CGFloat) -> CGFloat {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        return CGFloat((Double(hz) - Double(range.lowerBound)) / span) * width
    }

    private func hz(atX x: CGFloat, width: CGFloat) -> UInt64 {
        guard width > 0 else { return range.lowerBound }
        let f = Double(x / width).clamped(to: 0...1)
        let raw = range.lowerBound + UInt64(f * Double(range.upperBound - range.lowerBound))
        return session.band?.snapped(raw) ?? raw
    }

    /// `144`, `462.5375`: MHz with the zeros a person would not say.
    private func bound(_ hz: UInt64) -> String {
        var s = String(format: "%.4f", Double(hz) / 1e6)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Past a cap by more than a few points the drag crosses into the neighbour, once; on the
    /// track it scrubs.
    private func moved(to px: CGFloat, width: CGFloat) {
        guard !crossed else { return }
        if px < -4 {
            crossed = true
            if let b = neighbours.below { Task { await session.select(band: b, at: b.maxHz) } }
        } else if px > width + 4 {
            crossed = true
            if let b = neighbours.above { Task { await session.select(band: b, at: b.minHz) } }
        } else {
            session.scrub(to: hz(atX: px, width: width))
        }
    }

    private func ended(at px: CGFloat, width: CGFloat) {
        defer { crossed = false }
        guard !crossed else { return }
        session.tune(to: hz(atX: px, width: width))
    }
}
