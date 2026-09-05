// FIR design and decimating FIR filters (docs/engine-internals.md, "Channelizer plan").
// Design happens at configure time; `process` is allocation-free and keeps `taps−1` samples of
// history so decimation phase is continuous across blocks (block-wise output == one-shot output).

import Foundation

/// Windowed-sinc (Blackman) low-pass design.
public enum FIRDesign {
    /// Largest tap count the designer will return.
    public static let maxTaps = 1023

    /// Largest tap count for a non-decimating selectivity filter at the audio rate (≈ 48 kHz), where
    /// the extra taps buy stopband width for CW/narrow SSB at a fraction of the stage-1/2 cost.
    public static let maxSelectivityTaps = 2047

    /// Number of taps for a transition width: `≈ 4·rate/transition`, forced odd, clamped to `3...maxTaps`.
    public static func tapCount(rate: Double, transitionHz: Double, maxTaps: Int = maxTaps) -> Int {
        guard rate > 0, transitionHz > 0 else { return maxTaps }
        var n = Int((4 * rate / transitionHz).rounded(.up))
        if n % 2 == 0 { n += 1 }
        return Swift.max(3, Swift.min(maxTaps, n))
    }

    /// Low-pass taps with unity DC gain. `cutoffHz` is the −6 dB point; `taps` must be odd.
    public static func lowPass(cutoffHz: Double, rate: Double, taps: Int) -> [Float] {
        precondition(taps >= 1 && taps % 2 == 1, "taps must be odd")
        let fc = Swift.min(0.5, Swift.max(0, cutoffHz / rate)) // cycles/sample
        let m = taps - 1
        var h = [Double](repeating: 0, count: taps)
        var sum = 0.0
        for n in 0 ..< taps {
            let k = Double(n) - Double(m) / 2
            let sinc = k == 0 ? 2 * fc : sin(2 * Double.pi * fc * k) / (Double.pi * k)
            let w = m == 0 ? 1.0 : 0.42 - 0.5 * cos(2 * Double.pi * Double(n) / Double(m)) + 0.08 * cos(4 * Double.pi * Double(n) / Double(m))
            h[n] = sinc * w
            sum += h[n]
        }
        if sum != 0 { for n in 0 ..< taps { h[n] /= sum } }
        return h.map { Float($0) }
    }

    /// Convenience: design from cutoff + transition width.
    public static func lowPass(cutoffHz: Double, rate: Double, transitionHz: Double, maxTaps: Int = maxTaps) -> [Float] {
        lowPass(cutoffHz: cutoffHz, rate: rate, taps: tapCount(rate: rate, transitionHz: transitionHz, maxTaps: maxTaps))
    }
}

/// Complex (split re/im) FIR + integer decimator with continuous history across blocks.
public final class FIRDecimator {
    public let taps: [Float]
    public let decimation: Int
    /// Largest input block `process` accepts.
    public let maxBlock: Int
    /// Upper bound on outputs per `process` call: `ceil((maxBlock + decimation − 1) / decimation)`.
    public var maxOutput: Int { (maxBlock + decimation - 1) / decimation }

    private let tapPtr: UnsafeMutablePointer<Float>
    private let workRe: UnsafeMutablePointer<Float>
    private let workIm: UnsafeMutablePointer<Float>
    private let workCapacity: Int
    /// Samples currently held in `work` (history + not-yet-consumed input).
    private var pending = 0

    public init(taps: [Float], decimation: Int, maxBlock: Int) {
        precondition(!taps.isEmpty && decimation >= 1 && maxBlock >= 1)
        self.taps = taps
        self.decimation = decimation
        self.maxBlock = maxBlock
        let tp = UnsafeMutablePointer<Float>.allocate(capacity: taps.count)
        taps.withUnsafeBufferPointer { tp.update(from: $0.baseAddress!, count: taps.count) }
        tapPtr = tp
        workCapacity = maxBlock + taps.count - 1 + decimation
        workRe = UnsafeMutablePointer<Float>.allocate(capacity: workCapacity)
        workIm = UnsafeMutablePointer<Float>.allocate(capacity: workCapacity)
        reset()
    }

    deinit {
        tapPtr.deallocate()
        workRe.deallocate()
        workIm.deallocate()
    }

    /// Clear history (prime with `taps−1` zeros so the first output aligns with a one-shot filter
    /// that had zero history).
    public func reset() {
        pending = taps.count - 1
        Kernels.clear(workRe, count: workCapacity)
        Kernels.clear(workIm, count: workCapacity)
    }

    /// Filter + decimate `count ≤ maxBlock` samples. Returns outputs written to `outRe`/`outIm`
    /// (capacity ≥ `maxOutput`). Hot path: no allocation.
    @discardableResult
    public func process(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int,
                        outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) -> Int {
        precondition(count <= maxBlock)
        let nTaps = taps.count
        (workRe + pending).update(from: re, count: count)
        (workIm + pending).update(from: im, count: count)
        let total = pending + count
        let outputs = total >= nTaps ? (total - nTaps) / decimation + 1 : 0
        if outputs > 0 {
            Kernels.firDecimate(re: workRe, im: workIm, taps: tapPtr, tapCount: nTaps, decimation: decimation,
                                outRe: outRe, outIm: outIm, outputCount: outputs)
        }
        let consumed = outputs * decimation
        let remain = total - consumed
        if remain > 0 && consumed > 0 {
            // Overlapping move-down; regions may overlap so use memmove semantics.
            memmove(workRe, workRe + consumed, remain * MemoryLayout<Float>.size)
            memmove(workIm, workIm + consumed, remain * MemoryLayout<Float>.size)
        }
        pending = remain
        return outputs
    }
}

/// Real FIR + integer decimator with continuous history (WFM audio decimation).
public final class RealFIRDecimator {
    public let taps: [Float]
    public let decimation: Int
    public let maxBlock: Int
    public var maxOutput: Int { (maxBlock + decimation - 1) / decimation }

    private let tapPtr: UnsafeMutablePointer<Float>
    private let work: UnsafeMutablePointer<Float>
    private let workCapacity: Int
    private var pending = 0

    public init(taps: [Float], decimation: Int, maxBlock: Int) {
        precondition(!taps.isEmpty && decimation >= 1 && maxBlock >= 1)
        self.taps = taps
        self.decimation = decimation
        self.maxBlock = maxBlock
        let tp = UnsafeMutablePointer<Float>.allocate(capacity: taps.count)
        taps.withUnsafeBufferPointer { tp.update(from: $0.baseAddress!, count: taps.count) }
        tapPtr = tp
        workCapacity = maxBlock + taps.count - 1 + decimation
        work = UnsafeMutablePointer<Float>.allocate(capacity: workCapacity)
        reset()
    }

    deinit {
        tapPtr.deallocate()
        work.deallocate()
    }

    /// Clear history.
    public func reset() {
        pending = taps.count - 1
        Kernels.clear(work, count: workCapacity)
    }

    /// Filter + decimate `count ≤ maxBlock` samples into `out` (capacity ≥ `maxOutput`). Returns outputs.
    @discardableResult
    public func process(_ src: UnsafePointer<Float>, count: Int, out: UnsafeMutablePointer<Float>) -> Int {
        precondition(count <= maxBlock)
        let nTaps = taps.count
        (work + pending).update(from: src, count: count)
        let total = pending + count
        let outputs = total >= nTaps ? (total - nTaps) / decimation + 1 : 0
        if outputs > 0 {
            Kernels.firDecimateReal(work, taps: tapPtr, tapCount: nTaps, decimation: decimation, out: out, outputCount: outputs)
        }
        let consumed = outputs * decimation
        let remain = total - consumed
        if remain > 0 && consumed > 0 {
            memmove(work, work + consumed, remain * MemoryLayout<Float>.size)
        }
        pending = remain
        return outputs
    }
}
