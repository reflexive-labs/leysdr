// SPDX-License-Identifier: GPL-3.0-or-later

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
    /// Audio output level over the meter interval, measured on the demodulated block rather
    /// than on the channel IQ: a strong unmodulated carrier is loud in `powerDBFS` and quiet here.
    /// NaN on a squelch record and before the first block; a raw-IQ channel has no audio and leaves
    /// both NaN.
    public var audioDBFS: Float = .nan
    public var audioPeakDBFS: Float = .nan
    /// The FM discriminator over the meter interval, read ahead of de-emphasis and the high-pass:
    /// its largest excursion from its DC is the peak deviation, and its DC is the tuning error,
    /// positive when the transmitter sits above the channel. NaN for every other mode, on a
    /// squelch record and before the first block; `freqErrorHz` is NaN while the squelch is
    /// closed as well, because noise has no tuning error.
    public var deviationHz: Float = .nan
    public var freqErrorHz: Float = .nan
}

/// Fixed-capacity telemetry ring plus a "poke" stream that wakes the drain task.
/// Producer: the DSP thread (`push`, allocation-free; the ring is lock-free, and the poke takes the
/// stream's short internal lock). Consumer: one drain task.
///
/// Policy is drop-oldest: when the ring is full the producer evicts the oldest unread record
/// (advancing `head` with a CAS) and counts it in `dropped`, so a stalled consumer always sees the
/// newest readings instead of a stale prefix. Each slot carries a seqlock version (odd while being
/// written) so the consumer can detect a slot overwritten underneath it and retry; records are
/// plain-old-data, so a torn copy is harmless and simply discarded.
/// Unchecked Sendable: one producer (the DSP thread) and one consumer; each slot is guarded by its seqlock version.
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

    /// Producer side (DSP thread). Never allocates; evicts the oldest record when full. The poke at
    /// the end is the one lock it takes: `yield` holds the stream's internal lock for the hand-off.
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

/// The transmission a channel has announced and not yet ended, shared by every core the channel
/// builds. A structural change (a retune by offset or by the capture's centre, a new width or
/// mode) swaps the core, and the new core's squelch starts over; without this, the open edge the
/// old core sent would never get its close, and every client's log would keep a transmission
/// from the old frequency running (docs/dev/engine-internals.md, "Squelch and meters").
///
/// Everything in it belongs to the capture's DSP thread: each core reads and writes it only from
/// `process(block:at:)`, the slot touches it only on a block where the channel has no core, and
/// `ChannelDSPCore.reset()` only while no block is in flight. That single owner is what makes
/// `@unchecked Sendable` safe, and it is also the telemetry queue's single producer.
public final class ChannelTransmission: @unchecked Sendable {
    private let telemetry: ChannelTelemetryQueue
    /// An open edge went out and its close has not.
    var announced = false
    /// Capture samples since the squelch opened, and the loudest values seen in that interval.
    var openSamples: UInt64 = 0
    var peakPowerDBFS: Float = .nan
    var peakSNRDB: Float = .nan
    /// Start time of the most recent block: the last moment the channel had signal, so a close
    /// the channel synthesises is stamped with it.
    var lastBlockTime: SampleTime?
    /// The generation of the core that processed the last block; 0 before the first block and
    /// while the channel has no core.
    var owner: UInt64 = 0

    public init(telemetry: ChannelTelemetryQueue) {
        self.telemetry = telemetry
    }

    /// Ends the announced transmission with a close edge carrying its summary, as if the squelch
    /// had shut on the last block. Returns true when there was one to end. DSP thread only.
    @discardableResult
    func end() -> Bool {
        defer { clear() }
        guard announced, let time = lastBlockTime else { return false }
        announced = false
        telemetry.push(closeRecord(at: time))
        return true
    }

    /// The close edge's record, summarising the interval so far.
    func closeRecord(at time: SampleTime) -> ChannelTelemetryRecord {
        var rec = ChannelTelemetryRecord(kind: .squelch, time: time, powerDBFS: .nan, snrDB: .nan, squelchOpen: false)
        rec.openSamples = openSamples
        rec.peakPowerDBFS = peakPowerDBFS
        rec.peakSNRDB = peakSNRDB
        return rec
    }

    func clear() {
        openSamples = 0
        peakPowerDBFS = .nan
        peakSNRDB = .nan
    }

    /// A block went by while the channel had no core (it is out of capture): the transmission it
    /// announced is over, and ends here rather than when the channel next fits. One compare on
    /// every later block. DSP thread only.
    public func noCore() {
        guard owner != 0 else { return }
        owner = 0
        end()
    }
}

/// Immutable-by-structure DSP core for one channel. Built on the control plane, run on the DSP
/// thread. Squelch threshold and AGC are adjustable in place through atomics; anything else
/// (offset, bandwidth, mode, capture rate) requires a new core.
/// Unchecked Sendable: built on the control plane and then run only by the DSP thread; the settings shared with the control plane are atomics.
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
    /// Where the demodulator writes its raw stage for `.demod` sinks. Allocated with everything
    /// else this core owns, so the hot path only ever borrows it, and nil for raw IQ channels,
    /// which have no demodulator stage to tap.
    private let rawOut: SampleStorage?
    private var meter: PowerMeter
    /// The demodulator again, when its raw stage is frequency (the FM modes): the meter takes the
    /// discriminator's interval from it. Decided once here so the hot path pays one nil check.
    private let discriminator: (any DiscriminatorSource)?
    /// The capture's floor (`BandFloor`), or nil for a core run outside a capture, whose `snrDB`
    /// is then NaN. `bandwidthDB` is `10·log10(bandwidth)`, fixed for the life of the core, so a
    /// block's SNR is one atomic load and two subtractions.
    private let floor: BandFloor?
    private let bandwidthDB: Float
    private var squelch: Squelch
    private let squelchBits = Atomic<UInt32>(Float.nan.bitPattern)
    private let agcAuto = Atomic<Bool>(true)
    private let sinkLock = NSLock()
    private var sinks: [any AudioSink] = []
    /// Whether anything in `sinks` asked for the demod tap, decided when the table is set so the
    /// hot path spends one branch instead of asking every sink what it wanted.
    private var hasDemodSink = false
    private let telemetry: ChannelTelemetryQueue
    /// Channel-rate samples per `.meter` emission (100 ms).
    private let meterInterval: Int
    private var samplesSinceMeter = 0
    private let blocksProcessed = Atomic<UInt64>(0)
    private let squelchCloses = Atomic<UInt64>(0)
    /// The transmission in progress, shared with the cores before and after this one, and this
    /// core's place in that line: the first block this core sees with another generation as the
    /// owner is the first block after a swap.
    private let transmission: ChannelTransmission
    private let generation: UInt64
    private static let generations = Atomic<UInt64>(0)
    /// The capture sample index just past the last block processed, for the sub-audible task to
    /// stamp its hops with (invariant 5). One relaxed store per block.
    private let sampleEnd = Atomic<UInt64>(0)

    /// - Throws: `INVALID_ARGUMENT`, `OFFSET_OUT_OF_CAPTURE`, `MODE_UNSUPPORTED` (from the demodulator).
    ///
    /// `transmission` is the channel's, shared by every core it builds so a swap can end what the
    /// last core announced; a core built alone gets one of its own.
    public init(captureRate: UInt64, config: ChannelConfig, telemetry: ChannelTelemetryQueue, maxBlock: Int = 16384,
                floor: BandFloor? = nil, transmission: ChannelTransmission? = nil) throws {
        self.transmission = transmission ?? ChannelTransmission(telemetry: telemetry)
        generation = Self.generations.wrappingAdd(1, ordering: .relaxed).newValue
        self.captureRate = captureRate
        self.config = config
        self.telemetry = telemetry
        self.floor = floor
        bandwidthDB = 10 * log10f(Float(Swift.max(1, config.bandwidthHz)))
        channelizer = try Channelizer(captureRate: captureRate, offsetHz: config.offsetHz, bandwidthHz: config.bandwidthHz,
                                      mode: config.mode, maxBlock: maxBlock)
        demodulator = DemodulatorFactory.make(mode: config.mode)
        amDemodulator = demodulator as? AMDemodulator
        ssbDemodulator = demodulator as? SSBDemodulator
        discriminator = demodulator as? DiscriminatorSource
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
        rawOut = config.mode == .rawIQ ? nil : SampleStorage(capacity: channelizer.maxOutput, format: .f32)
        meter = PowerMeter()
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

    // The transmission in progress lives in `transmission`. `openSamples` there counts CAPTURE
    // samples since the squelch opened -- the same rate `SampleTime` uses, which is the one a
    // client already knows from the capture; the channel's own rate is not on the wire. The peaks
    // are the loudest values seen in that interval. Reset on every open edge, drained on the close.

    /// Blocks processed so far.
    public var blocks: UInt64 { blocksProcessed.load(ordering: .relaxed) }

    /// How many transmissions have ended: one per squelch close edge. The sub-audible task watches
    /// this to learn that the signal it has been measuring has ended and its phase history is
    /// stale. A count rather than a flag because a whole transmission can
    /// come and go between two of that task's 50 ms polls.
    public var squelchCloseCount: UInt64 { squelchCloses.load(ordering: .relaxed) }

    /// The capture sample index just past the last block this core processed; 0 before the first.
    public var sampleIndexEnd: UInt64 { sampleEnd.load(ordering: .relaxed) }

    /// Capture samples per sub-audible tap sample, for converting what is still unread in the tap
    /// into capture time. 0 when there is no tap.
    public var captureSamplesPerTapSample: Double {
        subAudibleRate > 0 ? Double(captureRate) / subAudibleRate : 0
    }

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
        hasDemodSink = rawOut != nil && newSinks.contains { $0.tap == .demod }
        sinkLock.unlock()
    }

    /// Current sinks.
    public var currentSinks: [any AudioSink] {
        sinkLock.lock(); defer { sinkLock.unlock() }
        return sinks
    }

    /// Hot path. `block` is interleaved cf32 at the capture rate (count ≤ maxBlock); `time` is its
    /// start. Channelizes, demodulates, zeros the conditioned block while the squelch is closed and
    /// writes it to the `.audio` sinks, hands the demodulator's raw block to the `.demod` sinks
    /// unzeroed, and pushes meter/squelch telemetry. No allocation, no lock held across calls.
    public func process(block: SampleBuffer, at time: SampleTime) {
        let sp = Signpost.begin(.channelProcess)
        defer { Signpost.end(.channelProcess, sp) }
        let tx = transmission
        if tx.owner != generation {
            // The first block since this core replaced another: its squelch starts over, so the
            // transmission the old core announced ends here, stamped with the old core's last
            // block, and this block decides afresh whether the new one is open. The old core is
            // not in flight: the capture's one DSP thread finished its block before this one.
            tx.end()
            tx.owner = generation
        }
        var iq = iqOut.view()
        let n = channelizer.process(input: block, output: &iq)
        guard n > 0 else { return }
        iq.count = n
        let power = meter.measure(iq)
        // Power over the band's floor at this channel's width; NaN until the capture has read a
        // row. The squelch is not involved: it compares `power` to its own dBFS threshold.
        let snr = floor.map { power - ($0.densityDBFS + bandwidthDB) } ?? .nan
        tx.lastBlockTime = time
        squelch.thresholdDB = Float(bitPattern: squelchBits.load(ordering: .relaxed))
        // Track the transmission in progress: two compares, no branch on the common path. The block
        // that opens the squelch counts, so a short transmission is never measured as zero samples.
        if squelch.isOpen {
            tx.openSamples &+= UInt64(block.count)
            if !(power <= tx.peakPowerDBFS) { tx.peakPowerDBFS = power }
            if !(snr <= tx.peakSNRDB) { tx.peakSNRDB = snr }
        }
        if squelch.update(powerDB: power) {
            var rec = ChannelTelemetryRecord(kind: .squelch, time: time, powerDBFS: power, snrDB: snr, squelchOpen: squelch.isOpen)
            if squelch.isOpen {
                // Opening: start a fresh interval. This block belongs to it.
                tx.openSamples = UInt64(block.count)
                tx.peakPowerDBFS = power
                tx.peakSNRDB = snr
                tx.announced = true
            } else {
                rec.openSamples = tx.openSamples
                rec.peakPowerDBFS = tx.peakPowerDBFS
                rec.peakSNRDB = tx.peakSNRDB
                tx.clear()
                tx.announced = false
                squelchCloses.wrappingAdd(1, ordering: .relaxed)
            }
            telemetry.push(rec)
        }
        let agcOn = agcAuto.load(ordering: .relaxed)
        if let am = amDemodulator { am.agcEnabled = agcOn }
        if let ssb = ssbDemodulator { ssb.agcEnabled = agcOn }
        sinkLock.lock()
        let table = sinks
        let wantsRaw = hasDemodSink
        sinkLock.unlock()
        var audio = audioOut.view()
        // With no demod-tap sink the raw stage costs one branch: `raw` is nil and the demodulator
        // skips it.
        var raw: SampleBuffer? = wantsRaw ? rawOut?.view() : nil
        let dsp = Signpost.begin(.demodulate)
        var frames = demodulator.process(iq: iq, audioOut: &audio, rawOut: &raw)
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
        // Squelched: only the `.audio` output is muted. The demod tap below carries the detector's
        // own output whether the squelch is open or shut; `AudioTap` in `bulk.proto` documents what
        // that is for.
        if !squelch.isOpen, frames > 0 {
            Kernels.clear(out.base.assumingMemoryBound(to: Float.self), count: out.format == .cf32 ? frames * 2 : frames)
        }
        if frames > 0 {
            for sink in table where sink.tap == .audio { sink.write(out, at: time) }
        }
        if let raw, raw.count > 0 {
            for sink in table where sink.tap == .demod { sink.write(raw, at: time) }
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
            var rec = ChannelTelemetryRecord(kind: .meter, time: time, powerDBFS: power, snrDB: snr, squelchOpen: squelch.isOpen)
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
            if let iv = discriminator?.takeDiscriminatorInterval() {
                rec.deviationHz = Float(iv.deviationHz)
                // A closed squelch is noise, and the DC of noise is not a tuning error.
                rec.freqErrorHz = squelch.isOpen ? Float(iv.freqErrorHz) : .nan
            }
            telemetry.push(rec)
        }
        sampleEnd.store(time.sampleIndex &+ UInt64(block.count), ordering: .relaxed)
        blocksProcessed.wrappingAdd(1, ordering: .relaxed)
    }

    /// Start the channel over on a discontinuous stream: filter history, NCO phase, demodulator and
    /// last block power go, and so does the transmission in progress -- its sample count and peaks
    /// describe the stream before the gap, and a duration that spans the gap would be wrong. Call
    /// it only while no block is in flight (the device is stopped and the DSP thread drained); the
    /// state it touches belongs to the DSP thread.
    public func reset() {
        // A squelch that was open ends here rather than silently: the fresh squelch below starts
        // closed, so without this record the close edge never reaches anyone and every watcher of
        // the edge -- the transmission summary, the sub-audible task's phase history -- would carry
        // pre-gap state into the new stream. The telemetry queue has one producer, and the caller's
        // contract above (no block in flight) is what makes this push that one producer.
        let tx = transmission
        if squelch.isOpen, let time = tx.lastBlockTime {
            squelchCloses.wrappingAdd(1, ordering: .relaxed)
            telemetry.push(tx.closeRecord(at: time))
        }
        tx.announced = false
        channelizer.reset()
        demodulator.reset()
        meter.reset()
        // The tapped samples describe the stream before the gap. `requestFlush` rather than `clear`
        // because the detection task owns the read side and is still running.
        subAudibleTap?.requestFlush()
        samplesSinceMeter = 0
        squelch = Squelch(thresholdDB: squelch.thresholdDB)
        tx.lastBlockTime = nil
        tx.clear()
        audioSumSquares = 0
        audioSamples = 0
        audioPeak = 0
    }
}
