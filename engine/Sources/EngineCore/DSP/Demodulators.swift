// SPDX-License-Identifier: GPL-3.0-or-later

// Demodulators (docs/dev/engine-internals.md, "Demodulators"). `configure` allocates all scratch;
// `process` is the hot path — kernels only, no allocation, no locks.

import Foundation

/// Scratch every demodulator shares: split-complex copies of the input plus one sample of history.
/// `work[0]` holds the previous block's last sample so `work[1...]` is the current block.
final class DemodScratch {
    let maxBlock: Int
    let workRe, workIm, tmpRe, tmpIm, real: UnsafeMutablePointer<Float>

    init(maxBlock: Int) {
        self.maxBlock = maxBlock
        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        workRe = alloc(maxBlock + 1); workIm = alloc(maxBlock + 1)
        tmpRe = alloc(maxBlock); tmpIm = alloc(maxBlock); real = alloc(maxBlock)
    }

    deinit { for p in [workRe, workIm, tmpRe, tmpIm, real] { p.deallocate() } }

    /// Deinterleave `input` into `work[1...]`, keeping `work[0]` as the previous sample.
    @inline(__always) func load(_ input: SampleBuffer) -> Int {
        let n = input.count
        Kernels.deinterleave(input.base.assumingMemoryBound(to: Float.self), re: workRe + 1, im: workIm + 1, count: n)
        return n
    }

    /// Carry the last sample of this block into `work[0]` for the next call.
    @inline(__always) func carry(_ n: Int) {
        workRe[0] = workRe[n]
        workIm[0] = workIm[n]
    }

    func reset() {
        workRe[0] = 0
        workIm[0] = 0
    }
}

/// Quadrature discriminator shared by NFM and WFM: `arg(x[n]·conj(x[n−1]))` scaled so
/// `±deviation` reads `±0.5`, into `scratch.real`.
@inline(__always)
func discriminate(_ s: DemodScratch, count n: Int, scale: Float) {
    Kernels.complexMultiply(aRe: s.workRe + 1, aIm: s.workIm + 1, bRe: s.workRe, bIm: s.workIm,
                            outRe: s.tmpRe, outIm: s.tmpIm, count: n, conjugateB: true)
    Kernels.atan2(y: s.tmpIm, x: s.tmpRe, to: s.real, count: n)
    Kernels.scaleAdd(s.real, scale: scale, offset: 0, to: s.real, count: n)
    s.carry(n)
}

/// Hand a demodulator's raw stage to a caller that asked for one: `count` samples from `src`, and
/// the count reported back on the buffer. Hot path, and nothing at all when `rawOut` is nil.
@inline(__always)
func emitRaw(_ rawOut: inout SampleBuffer?, from src: UnsafePointer<Float>, count n: Int) {
    guard let raw = rawOut else { return }
    precondition(raw.format == .f32 && raw.count >= n)
    raw.base.assumingMemoryBound(to: Float.self).update(from: src, count: n)
    rawOut?.count = n
}

/// Default scratch size: one full capture block, which is the most any channel can hand a demodulator.
let demodulatorMaxBlock = 16384

/// Narrow-band FM: discriminator (full-scale deviation → ±1.0), 300 Hz two-pole high-pass (removes
/// CTCSS/PL tones and any DC offset), 6 dB/octave de-emphasis above 300 Hz (τ ≈ 530 µs, the TIA-603
/// voice response; transmitters pre-emphasize) with ×2 make-up gain, 1-pole LPF ≈ 4 kHz, output clipped to ±1.
public final class NFMDemodulator: Demodulator, SubAudibleSource {
    public let mode: DemodMode = .nfm
    public private(set) var outputRate: UInt32 = 0
    /// Full scale is what the channel itself can carry, not one fixed number: a 12.5 kHz channel
    /// holds ±2.5 kHz of deviation and a 25 kHz one the ±5 kHz a wide NFM transmitter sends, so a
    /// narrow radio fills the trace and plays as loudly as a wide one instead of sitting at a
    /// quarter scale. Clamped either side because a channel narrower or wider than the pair of
    /// standard spacings is still listened to as one of them.
    public static func fullScaleDeviation(bandwidthHz: UInt32) -> Double {
        Swift.min(5000, Swift.max(2500, Double(bandwidthHz) / 5))
    }

    /// The deviation `discriminate` puts at ±1.0. Set from the channel's bandwidth by `configure`.
    public private(set) var fullScaleDeviationHz: Double = 5000
    /// Set once when the channel is built, before any block is processed.
    public var subAudibleTap: FloatRing?
    public private(set) var subAudibleRate: Double = 0
    /// Two decimation stages from the channel rate down to roughly 1 kHz. Two rather than one
    /// boxcar: nothing anti-aliases a boxcar, so voice near 1.3 kHz folds straight into the
    /// 60-300 Hz band at about -13 dB and fabricates tone energy out of speech.
    private var subStage1: RealFIRDecimator?
    private var subStage2: RealFIRDecimator?
    private var subScratch1: UnsafeMutablePointer<Float>?
    private var subScratch2: UnsafeMutablePointer<Float>?
    private var subCapacity = 0
    public let maxBlock = demodulatorMaxBlock
    private var scratch: DemodScratch?
    private var scale: Float = 0
    private var lpfCoefficient: Float = 1
    private var lpfState: Float = 0
    /// High-pass: y[n] = a·(y[n−1] + x[n] − x[n−1]), two cascaded stages (≈ 12 dB/oct; −20 dB at 100 Hz).
    private var hpfCoefficient: Float = 0
    private var hpfPrevIn: (Float, Float) = (0, 0)
    private var hpfPrevOut: (Float, Float) = (0, 0)
    /// De-emphasis: one-pole low-pass at 300 Hz followed by ×2 make-up gain (unity near 520 Hz).
    private var deemphasisCoefficient: Float = 1
    private var deemphasisState: Float = 0
    private static let deemphasisMakeup: Float = 2

    public init() {}

    deinit {
        subScratch1?.deallocate()
        subScratch2?.deallocate()
    }

    public func configure(inputRate: UInt32, bandwidthHz: UInt32) throws {
        guard inputRate > 0 else { throw EngineError.invalidArgument("inputRate must be > 0") }
        outputRate = inputRate
        fullScaleDeviationHz = Self.fullScaleDeviation(bandwidthHz: bandwidthHz)
        scale = Float(1.0 * Double(inputRate) / (2 * Double.pi * fullScaleDeviationHz))
        lpfCoefficient = Kernels.onePoleCoefficient(cutoffHz: 4_000, rate: Double(inputRate))
        let rc = 1 / (2 * Double.pi * 300)
        hpfCoefficient = Float(rc / (rc + 1 / Double(inputRate)))
        deemphasisCoefficient = Kernels.onePoleCoefficient(cutoffHz: 300, rate: Double(inputRate))
        if scratch == nil { scratch = DemodScratch(maxBlock: maxBlock) }
        configureSubAudible(inputRate: Double(inputRate))
        reset()
    }

    /// Build the sub-audible decimation chain for this channel rate. Called from `configure`, never
    /// from the DSP thread: every allocation the tap needs happens here.
    ///
    /// The exact decimated rate is carried as a Double and never assumed: the channel runs at
    /// 48 kHz from a 2.4 MSPS capture but 51.2 kHz from a 2.048 MSPS one, and a detector told the
    /// wrong rate measures the wrong frequency.
    private func configureSubAudible(inputRate: Double) {
        subStage1 = nil
        subStage2 = nil
        subScratch1?.deallocate()
        subScratch2?.deallocate()
        subScratch1 = nil
        subScratch2 = nil
        subAudibleRate = 0
        let total = Int((inputRate / 1000).rounded())
        guard total >= 2 else { return }
        // Split the work: a single stage from 48 kHz to 1 kHz would need hundreds of taps for a
        // 300 Hz transition, where two cheap stages do the same job.
        var d2 = 4
        while d2 > 1, total % d2 != 0 { d2 -= 1 }
        let d1 = total / d2
        let mid = inputRate / Double(d1)
        let taps1 = FIRDesign.lowPass(cutoffHz: 0.4 * mid / 2, rate: inputRate, transitionHz: 0.2 * mid / 2)
        subStage1 = RealFIRDecimator(taps: taps1, decimation: d1, maxBlock: maxBlock)
        subCapacity = maxBlock / d1 + 8
        subScratch1 = UnsafeMutablePointer<Float>.allocate(capacity: subCapacity)
        subScratch1?.initialize(repeating: 0, count: subCapacity)
        if d2 > 1 {
            let taps2 = FIRDesign.lowPass(cutoffHz: 320, rate: mid, transitionHz: 120)
            subStage2 = RealFIRDecimator(taps: taps2, decimation: d2, maxBlock: subCapacity)
            subScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: subCapacity)
            subScratch2?.initialize(repeating: 0, count: subCapacity)
        }
        subAudibleRate = inputRate / Double(d1 * d2)
    }

    /// Decimate the discriminator output into the tap. Hot path: no allocation, no locks, and a
    /// single nil check when nobody is listening.
    private func tapSubAudible(_ src: UnsafePointer<Float>, count: Int) {
        guard let ring = subAudibleTap, let s1 = subStage1, let buf1 = subScratch1 else { return }
        let n1 = s1.process(src, count: count, out: buf1)
        guard n1 > 0 else { return }
        if let s2 = subStage2, let buf2 = subScratch2 {
            let n2 = s2.process(buf1, count: n1, out: buf2)
            if n2 > 0 { ring.push(UnsafeBufferPointer(start: buf2, count: n2)) }
        } else {
            ring.push(UnsafeBufferPointer(start: buf1, count: n1))
        }
    }

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer, rawOut: inout SampleBuffer?) -> Int {
        guard let s = scratch, input.count > 0 else { rawOut?.count = 0; return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock && output.count >= input.count)
        let n = s.load(input)
        discriminate(s, count: n, scale: scale)
        // Both taps come before every stage that follows: the 300 Hz high-pass below is what makes
        // CTCSS inaudible, and it is the reason this has to be taken here rather than off the audio.
        tapSubAudible(s.real, count: n)
        emitRaw(&rawOut, from: s.real, count: n)
        let out = output.base.assumingMemoryBound(to: Float.self)
        Kernels.onePoleLowPass(s.real, to: out, count: n, coefficient: lpfCoefficient, state: &lpfState)
        highPass(out, count: n)
        Kernels.onePoleLowPass(out, to: out, count: n, coefficient: deemphasisCoefficient, state: &deemphasisState)
        Kernels.scaleAdd(out, scale: Self.deemphasisMakeup, offset: 0, to: out, count: n)
        // Unsquelched noise produces uniform ±π phase steps (≈ ±4.8 after scaling): hard-limit to full scale.
        Kernels.clip(out, lo: -1, hi: 1, to: out, count: n)
        return n
    }

    /// In-place two-stage one-pole high-pass. Plain loop: allocation-free and trivially cheap at audio rate.
    private func highPass(_ x: UnsafeMutablePointer<Float>, count n: Int) {
        let a = hpfCoefficient
        var (pi0, pi1) = hpfPrevIn
        var (po0, po1) = hpfPrevOut
        for i in 0..<n {
            let x0 = x[i]
            let y0 = a * (po0 + x0 - pi0)
            pi0 = x0; po0 = y0
            let y1 = a * (po1 + y0 - pi1)
            pi1 = y0; po1 = y1
            x[i] = y1
        }
        hpfPrevIn = (pi0, pi1)
        hpfPrevOut = (po0, po1)
    }

    public func reset() {
        scratch?.reset()
        lpfState = 0
        hpfPrevIn = (0, 0)
        hpfPrevOut = (0, 0)
        deemphasisState = 0
        subStage1?.reset()
        subStage2?.reset()
    }
}

/// Wide-band FM (mono): discriminator at `r1` (±75 kHz → ±0.5), 75 µs de-emphasis,
/// FIR LPF 15 kHz + decimate by `round(r1 / 48 kHz)`, output clipped to ±1.
public final class WFMDemodulator: Demodulator {
    public let mode: DemodMode = .wfm
    public private(set) var outputRate: UInt32 = 0
    public let maxBlock = demodulatorMaxBlock
    /// Audio decimation factor chosen at configure time.
    public private(set) var decimation = 1
    /// Broadcast FM is ±75 kHz by regulation, so full scale does not follow the channel the way
    /// NFM's does.
    public static let fullScaleDeviationHz: Double = 75_000
    private var scratch: DemodScratch?
    private var audioFilter: RealFIRDecimator?
    /// Decimation for the raw tap, which keeps everything the audio filter throws away above
    /// 15 kHz -- the 19 kHz stereo pilot most of all -- and so cannot share the audio filter.
    private var rawFilter: RealFIRDecimator?
    /// Whether the raw tap was filled on the previous block: an idle filter holds history from
    /// whenever it last ran, and that is not history of the block about to be tapped.
    private var rawActive = false
    private var scale: Float = 0
    private var deemphasisCoefficient: Float = 1
    private var deemphasisState: Float = 0

    public init() {}

    public func configure(inputRate: UInt32, bandwidthHz: UInt32) throws {
        guard inputRate > 0 else { throw EngineError.invalidArgument("inputRate must be > 0") }
        let rate = Double(inputRate)
        decimation = max(1, Int((rate / 48_000).rounded()))
        outputRate = UInt32((rate / Double(decimation)).rounded())
        scale = Float(0.5 * rate / (2 * Double.pi * Self.fullScaleDeviationHz))
        deemphasisCoefficient = Float(1 - exp(-1 / (rate * 75e-6)))
        let audioRate = rate / Double(decimation)
        let cutoff = min(15_000, 0.45 * audioRate)
        let transition = max(audioRate - 2 * cutoff, 0.1 * audioRate)
        audioFilter = RealFIRDecimator(taps: FIRDesign.lowPass(cutoffHz: cutoff, rate: rate, transitionHz: transition),
                                       decimation: decimation, maxBlock: maxBlock)
        rawFilter = RealFIRDecimator(taps: FIRDesign.lowPass(cutoffHz: 0.45 * audioRate, rate: rate, transitionHz: 0.1 * audioRate),
                                     decimation: decimation, maxBlock: maxBlock)
        if scratch == nil { scratch = DemodScratch(maxBlock: maxBlock) }
        reset()
    }

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer, rawOut: inout SampleBuffer?) -> Int {
        guard let s = scratch, let filter = audioFilter, input.count > 0 else { rawOut?.count = 0; return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock)
        precondition(output.count >= (input.count + decimation - 1) / decimation)
        let n = s.load(input)
        discriminate(s, count: n, scale: scale)
        emitRawTap(&rawOut, from: s.real, count: n)
        Kernels.onePoleLowPass(s.real, to: s.real, count: n, coefficient: deemphasisCoefficient, state: &deemphasisState)
        let out = output.base.assumingMemoryBound(to: Float.self)
        let produced = filter.process(s.real, count: n, out: out)
        Kernels.clip(out, lo: -1, hi: 1, to: out, count: produced)
        return produced
    }

    /// Decimate the discriminator into the raw tap, ahead of the de-emphasis and the 15 kHz
    /// low-pass the audio path applies next, and scaled so ±75 kHz deviation reads ±1.0 as it does
    /// for NFM. The tap reports its own frame count: its decimator runs only while someone is
    /// listening, so its phase is its own.
    @inline(__always)
    private func emitRawTap(_ rawOut: inout SampleBuffer?, from src: UnsafePointer<Float>, count n: Int) {
        guard let raw = rawOut, let filter = rawFilter else {
            rawOut?.count = 0
            rawActive = false
            return
        }
        precondition(raw.format == .f32 && raw.count >= (n + decimation - 1) / decimation)
        if !rawActive { filter.reset() }
        rawActive = true
        let dst = raw.base.assumingMemoryBound(to: Float.self)
        let produced = filter.process(src, count: n, out: dst)
        Kernels.scaleAdd(dst, scale: 2, offset: 0, to: dst, count: produced)
        rawOut?.count = produced
    }

    public func reset() {
        scratch?.reset()
        audioFilter?.reset()
        rawFilter?.reset()
        rawActive = false
        deemphasisState = 0
    }
}

/// Slow-envelope AGC shared by AM and SSB/CW (channel `agc == .auto`): tracks a per-block level with a
/// fast attack (half-way per block) and slow release (≈ 80 ms), and returns the gain that brings the
/// envelope to `target`, clamped to 1000 so silence does not explode. Allocation-free.
public struct EnvelopeAGC {
    /// Target level after AGC (linear, relative to full scale).
    public var target: Float = 0.5
    /// Maximum gain applied (linear).
    public var maxGain: Float = 1_000
    private var releaseCoefficient: Float = 1
    private var envelope: Float = 0

    public init() {}

    /// Set the release time constant (`cutoffHz` ≈ 2 Hz → ≈ 80 ms) for `rate` samples per second.
    public mutating func configure(rate: Double, releaseCutoffHz: Double = 2) {
        releaseCoefficient = Kernels.onePoleCoefficient(cutoffHz: releaseCutoffHz, rate: rate)
        envelope = 0
    }

    public mutating func reset() { envelope = 0 }

    /// Update the envelope with one block's measured `level` (`count` samples) and return the gain to apply.
    @inline(__always)
    public mutating func gain(level: Float, count: Int) -> Float {
        let a: Float = level > envelope ? 0.5 : min(1, releaseCoefficient * Float(count))
        envelope += a * (level - envelope)
        return envelope > 1e-4 ? min(target / envelope, maxGain) : 1
    }
}

/// AM envelope detector: `|x|`, DC block (1-pole HPF ≈ 50 Hz), audio LPF ≈ 5 kHz, slow-envelope AGC.
public final class AMDemodulator: Demodulator {
    public let mode: DemodMode = .am
    public private(set) var outputRate: UInt32 = 0
    public let maxBlock = demodulatorMaxBlock
    /// Normalise output by a slow envelope of the carrier level (channel `agc == .auto`).
    public var agcEnabled = true
    /// Target carrier level after AGC (linear, relative to full scale).
    public var agcTarget: Float {
        get { agc.target }
        set { agc.target = newValue }
    }
    private var agc = EnvelopeAGC()
    private var scratch: DemodScratch?
    private var dcCoefficient: Float = 1
    private var dcState: Float = 0
    private var lpfCoefficient: Float = 1
    private var lpfState: Float = 0

    public init() {}

    public func configure(inputRate: UInt32, bandwidthHz: UInt32) throws {
        guard inputRate > 0 else { throw EngineError.invalidArgument("inputRate must be > 0") }
        outputRate = inputRate
        let rate = Double(inputRate)
        dcCoefficient = Kernels.onePoleCoefficient(cutoffHz: 50, rate: rate)
        lpfCoefficient = Kernels.onePoleCoefficient(cutoffHz: min(5_000, 0.45 * rate), rate: rate)
        agc.configure(rate: rate) // ≈ 80 ms release
        if scratch == nil { scratch = DemodScratch(maxBlock: maxBlock) }
        reset()
    }

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer, rawOut: inout SampleBuffer?) -> Int {
        guard let s = scratch, input.count > 0 else { rawOut?.count = 0; return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock && output.count >= input.count)
        let n = s.load(input)
        let out = output.base.assumingMemoryBound(to: Float.self)
        Kernels.magnitude(re: s.workRe + 1, im: s.workIm + 1, to: s.real, count: n)
        // The envelope as the detector produced it: the carrier is still in it as DC, which is what
        // makes the raw tap show a tuning-independent carrier level where the audio shows none.
        emitRaw(&rawOut, from: s.real, count: n)
        // Carrier level = low-passed magnitude (this is also the DC estimate the HPF subtracts).
        Kernels.onePoleLowPass(s.real, to: s.tmpRe, count: n, coefficient: dcCoefficient, state: &dcState)
        // Slow envelope of the carrier level; fast attack means a steady carrier settles within a few blocks.
        let gain: Float = agcEnabled ? agc.gain(level: Kernels.mean(s.tmpRe, count: n), count: n) : 1
        for i in 0 ..< n { s.real[i] = (s.real[i] - s.tmpRe[i]) * gain }
        Kernels.onePoleLowPass(s.real, to: out, count: n, coefficient: lpfCoefficient, state: &lpfState)
        return n
    }

    public func reset() {
        scratch?.reset()
        dcState = 0; lpfState = 0
        agc.reset()
    }
}

/// Product detector for USB/LSB/CW. The channelizer centres the wanted sideband at DC; this mixes
/// it back by `∓bw/2` (CW: to a 700 Hz BFO), takes the real part, and (channel `agc == .auto`)
/// normalises by a slow envelope of the channel IQ magnitude — the same AGC shape as AM.
public final class SSBDemodulator: Demodulator {
    /// CW beat-frequency oscillator.
    public static let cwBFOHz: Double = 700
    public let mode: DemodMode
    public private(set) var outputRate: UInt32 = 0
    public let maxBlock = demodulatorMaxBlock
    /// Normalise output by a slow envelope of the signal level (channel `agc == .auto`).
    public var agcEnabled = true
    /// Target audio level after AGC (linear, relative to full scale).
    public var agcTarget: Float {
        get { agc.target }
        set { agc.target = newValue }
    }
    private var agc = EnvelopeAGC()
    private var scratch: DemodScratch?
    private var bfo: NCO?
    private var oscRe, oscIm: UnsafeMutablePointer<Float>

    public init(mode: DemodMode) {
        precondition(mode == .usb || mode == .lsb || mode == .cw)
        self.mode = mode
        oscRe = UnsafeMutablePointer<Float>.allocate(capacity: demodulatorMaxBlock)
        oscIm = UnsafeMutablePointer<Float>.allocate(capacity: demodulatorMaxBlock)
    }

    deinit { oscRe.deallocate(); oscIm.deallocate() }

    /// Mix-back frequency for the mode: `+bw/2` (USB), `−bw/2` (LSB), `+700` (CW).
    public static func mixFrequency(mode: DemodMode, bandwidthHz: UInt32) -> Double {
        switch mode {
        case .usb: return Double(bandwidthHz) / 2
        case .lsb: return -Double(bandwidthHz) / 2
        default: return cwBFOHz
        }
    }

    public func configure(inputRate: UInt32, bandwidthHz: UInt32) throws {
        guard inputRate > 0 else { throw EngineError.invalidArgument("inputRate must be > 0") }
        outputRate = inputRate
        bfo = NCO(rate: Double(inputRate), frequencyHz: SSBDemodulator.mixFrequency(mode: mode, bandwidthHz: bandwidthHz), maxBlock: maxBlock)
        agc.configure(rate: Double(inputRate)) // ≈ 80 ms release
        if scratch == nil { scratch = DemodScratch(maxBlock: maxBlock) }
        reset()
    }

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer, rawOut: inout SampleBuffer?) -> Int {
        guard let s = scratch, let bfo, input.count > 0 else { rawOut?.count = 0; return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock && output.count >= input.count)
        let n = s.load(input)
        bfo.fill(cosOut: oscRe, sinOut: oscIm, count: n)
        // Real part of x · e^{jωt} = re·cos − im·sin.
        let out = output.base.assumingMemoryBound(to: Float.self)
        Kernels.multiply(s.workRe + 1, oscRe, to: s.tmpRe, count: n)
        Kernels.multiply(s.workIm + 1, oscIm, to: s.tmpIm, count: n)
        Kernels.scaleAdd(s.tmpIm, scale: -1, offset: 0, to: s.tmpIm, count: n)
        Kernels.add(s.tmpRe, s.tmpIm, to: out, count: n)
        // Before AGC: the raw tap carries the signal at the level it arrived at.
        emitRaw(&rawOut, from: out, count: n)
        if agcEnabled {
            // Block level = mean |x| of the channel IQ (a tone's |x| is its amplitude); the envelope's
            // attack/release smooths it. Clip after gain so a release-phase overshoot stays in range.
            Kernels.magnitude(re: s.workRe + 1, im: s.workIm + 1, to: s.real, count: n)
            let gain = agc.gain(level: Kernels.mean(s.real, count: n), count: n)
            Kernels.scaleAdd(out, scale: gain, offset: 0, to: out, count: n)
            Kernels.clip(out, lo: -1, hi: 1, to: out, count: n)
        }
        s.carry(n)
        return n
    }

    public func reset() {
        scratch?.reset()
        bfo?.reset()
        agc.reset()
    }
}

/// No demodulation: channel IQ goes to taps/stream sinks only. `process` produces no audio.
public final class RawIQDemodulator: Demodulator {
    public let mode: DemodMode = .rawIQ
    public private(set) var outputRate: UInt32 = 0
    public let maxBlock = demodulatorMaxBlock
    public init() {}
    public func configure(inputRate: UInt32, bandwidthHz: UInt32) throws { outputRate = inputRate }
    /// No detector, so no raw stage either: `rawOut` comes back empty rather than stale.
    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer, rawOut: inout SampleBuffer?) -> Int {
        rawOut?.count = 0
        return 0
    }

    public func reset() {}
}

/// Builds the demodulator for a mode. Every `DemodMode` is available.
public enum DemodulatorFactory {
    /// What ±1.0 on a demodulated sample stands for, in hertz of deviation, for the FM modes;
    /// 0 for the amplitude modes, whose samples are a level rather than a frequency. The daemon
    /// answers this in the audio descriptor so a client reads hertz off a tap without hard-coding
    /// a full scale of its own.
    public static func fullScaleDeviationHz(mode: DemodMode, bandwidthHz: UInt32) -> Double {
        switch mode {
        case .nfm: return NFMDemodulator.fullScaleDeviation(bandwidthHz: bandwidthHz)
        case .wfm: return WFMDemodulator.fullScaleDeviationHz
        case .am, .usb, .lsb, .cw, .rawIQ: return 0
        }
    }

    public static func make(mode: DemodMode) -> any Demodulator {
        switch mode {
        case .nfm: return NFMDemodulator()
        case .wfm: return WFMDemodulator()
        case .am: return AMDemodulator()
        case .usb, .lsb, .cw: return SSBDemodulator(mode: mode)
        case .rawIQ: return RawIQDemodulator()
        }
    }
}

/// Per-block power meter: mean power of a cf32 block in dBFS plus a running-minimum noise floor
/// over a 5 s window (two half-window buckets). `snrDB` is NaN until 1 s of data has been seen.
public struct PowerMeter {
    public let rate: Double
    /// Samples per half-window (window = 5 s).
    private let bucketLength: UInt64
    private var bucketSamples: UInt64 = 0
    private var totalSamples: UInt64 = 0
    private var currentMin: Float = .infinity
    private var previousMin: Float = .infinity
    /// Most recent block power (dBFS); NaN before the first block.
    public private(set) var powerDBFS: Float = .nan

    public init(rate: Double, windowSeconds: Double = 5) {
        self.rate = rate
        bucketLength = max(1, UInt64(rate * windowSeconds / 2))
    }

    /// Running-minimum block power (dBFS) over the window; `+inf` before any block.
    public var floorDBFS: Float { min(currentMin, previousMin) }

    /// `power − floor` in dB; NaN until 1 s of samples has been measured.
    public var snrDB: Float {
        guard Double(totalSamples) >= rate else { return .nan }
        return powerDBFS - floorDBFS
    }

    /// Measure one interleaved cf32 block. Allocation-free. Returns the block power in dBFS.
    @discardableResult
    public mutating func measure(_ block: SampleBuffer) -> Float {
        precondition(block.format == .cf32)
        let n = block.count
        guard n > 0 else { return powerDBFS }
        let p = block.base.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for i in 0 ..< n { sum += p[2 * i] * p[2 * i] + p[2 * i + 1] * p[2 * i + 1] }
        let mean = sum / Float(n)
        let db = mean > 0 ? 10 * log10f(mean) : -200
        powerDBFS = db
        totalSamples &+= UInt64(n)
        bucketSamples &+= UInt64(n)
        if bucketSamples >= bucketLength {
            previousMin = currentMin
            currentMin = .infinity
            bucketSamples = 0
        }
        if db < currentMin { currentMin = db }
        return db
    }

    public mutating func reset() {
        bucketSamples = 0; totalSamples = 0
        currentMin = .infinity; previousMin = .infinity
        powerDBFS = .nan
    }
}

/// Squelch with 2 dB hysteresis: opens when power > threshold, closes when power < threshold − 2 dB.
/// A NaN threshold means "always open".
public struct Squelch: Hashable, Sendable {
    public static let hysteresisDB: Float = 2
    public var thresholdDB: Float
    public private(set) var isOpen: Bool

    public init(thresholdDB: Float) {
        self.thresholdDB = thresholdDB
        isOpen = thresholdDB.isNaN
    }

    /// Feed one block's power. Returns true if the open/closed state changed.
    @discardableResult
    public mutating func update(powerDB: Float) -> Bool {
        let was = isOpen
        if thresholdDB.isNaN {
            isOpen = true
        } else if isOpen {
            if powerDB < thresholdDB - Squelch.hysteresisDB { isOpen = false }
        } else if powerDB > thresholdDB {
            isOpen = true
        }
        return was != isOpen
    }
}
