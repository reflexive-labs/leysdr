// Demodulators (docs/engine-internals.md, "Demodulators"). `configure` allocates all scratch;
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

/// Default scratch size: one full capture block, which is the most any channel can hand a demodulator.
let demodulatorMaxBlock = 16384

/// Narrow-band FM: discriminator (±5 kHz → ±0.5), 1-pole audio LPF ≈ 4 kHz, no de-emphasis, output clipped to ±1.
public final class NFMDemodulator: Demodulator {
    public let mode: DemodMode = .nfm
    public private(set) var outputRate: UInt32 = 0
    public let maxBlock = demodulatorMaxBlock
    private var scratch: DemodScratch?
    private var scale: Float = 0
    private var lpfCoefficient: Float = 1
    private var lpfState: Float = 0

    public init() {}

    public func configure(inputRate: UInt32, bandwidthHz: UInt32) throws {
        guard inputRate > 0 else { throw EngineError.invalidArgument("inputRate must be > 0") }
        outputRate = inputRate
        scale = Float(0.5 * Double(inputRate) / (2 * Double.pi * 5_000))
        lpfCoefficient = Kernels.onePoleCoefficient(cutoffHz: 4_000, rate: Double(inputRate))
        if scratch == nil { scratch = DemodScratch(maxBlock: maxBlock) }
        reset()
    }

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int {
        guard let s = scratch, input.count > 0 else { return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock && output.count >= input.count)
        let n = s.load(input)
        discriminate(s, count: n, scale: scale)
        let out = output.base.assumingMemoryBound(to: Float.self)
        Kernels.onePoleLowPass(s.real, to: out, count: n, coefficient: lpfCoefficient, state: &lpfState)
        // Unsquelched noise produces uniform ±π phase steps (≈ ±2.4 after scaling): hard-limit to full scale.
        Kernels.clip(out, lo: -1, hi: 1, to: out, count: n)
        return n
    }

    public func reset() {
        scratch?.reset()
        lpfState = 0
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
    private var scratch: DemodScratch?
    private var audioFilter: RealFIRDecimator?
    private var scale: Float = 0
    private var deemphasisCoefficient: Float = 1
    private var deemphasisState: Float = 0

    public init() {}

    public func configure(inputRate: UInt32, bandwidthHz: UInt32) throws {
        guard inputRate > 0 else { throw EngineError.invalidArgument("inputRate must be > 0") }
        let rate = Double(inputRate)
        decimation = max(1, Int((rate / 48_000).rounded()))
        outputRate = UInt32((rate / Double(decimation)).rounded())
        scale = Float(0.5 * rate / (2 * Double.pi * 75_000))
        deemphasisCoefficient = Float(1 - exp(-1 / (rate * 75e-6)))
        let audioRate = rate / Double(decimation)
        let cutoff = min(15_000, 0.45 * audioRate)
        let transition = max(audioRate - 2 * cutoff, 0.1 * audioRate)
        audioFilter = RealFIRDecimator(taps: FIRDesign.lowPass(cutoffHz: cutoff, rate: rate, transitionHz: transition),
                                       decimation: decimation, maxBlock: maxBlock)
        if scratch == nil { scratch = DemodScratch(maxBlock: maxBlock) }
        reset()
    }

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int {
        guard let s = scratch, let filter = audioFilter, input.count > 0 else { return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock)
        precondition(output.count >= (input.count + decimation - 1) / decimation)
        let n = s.load(input)
        discriminate(s, count: n, scale: scale)
        Kernels.onePoleLowPass(s.real, to: s.real, count: n, coefficient: deemphasisCoefficient, state: &deemphasisState)
        let out = output.base.assumingMemoryBound(to: Float.self)
        let produced = filter.process(s.real, count: n, out: out)
        Kernels.clip(out, lo: -1, hi: 1, to: out, count: produced)
        return produced
    }

    public func reset() {
        scratch?.reset()
        audioFilter?.reset()
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

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int {
        guard let s = scratch, input.count > 0 else { return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock && output.count >= input.count)
        let n = s.load(input)
        let out = output.base.assumingMemoryBound(to: Float.self)
        Kernels.magnitude(re: s.workRe + 1, im: s.workIm + 1, to: s.real, count: n)
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

    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int {
        guard let s = scratch, let bfo, input.count > 0 else { return 0 }
        precondition(input.format == .cf32 && output.format == .f32 && input.count <= maxBlock && output.count >= input.count)
        let n = s.load(input)
        bfo.fill(cosOut: oscRe, sinOut: oscIm, count: n)
        // Real part of x · e^{jωt} = re·cos − im·sin.
        let out = output.base.assumingMemoryBound(to: Float.self)
        Kernels.multiply(s.workRe + 1, oscRe, to: s.tmpRe, count: n)
        Kernels.multiply(s.workIm + 1, oscIm, to: s.tmpIm, count: n)
        Kernels.scaleAdd(s.tmpIm, scale: -1, offset: 0, to: s.tmpIm, count: n)
        Kernels.add(s.tmpRe, s.tmpIm, to: out, count: n)
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
    public func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int { 0 }
    public func reset() {}
}

/// Builds the demodulator for a mode. Every `DemodMode` is available.
public enum DemodulatorFactory {
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
