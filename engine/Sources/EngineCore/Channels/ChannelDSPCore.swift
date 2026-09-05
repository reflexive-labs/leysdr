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
}

/// Fixed-capacity SPSC queue of telemetry records plus a "poke" stream that wakes the drain task.
/// Producer: the DSP thread (`push`, allocation-free, drops when full). Consumer: one drain task.
public final class ChannelTelemetryQueue: @unchecked Sendable {
    public let capacity: Int
    private let slots: UnsafeMutablePointer<ChannelTelemetryRecord>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let droppedCount = Atomic<Int>(0)
    /// Yields once per push (buffering newest 1): the consumer drains everything on each wake.
    public let poke: AsyncStream<Void>
    private let pokeContinuation: AsyncStream<Void>.Continuation

    public init(capacity: Int = 64) {
        self.capacity = capacity
        slots = UnsafeMutablePointer<ChannelTelemetryRecord>.allocate(capacity: capacity)
        let zero = SampleTime(captureID: CaptureID(), sampleIndex: 0)
        slots.initialize(repeating: ChannelTelemetryRecord(kind: .meter, time: zero, powerDBFS: .nan, snrDB: .nan, squelchOpen: true), count: capacity)
        (poke, pokeContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        pokeContinuation.finish()
    }

    /// Records dropped because the queue was full.
    public var dropped: Int { droppedCount.load(ordering: .relaxed) }

    /// Producer side (DSP thread). Never blocks or allocates.
    public func push(_ record: ChannelTelemetryRecord) {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        if t - h >= capacity {
            droppedCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        slots[t % capacity] = record
        tail.store(t + 1, ordering: .releasing)
        pokeContinuation.yield(())
    }

    /// Consumer side. Returns nil when empty.
    public func pop() -> ChannelTelemetryRecord? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard t > h else { return nil }
        let r = slots[h % capacity]
        head.store(h + 1, ordering: .releasing)
        return r
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
        audioRate = demodulator.outputRate
        iqOut = SampleStorage(capacity: channelizer.maxOutput, format: .cf32)
        audioOut = SampleStorage(capacity: channelizer.maxOutput, format: .f32)
        meter = PowerMeter(rate: channelizer.outputRateHz)
        squelch = Squelch(thresholdDB: Float(config.squelchDB))
        meterInterval = max(1, Int(channelizer.outputRateHz / 10))
        setSquelch(thresholdDB: config.squelchDB)
        setAGC(config.agc)
    }

    /// Blocks processed so far.
    public var blocks: UInt64 { blocksProcessed.load(ordering: .relaxed) }

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
        if squelch.update(powerDB: power) {
            telemetry.push(ChannelTelemetryRecord(kind: .squelch, time: time, powerDBFS: power, snrDB: meter.snrDB, squelchOpen: squelch.isOpen))
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
        samplesSinceMeter += n
        if samplesSinceMeter >= meterInterval {
            samplesSinceMeter -= meterInterval
            telemetry.push(ChannelTelemetryRecord(kind: .meter, time: time, powerDBFS: power, snrDB: meter.snrDB, squelchOpen: squelch.isOpen))
        }
        blocksProcessed.wrappingAdd(1, ordering: .relaxed)
    }

    /// Reset filter, demodulator and meter state (e.g. after a stream restart).
    public func reset() {
        channelizer.reset()
        demodulator.reset()
        meter.reset()
        samplesSinceMeter = 0
    }
}
