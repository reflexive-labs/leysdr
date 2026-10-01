// SPDX-License-Identifier: GPL-3.0-or-later

// Sub-audible tone detection (docs/design/signal-views.md, "Sub-audible tones").
//
// CTCSS/PL sits under the voice at 67-254 Hz. The NFM chain removes it one stage after the
// discriminator with a 300 Hz two-pole high-pass so the tone is not audible. The
// discriminator output itself is untouched, so the tap costs nothing and risks no audio regression.

import Foundation

/// The 38 standard EIA CTCSS tones, Hz.
///
/// The spacing is what makes this hard: 67.0 and 69.3 are 2.3 Hz apart, so a detector whose
/// resolution is one bin width cannot tell them apart, and one that snaps to the nearest standard
/// tone will confidently name the wrong one. Naming the wrong tone is worse than naming none.
package enum CTCSS {
    package static let tones: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
        94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 162.2, 167.9, 173.8, 179.9,
        186.2, 192.8, 203.5, 210.7, 218.1, 225.7, 233.6, 241.8,
    ]

    /// Distance to the nearest neighbour of `tones[i]`. Callers scale this down to get the widest
    /// a measurement may sit from a tone and still be unambiguously that one.
    static func neighbourGap(_ i: Int) -> Double {
        var gap = Double.infinity
        if i > 0 { gap = Swift.min(gap, tones[i] - tones[i - 1]) }
        if i < tones.count - 1 { gap = Swift.min(gap, tones[i + 1] - tones[i]) }
        return gap.isFinite ? gap : 10
    }

    /// The widest a measurement may sit from `tones[i]` and still be unambiguously that one: a
    /// fraction of the way to its nearest neighbour, tightened to 1% of the tone itself so a wide
    /// gap at the top of the ladder does not buy a sloppy reading.
    static func tolerance(_ i: Int) -> Double {
        Swift.min(0.01 * tones[i], 0.4 * neighbourGap(i))
    }

    /// The same tolerance for a tone named by value, for callers that hold a standard tone rather
    /// than its index. An unknown value keeps the 1% term alone.
    static func tolerance(forStandard t: Double) -> Double {
        guard let i = tones.firstIndex(of: t) else { return 0.01 * t }
        return tolerance(i)
    }

    /// A transmitter sends CTCSS at roughly 10-25% of full deviation. Energy far under this band is
    /// hum -- 50 Hz mains lands on exactly 100.0 Hz, which is also one of the commonest PL tones --
    /// and energy far over it is not a sub-audible tone at all.
    package static let minDeviationHz: Double = 200
    package static let maxDeviationHz: Double = 1500
}

/// Which sub-audible signalling a result claims.
package enum SubAudibleKind: Sendable, Equatable {
    case none, ctcss, dcs
}

/// What the sub-audible detectors concluded about one window: the CTCSS detector's measurements,
/// and the DCS decoder's lock when it has one.
package struct SubAudibleResult: Sendable, Equatable {
    /// Measured tone frequency, Hz. NaN when nothing was measured.
    package var toneHz: Double = .nan
    /// The standard tone `toneHz` unambiguously is, or 0 when it is not classifiable. Reporting a
    /// measurement without a classification is correct; snapping to a 2.3 Hz ladder is a guess.
    package var standardToneHz: Double = 0
    /// Peak deviation the tone was sent at, Hz.
    package var deviationHz: Double = .nan
    /// The tone against the rest of the 60-260 Hz band, dB.
    package var toneSNRDB: Double = .nan
    /// A stated score, not a probability: see `confidence(...)`.
    package var confidence: Double = 0
    /// Whether the CTCSS detector is willing to report a tone at all. False whenever `dcs` is set.
    package var detected: Bool = false
    /// Why nothing was reported, for the log. Empty when `detected`.
    package var reason: String = ""
    /// The DCS decoder's lock, or nil. When set, the result claims DCS and no tone: `toneHz` is NaN,
    /// `standardToneHz` 0, and `deviationHz` and `confidence` are the decoder's.
    package var dcs: DCSResult?
    /// The sample time of the hop at which the current claim (this kind, and this tone or this
    /// code and polarity) was first made; nil while nothing is claimed. Set by the channel's
    /// sub-audible task, which knows the time, never by a detector.
    package var firstSeen: SampleTime?

    package init() {}

    package var kind: SubAudibleKind {
        if dcs != nil { return .dcs }
        return detected ? .ctcss : .none
    }

    /// Whether `other` claims the same thing: the same kind, and the same standard tone or the same
    /// code and polarity. What the task treats as an edge.
    package func sameClaim(as other: SubAudibleResult) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .none: return true
        case .ctcss: return standardToneHz == other.standardToneHz
        case .dcs: return dcs?.code == other.dcs?.code && dcs?.inverted == other.dcs?.inverted
        }
    }

    /// One hop's answer from both detectors. A DCS lock suppresses the CTCSS claim, because the
    /// code's broadband sub-audible energy feeds the Goertzel bank (docs/design/signal-views.md,
    /// "DCS"); without a lock the CTCSS result stands as it is.
    package static func merged(ctcss: SubAudibleResult, dcs: DCSResult) -> SubAudibleResult {
        guard dcs.detected else { return ctcss }
        var out = SubAudibleResult()
        out.dcs = dcs
        out.deviationHz = dcs.deviationHz
        out.confidence = dcs.confidence
        out.reason = "DCS lock suppresses the CTCSS claim"
        return out
    }
}

/// A Goertzel bank over the standard tones, plus the tests that decide whether its winner is a tone
/// or a coincidence.
///
/// The bank is a **gate, not the answer**. At N=512 and ~1 kHz its bin width is about 2 Hz, and the
/// ladder is spaced as tightly as 2.3 Hz, so the winning bin narrows the field to a candidate and
/// supplies the tone-to-band ratio; the frequency itself comes from the phase advance between
/// windows, which is not limited by bin width.
package final class SubAudibleDetector {
    /// Window length in samples. At ~1 kHz this is about half a second, which is what it takes to
    /// separate tones 2.3 Hz apart.
    package let windowSize: Int
    /// Samples between windows. Overlapping means an answer every hop rather than every window, and
    /// gives consecutive windows a phase relationship to measure.
    package let hop: Int
    package let rate: Double

    private var window: [Float]
    private var prevPhase: [Double]
    private var havePrev: [Bool]
    /// Frequency and deviation estimates from the last `stabilityHops` hops, for the two stability
    /// tests. Both fill regardless of the per-hop gates, so a hop that failed one still counts
    /// against the tone: a voice that dips under the deviation floor for one syllable has moved.
    private var recent: [Double] = []
    private var recentDeviation: [Double] = []

    package init(rate: Double, windowSize: Int = 512, hop: Int = 128) {
        precondition(rate > 0 && windowSize > 0 && hop > 0)
        self.rate = rate
        self.windowSize = windowSize
        self.hop = hop
        window = [Float](repeating: 0, count: windowSize)
        window.withUnsafeMutableBufferPointer { Kernels.hannWindow($0.baseAddress!, count: windowSize) }
        prevPhase = [Double](repeating: 0, count: CTCSS.tones.count)
        havePrev = [Bool](repeating: false, count: CTCSS.tones.count)
    }

    /// Forget the phase history. Called when the squelch closes: the next transmission is a
    /// different one, and carrying phase across it would fabricate a stable estimate.
    package func reset() {
        recentDeviation.removeAll(keepingCapacity: true)
        for i in havePrev.indices { havePrev[i] = false }
        recent.removeAll(keepingCapacity: true)
    }

    /// Analyse one window of decimated discriminator output. `samples` must be `windowSize` long
    /// and in units where ±1.0 is `fullScaleDeviationHz`.
    package func analyse(_ samples: [Float], fullScaleDeviationHz: Double) -> SubAudibleResult {
        precondition(samples.count == windowSize)
        var out = SubAudibleResult()

        // Remove DC before windowing: the discriminator's DC is the tuning error, not a tone, and a
        // large one leaks into every low bin.
        var mean: Float = 0
        for v in samples { mean += v }
        mean /= Float(samples.count)
        var work = [Float](repeating: 0, count: windowSize)
        for i in 0 ..< windowSize { work[i] = (samples[i] - mean) * window[i] }

        // The bank.
        var power = [Double](repeating: 0, count: CTCSS.tones.count)
        var phase = [Double](repeating: 0, count: CTCSS.tones.count)
        for (i, f) in CTCSS.tones.enumerated() {
            let (p, ph) = goertzel(work, frequency: f)
            power[i] = p
            phase[i] = ph
        }
        guard let best = power.indices.max(by: { power[$0] < power[$1] }) else {
            out.reason = "no bins"
            return out
        }
        // Tone against the rest of the band. The median bin is the band's own level, so this is the
        // tone's margin over the sub-audible noise it sits in.
        let sorted = power.sorted()
        let median = sorted[sorted.count / 2]
        guard power[best] > 0, median > 0 else {
            out.reason = "no energy"
            return out
        }
        out.toneSNRDB = 10 * Foundation.log10(power[best] / median)

        // Amplitude of the winning bin, as peak deviation in Hz. The Hann window halves coherent
        // gain, and the Goertzel power is (N/2 * amplitude * coherentGain)^2 for a real tone.
        let amplitude = 2 * (power[best].squareRoot()) / (Double(windowSize) * 0.5)
        out.deviationHz = amplitude * fullScaleDeviationHz

        // Frequency from the phase advance between this window and the last, which is not limited
        // by bin width. Unambiguous over +-rate/(2*hop).
        let havePhaseReference = havePrev[best]
        var measured = CTCSS.tones[best]
        if havePhaseReference {
            let expected = 2 * Double.pi * CTCSS.tones[best] * Double(hop) / rate
            var d = phase[best] - prevPhase[best] - expected
            while d > Double.pi { d -= 2 * Double.pi }
            while d < -Double.pi { d += 2 * Double.pi }
            measured = CTCSS.tones[best] + d * rate / (2 * Double.pi * Double(hop))
        }
        for i in prevPhase.indices {
            prevPhase[i] = phase[i]
            havePrev[i] = i == best ? true : havePrev[i]
        }
        guard havePhaseReference else {
            // The bin only narrows the candidates: on a 2.3 Hz ladder its nominal centre is not a
            // measurement. With no previous window to measure phase advance against there is no
            // frequency yet, and nothing to feed the stability test.
            out.reason = "no phase reference yet"
            return out
        }
        out.toneHz = measured
        recent.append(measured)
        recentDeviation.append(out.deviationHz)
        if recent.count > Self.stabilityHops { recent.removeFirst() }
        if recentDeviation.count > Self.stabilityHops { recentDeviation.removeFirst() }

        // The tests. Each rejects a different way of being wrong, and all must pass.
        let snr = out.toneSNRDB
        if snr < Self.minSNRDB {
            out.reason = "tone is only \(Int(snr.rounded())) dB over the band"
            return out
        }
        if !(out.deviationHz >= CTCSS.minDeviationHz && out.deviationHz <= CTCSS.maxDeviationHz) {
            // 50 Hz mains hum lands on exactly 100.0 Hz, is perfectly stable, and passes every
            // frequency test there is. Deviation is the only thing that separates it from a tone.
            out.reason = "deviation \(Int(out.deviationHz.rounded())) Hz is outside a transmitter's range"
            return out
        }
        // Voice moves; a tone does not. A human pitch contour shifts far more than maxSpreadHz in
        // 100 ms, but NOAA weather radio's synthesised announcer held a vowel inside it for three
        // hops and was named a PL (233.6 Hz, then 241.8) on a station that transmits none; over a
        // whole second it never did. So the estimate must hold for the whole horizon, and so must
        // the deviation: a transmitter sends its tone at one level, and a voice fundamental's level
        // rises and falls with every syllable (docs/design/signal-views.md, "Sub-audible tones";
        // the numbers are on `stabilityHops` and `maxDeviationRatio` below).
        guard recent.count >= Self.stabilityHops else {
            out.reason = "settling: \(recent.count) of \(Self.stabilityHops) hops"
            return out
        }
        let spread = recent.max()! - recent.min()!
        if spread > Self.maxSpreadHz {
            out.reason = "frequency moved \(String(format: "%.1f", spread)) Hz across \(Self.stabilityHops) hops"
            return out
        }
        let devLo = recentDeviation.min()!, devHi = recentDeviation.max()!
        if devLo <= 0 || devHi / devLo > Self.maxDeviationRatio {
            out.reason = "deviation moved from \(Int(devLo.rounded())) to \(Int(devHi.rounded())) Hz across \(Self.stabilityHops) hops"
            return out
        }
        out.detected = true

        // Classification, last and separately. Report the measurement whatever happens; only claim
        // a standard tone when no other tone is within reach of it.
        out.standardToneHz = Self.classify(measured)
        out.confidence = Self.confidence(snrDB: snr, measured: measured,
                                         standard: out.standardToneHz, hops: recent.count)
        return out
    }

    /// The least a tone may stand over the rest of the sub-audible band. Measured on synthesised
    /// NFM: a real tone clears its nearest rival by 7.5 dB or more even at 2% deviation, and voice
    /// alone never managed more than 2.
    package static let minSNRDB: Double = 6
    /// The most the estimate may drift across the horizon.
    package static let maxSpreadHz: Double = 0.5
    /// How many hops the estimate and the deviation must hold for before a tone is claimed: at the
    /// tap's 1 kHz and a 128-sample hop, about a second. Measured 2026-09-14 on real captures: over
    /// three hops the synthesised NOAA announcer (`noaa-wx2-auto`) was named a tone on 5 of 90 hops
    /// and the handheld's real 100 Hz PL (`ht-narrow`) on 48 of 75, once as 110.9; over eight hops
    /// the announcer is named on none and the handheld on 42, every one of them 100.0.
    package static let stabilityHops = 8
    /// The most the deviation may vary across the horizon, as a ratio of loudest to quietest hop.
    /// The handheld's PL measured 258 to 314 Hz over 47 hops (a ratio of 1.22); the announcer's
    /// fundamental swung from 201 to 345 Hz within the hops it was claimed on.
    package static let maxDeviationRatio: Double = 1.5

    /// The standard tone `measured` unambiguously is, or 0. A measurement that two tones could both
    /// explain is reported as a measurement only. Snapping to the nearer one on a 2.3 Hz ladder
    /// would report a guess as a reading.
    package static func classify(_ measured: Double) -> Double {
        var candidates: [Int] = []
        for (i, t) in CTCSS.tones.enumerated() {
            let tol = CTCSS.tolerance(i)
            if abs(measured - t) <= tol { candidates.append(i) }
        }
        return candidates.count == 1 ? CTCSS.tones[candidates[0]] : 0
    }

    /// A stated score in [0, 1], **not** a probability. Calibrating a probability needs a corpus of
    /// real off-air recordings we do not have, and an uncalibrated one would present a guess as a
    /// measurement, which the honesty invariant forbids. The formula is the contract. A client that
    /// wants its own judgement has toneSNRDB, deviationHz and the hop count.
    package static func confidence(snrDB: Double, measured: Double, standard: Double, hops: Int) -> Double {
        guard standard > 0 else { return 0 }
        let snr = clamp01((snrDB - minSNRDB) / 14)
        let tol = Swift.max(1e-9, CTCSS.tolerance(forStandard: standard))
        let near = clamp01(1 - abs(measured - standard) / tol)
        let settled = Swift.min(Double(hops), 3) / 3
        return snr * near * settled
    }

    /// Single-bin power and phase. Fixed state, no allocation beyond the caller's.
    private func goertzel(_ x: [Float], frequency: Double) -> (power: Double, phase: Double) {
        let k = 2 * Foundation.cos(2 * Double.pi * frequency / rate)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = Double(v) + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * Foundation.cos(2 * Double.pi * frequency / rate)
        let imag = s2 * Foundation.sin(2 * Double.pi * frequency / rate)
        return (real * real + imag * imag, Foundation.atan2(imag, real))
    }
}

private func clamp01(_ v: Double) -> Double { Swift.min(1, Swift.max(0, v)) }
