// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a sweep points the radio, and which part of each span it believes.
///
/// Two facts drive the geometry, and neither is negotiable on an RTL-SDR:
///
/// 1. **The DC spike sits at the exact capture centre.** Nothing upstream corrects it -- the
///    RTL-SDR path applies only the cu8-to-float conversion -- so the centre bins carry a
///    permanent full-strength artefact. A detector that thresholds against a noise floor would
///    report a carrier at the middle of every step.
/// 2. **The span's outer edges roll off** through the tuner's IF filter, so the last few percent
///    read low and a real signal there looks weaker than it is.
///
/// So a step analyses only the two quarter-bands between `guardFraction` and `edgeFraction` of the
/// span either side of centre, and the sweep advances by `advance` = 2 x (edge - guard) x span
/// **divided by two**: half a window per step. That is what makes step k+1's lower quarter land
/// exactly on step k's DC hole, so the hole is covered rather than skipped, and it gives every
/// frequency in the range at least two looks at two different tuner settings -- which is the only
/// cheap way to tell a real signal from a tuner spur that moves with the local oscillator.
///
/// The price is twice as many steps as a naive sweep. It buys complete coverage and a free
/// cross-check; a sweep that skipped 10% of every span while claiming to have covered the band
/// would be the quiet wrong answer the honesty invariants exist to prevent.
public struct SweepPlan: Sendable, Equatable {
    /// A half-open span of frequency the detector is allowed to believe.
    public struct Window: Sendable, Equatable {
        public var lowHz: UInt64
        public var highHz: UInt64
        public init(lowHz: UInt64, highHz: UInt64) {
            self.lowHz = lowHz
            self.highHz = highHz
        }

        public func contains(_ hz: UInt64) -> Bool { hz >= lowHz && hz < highHz }

        /// The part of this window also inside `other`; empty when they do not overlap.
        public func clamped(to other: Window) -> Window {
            Window(lowHz: Swift.max(lowHz, other.lowHz), highHz: Swift.min(highHz, other.highHz))
        }
    }

    /// One tuner position, and the two windows of it the detector is allowed to believe.
    public struct Step: Sendable, Equatable {
        public var centerHz: UInt64
        /// Below centre, above the DC guard.
        public var low: Window
        /// Above centre, above the DC guard.
        public var high: Window
    }

    /// The steps, in tuning order.
    public var steps: [Step]
    /// The capture sample rate every step runs at. A sweep never changes rate: `setSampleRate`
    /// stops the stream, drains the ring and republishes the anchor, where a retune does none of
    /// those things.
    public var sampleRateHz: UInt64
    /// What the plan actually covers, which is the requested range intersected with what the
    /// radio can tune. Never wider than the request.
    public var covered: Window
    /// Set when the request was wider than the radio, so a caller can say so rather than
    /// silently returning less than was asked for.
    public var clipped: Bool

    /// Fraction of the span either side of centre that the DC artefact is assumed to reach.
    /// A Hann mainlobe is 2 bins wide, so the spike itself is far narrower than this; the margin
    /// covers the LO leakage skirt, which is not a single bin.
    public static let guardFraction = 0.05
    /// Outer limit of the usable span, as a fraction either side of centre. 0.45 of 2.4 MSPS
    /// leaves 120 kHz of roll-off unanalysed at each edge.
    public static let edgeFraction = 0.45

    /// Builds the plan, or nil when the range and the radio do not overlap at all.
    ///
    /// `tuningRanges` are the device's; centres are kept inside them, which is what stops
    /// `rtlsdr_set_center_freq`'s unchecked `UInt32(truncatingIfNeeded:)` from ever seeing a
    /// value the descriptor would have rejected.
    public static func plan(minHz: UInt64, maxHz: UInt64, sampleRateHz: UInt64,
                            tuningRanges: [FrequencyRange]) -> SweepPlan?
    {
        guard maxHz > minHz, sampleRateHz > 0 else { return nil }
        let span = Double(sampleRateHz)
        let guardHz = Self.guardFraction * span
        let edgeHz = Self.edgeFraction * span
        // Half a window: the distance that puts the next step's lower quarter on this step's hole.
        let advance = (edgeHz - guardHz)
        guard advance > 0 else { return nil }

        // The centres a step may take: the tuner's range shrunk by the half-span it needs either
        // side, so no analysis window falls off the end of what the radio can hear.
        var lowestCenter = UInt64.max
        var highestCenter: UInt64 = 0
        for r in tuningRanges {
            // A point range is legitimate: a file device tunes to exactly the frequency its
            // recording was made at, and a sweep over one is the single-step fixture run the
            // detector is tested with.
            guard r.maxHz >= r.minHz, r.maxHz > 0 else { continue }
            lowestCenter = Swift.min(lowestCenter, r.minHz)
            highestCenter = Swift.max(highestCenter, r.maxHz)
        }
        guard highestCenter > 0 else { return nil }

        // What the radio can actually hear, allowing for the half-span either side of a centre.
        let audibleLow = Double(lowestCenter) - edgeHz
        let audibleHigh = Double(highestCenter) + edgeHz
        let wantLow = Double(minHz), wantHigh = Double(maxHz)
        let coverLow = Swift.max(0, Swift.max(wantLow, audibleLow))
        let coverHigh = Swift.min(wantHigh, audibleHigh)
        guard coverHigh > coverLow else { return nil }
        let clipped = coverLow > wantLow + 1 || coverHigh < wantHigh - 1

        // The ends first: a step whose upper window starts at the bottom of the range, and one
        // whose lower window ends at the top. Without them the outermost slice of what was asked
        // for would be seen once, by one edge of one step, which is the least trustworthy place
        // in a span. They are also the whole plan when the range fits inside a single window --
        // the range is then taken twice at two tuner positions, which is the strongest artefact
        // cross-check the geometry can buy.
        var centers: [Double] = [Swift.max(0, coverLow - guardHz), coverHigh + guardHz]
        if coverHigh - coverLow > advance {
            // Between them, march by half a window so each step's lower quarter lands on the
            // previous step's DC hole.
            var c = coverLow + edgeHz
            while c - edgeHz < coverHigh {
                centers.append(c)
                c += advance
                if centers.count > 100_000 { break }
            }
        }
        centers.sort()
        // Do not tune outside the device's range; a clamped centre still analyses honestly,
        // it just overlaps its neighbour more.
        // A centre can be lower than half a span -- an HF recording at 1 MHz played at 2.4 MSPS --
        // and the window below it would then be a negative frequency. UInt64(negative Double) is a
        // trap in Swift, not a saturating conversion, so this clamps at DC rather than crashing the
        // daemon on somebody's `ley scan`.
        func hzAt(_ v: Double) -> UInt64 { v <= 0 ? 0 : UInt64(v.rounded()) }
        let steps = centers.map { raw -> Step in
            let hz = UInt64(Swift.max(Double(lowestCenter), Swift.min(Double(highestCenter), raw)).rounded())
            return Step(centerHz: hz,
                        low: Window(lowHz: hzAt(Double(hz) - edgeHz), highHz: hzAt(Double(hz) - guardHz)),
                        high: Window(lowHz: hzAt(Double(hz) + guardHz), highHz: hzAt(Double(hz) + edgeHz)))
        }
        // A clamped run can repeat a centre; sweeping the same point twice is wasted dwell.
        var seen = Set<UInt64>()
        let unique = steps.filter { seen.insert($0.centerHz).inserted }
        return SweepPlan(steps: unique, sampleRateHz: sampleRateHz,
                         covered: Window(lowHz: UInt64(coverLow.rounded()), highHz: UInt64(coverHigh.rounded())),
                         clipped: clipped)
    }

    /// Hertz of `covered` that at least one window actually looks at.
    ///
    /// Normally this is all of it -- that is what the geometry is for. It is not, when the whole
    /// request falls inside one step's DC guard: a radio with a single tuning point (a file
    /// device) has no neighbouring step to cover its hole, so a request within 5% of that point is
    /// a range the sweep cannot see. Reporting nothing found there would be a lie.
    public var analysedHz: UInt64 {
        var spans: [(UInt64, UInt64)] = []
        for s in steps {
            for w in [s.low, s.high] {
                let c = w.clamped(to: covered)
                if c.highHz > c.lowHz { spans.append((c.lowHz, c.highHz)) }
            }
        }
        spans.sort { $0.0 < $1.0 }
        var total: UInt64 = 0
        var cursor: UInt64 = 0
        for (lo, hi) in spans {
            let start = Swift.max(lo, cursor)
            if hi > start {
                total += hi - start
                cursor = hi
            }
        }
        return total
    }

    /// How many of the plan's analysis windows contain `hz`. The geometry is supposed to
    /// guarantee at least one everywhere inside `covered`, and two almost everywhere; this is
    /// what the test checks.
    public func looks(at hz: UInt64) -> Int {
        steps.reduce(0) { $0 + ($1.low.contains(hz) ? 1 : 0) + ($1.high.contains(hz) ? 1 : 0) }
    }
}
