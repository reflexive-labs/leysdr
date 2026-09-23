// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// v0 energy detection over the FFT ladder: what is actually on this band, with the evidence.
///
/// The design and every number here are in `docs/design/scan.md`; each was measured by Monte
/// Carlo before it was written down, because this repo has twice shipped a detector that quoted
/// noise as signal. The short version:
///
/// - The floor is a **local** median with a guard band, not one number per row. The R820T's IF
///   response tilts the floor several dB across a span -- the same size as the threshold itself --
///   and a single median is 9 dB wrong end to end across a 12 dB droop.
/// - The threshold is derived from the row's **actual** look count, because an averaged bin is
///   Gamma-distributed with that shape and assuming 16 looks when the ladder gave 2 sets it 4 dB
///   too low.
/// - Bandwidth is an equivalent rectangular width from the second moment, not the width of the
///   run above the threshold: that width is not a property of the signal, it grows with SNR.
/// - A candidate whose mirror image about the capture centre is 20 dB stronger is the R820T's IQ
///   image, not a carrier.
public enum SpectrumDetect {
    /// Reference bins either side of the bin under test, past the guard.
    public static let referenceBins = 96
    /// Bins either side of the bin under test that are excluded from its own floor estimate, so a
    /// wide signal does not raise the floor it is measured against. 96 bins is 225 kHz at
    /// 2.4 MSPS over 1024 bins, which clears a 200 kHz WFM signal.
    public static let guardBins = 96
    /// Runs separated by no more than this are one signal: a notch in the middle of a wide carrier
    /// is not two carriers.
    public static let joinGap = 2
    /// A candidate is the mirror of a real signal when the bin reflected about the capture centre
    /// is at least this much stronger. The R820T rejects its image by 30-40 dB, so 20 is
    /// conservative in the direction of keeping signals.
    public static let imageMarginDB: Float = 20
    /// Second central moment of a periodic Hann window, in bins squared. Subtracted from a
    /// signal's measured moment because convolution adds variances.
    public static let windowMomentBins2 = 0.3333

    /// One thing found in one row.
    public struct Hit: Sendable, Hashable {
        /// Power-weighted centroid, in absolute Hz.
        public var centerHz: UInt64
        /// Equivalent rectangular width: the width a flat spectrum with the same second moment
        /// would have. Zero when the signal is narrower than the analysis can resolve.
        public var bandwidthHz: UInt32
        /// Peak bin over the local floor, in dB.
        public var snrDB: Double
        /// The local floor the SNR was measured against, dBFS per bin.
        public var floorDBFS: Double
        /// Index of the loudest bin, for the mirror test and for debugging.
        public var peakBin: Int
    }

    /// Threshold over the measured floor, as a power ratio, for a row of `looks` averaged
    /// periodograms and a per-bin false-alarm probability of `pFalse`.
    ///
    /// An averaged bin is Gamma(looks, mean/looks). Wilson-Hilferty gives the quantile in closed
    /// form: X^(1/3) is approximately Normal(1 - 1/(9M), 1/(9M)). Taking the ratio to the median
    /// (the same expression at z = 0) is what lets the floor estimator return a median while the
    /// model is about the mean -- neither has to be converted. At one look this reproduces the
    /// exact exponential answer to within 0.2 dB, erring high.
    public static func thresholdRatio(looks: Int, pFalse: Double) -> Double {
        let m = Double(Swift.max(1, looks))
        let p = Swift.min(Swift.max(pFalse, 1e-15), 0.49)
        func wh(_ z: Double) -> Double {
            let a = 1.0 / (9.0 * m)
            let v = 1.0 - a + z * (a).squareRoot()
            return v > 0 ? v * v * v : 1e-12
        }
        return wh(inverseNormalCDF(1 - p)) / wh(0)
    }

    /// The per-bin false-alarm probability that spends a whole sweep's budget: `expected` false
    /// detections spread over every bin of every row of every step.
    public static func sweepPFalse(expected: Double, bins: Int, rowsPerStep: Int, steps: Int) -> Double {
        let opportunities = Double(Swift.max(1, bins)) * Double(Swift.max(1, rowsPerStep)) * Double(Swift.max(1, steps))
        return Swift.max(expected / opportunities, 1e-15)
    }

    /// Local median floor: for each bin, the median of `referenceBins` either side, skipping
    /// `guardBins`. Linear power in, linear power out.
    ///
    /// `scratch` must hold at least `2 * referenceBins` floats and is reused for every bin, so
    /// this allocates nothing. It does not run on the DSP thread: it is roughly
    /// bins x 2 x referenceBins operations, which is fine on a sweep task and is not fine in a
    /// `SpectrumSink.write`.
    public static func localFloor(power: UnsafePointer<Float>, count: Int,
                                  into floor: UnsafeMutablePointer<Float>,
                                  scratch: UnsafeMutablePointer<Float>)
    {
        guard count > 0 else { return }
        for i in 0 ..< count {
            var n = 0
            let loEnd = i - guardBins
            let hiStart = i + guardBins + 1
            let loRoom = Swift.max(0, loEnd)
            let hiRoom = Swift.max(0, count - hiStart)
            // Near a row's edge one side runs out. Take the shortfall from the other side rather
            // than shrinking the sample: the threshold is calibrated for a fixed reference count,
            // and halving it near the edges would raise the false-alarm rate exactly where the
            // roll-off already makes the floor hardest to read. The estimate is still biased
            // toward the row's middle there, which is why the sweep looks at almost every
            // frequency from two tuner positions: one step's window edge is another's interior.
            let wantLo = Swift.min(loRoom, referenceBins + Swift.max(0, referenceBins - hiRoom))
            let wantHi = Swift.min(hiRoom, referenceBins + Swift.max(0, referenceBins - loRoom))
            if wantLo > 0 {
                for j in (loEnd - wantLo) ..< loEnd { scratch[n] = power[j]; n += 1 }
            }
            if wantHi > 0 {
                for j in hiStart ..< (hiStart + wantHi) { scratch[n] = power[j]; n += 1 }
            }
            if n == 0 {
                // A row narrower than the guard band on both sides: fall back to the whole row
                // rather than returning a floor of zero, which would make every bin infinitely
                // loud. Bounded by the scratch the caller was told to provide, taking an even
                // sample rather than the first slice so the median still describes the whole row.
                let capacity = 2 * referenceBins
                let stride = Swift.max(1, (count + capacity - 1) / capacity)
                var j = 0
                while j < count, n < capacity {
                    scratch[n] = power[j]
                    n += 1
                    j += stride
                }
            }
            floor[i] = median(scratch, count: n)
        }
    }

    /// Finds every signal in one row.
    ///
    /// `rowDB` is the ladder's row: dBFS, fft-shifted so index 0 is `centerHz - spanHz/2` and
    /// index `count/2` is DC. `window` limits the search to the part of the span worth believing
    /// (see `SweepPlan`); bins outside it are used for the floor estimate but never reported.
    ///
    /// `power`, `floor` and `scratch` are caller-owned working buffers of at least `count`,
    /// `count` and `2 * referenceBins` floats, so a sweep allocates once and not per row.
    public static func detect(rowDB: UnsafePointer<Float>, count: Int,
                              centerHz: UInt64, spanHz: UInt64, looks: Int, pFalse: Double,
                              believe: ClosedRange<UInt64>,
                              power: UnsafeMutablePointer<Float>,
                              floor: UnsafeMutablePointer<Float>,
                              scratch: UnsafeMutablePointer<Float>) -> [Hit]
    {
        guard count >= 8, spanHz > 0 else { return [] }
        // Rows arrive in dB. Everything below -- the median, the centroid, the moment -- is a
        // statement about power, and the mean of decibels is a different statistic.
        Kernels.dbToPower(rowDB, to: power, count: count)
        localFloor(power: power, count: count, into: floor, scratch: scratch)

        let ratio = Float(thresholdRatio(looks: looks, pFalse: pFalse))
        let binWidth = Double(spanHz) / Double(count)
        let lowEdge = Double(centerHz) - Double(spanHz) / 2
        // Bin b IS the frequency lowEdge + b*binWidth, not the interval [b, b+1): the ladder's
        // rows are point samples of the spectrum (FFT.swift: index 0 is centre - Fs/2, index
        // size/2 is DC). Treating them as intervals put every reported frequency half a bin high --
        // 1.17 kHz at 2.4 MSPS over 1024 bins, visible in the fixture run as carriers at
        // 145.201 MHz where the generator put 145.200.
        func hz(_ bin: Double) -> Double { lowEdge + bin * binWidth }

        // Search only the part of the span the sweep asked about, and never the analysis edges.
        var first = Int(((Double(believe.lowerBound) - lowEdge) / binWidth).rounded(.down))
        var last = Int(((Double(believe.upperBound) - lowEdge) / binWidth).rounded(.up))
        first = Swift.max(0, first)
        last = Swift.min(count - 1, last)
        // `>=`, the same bound `windowFloorDBFS` uses: a window that rounds to a single bin still
        // has one bin to search, and reporting a floor for it without testing that bin would be a
        // silent wrong answer.
        guard last >= first else { return [] }

        var hits: [Hit] = []
        var i = first
        while i <= last {
            guard power[i] > ratio * floor[i] else { i += 1; continue }
            // Extend while over threshold, tolerating gaps of up to joinGap bins.
            var end = i
            var j = i + 1
            while j <= last {
                if power[j] > ratio * floor[j] {
                    end = j
                    j += 1
                    continue
                }
                var gap = 0
                var k = j
                while k <= last, gap < joinGap, !(power[k] > ratio * floor[k]) { gap += 1; k += 1 }
                if k <= last, power[k] > ratio * floor[k] { end = k; j = k + 1; continue }
                break
            }
            defer { i = end + 1 }

            // Excess power over the local floor, which is what the centroid and the moment are
            // moments of: including the floor would drag both toward the middle of the run.
            var sum = 0.0, sumX = 0.0, sumXX = 0.0
            var peak = i
            for b in i ... end {
                let w = Double(Swift.max(0, power[b] - floor[b]))
                sum += w
                sumX += w * Double(b)
                sumXX += w * Double(b) * Double(b)
                if power[b] - floor[b] > power[peak] - floor[peak] { peak = b }
            }
            guard sum > 0 else { continue }
            let centroid = sumX / sum
            let variance = Swift.max(0, sumXX / sum - centroid * centroid - windowMomentBins2)
            // Equivalent rectangular width: a flat spectrum of width W has variance W^2/12.
            let widthHz = (12 * variance).squareRoot() * binWidth

            let f = Double(floor[peak])
            let snr = 10 * log10(Double(power[peak]) / Swift.max(f, 1e-30))
            let centreHz = hz(centroid)
            guard centreHz > 0 else { continue }
            hits.append(Hit(centerHz: UInt64(centreHz.rounded()),
                            bandwidthHz: UInt32(Swift.max(0, widthHz).rounded()),
                            snrDB: snr,
                            floorDBFS: 10 * log10(Swift.max(f, 1e-30)),
                            peakBin: peak))
        }
        return hits.filter { !isImage($0, power: power, count: count) }
    }

    /// The median of the local floor across one window, in dBFS per bin. Reported even when a
    /// window held nothing: an empty band's floor is the answer to "why did you find nothing",
    /// and a scan that only reports a floor where it found a signal cannot give it.
    ///
    /// `floor` is the buffer `detect` filled, so this must be called after it.
    public static func windowFloorDBFS(floor: UnsafeMutablePointer<Float>, count: Int,
                                       centerHz: UInt64, spanHz: UInt64,
                                       believe: ClosedRange<UInt64>,
                                       scratch: UnsafeMutablePointer<Float>) -> Double
    {
        guard count > 0, spanHz > 0 else { return .nan }
        let binWidth = Double(spanHz) / Double(count)
        let lowEdge = Double(centerHz) - Double(spanHz) / 2
        var first = Int(((Double(believe.lowerBound) - lowEdge) / binWidth).rounded(.down))
        var last = Int(((Double(believe.upperBound) - lowEdge) / binWidth).rounded(.up))
        first = Swift.max(0, first)
        last = Swift.min(count - 1, last)
        guard last >= first else { return .nan }
        var n = 0
        // The scratch buffer is sized for the reference window, which is smaller than a believed
        // window: take an even sample across it rather than a contiguous slice, so the median
        // describes the whole window and not one end of it.
        let capacity = 2 * referenceBins
        let stride = Swift.max(1, (last - first + 1 + capacity - 1) / capacity)
        var i = first
        while i <= last, n < capacity {
            scratch[n] = floor[i]
            n += 1
            i += stride
        }
        guard n > 0 else { return .nan }
        return 10 * log10(Double(Swift.max(median(scratch, count: n), 1e-30)))
    }

    /// True when the hit is the mirror of a much stronger signal reflected about the capture
    /// centre -- the R820T's IQ image, which is stationary, persistent and looks exactly like a
    /// carrier to energy detection.
    ///
    /// Dropping it is only safe because of the sweep geometry: the mirror position moves with the
    /// tuner and a real signal does not, and almost every frequency is analysed from two centres.
    /// A real pair of signals symmetric about *this* centre would lose the weaker one here and be
    /// found in its other look.
    static func isImage(_ hit: Hit, power: UnsafePointer<Float>, count: Int) -> Bool {
        // Index `count/2` is DC; the reflection of bin b is count - b.
        let mirror = count - hit.peakBin
        guard mirror > 0, mirror < count else { return false }
        let margin = powf(10, imageMarginDB / 10)
        return power[mirror] > margin * power[hit.peakBin]
    }

    /// Median of the first `count` values, by selection. Reorders the buffer, which is why every
    /// caller passes scratch.
    static func median(_ v: UnsafeMutablePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        return select(v, count: count, k: count / 2)
    }

    /// Quickselect: the k-th smallest of the first `count` values.
    static func select(_ v: UnsafeMutablePointer<Float>, count: Int, k: Int) -> Float {
        var lo = 0, hi = count - 1
        var target = Swift.min(Swift.max(k, 0), count - 1)
        while lo < hi {
            let pivot = v[(lo + hi) / 2]
            var a = lo, b = hi
            while a <= b {
                while v[a] < pivot { a += 1 }
                while v[b] > pivot { b -= 1 }
                if a <= b {
                    let t = v[a]; v[a] = v[b]; v[b] = t
                    a += 1; b -= 1
                }
            }
            if target <= b { hi = b } else if target >= a { lo = a } else { return v[target] }
        }
        target = Swift.min(Swift.max(target, 0), count - 1)
        return v[target]
    }

    /// Inverse standard normal CDF (Acklam's rational approximation, ~1e-9 absolute).
    /// Needed because the threshold is a quantile and Foundation has no erfinv.
    static func inverseNormalCDF(_ p: Double) -> Double {
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let plow = 0.02425
        if p <= 0 { return -Double.infinity }
        if p >= 1 { return .infinity }
        if p < plow {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p <= 1 - plow {
            let q = p - 0.5, r = q * q
            return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
                (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        }
        let q = (-2 * log(1 - p)).squareRoot()
        return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
            ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    }
}
