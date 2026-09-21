// SPDX-License-Identifier: Apache-2.0

// Region 2: the band rail (docs/design/app-design-handoff.md). The radio is one dial, revealed a
// band at a time: the band's name, its neighbours named at the end caps, a track from one edge
// of the band to the other with the bounds numbered beneath the caps, a pill for the slice on
// screen, the tuned frequency as an accent tick and every bookmark in the band as a `good` one.
// A click tunes; a drag moves the region inside the band and leaves the station where it is
// unless the edge pushes it; the neighbours' names are the way into them. The one number the
// rail states is what a column of the spectrum covers.

import LeylineClient
import SwiftUI

struct BandRailView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 10) {
                Text(title).font(Theme.Font.title).foregroundStyle(Theme.ink)
                    .lineLimit(1).fixedSize()
                if let rail = railRange {
                    let neighbours = Bands.neighbours(of: rail, in: session.tunableBands)
                    NeighbourButton(band: neighbours.below, side: .below, from: rail)
                    BandRail(range: rail)
                    NeighbourButton(band: neighbours.above, side: .above, from: rail)
                } else {
                    Spacer()
                }
                // What a column covers rides on the zoom pair's help rather than the header:
                // beside the inspector the rail had no room for it, and it is a number to know,
                // not to watch (the owner, 2026-09-21).
                let columns = perColumn(width: geo.size.width)
                HStack(spacing: 2) {
                    zoomButton("minus") { session.zoomOut() }.disabled(session.zoom <= 1)
                        .help(columns.isEmpty ? "Zoom out" : "Zoom out: \(columns) now")
                    zoomButton("plus") { session.zoomIn() }.disabled(session.zoom >= 8)
                        .help(columns.isEmpty ? "Zoom in" : "Zoom in: \(columns) now")
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
    /// visible span over that many points. The zoom pair's help text; no longer drawn.
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

/// What lies past an end cap, faint, pointing the way: the next band's name when it sits
/// against this one (`Bands.abut`), else the frequency a click would land on, because a band
/// 60 MHz away is not a neighbour and must not be named as one. The hover names it and says
/// how far. A click crosses at the near edge either way, so the dial reads on from where this
/// band ends. Nothing there when there is no band that way the radio can reach.
struct NeighbourButton: View {
    @Environment(AppSession.self) private var session
    let band: Band?
    let side: RailSide
    let from: ClosedRange<UInt64>

    var body: some View {
        if let band {
            let edge = side == .below ? band.maxHz : band.minHz
            let abuts = Bands.abut(from, band)
            Button {
                Task { await session.select(band: band, at: edge) }
            } label: {
                HStack(spacing: 4) {
                    if side == .below { arrow("arrowtriangle.left.fill") }
                    Text(abuts ? band.name : Frequency.fieldParts(edge).major).font(
                        Theme.Font.value
                    ).lineLimit(1).fixedSize()
                    if side == .above { arrow("arrowtriangle.right.fill") }
                }
                .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
            .help(
                abuts
                    ? "\(band.name), \(side == .below ? "below" : "above") this band"
                    : "\(band.name), \(Frequency.format(gap(to: band))) \(side == .below ? "below" : "above") this band"
            )
        }
    }

    private func gap(to band: Band) -> UInt64 {
        side == .below
            ? (from.lowerBound > band.maxHz ? from.lowerBound - band.maxHz : 0)
            : (band.minHz > from.upperBound ? band.minHz - from.upperBound : 0)
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 6))
    }
}

/// The track itself: end caps with the bounds numbered beneath, the pill for the capture's
/// span (with the zoomed window inset when there is one), bookmark ticks, the tuned tick, and
/// the gesture.
struct BandRail: View {
    @Environment(AppSession.self) private var session
    let range: ClosedRange<UInt64>
    /// The centre when the drag began, so every event is a whole translation from it rather
    /// than a step from the last, which drifts.
    @State private var dragStartCentre: Int64?
    /// Once the pointer has moved a few points the gesture is a drag of the region, and its end
    /// is not a click.
    @State private var panned = false

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
                // The region the radio holds, where the hand has it during a drag.
                if let region = captureRange {
                    pill(region, width: w, fill: Theme.raised, stroke: Theme.borderStrong)
                    // The zoomed window inside it.
                    if session.zoom > 1, let vis = session.visibleRange {
                        pill(vis, width: w, fill: Theme.selected, stroke: Theme.borderFocus)
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
                    Text(Frequency.mhz(range.lowerBound))
                    Spacer()
                    Text(Frequency.mhz(range.upperBound))
                }
                .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                .frame(width: w)
                .offset(y: Self.trackY + Self.capHeight / 2 + 3)
            }
            // Top-leading, because the offsets above do not count toward layout and a centred
            // frame put the track two thirds of the way down and the bounds off the strip.
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in moved(v, width: w) }
                    .onEnded { v in ended(v, width: w) })
        }
    }

    /// The capture's span, from the centre a drag is taking it to when there is one.
    private var captureRange: ClosedRange<UInt64>? {
        guard let cap = session.capture, cap.sampleRate > 0 else { return nil }
        let centre = session.panCentre ?? Int64(cap.centerHz)
        let half = Int64(cap.sampleRate / 2)
        return UInt64(max(0, centre - half))...UInt64(max(0, centre + half))
    }

    @ViewBuilder
    private func pill(_ r: ClosedRange<UInt64>, width w: CGFloat, fill: Color, stroke: Color)
        -> some View
    {
        let lo = x(of: max(r.lowerBound, range.lowerBound), width: w)
        let hi = x(of: min(r.upperBound, range.upperBound), width: w)
        if hi > lo {
            RoundedRectangle(cornerRadius: Self.pillHeight / 2)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: Self.pillHeight / 2).stroke(stroke))
                .frame(width: max(hi - lo, Self.pillHeight), height: Self.pillHeight)
                .offset(x: lo, y: Self.trackY - Self.pillHeight / 2)
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

    /// A drag of the region: the centre moves by the pointer's whole translation from where it
    /// began, never past the band's edges, and the station stays put unless the region's edge
    /// pushes it (`AppSession.pan`). A drag never changes the band; the neighbours' names do.
    private func moved(_ v: DragGesture.Value, width: CGFloat) {
        guard panned || abs(v.translation.width) >= 3 else { return }
        if dragStartCentre == nil {
            guard let cap = session.capture else { return }
            dragStartCentre = session.panCentre ?? Int64(cap.centerHz)
        }
        guard let start = dragStartCentre else { return }
        panned = true
        session.pan(centreTo: start + translation(v, width: width), ended: false)
    }

    /// A drag ends where the region is; anything shorter than a drag is a click, which tunes
    /// to the frequency under the pointer on the band's grid.
    private func ended(_ v: DragGesture.Value, width: CGFloat) {
        defer {
            panned = false
            dragStartCentre = nil
        }
        if panned, let start = dragStartCentre {
            session.pan(centreTo: start + translation(v, width: width), ended: true)
        } else {
            session.tune(to: hz(atX: v.location.x, width: width))
        }
    }

    /// The pointer's travel since the drag began, in hertz along the rail.
    private func translation(_ v: DragGesture.Value, width: CGFloat) -> Int64 {
        guard width > 0 else { return 0 }
        let span = Double(range.upperBound - range.lowerBound)
        return Int64((Double(v.translation.width) / Double(width) * span).rounded())
    }
}
