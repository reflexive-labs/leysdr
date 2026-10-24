// SPDX-License-Identifier: Apache-2.0

// The view: which frequencies the spectrum and waterfall show, which the band rail draws as its
// thumb (docs/design/channels.md, "The band rail"). It is the window's own presentation state,
// never the radio's (invariant 7): it moves inside the span the radio captures without retuning
// it, and only a rail drag past the capture's edge hands over to a retune. Narrowing it shows
// fewer of the daemon's spectrum bins and computes none (invariant 2), so the narrowest view is
// set by how many bins the spectrum has. The rail's ticks are hit-tested here too: one gesture
// covers the whole track, and a click picks the nearest tick.

import Foundation

/// The view's arithmetic: its width (the span), where it sits inside the capture, the zoom steps,
/// the band fit, the rail drag and the edge marker.
public enum ViewWindow {
    /// The narrowest view holds at least this many of the spectrum's bins, so a column is never
    /// drawn from a fraction of one.
    public static let minimumBins = 64

    /// The capture's span, its lower edge held at 0 Hz.
    public static func span(centerHz: UInt64, sampleRate: UInt64) -> ClosedRange<UInt64> {
        let lo = centerHz > sampleRate / 2 ? centerHz - sampleRate / 2 : 0
        return lo...(centerHz + sampleRate / 2)
    }

    /// The narrowest span: `minimumBins` of the capture's `bins`. A spectrum of fewer bins than
    /// that cannot be narrowed at all.
    public static func narrowest(sampleRate: UInt64, bins: Int) -> UInt64 {
        guard bins > minimumBins else { return sampleRate }
        return max(1, sampleRate * UInt64(minimumBins) / UInt64(bins))
    }

    /// `spanHz` held between the narrowest span and the whole capture.
    public static func clampedSpan(_ spanHz: UInt64, sampleRate: UInt64, bins: Int) -> UInt64 {
        min(max(spanHz, narrowest(sampleRate: sampleRate, bins: bins)), sampleRate)
    }

    /// `+`: half the width shown, no narrower than the spectrum's bins allow.
    public static func zoomedIn(spanHz: UInt64, sampleRate: UInt64, bins: Int) -> UInt64 {
        clampedSpan(spanHz / 2, sampleRate: sampleRate, bins: bins)
    }

    /// `−`: twice the width shown, no wider than the capture.
    public static func zoomedOut(spanHz: UInt64, sampleRate: UInt64, bins: Int) -> UInt64 {
        let doubled = spanHz.multipliedReportingOverflow(by: 2)
        return clampedSpan(
            doubled.overflow ? sampleRate : doubled.partialValue, sampleRate: sampleRate,
            bins: bins)
    }

    /// A window `spanHz` wide centred on `focusHz`, slid to lie inside the capture; the whole
    /// capture when `spanHz` is as wide as it or wider.
    public static func visible(
        centerHz: UInt64, sampleRate: UInt64, spanHz: UInt64, focusHz: UInt64
    )
        -> ClosedRange<UInt64>?
    {
        guard sampleRate > 0 else { return nil }
        let full = span(centerHz: centerHz, sampleRate: sampleRate)
        let width = min(spanHz, full.upperBound - full.lowerBound)
        guard width < full.upperBound - full.lowerBound else { return full }
        let lo =
            min(
                max(focusHz, full.lowerBound + width / 2), full.upperBound - (width - width / 2))
            - width / 2
        return lo...(lo + width)
    }

    /// How a range is shown: the span, the frequency the view centres on, what it then shows,
    /// and whether that holds the whole range asked for.
    public struct Fit: Sendable, Equatable {
        public let spanHz: UInt64
        public let focusHz: UInt64
        public let shown: ClosedRange<UInt64>
        public let whole: Bool
    }

    /// The closest view of `lowHz` to `highHz`, `padHz` wider at each end: the part of it inside
    /// the capture, as wide as that part (within the narrowest and widest spans), centred on it.
    /// Nil when the capture holds none of the range itself. A band's default view and
    /// `show_band` are both this, padded by half the band's channel width
    /// (`Band.channelWidthHz`) so a channel on the band's edge shows whole; `whole` is about the
    /// range, not the padding.
    public static func fit(
        lowHz: UInt64, highHz: UInt64, padHz: UInt64 = 0, centerHz: UInt64, sampleRate: UInt64,
        bins: Int
    ) -> Fit? {
        guard sampleRate > 0, lowHz < highHz else { return nil }
        let full = span(centerHz: centerHz, sampleRate: sampleRate)
        guard max(lowHz, full.lowerBound) < min(highHz, full.upperBound) else { return nil }
        let lo = max(lowHz > padHz ? lowHz - padHz : 0, full.lowerBound)
        let hi = min(highHz + padHz, full.upperBound)
        let width = clampedSpan(hi - lo, sampleRate: sampleRate, bins: bins)
        let focus = lo + (hi - lo) / 2
        guard
            let shown = visible(
                centerHz: centerHz, sampleRate: sampleRate, spanHz: width, focusHz: focus)
        else { return nil }
        return Fit(
            spanHz: width, focusHz: focus, shown: shown,
            whole: lowHz >= full.lowerBound && highHz <= full.upperBound)
    }

    /// What the spectrum and waterfall show. `spanHz` and `centreHz` are the window's own
    /// choices, nil until a zoom, a drag, a view tool or a tune outside the view sets them. With
    /// no span the view fits the band, `bandPadHz` past each edge (`fit`), or shows the whole
    /// capture without one; with no centre it centres on the band it fits, else on the tuned
    /// frequency, else on the capture.
    public static func shown(
        centerHz: UInt64, sampleRate: UInt64, bins: Int, band: ClosedRange<UInt64>?,
        bandPadHz: UInt64 = 0, spanHz: UInt64?, centreHz: UInt64?, tunedHz: UInt64?
    ) -> ClosedRange<UInt64>? {
        guard sampleRate > 0 else { return nil }
        let fitted =
            spanHz == nil
            ? band.flatMap {
                fit(
                    lowHz: $0.lowerBound, highHz: $0.upperBound, padHz: bandPadHz,
                    centerHz: centerHz, sampleRate: sampleRate, bins: bins)
            } : nil
        let width = clampedSpan(
            spanHz ?? fitted?.spanHz ?? sampleRate, sampleRate: sampleRate, bins: bins)
        let focus = centreHz ?? fitted?.focusHz ?? tunedHz ?? centerHz
        return visible(centerHz: centerHz, sampleRate: sampleRate, spanHz: width, focusHz: focus)
    }

    /// The view's centre after the radio is tuned to `tunedHz`: kept while the tuned frequency
    /// is inside what is shown, else moved to it, so a tune never leaves the channel off screen
    /// and a click inside the view never moves the view.
    public static func followed(
        centreHz: UInt64?, shown: ClosedRange<UInt64>?, tunedHz: UInt64?
    ) -> UInt64? {
        guard let t = tunedHz, let r = shown, !r.contains(t) else { return centreHz }
        return t
    }

    /// Which side of the view a frequency lies off, for the spectrum's edge marker.
    public enum Edge: Sendable, Equatable {
        case below, above
    }

    /// The side `hz` lies off the view, or nil when the view shows it (or there is none).
    public static func edge(of hz: UInt64?, in shown: ClosedRange<UInt64>?) -> Edge? {
        guard let hz, let shown, !shown.contains(hz) else { return nil }
        return hz < shown.lowerBound ? .below : .above
    }

    /// The edge marker's words: `◂ 146.940` at the left edge, `146.940 ▸` at the right, the
    /// arrow on the side the tuned frequency lies, and megahertz without their unit.
    public static func edgeWords(_ edge: Edge, hz: UInt64) -> String {
        var f = BookmarkNaming.frequencyWords(hz)
        if f.hasSuffix(" MHz") { f.removeLast(4) }
        return edge == .below ? "◂ \(f)" : "\(f) ▸"
    }

    /// The thumb: the part of the view on the rail, nil when none of it is.
    public static func thumb(_ shown: ClosedRange<UInt64>?, on rail: ClosedRange<UInt64>)
        -> ClosedRange<UInt64>?
    {
        guard let shown else { return nil }
        let lo = max(shown.lowerBound, rail.lowerBound)
        let hi = min(shown.upperBound, rail.upperBound)
        return lo <= hi ? lo...hi : nil
    }

    /// Where a rail drag leaves the view and the capture.
    public struct Drag: Sendable, Equatable {
        /// The view's new centre.
        public let viewCentreHz: Int64
        /// The capture's centre: the one passed in while the view stays inside it, else moved
        /// just far enough that the view's edge sits on the capture's.
        public let captureCentreHz: Int64
    }

    /// A drag of the thumb by `byHz` from `viewCentreHz`, a view `spanHz` wide, over a capture
    /// at `captureCentreHz` (the centre the drag has pushed it to so far). The view moves
    /// first, kept inside `within` (the band) when the band is wider than the view; past the
    /// capture's edge the capture follows the view's edge, as a push, and coming back leaves
    /// it where it was pushed to.
    public static func dragged(
        viewCentreHz start: Int64, byHz: Int64, spanHz: UInt64, captureCentreHz: Int64,
        sampleRate: UInt64, within band: ClosedRange<UInt64>? = nil
    ) -> Drag {
        let width = Int64(min(spanHz, sampleRate))
        let h = width / 2
        var d = start + byHz
        if let band, Int64(band.upperBound - band.lowerBound) > width {
            d = min(max(d, Int64(band.lowerBound) + h), Int64(band.upperBound) - (width - h))
        }
        let half = Int64(sampleRate / 2)
        var c = captureCentreHz
        if d + (width - h) > c + half { c = d + (width - h) - half }
        if d - h < c - half { c = d - h + half }
        return Drag(viewCentreHz: d, captureCentreHz: c)
    }

    /// A step of the thumb from accessibility (VoiceOver's increment and decrement): the view
    /// moves a tenth of its span up (`up`) or down, by the same rules as a drag (`dragged`), so
    /// it retunes nothing until it would pass the capture's edge.
    public static func stepped(
        viewCentreHz: Int64, up: Bool, spanHz: UInt64, captureCentreHz: Int64,
        sampleRate: UInt64, within band: ClosedRange<UInt64>? = nil
    ) -> Drag {
        let tenth = Int64(min(spanHz, sampleRate) / 10)
        return dragged(
            viewCentreHz: viewCentreHz, byHz: up ? tenth : -tenth, spanHz: spanHz,
            captureCentreHz: captureCentreHz, sampleRate: sampleRate, within: band)
    }

    /// The thumb's value to accessibility, the view as a person says it: `144.0 to 148.0 MHz`.
    /// Each end is rounded to the fewest decimals (one to four) whose last digit is no more than
    /// a twentieth of the span, so a fitted 2 m reads `144.0 to 148.0 MHz` although the fit's
    /// padding puts its ends at 143.9975 and 148.0025, and the narrowest view keeps the digits
    /// that tell it from its neighbour (`146.475 to 146.565 MHz`).
    public static func valueWords(_ r: ClosedRange<UInt64>) -> String {
        let span = r.upperBound - r.lowerBound
        var places = 1
        while places < 4, unitHz(places) * 20 > span { places += 1 }
        let f = { (hz: UInt64) in String(format: "%.\(places)f", Double(hz) / 1e6) }
        return "\(f(r.lowerBound)) to \(f(r.upperBound)) MHz"
    }

    /// The last digit's worth at `places` decimals of a megahertz, in hertz.
    private static func unitHz(_ places: Int) -> UInt64 {
        var u: UInt64 = 1_000_000
        for _ in 0..<places { u /= 10 }
        return u
    }

    /// The span in words for the zoom buttons' help: `2 MHz`, `2.88 MHz`, `720 kHz`, `90 kHz`.
    public static func spanWords(_ hz: UInt64) -> String {
        if hz >= 1_000_000 { return trimmed(Double(hz) / 1_000_000, places: 2) + " MHz" }
        if hz >= 1_000 {
            return trimmed(Double(hz) / 1_000, places: hz >= 10_000 ? 0 : 1) + " kHz"
        }
        return "\(hz) Hz"
    }

    private static func trimmed(_ v: Double, places: Int) -> String {
        var s = String(format: "%.\(places)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

/// The band rail's ticks under one gesture: no tick is a target of its own, so a press that
/// moves drags the thumb wherever it starts, and a click picks the nearest tick within a few
/// points. Ticks closer than their marks can be told apart draw as a strip.
public enum RailTicks {
    /// A click this many points or nearer from a tick is a click on it.
    public static let nearestPoints = 5.0
    /// Neighbouring ticks closer than this many points cannot be told apart, and draw as one
    /// strip.
    public static let densePoints = 3.0

    /// The index in `xs` of the tick nearest `x`, within `within` points; the earlier on a tie,
    /// so the caller orders the kinds it prefers first. Nil when none is that near.
    public static func nearest(to x: Double, among xs: [Double], within: Double = nearestPoints)
        -> Int?
    {
        var best: (index: Int, distance: Double)?
        for (i, t) in xs.enumerated() {
            let d = abs(t - x)
            guard d <= within else { continue }
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// The runs of two or more ticks each nearer its neighbour than `gap` points, as the span
    /// from the first tick's x to the last's, left to right.
    public static func denseRuns(_ xs: [Double], gap: Double = densePoints) -> [ClosedRange<Double>]
    {
        let sorted = xs.filter(\.isFinite).sorted()
        var runs: [ClosedRange<Double>] = []
        var start = 0
        for i in 0..<sorted.count {
            let last = i == sorted.count - 1
            if last || sorted[i + 1] - sorted[i] >= gap {
                if i > start { runs.append(sorted[start]...sorted[i]) }
                start = i + 1
            }
        }
        return runs
    }
}
