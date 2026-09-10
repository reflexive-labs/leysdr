// The hot-path half of a channel: channelizer → demodulator → squelch → sinks → meter.
// Owned by `DefaultChannelEngine`, driven by the capture's DSP thread. Everything in
// `process(block:at:)` is synchronous and allocation-free; configuration arrives by swapping the
// whole core (structural changes) or by atomics (squelch threshold, AGC).

import Foundation
import Synchronization

/// One telemetry record produced on the DSP thread and drained by the control plane.
public struct ChannelTelemetryRecord: Sendable {
    public enum Kind: UInt8, Sendable { case meter, squelch }
    public var kind: Kind
    public var time: SampleTime
    public var powerDBFS: Float
    public var snrDB: Float
    public var squelchOpen: Bool
    /// Summary of the transmission that just ended. Set on the close edge of a squelch record only;
    /// zero and NaN otherwise, because a transmission still in progress has neither a duration nor a
    /// final peak. Plain-old-data like the rest of the record: the ring copies it by value and a
    /// torn read is discarded, so no reference type may ever appear here.
    public var openSamples: UInt64 = 0
    public var peakSNRDB: Float = .nan
    public var peakPowerDBFS: Float = .nan
    /// What the listener hears over the meter interval, measured on the demodulated block rather
    /// than on the channel IQ: a strong unmodulated carrier is loud in `powerDBFS` and quiet here.
    /// NaN on a squelch record and before the first block; a raw-IQ channel has no audio and leaves
    /// both NaN, because there is nothing a listener would hear.
    public var audioDBFS: Float = .nan
    public var audioPeakDBFS: Float = .nan
}

/// Fixed-capacity telemetry ring plus a "poke" stream that wakes the drain task.
/// Producer: the DSP thread (`push`, allocation-free, lock-free). Consumer: one drain task.
///
/// Policy is drop-oldest: when the ring is full the producer evicts the oldest unread record
/// (advancing `head` with a CAS) and counts it in `dropped`, so a stalled consumer always sees the
/// newest readings instead of a stale prefix. Each slot carries a seqlock version (odd while being
/// written) so the consumer can detect a slot overwritten underneath it and retry; records are
/// plain-old-data, so a torn copy is harmless and simply discarded.
public final class ChannelTelemetryQueue: @unchecked Sendable {
    public let capacity: Int
    private let slots: UnsafeMutablePointer<ChannelTelemetryRecord>
    /// Per-slot seqlock versions: even = stable, odd = the producer is writing.
    private let versions: UnsafeMutablePointer<Atomic<UInt64>>
    private let head = Atomic<Int>(0)    // next slot to read (monotonic); advanced by CAS from either side
    private let tail = Atomic<Int>(0)    // next slot to write (monotonic); producer-owned
    private let droppedCount = Atomic<Int>(0)
    /// Yields once per push (buffering newest 1): the consumer drains everything on each wake.
    public let poke: AsyncStream<Void>
    private let pokeContinuation: AsyncStream<Void>.Continuation

    public init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
        slots = UnsafeMutablePointer<ChannelTelemetryRecord>.allocate(capacity: capacity)
        let zero = SampleTime(captureID: CaptureID(), sampleIndex: 0)
        slots.initialize(repeating: ChannelTelemetryRecord(kind: .meter, time: zero, powerDBFS: .nan, snrDB: .nan, squelchOpen: true), count: capacity)
        versions = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: capacity)
        for i in 0..<capacity { (versions + i).initialize(to: Atomic<UInt64>(0)) }
        (poke, pokeContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        versions.deinitialize(count: capacity)
        versions.deallocate()
        pokeContinuation.finish()
    }

    /// Cumulative count of records evicted (oldest first) because the queue was full.
    public var dropped: Int { droppedCount.load(ordering: .relaxed) }

    /// Producer side (DSP thread). Never blocks or allocates; evicts the oldest record when full.
    public func push(_ record: ChannelTelemetryRecord) {
        let t = tail.load(ordering: .relaxed)
        while true {
            let h = head.load(ordering: .acquiring)
            if t - h < capacity { break }
            // Full: claim the oldest slot by advancing head. A failed CAS means the consumer took it.
            if head.compareExchange(expected: h, desired: h + 1, ordering: .acquiringAndReleasing).exchanged {
                droppedCount.wrappingAdd(1, ordering: .relaxed)
            }
        }
        let idx = t % capacity
        let v = versions + idx
        v.pointee.wrappingAdd(1, ordering: .acquiringAndReleasing)   // odd: writing
        slots[idx] = record
        v.pointee.wrappingAdd(1, ordering: .releasing)               // even: stable
        tail.store(t + 1, ordering: .releasing)
        pokeContinuation.yield(())
    }

    /// Consumer side. Returns nil when empty. Retries when the producer evicts the slot mid-read.
    public func pop() -> ChannelTelemetryRecord? {
        while true {
            let h = head.load(ordering: .relaxed)
            let t = tail.load(ordering: .acquiring)
            guard t > h else { return nil }
            let idx = h % capacity
            let v = versions + idx
            let v1 = v.pointee.load(ordering: .acquiring)
            if v1 & 1 == 1 { continue }
            let r = slots[idx]
            atomicMemoryFence(ordering: .acquiring)
            let v2 = v.pointee.load(ordering: .relaxed)
            if v1 != v2 { continue }
            if head.compareExchange(expected: h, desired: h + 1, ordering: .acquiringAndReleasing).exchanged {
                return r
            }
        }
    }

    /// Ends the poke stream; the drain task exits after its final sweep.
    public func finish() { pokeContinuation.finish() }
}

/// Immutable-by-structure DSP core for one channel. Built on the control plane, run on the DSP
/// thread. Squelch threshold and AGC are adjustable in place through atomics; anything else
/// (offset, bandwidth, mode, capture rate) requires a new core.
public final class ChannelDSPCore: @unchecked Sendable {
    public let captureRate: UInt64
    public let config: ChannelConfig
    public let channelizer: Channelizer
    public let demodulator: any Demodulator
    private let amDemodulator: AMDemodulator?
    private let ssbDemodulator: SSBDemodulator?
    /// Rate of the audio handed to sinks (channelizer output rate, or WFM's decimated rate).
    public let audioRate: UInt32
    private let iqOut: SampleStorage
    private let audioOut: SampleStorage
    private var meter: PowerMeter
    private var squelch: Squelch
    private let squelchBits = Atomic<UInt32>(Float.nan.bitPattern)
    private let agcAuto = Atomic<Bool>(true)
    private let sinkLock = NSLock()
    private var sinks: [any AudioSink] = []
    private let telemetry: ChannelTelemetryQueue
    /// Channel-rate samples per `.meter` emission (100 ms).
    private let meterInterval: Int
    private var samplesSinceMeter = 0
    private let blocksProcessed = Atomic<UInt64>(0)
    private let squelchCloses = Atomic<UInt64>(0)

    /// - Throws: `INVALID_ARGUMENT`, `OFFSET_OUT_OF_CAPTURE`, `MODE_UNSUPPORTED` (from the demodulator).
    public init(captureRate: UInt64, config: ChannelConfig, telemetry: ChannelTelemetryQueue, maxBlock: Int = 16384) throws {
        self.captureRate = captureRate
        self.config = config
        self.telemetry = telemetry
        channelizer = try Channelizer(captureRate: captureRate, offsetHz: config.offsetHz, bandwidthHz: config.bandwidthHz,
                                      mode: config.mode, maxBlock: maxBlock)
        demodulator = DemodulatorFactory.make(mode: config.mode)
        amDemodulator = demodulator as? AMDemodulator
        ssbDemodulator = demodulator as? SSBDemodulator
        try demodulator.configure(inputRate: channelizer.outputRate, bandwidthHz: config.bandwidthHz)
        // Armed after configure, which is what decides the tapped rate, and never changed again for
        // the life of this core: a config change rebuilds it. That is what lets the DSP thread read
        // the reference without synchronisation.
        if config.subAudibleDetect, let src = demodulator as? SubAudibleSource, src.subAudibleRate > 0 {
            // Four seconds at the tapped rate: the drain runs many times a second, so this is slack,
            // not a buffer anyone is meant to fill.
            let ring = FloatRing(capacity: Int(src.subAudibleRate * 4))
            src.subAudibleTap = ring
            subAudibleTap = ring
            subAudibleRate = src.subAudibleRate
            subAudibleFullScale = src.fullScaleDeviationHz
        }
        audioRate = demodulator.outputRate
        iqOut = SampleStorage(capacity: channelizer.maxOutput, format: .cf32)
        audioOut = SampleStorage(capacity: channelizer.maxOutput, format: .f32)
        meter = PowerMeter(rate: channelizer.outputRateHz)
        squelch = Squelch(thresholdDB: Float(config.squelchDB))
        meterInterval = max(1, Int(channelizer.outputRateHz / 10))
        setSquelch(thresholdDB: config.squelchDB)
        setAGC(config.agc)
    }

    /// The sub-audible tap, when this channel asked for one. Read by the slow detection task; the
    /// DSP thread writes it through the demodulator and never looks at these.
    public private(set) var subAudibleTap: FloatRing?
    public private(set) var subAudibleRate: Double = 0
    public private(set) var subAudibleFullScale: Double = 0

    /// Audio energy accumulated since the last meter record, owned by the DSP thread alone. The sum
    /// is a Double because a 100 ms interval at 48 kHz is 4800 squares and Float would drift.
    private var audioSumSquares: Double = 0
    private var audioSamples: Int = 0
    private var audioPeak: Float = 0

    /// The transmission in progress, owned by the DSP thread alone. `openSamples` counts CAPTURE
    /// samples since the squelch opened -- the same rate `SampleTime` uses, which is the one a
    /// client already knows from the capture; the channel's own rate is not on the wire. The peaks
    /// are the loudest values seen in that interval. Reset on every open edge, drained on the close.
    private var openSamples: UInt64 = 0
    private var peakPowerDBFS: Float = .nan
    private var peakSNRDB: Float = .nan

    /// Blocks processed so far.
    public var blocks: UInt64 { blocksProcessed.load(ordering: .relaxed) }

    /// How many transmissions have ended: one per squelch close edge. The sub-audible task watches
    /// this to know the signal it has been measuring is over, so the phase history it carries is no
    /// longer a history of anything. A count rather than a flag because a whole transmission can
    /// come and go between two of that task's 50 ms polls.
    public var squelchCloseCount: UInt64 { squelchCloses.load(ordering: .relaxed) }

    /// Adjust the squelch threshold (dBFS, NaN = off) without rebuilding. Takes effect next block.
    public func setSquelch(thresholdDB: Double) {
        squelchBits.store(Float(thresholdDB).bitPattern, ordering: .relaxed)
    }

    /// Adjust AGC without rebuilding (AM and SSB/CW honour it; FM modes ignore it). Takes effect next block.
    public func setAGC(_ mode: GainMode) {
        agcAuto.store(mode == .auto, ordering: .relaxed)
    }

    /// Replace the sink table. The DSP thread copies the array reference under the lock once per block.
    public func setSinks(_ newSinks: [any AudioSink]) {
        sinkLock.lock()
        sinks = newSinks
        sinkLock.unlock()
    }

    /// Current sinks.
    public var currentSinks: [any AudioSink] {
        sinkLock.lock(); defer { sinkLock.unlock() }
        return sinks
    }

    /// Hot path. `block` is interleaved cf32 at the capture rate (count ≤ maxBlock); `time` is its
    /// start. Channelizes, demodulates, applies squelch (zeros when closed), writes to every sink
    /// and pushes meter/squelch telemetry. No allocation, no lock held across calls.
    public func process(block: SampleBuffer, at time: SampleTime) {
        let sp = Signpost.begin(.channelProcess)
        defer { Signpost.end(.channelProcess, sp) }
        var iq = iqOut.view()
        let n = channelizer.process(input: block, output: &iq)
        guard n > 0 else { return }
        iq.count = n
        let power = meter.measure(iq)
        squelch.thresholdDB = Float(bitPattern: squelchBits.load(ordering: .relaxed))
        // Track the transmission in progress: two compares, no branch on the common path. The block
        // that opens the squelch counts, so a short transmission is never measured as zero samples.
        if squelch.isOpen {
            openSamples &+= UInt64(block.count)
            if !(power <= peakPowerDBFS) { peakPowerDBFS = power }
            let snr = meter.snrDB
            if !(snr <= peakSNRDB) { peakSNRDB = snr }
        }
        if squelch.update(powerDB: power) {
            var rec = ChannelTelemetryRecord(kind: .squelch, time: time, powerDBFS: power, snrDB: meter.snrDB, squelchOpen: squelch.isOpen)
            if squelch.isOpen {
                // Opening: start a fresh interval. This block belongs to it.
                openSamples = UInt64(block.count)
                peakPowerDBFS = power
                peakSNRDB = meter.snrDB
            } else {
                rec.openSamples = openSamples
                rec.peakPowerDBFS = peakPowerDBFS
                rec.peakSNRDB = peakSNRDB
                openSamples = 0
                peakPowerDBFS = .nan
                peakSNRDB = .nan
                squelchCloses.wrappingAdd(1, ordering: .relaxed)
            }
            telemetry.push(rec)
        }
        let agcOn = agcAuto.load(ordering: .relaxed)
        if let am = amDemodulator { am.agcEnabled = agcOn }
        if let ssb = ssbDemodulator { ssb.agcEnabled = agcOn }
        var audio = audioOut.view()
        let dsp = Signpost.begin(.demodulate)
        var frames = demodulator.process(iq: iq, audioOut: &audio)
        Signpost.end(.demodulate, dsp)
        var out: SampleBuffer
        if config.mode == .rawIQ {
            // Raw IQ channels hand the channelized cf32 block to sinks unchanged.
            out = iq
            frames = n
        } else {
            audio.count = frames
            out = audio
        }
        if !squelch.isOpen, frames > 0 {
            Kernels.clear(out.base.assumingMemoryBound(to: Float.self), count: out.format == .cf32 ? frames * 2 : frames)
        }
        sinkLock.lock()
        let table = sinks
        sinkLock.unlock()
        if frames > 0 {
            for sink in table { sink.write(out, at: time) }
        }
        // Audio level over the meter interval. Two vDSP passes over the block that was just written
        // to the sinks, so the data is already in cache. Raw IQ has no audio to measure.
        if config.mode != .rawIQ, frames > 0 {
            let base = out.base.assumingMemoryBound(to: Float.self)
            audioSumSquares += Double(Kernels.meanSquare(base, count: frames)) * Double(frames)
            audioSamples += frames
            let peak = Kernels.maxMagnitude(base, count: frames)
            if peak > audioPeak { audioPeak = peak }
        }
        samplesSinceMeter += n
        if samplesSinceMeter >= meterInterval {
            samplesSinceMeter -= meterInterval
            var rec = ChannelTelemetryRecord(kind: .meter, time: time, powerDBFS: power, snrDB: meter.snrDB, squelchOpen: squelch.isOpen)
            if audioSamples > 0 {
                // Full scale is 1.0, so RMS 1.0 is 0 dBFS. A silent interval is -inf, which the
                // mapping layer floors; NaN stays NaN and means "not measured", which is different.
                let rms = (audioSumSquares / Double(audioSamples)).squareRoot()
                rec.audioDBFS = rms > 0 ? Float(20 * Foundation.log10(rms)) : -.infinity
                // log10f: audioPeak is a Float, and Darwin's overlay has no Float overload of log10.
                rec.audioPeakDBFS = audioPeak > 0 ? 20 * Foundation.log10f(audioPeak) : -.infinity
            }
            audioSumSquares = 0
            audioSamples = 0
            audioPeak = 0
            telemetry.push(rec)
        }
        blocksProcessed.wrappingAdd(1, ordering: .relaxed)
    }

    /// Start the channel over on a discontinuous stream: filter history, NCO phase, demodulator and
    /// noise floor go, and so does the transmission in progress -- its sample count and peaks
    /// describe the stream before the gap, and a duration that spans dead air is a lie about the
    /// air. Call it only while no block is in flight (the device is stopped and the DSP thread
    /// drained); the state it touches belongs to the DSP thread.
    public func reset() {
        channelizer.reset()
        demodulator.reset()
        meter.reset()
        samplesSinceMeter = 0
        squelch = Squelch(thresholdDB: squelch.thresholdDB)
        openSamples = 0
        peakPowerDBFS = .nan
        peakSNRDB = .nan
        audioSumSquares = 0
        audioSamples = 0
        audioPeak = 0
    }
}
