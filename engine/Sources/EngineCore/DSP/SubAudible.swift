// Sub-audible tone detection (docs/design-signal-views.md, "Sub-audible tones").
//
// CTCSS/PL rides under the voice at 67-254 Hz. The NFM chain destroys it one stage after the
// discriminator, deliberately: a 300 Hz two-pole high-pass is what stops it being audible. The
// discriminator output itself is untouched, so the tap costs nothing and risks no audio regression.

import Foundation

/// The 38 standard EIA CTCSS tones, Hz.
///
/// The spacing is what makes this hard: 67.0 and 69.3 are 2.3 Hz apart, so a detector whose
/// resolution is one bin width cannot tell them apart, and one that snaps to the nearest standard
/// tone will confidently name the wrong one. Naming the wrong tone is worse than naming none.
public enum CTCSS {
    public static let tones: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
        94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 162.2, 167.9, 173.8, 179.9,
        186.2, 192.8, 203.5, 210.7, 218.1, 225.7, 233.6, 241.8,
    ]

    /// Half the distance to the nearest neighbour of `tones[i]`: the widest a measurement may sit
    /// from a tone and still be unambiguously that one.
    static func neighbourGap(_ i: Int) -> Double {
        var gap = Double.infinity
        if i > 0 { gap = Swift.min(gap, tones[i] - tones[i - 1]) }
        if i < tones.count - 1 { gap = Swift.min(gap, tones[i + 1] - tones[i]) }
        return gap.isFinite ? gap : 10
    }

    /// A transmitter sends CTCSS at roughly 10-25% of full deviation. Energy far under this band is
    /// hum -- 50 Hz mains lands on exactly 100.0 Hz, which is also one of the commonest PL tones --
    /// and energy far over it is not a sub-audible tone at all.
    public static let minDeviationHz: Double = 200
    public static let maxDeviationHz: Double = 1500
}

/// What a sub-audible detector concluded about one window.
public struct SubAudibleResult: Sendable, Equatable {
    /// Measured tone frequency, Hz. NaN when nothing was measured.
    public var toneHz: Double = .nan
    /// The standard tone `toneHz` unambiguously is, or 0 when it is not classifiable. Reporting a
    /// measurement without a classification is honest; snapping a 2.3 Hz ladder is not.
    public var standardToneHz: Double = 0
    /// Peak deviation the tone was sent at, Hz.
    public var deviationHz: Double = .nan
    /// The tone against the rest of the 60-260 Hz band, dB.
    public var toneSNRDB: Double = .nan
    /// A stated score, not a probability: see `confidence(...)`.
    public var confidence: Double = 0
    /// Whether the detector is willing to report a tone at all.
    public var detected: Bool = false
    /// Why nothing was reported, for the log. Empty when `detected`.
    public var reason: String = ""
}

/// A Goertzel bank over the standard tones, plus the tests that decide whether its winner is a tone
/// or a coincidence.
///
/// The bank is a **gate, not the answer**. At N=512 and ~1 kHz its bin width is about 2 Hz, and the
/// ladder is spaced as tightly as 2.3 Hz, so the winning bin narrows the field to a candidate and
/// supplies the tone-to-band ratio; the frequency itself comes from the phase advance between
/// windows, which is not limited by bin width.
public final class SubAudibleDetector {
    /// Window length in samples. At ~1 kHz this is about half a second, which is what it takes to
    /// separate tones 2.3 Hz apart.
    public let windowSize: Int
    /// Samples between windows. Overlapping means an answer every hop rather than every window, and
    /// gives consecutive windows a phase relationship to measure.
    public let hop: Int
    public let rate: Double

    private var window: [Float]
    private var prevPhase: [Double]
    private var havePrev: [Bool]
    /// Frequency estimates from the last few hops, for the stability test.
    private var recent: [Double] = []
    private static let recentKeep = 3

    public init(rate: Double, windowSize: Int = 512, hop: Int = 128) {
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
    public func reset() {
        for i in havePrev.indices { havePrev[i] = false }
        recent.removeAll(keepingCapacity: true)
    }

    /// Analyse one window of decimated discriminator output. `samples` must be `windowSize` long
    /// and in units where ±1.0 is `fullScaleDeviationHz`.
    public func analyse(_ samples: [Float], fullScaleDeviationHz: Double) -> SubAudibleResult {
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
        var measured = CTCSS.tones[best]
        if havePrev[best] {
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
        out.toneHz = measured
        recent.append(measured)
        if recent.count > Self.recentKeep { recent.removeFirst() }

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
        // Voice moves; a tone does not. A pitch contour shifts far more than this in 100 ms.
        if recent.count >= 2 {
            let spread = (recent.max()! - recent.min()!)
            if spread > Self.maxSpreadHz {
                out.reason = "frequency moved \(String(format: "%.1f", spread)) Hz between hops"
                return out
            }
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
    public static let minSNRDB: Double = 6
    /// The most the estimate may wander across the last few hops.
    public static let maxSpreadHz: Double = 0.5

    /// The standard tone `measured` unambiguously is, or 0. A measurement that two tones could both
    /// explain is reported as a measurement and nothing more: snapping to the nearer one on a
    /// 2.3 Hz ladder is a guess wearing the clothes of a reading.
    public static func classify(_ measured: Double) -> Double {
        var candidates: [Int] = []
        for (i, t) in CTCSS.tones.enumerated() {
            let tol = Swift.min(0.01 * t, 0.4 * CTCSS.neighbourGap(i))
            if abs(measured - t) <= tol { candidates.append(i) }
        }
        return candidates.count == 1 ? CTCSS.tones[candidates[0]] : 0
    }

    /// A stated score in [0, 1], **not** a probability. Calibrating a probability needs a corpus of
    /// real off-air recordings we do not have, and shipping an uncalibrated one would be exactly the
    /// dressed-up guessing the honesty invariant forbids. The formula is the contract; a client that
    /// wants to judge for itself has toneSNRDB, deviationHz and the hop count.
    public static func confidence(snrDB: Double, measured: Double, standard: Double, hops: Int) -> Double {
        guard standard > 0 else { return 0 }
        let snr = clamp01((snrDB - minSNRDB) / 14)
        let tol = Swift.max(1e-9, Swift.min(0.01 * standard, 0.4 * 2.3))
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
