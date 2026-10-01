// SPDX-License-Identifier: GPL-3.0-or-later

// Channelizer: NCO mix → FIR↓D1 → (narrow modes) anti-alias FIR↓D2 → selectivity FIR at r2.
// See docs/dev/engine-internals.md, "Channelizer plan". Configure-time allocation only; `process` is the hot path.

import Foundation

/// Decimation plan for a channel at a given capture rate and mode.
package struct ChannelPlan: Hashable, Sendable {
    /// Stage-1 decimation (`max(1, floor(Fs / 240 kHz))`).
    package var d1: Int
    /// Stage-1 output rate `Fs / d1` (≥ 240 kHz).
    package var r1: Double
    /// Stage-2 decimation (`round(r1 / 48 kHz)`, ≥ 1). WFM demodulates at `r1` and applies `d2` to audio.
    package var d2: Int
    /// Stage-2 output rate `r1 / d2` (≈ 48 kHz).
    package var r2: Double
    /// Stage-1 low-pass cutoff (Hz).
    package var stage1CutoffHz: Double
    /// Stage-2 anti-alias cutoff (Hz) for the `r1 → r2` decimation: `0.45·r2`.
    package var antiAliasCutoffHz: Double
    /// Selectivity low-pass cutoff (Hz) at `r2` — this filter *is* the channel bandwidth (`bw/2`).
    package var stage2CutoffHz: Double
    /// Whether the channelizer runs stage 2 (false for WFM).
    package var usesStage2: Bool

    /// Rate the channelizer emits: `r2` for narrow modes, `r1` for WFM.
    package var outputRate: Double { usesStage2 ? r2 : r1 }

    /// The decimation ladder for a capture rate: stage 1 down to at least 240 kHz, stage 2 to about
    /// 48 kHz. The one copy of this arithmetic, so the bandwidth the accessor advertises and the
    /// bandwidth `plan` accepts cannot drift apart.
    static func rates(captureRate: UInt64) -> (d1: Int, r1: Double, d2: Int, r2: Double) {
        let fs = Double(captureRate)
        let d1 = max(1, Int(fs / 240_000))
        let r1 = fs / Double(d1)
        let d2 = max(1, Int((r1 / 48_000).rounded()))
        return (d1, r1, d2, r1 / Double(d2))
    }

    /// Largest bandwidth a narrow (stage-2) mode can carry at `r2`: `0.9·r2` (≈ 43 kHz at 2.4 MSPS).
    package static func maxNarrowBandwidthHz(captureRate: UInt64) -> Double {
        0.9 * rates(captureRate: captureRate).r2
    }

    /// Highest capture rate a plan is computed for (100 MSPS). Above it the decimator ratios stop
    /// being meaningful; anything larger is a malformed sidecar or device descriptor.
    package static let maxCaptureRate: UInt64 = 100_000_000

    /// - Throws: `INVALID_ARGUMENT` when `captureRate` exceeds `maxCaptureRate`, or when a narrow
    ///   mode asks for more than `maxNarrowBandwidthHz` (the channel would silently be filtered
    ///   narrower than it reports).
    package static func plan(captureRate: UInt64, mode: DemodMode, bandwidthHz: UInt32) throws -> ChannelPlan {
        guard captureRate <= maxCaptureRate else {
            throw EngineError.invalidArgument("capture rate \(captureRate) S/s exceeds \(maxCaptureRate) S/s")
        }
        let (d1, r1, d2, r2) = rates(captureRate: captureRate)
        let bw = Double(bandwidthHz)
        let wfm = mode == .wfm
        let maxBW = maxNarrowBandwidthHz(captureRate: captureRate)
        if !wfm, bw > maxBW {
            throw EngineError.invalidArgument(
                "bandwidth \(bandwidthHz) Hz exceeds \(Int(maxBW)) Hz, the most a \(mode.rawValue) channel can carry at \(captureRate) S/s (narrow modes run at r2 ≈ 48 kHz); use wfm for wide channels")
        }
        let c1 = wfm ? bw / 2 : min(bw / 2 + 5_000, 0.4 * r1)
        return ChannelPlan(d1: d1, r1: r1, d2: d2, r2: r2, stage1CutoffHz: min(c1, 0.45 * r1),
                           antiAliasCutoffHz: 0.45 * r2, stage2CutoffHz: bw / 2, usesStage2: !wfm)
    }
}

/// Mixes a channel to baseband and decimates it to the demodulator rate.
package final class Channelizer {
    package let captureRate: UInt64
    package let mode: DemodMode
    package let bandwidthHz: UInt32
    package let plan: ChannelPlan
    /// Largest input block (complex samples) `process` accepts.
    package let maxBlock: Int
    /// Upper bound on output samples per `process` call.
    package let maxOutput: Int
    /// Output rate rounded to the wire type; `outputRateHz` is exact.
    package var outputRate: UInt32 { UInt32(outputRateHz.rounded()) }
    package var outputRateHz: Double { plan.outputRate }
    package private(set) var offsetHz: Int64

    private let nco: NCO
    private let stage1: FIRDecimator
    /// Anti-alias FIR for `r1 → r2` (nil for WFM or when `d2 == 1`).
    private let stage2: FIRDecimator?
    /// Bandwidth-setting FIR at `r2` (nil for WFM).
    private let selectivity: FIRDecimator?
    private let inRe, inIm, oscRe, oscIm, s1Re, s1Im, s2Re, s2Im, s3Re, s3Im: UnsafeMutablePointer<Float>

    /// - Throws: `INVALID_ARGUMENT` for a zero/oversize bandwidth or block; `OFFSET_OUT_OF_CAPTURE`
    ///   when the channel does not fit inside ±Fs/2.
    package init(captureRate: UInt64, offsetHz: Int64, bandwidthHz: UInt32, mode: DemodMode, maxBlock: Int) throws {
        guard captureRate > 0 else { throw EngineError.invalidArgument("capture rate must be > 0") }
        guard bandwidthHz > 0, UInt64(bandwidthHz) <= captureRate else {
            throw EngineError.invalidArgument("bandwidth \(bandwidthHz) Hz must be in 1...\(captureRate)")
        }
        guard maxBlock > 0 else { throw EngineError.invalidArgument("maxBlock must be > 0") }
        try Channelizer.checkOffset(offsetHz, bandwidthHz: bandwidthHz, captureRate: captureRate)
        self.captureRate = captureRate
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.maxBlock = maxBlock
        self.offsetHz = offsetHz
        let plan = try ChannelPlan.plan(captureRate: captureRate, mode: mode, bandwidthHz: bandwidthHz)
        self.plan = plan
        let fs = Double(captureRate)
        nco = NCO(rate: fs, frequencyHz: Channelizer.ncoFrequency(offsetHz: offsetHz, bandwidthHz: bandwidthHz, mode: mode), maxBlock: maxBlock)
        // Stage 1: everything above r1 − cutoff aliases in, so the transition band is r1 − 2·cutoff.
        let t1 = max(plan.r1 - 2 * plan.stage1CutoffHz, 0.05 * plan.r1)
        stage1 = FIRDecimator(taps: FIRDesign.lowPass(cutoffHz: plan.stage1CutoffHz, rate: fs, transitionHz: t1),
                              decimation: plan.d1, maxBlock: maxBlock)
        if plan.usesStage2 {
            // Stage 2 only keeps aliases out of r2 (cutoff 0.45·r2, transition 0.1·r2 → ~200 taps at r1).
            if plan.d2 > 1 {
                let t2 = plan.r2 - 2 * plan.antiAliasCutoffHz
                stage2 = FIRDecimator(taps: FIRDesign.lowPass(cutoffHz: plan.antiAliasCutoffHz, rate: plan.r1, transitionHz: t2),
                                      decimation: plan.d2, maxBlock: stage1.maxOutput)
            } else {
                stage2 = nil
            }
            let s2Max = stage2?.maxOutput ?? stage1.maxOutput
            // Selectivity at r2 sets the channel bandwidth: transition ≤ half the cutoff, stopband
            // inside r2/2. Designed at the audio rate the tap budget buys real skirts for CW/SSB.
            let t3 = max(min(plan.r2 - 2 * plan.stage2CutoffHz, 0.5 * plan.stage2CutoffHz), 1)
            selectivity = FIRDecimator(taps: FIRDesign.lowPass(cutoffHz: plan.stage2CutoffHz, rate: plan.r2, transitionHz: t3,
                                                              maxTaps: FIRDesign.maxSelectivityTaps),
                                       decimation: 1, maxBlock: s2Max)
            maxOutput = s2Max
        } else {
            stage2 = nil
            selectivity = nil
            maxOutput = stage1.maxOutput
        }
        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        inRe = alloc(maxBlock); inIm = alloc(maxBlock); oscRe = alloc(maxBlock); oscIm = alloc(maxBlock)
        s1Re = alloc(stage1.maxOutput); s1Im = alloc(stage1.maxOutput)
        s2Re = alloc(maxOutput); s2Im = alloc(maxOutput)
        s3Re = alloc(maxOutput); s3Im = alloc(maxOutput)
    }

    deinit { for p in [inRe, inIm, oscRe, oscIm, s1Re, s1Im, s2Re, s2Im, s3Re, s3Im] { p.deallocate() } }

    /// NCO frequency for a channel: `−offset`, shifted by `−bw/2` (USB) / `+bw/2` (LSB) so the
    /// wanted sideband is centred at DC for the stage-2 low-pass. CW keeps the carrier at DC; the
    /// demodulator moves it to the 700 Hz BFO.
    package static func ncoFrequency(offsetHz: Int64, bandwidthHz: UInt32, mode: DemodMode) -> Double {
        let half = Double(bandwidthHz) / 2
        switch mode {
        case .usb: return -(Double(offsetHz) + half)
        case .lsb: return -(Double(offsetHz) - half)
        default: return -Double(offsetHz)
        }
    }

    /// Check that a channel of `bandwidthHz` at `offsetHz` fits inside ±captureRate/2.
    /// - Throws: `OFFSET_OUT_OF_CAPTURE`.
    package static func checkOffset(_ offsetHz: Int64, bandwidthHz: UInt32, captureRate: UInt64) throws {
        let half = Double(captureRate) / 2
        let edge = Double(bandwidthHz) / 2
        if Double(offsetHz) - edge < -half || Double(offsetHz) + edge > half {
            throw EngineError.offsetOutOfCapture(offsetHz, target: "")
        }
    }

    /// Move the channel within the capture. Phase-continuous; filters keep their history.
    /// Validation (`checkOffset`) is the caller's job — the Channel layer reports
    /// `OFFSET_OUT_OF_CAPTURE` before calling this.
    package func retune(offsetHz: Int64) {
        self.offsetHz = offsetHz
        nco.retune(frequencyHz: Channelizer.ncoFrequency(offsetHz: offsetHz, bandwidthHz: bandwidthHz, mode: mode))
    }

    /// Clear filter history and oscillator phase.
    package func reset() {
        nco.reset()
        stage1.reset()
        stage2?.reset()
        selectivity?.reset()
    }

    /// Mix, filter and decimate one block. `input` is interleaved cf32 (`count ≤ maxBlock`);
    /// `output` is interleaved cf32 with capacity ≥ `maxOutput`. Returns samples written.
    /// Hot path: no allocation, no locks.
    @discardableResult
    package func process(input: SampleBuffer, output: inout SampleBuffer) -> Int {
        precondition(input.format == .cf32 && output.format == .cf32)
        precondition(input.count <= maxBlock && output.count >= maxOutput)
        let n = input.count
        guard n > 0 else { return 0 }
        let src = input.base.assumingMemoryBound(to: Float.self)
        Kernels.deinterleave(src, re: inRe, im: inIm, count: n)
        nco.fill(cosOut: oscRe, sinOut: oscIm, count: n)
        Kernels.complexMultiply(aRe: inRe, aIm: inIm, bRe: oscRe, bIm: oscIm, outRe: inRe, outIm: inIm, count: n)
        let n1 = stage1.process(re: inRe, im: inIm, count: n, outRe: s1Re, outIm: s1Im)
        let dst = output.base.assumingMemoryBound(to: Float.self)
        guard let selectivity else {
            Kernels.interleave(re: s1Re, im: s1Im, to: dst, count: n1)
            return n1
        }
        var re = s1Re, im = s1Im, n2 = n1
        if let stage2 {
            n2 = stage2.process(re: s1Re, im: s1Im, count: n1, outRe: s2Re, outIm: s2Im)
            re = s2Re; im = s2Im
        }
        let n3 = selectivity.process(re: re, im: im, count: n2, outRe: s3Re, outIm: s3Im)
        Kernels.interleave(re: s3Re, im: s3Im, to: dst, count: n3)
        return n3
    }
}
