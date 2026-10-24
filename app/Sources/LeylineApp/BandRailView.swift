// SPDX-License-Identifier: Apache-2.0

// The band rail. It shows one band at a time: the band's name, its neighbours named at the end
// caps, a track from one edge of the band to the other with the bounds numbered beneath the caps,
// a faint underlay for what the radio captures (with a mark at an end cap when it runs past the
// band), the thumb for the view the spectrum and waterfall show, the tuned frequency as an accent
// tick, every bookmark in the band as a `good` one, the last sweep's hits in the band as
// `sweepTick` ones beside them (the design's "Scan the band") and a short plan's channels as
// fainter ticks under them (docs/design/channels.md, "The band rail"). The whole track is one
// gesture: a press that moves drags the thumb, which pans the view inside the capture and moves
// the radio only past the capture's edge; a click tunes the nearest tick within a few points,
// else the frequency under the pointer. Clicking a neighbour's name switches to that band. The
// zoom pair halves and doubles the view's span, and its help says the span.

import LeylineClient
import SwiftUI

struct BandRailView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.ink)
                .lineLimit(1).fixedSize()
            if let rail = session.railRange {
                let neighbours = Bands.neighbours(of: rail, in: session.tunableBands)
                NeighbourButton(band: neighbours.below, side: .below, from: rail)
                BandRail(range: rail)
                NeighbourButton(band: neighbours.above, side: .above, from: rail)
            } else {
                Spacer()
            }
            // The span rides on the zoom pair's help rather than the header: beside the
            // inspector the rail had no room for it, and it is reference information, not
            // something to monitor.
            let across = session.viewSpan.map { "\(ViewWindow.spanWords($0)) across now" }
            HStack(spacing: 2) {
                zoomButton("minus") { session.zoomOut() }.disabled(!session.canZoomOut)
                    .help(across.map { "Zoom out: \($0)" } ?? "Zoom out")
                    .accessibilityIdentifier("rail.zoom.out")
                zoomButton("plus") { session.zoomIn() }.disabled(!session.canZoomIn)
                    .help(across.map { "Zoom in: \($0)" } ?? "Zoom in")
                    .accessibilityIdentifier("rail.zoom.in")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panelHeader)
        .identifiedGroup("rail")
    }

    private var title: String {
        if let b = session.band { return b.name }
        if let hz = session.displayHz { return Frequency.format(hz) }
        return "No band"
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Font.buttonGlyph)
                .frame(width: 22, height: 20)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.inkTertiary)
    }
}

enum RailSide { case below, above }

/// The faint label past an end cap: the next band's name when it sits against this one
/// (`Bands.abut`), else the frequency a click would land on, because a band 60 MHz away is not
/// a neighbour and must not be labelled as one. The hover text gives the target and its
/// distance. A click crosses at the near edge either way, so tuning continues from where this
/// band ends. Empty when the radio cannot reach any band in that direction.
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
            .accessibilityIdentifier(side == .below ? "rail.below" : "rail.above")
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
        Image(systemName: name).font(Theme.Font.arrowGlyph)
    }
}

/// The track itself: end caps with the bounds numbered beneath, the capture's underlay, the
/// view's thumb, the ticks, the tuned tick, and the one gesture over all of them.
struct BandRail: View {
    @Environment(AppSession.self) private var session
    let range: ClosedRange<UInt64>
    /// The drag in progress: where the view and the capture stood when it began, and the centre
    /// it has pushed the capture to so far. Every event is a whole translation from the start
    /// rather than a step from the last, which drifts.
    @State private var drag: RailDrag?

    private static let trackY: CGFloat = 13
    private static let capHeight: CGFloat = 10
    private static let pillHeight: CGFloat = 10
    /// The underlay is thinner than the thumb, so the thumb reads as the thing to move.
    private static let underlayHeight: CGFloat = 6
    /// A press that moves this many points is a drag, and its release is not a click.
    private static let dragPoints: CGFloat = 3

    var body: some View {
        // Read here, not in the GeometryReader's closure, so the rail redraws when they change
        // (docs/dev/swift-style.md, section 7).
        let ticks = railTicks
        let thumb = session.railThumb
        let capture = captureRange
        let tuned = session.displayHz
        let words = session.visibleRange.map(ViewWindow.valueWords)
        let hits = session.sweepHits
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                // Track and caps.
                Rectangle().fill(Theme.border).frame(width: w, height: 2).offset(
                    y: Self.trackY - 1)
                cap(x: 0)
                cap(x: w)
                // What the radio captures, faintly, at its dragged position during a drag, with
                // a mark at the cap it runs past.
                if let capture {
                    pill(
                        capture, width: w, height: Self.underlayHeight, fill: Theme.raised,
                        stroke: Theme.border)
                    if capture.lowerBound < range.lowerBound { overflow(x: 0, pointing: -1) }
                    if capture.upperBound > range.upperBound { overflow(x: w, pointing: 1) }
                }
                // The view: the window the spectrum and waterfall show, always drawn.
                if let thumb {
                    pill(
                        thumb, width: w, height: Self.pillHeight, fill: Theme.selected,
                        stroke: Theme.borderFocus
                    )
                    // A slider to accessibility: VoiceOver reads the view (`144.0 to 148.0 MHz`)
                    // and its increment and decrement pan it a tenth of its span, as a drag would.
                    // A shape alone is an AXUnknown whose value nothing reads.
                    .accessibilityRepresentation {
                        Slider(value: .constant(0.5), in: 0...1)
                            .accessibilityLabel("View")
                            .accessibilityValue(words ?? "")
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: adjust(up: true)
                                case .decrement: adjust(up: false)
                                @unknown default: break
                                }
                            }
                    }
                    .accessibilityIdentifier("rail.thumb")
                }
                // The plan's channels inside the part, for a plan of `Plans.tickLimit` or fewer:
                // fainter than the bookmarks and under them. The rail keeps showing the part.
                ForEach(ticks.channels) { channel in
                    tickMark(Theme.planTick, width: 1, height: 6, at: x(of: channel.hz, width: w))
                        .help(channel.name)
                        .accessibilityIdentifier(
                            "rail.channel.\(ViewIdentifier.slug(channel.id))"
                        )
                        .pressable { session.tune(to: channel.hz) }
                }
                strips(ticks.channels.map { x(of: $0.hz, width: w) }, Theme.planTick, height: 6)
                // The last sweep's hits inside the rail: a group's hits show on the half the
                // rail is on. Under the bookmarks, so a bookmarked hit keeps its `good` tick.
                ForEach(ticks.hits) { hit in
                    tickMark(Theme.sweepTick, width: 1.5, height: 8, at: x(of: hit.hz, width: w))
                        .help("\(hit.label) · \(String(format: "%.0f", hit.snrDb)) dB")
                        .accessibilityIdentifier(
                            "rail.hit.\(ViewIdentifier.hitSlug(hit, among: hits))"
                        )
                        .pressable { session.tune(hit: hit) }
                }
                strips(ticks.hits.map { x(of: $0.hz, width: w) }, Theme.sweepTick, height: 8)
                // Bookmarks in the band.
                ForEach(ticks.bookmarks) { b in
                    tickMark(Theme.good, width: 1.5, height: 8, at: x(of: b.hz, width: w))
                        .help(b.name)
                        .accessibilityIdentifier("rail.bookmark.\(ViewIdentifier.slug(b.name))")
                        .pressable { session.tune(bookmark: b) }
                }
                strips(ticks.bookmarks.map { x(of: $0.hz, width: w) }, Theme.good, height: 8)
                // The tuned frequency.
                if let hz = tuned, range.contains(hz) {
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
                    .onEnded { v in ended(v, width: w, ticks: ticks) })
        }
        .identifiedGroup("rail.track")
    }

    /// The ticks on the rail, read in `body`.
    private struct Ticks {
        var channels: [PlanChannel]
        var hits: [SweepHit]
        var bookmarks: [Bookmark]
    }

    private var railTicks: Ticks {
        Ticks(
            channels: session.band.map { Plans.ticks(for: $0).filter { range.contains($0.hz) } }
                ?? [],
            hits: session.sweepHits.filter { range.contains($0.hz) },
            bookmarks: session.bookmarks.list.filter { range.contains($0.hz) })
    }

    /// The capture's span, from the centre a drag is taking it to when there is one.
    private var captureRange: ClosedRange<UInt64>? {
        guard let cap = session.capture, cap.sampleRate > 0 else { return nil }
        let centre = session.panCentre ?? Int64(cap.centerHz)
        let half = Int64(cap.sampleRate / 2)
        return UInt64(max(0, centre - half))...UInt64(max(0, centre + half))
    }

    /// A tick's mark, centred on `x`. It is not a target of its own: the track's gesture takes
    /// every press, and its click finds the nearest tick (`RailTicks.nearest`). The frame
    /// around the mark is what accessibility reports, so a check can click where a tick is.
    private func tickMark(_ colour: Color, width: CGFloat, height: CGFloat, at x: CGFloat)
        -> some View
    {
        Rectangle().fill(colour).frame(width: width, height: height)
            .frame(width: Theme.Layout.planTickHit)
            .offset(x: x - Theme.Layout.planTickHit / 2, y: Self.trackY - height / 2)
            // An element of its own with no gesture, so the tap that once made it one is not
            // what puts it in the tree.
            .accessibilityElement()
    }

    /// Ticks too close to tell apart (`RailTicks.denseRuns`), drawn over as one strip of their
    /// colour.
    private func strips(_ xs: [CGFloat], _ colour: Color, height: CGFloat) -> some View {
        let runs = RailTicks.denseRuns(xs.map(Double.init))
        return ForEach(runs.indices, id: \.self) { i in
            let lo = CGFloat(runs[i].lowerBound)
            let hi = CGFloat(runs[i].upperBound)
            RoundedRectangle(cornerRadius: 1).fill(colour)
                .frame(width: max(hi - lo, 2), height: height)
                .offset(x: lo, y: Self.trackY - height / 2)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func pill(
        _ r: ClosedRange<UInt64>, width w: CGFloat, height: CGFloat, fill: Color, stroke: Color
    ) -> some View {
        let lo = x(of: max(r.lowerBound, range.lowerBound), width: w)
        let hi = x(of: min(r.upperBound, range.upperBound), width: w)
        if hi >= lo {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: height / 2).stroke(stroke))
                .frame(width: max(hi - lo, height), height: height)
                .offset(x: min(lo, max(0, w - height)), y: Self.trackY - height / 2)
        }
    }

    /// The mark at an end cap the capture runs past: a small arrowhead outside the cap,
    /// `direction` -1 for the lower cap and 1 for the upper.
    private func overflow(x: CGFloat, pointing direction: CGFloat) -> some View {
        Path { p in
            let tip = x + direction * 5
            let back = x + direction * 2
            p.move(to: CGPoint(x: back, y: Self.trackY - 3))
            p.addLine(to: CGPoint(x: tip, y: Self.trackY))
            p.addLine(to: CGPoint(x: back, y: Self.trackY + 3))
        }
        .stroke(Theme.inkFaint, lineWidth: 1)
        .accessibilityHidden(true)
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

    /// A drag of the thumb: the view moves by the pointer's whole translation from where it
    /// began, inside the band, and the radio stays where it is until the view's edge reaches
    /// the capture's; from there the capture is pushed (`AppSession.pan`, with its push and
    /// ask rules). A drag never changes the band; clicking a neighbour's name does.
    private func moved(_ v: DragGesture.Value, width: CGFloat) {
        guard drag != nil || abs(v.translation.width) >= Self.dragPoints else { return }
        if drag == nil {
            guard let cap = session.capture, let r = session.visibleRange else { return }
            let centre = session.panCentre ?? Int64(cap.centerHz)
            drag = RailDrag(
                viewCentre: Int64(r.lowerBound + (r.upperBound - r.lowerBound) / 2),
                spanHz: r.upperBound - r.lowerBound, sampleRate: cap.sampleRate,
                startCapture: centre, pushed: centre)
        }
        step(v, width: width, ended: false)
    }

    /// A drag ends where the thumb is; anything shorter than a drag is a click, which tunes the
    /// nearest tick within a few points (a bookmark before a plan channel before a hit, on a
    /// tie), else the frequency under the pointer on the band's grid.
    private func ended(_ v: DragGesture.Value, width: CGFloat, ticks: Ticks) {
        defer { drag = nil }
        if drag != nil {
            step(v, width: width, ended: true)
            return
        }
        var xs: [Double] = []
        var tunes: [() -> Void] = []
        for b in ticks.bookmarks {
            xs.append(Double(x(of: b.hz, width: width)))
            tunes.append { session.tune(bookmark: b) }
        }
        for c in ticks.channels {
            xs.append(Double(x(of: c.hz, width: width)))
            tunes.append { session.tune(to: c.hz) }
        }
        for h in ticks.hits {
            xs.append(Double(x(of: h.hz, width: width)))
            tunes.append { session.tune(hit: h) }
        }
        if let i = RailTicks.nearest(to: Double(v.location.x), among: xs) {
            tunes[i]()
        } else {
            session.tune(to: hz(atX: v.location.x, width: width))
        }
    }

    /// One frame of a drag: the view to its new centre, and the capture pushed once the view
    /// has reached its edge; the push's release is the pan's.
    private func step(_ v: DragGesture.Value, width: CGFloat, ended: Bool) {
        guard var d = drag else { return }
        let moved = ViewWindow.dragged(
            viewCentreHz: d.viewCentre, byHz: translation(v, width: width), spanHz: d.spanHz,
            captureCentreHz: d.pushed, sampleRate: d.sampleRate,
            within: session.band.map { $0.minHz...$0.maxHz })
        session.moveView(centreTo: moved.viewCentreHz)
        if moved.captureCentreHz != d.pushed {
            d.pushed = moved.captureCentreHz
            drag = d
        }
        if d.pushed != d.startCapture {
            session.pan(centreTo: d.pushed, ended: ended)
        }
    }

    /// The thumb's increment or decrement: the view a tenth of its span up or down
    /// (`ViewWindow.stepped`), and past the capture's edge the capture pushed and released at
    /// once, as a drag that ends there.
    private func adjust(up: Bool) {
        guard let cap = session.capture, let r = session.visibleRange else { return }
        let capture = session.panCentre ?? Int64(cap.centerHz)
        let moved = ViewWindow.stepped(
            viewCentreHz: Int64(r.lowerBound + (r.upperBound - r.lowerBound) / 2), up: up,
            spanHz: r.upperBound - r.lowerBound, captureCentreHz: capture,
            sampleRate: cap.sampleRate, within: session.band.map { $0.minHz...$0.maxHz })
        session.moveView(centreTo: moved.viewCentreHz)
        log("rail", "view stepped \(up ? "up" : "down") to centre \(moved.viewCentreHz) Hz")
        if moved.captureCentreHz != capture {
            session.pan(centreTo: moved.captureCentreHz, ended: true)
        }
    }

    /// The pointer's travel since the drag began, in hertz along the rail.
    private func translation(_ v: DragGesture.Value, width: CGFloat) -> Int64 {
        guard width > 0 else { return 0 }
        let span = Double(range.upperBound - range.lowerBound)
        return Int64((Double(v.translation.width) / Double(width) * span).rounded())
    }
}

/// A rail drag's start: the view's centre and span, the capture's rate and centre, and the
/// centre the drag has pushed the capture to so far (`ViewWindow.dragged`).
private struct RailDrag {
    var viewCentre: Int64
    var spanHz: UInt64
    var sampleRate: UInt64
    var startCapture: Int64
    var pushed: Int64
}
