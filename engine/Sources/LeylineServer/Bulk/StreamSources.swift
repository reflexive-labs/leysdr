// SPDX-License-Identifier: GPL-3.0-or-later

// Hot-path adapters that feed a FrameRing from the engine: FFT rows (SpectrumSink), channel audio
// (CallbackSink into a FloatRing) and capture IQ (CaptureTap). None allocate on the write path.

import EngineCore
import Foundation
import Synchronization

/// `DB_U8` encoding: `clamp(round((db + 120) * 2), 0, 255)`.
@inline(__always)
func dbToU8(_ db: Float) -> UInt8 {
    let v = ((db + 120) * 2).rounded()
    if !(v > 0) { return 0 }
    if v >= 255 { return 255 }
    return UInt8(v)
}

/// Copies FFT rows into the ring as DB_F32 (little-endian f32) or DB_U8.
final class FFTFrameSink: SpectrumSink, Sendable {
    let ring: FrameRing
    let u8: Bool
    let bins: Int

    init(ring: FrameRing, bins: Int, u8: Bool) {
        self.ring = ring
        self.bins = bins
        self.u8 = u8
    }

    func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64, looks _: Int) {
        let n = min(row.count, bins)
        guard let src = row.baseAddress else { return }
        ring.write(sampleStart: time.sampleIndex, sampleCount: UInt64(n)) { dst in
            if u8 {
                let out = dst.assumingMemoryBound(to: UInt8.self)
                for i in 0..<n { out[i] = dbToU8(src[i]) }
                return n
            } else {
                dst.copyMemory(from: UnsafeRawPointer(src), byteCount: n * 4)
                return n * 4
            }
        }
    }
}

/// Audio path: the channel's CallbackSink pushes f32 frames into a FloatRing; the Stream reader
/// drains it into ≤ 4096-sample S16/F32 frames. Frame times are derived from the most recent block's
/// capture time and the ring backlog (audio is not sample-indexed by the channel).
/// Unchecked Sendable: `read`, `lastDropped` and `scratch` belong to the one Stream reader; the sink side touches only the ring and the atomics.
final class AudioFrameSource: @unchecked Sendable {
    static let maxFrame = 4096
    let ring: FloatRing
    let sink: CallbackSink
    let poke: AsyncStream<Void>
    private let pokeContinuation: AsyncStream<Void>.Continuation
    /// Shared with the sink closure (stdlib atomics are non-copyable, so they live in a box).
    private final class Counters: Sendable {
        let lastBlockStart = Atomic<UInt64>(0)
        let written = Atomic<Int>(0)
    }
    private let counters = Counters()
    private var read = 0
    private var lastDropped = 0
    let captureRate: Double
    let audioRate: Double
    private let scratch: UnsafeMutableBufferPointer<Float>

    /// `captureRate` is the rate at subscribe time and stays that for the life of the source: a
    /// capture-rate write ends every audio stream on the capture (`TeardownScope.captureRate`), so
    /// the source never outlives the rate it scales frame spans by, and the client re-subscribes
    /// for a fresh descriptor.
    init(captureRate: UInt64, audioRate: UInt32, tap: AudioTap = .audio) {
        self.captureRate = Double(captureRate)
        self.audioRate = Double(max(audioRate, 1))
        ring = FloatRing(capacity: 32768)
        scratch = .allocate(capacity: Self.maxFrame)
        var cont: AsyncStream<Void>.Continuation!
        poke = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        pokeContinuation = cont
        let r = ring
        let c = cont!
        let k = counters
        sink = CallbackSink(tap: tap) { audio, time in
            guard audio.format == .f32, audio.count > 0 else { return }
            let n = r.push(UnsafeBufferPointer(audio.floats))
            k.lastBlockStart.store(time.sampleIndex, ordering: .relaxed)
            k.written.wrappingAdd(n, ordering: .releasing)
            // The one lock on this path: `yield` takes the stream's internal lock for the hand-off.
            c.yield(())
        }
    }

    deinit { scratch.deallocate() }

    /// One drained frame (reader side): payload in the negotiated format plus its capture-time span.
    struct Frame {
        var payload: Data
        var sampleStart: UInt64
        var sampleCount: UInt64
        var droppedSamples: UInt64
    }

    /// Pops up to 4096 samples; nil when the ring is empty.
    func next(s16: Bool) -> Frame? {
        let n = ring.pop(into: scratch)
        guard n > 0 else { return nil }
        let w = counters.written.load(ordering: .acquiring)
        let backlog = max(0, w - read - n)
        let perAudio = captureRate / audioRate
        let blockStart = counters.lastBlockStart.load(ordering: .relaxed)
        let behind = UInt64(Double(backlog) * perAudio)
        let start = blockStart > behind ? blockStart - behind : 0
        read += n
        let dropped = ring.dropped
        let droppedNow = UInt64(Double(dropped - lastDropped) * perAudio)
        lastDropped = dropped
        let payload: Data
        if s16 {
            var d = Data(count: n * 2)
            d.withUnsafeMutableBytes { raw in
                let out = raw.baseAddress!.assumingMemoryBound(to: Int16.self)
                for i in 0..<n {
                    let v = max(-1, min(1, scratch[i]))
                    out[i] = Int16((v * 32767).rounded())
                }
            }
            payload = d
        } else {
            payload = Data(bytes: scratch.baseAddress!, count: n * 4)
        }
        return Frame(payload: payload, sampleStart: start, sampleCount: UInt64(Double(n) * perAudio), droppedSamples: droppedNow)
    }

    /// Wakes a reader parked on `poke` without new audio (used to end a cancelled reader).
    func wake() { pokeContinuation.yield(()) }

    func finish() { pokeContinuation.finish() }
}

/// IQ path: one capture block (cf32) per frame.
final class IQFrameTap: CaptureTap, Sendable {
    let id: StreamID
    let ring: FrameRing

    init(id: StreamID, ring: FrameRing) {
        self.id = id
        self.ring = ring
    }

    func write(iq: SampleBuffer, at time: SampleTime) {
        guard iq.format == .cf32 else { return }
        // A block bigger than a slot is truncated, so the frame spans only the samples that fit:
        // reporting the block's full count would credit the client samples it never received and
        // shift its sample-index arithmetic off the timeline.
        let bytes = min(iq.byteCount, ring.slotBytes)
        ring.write(sampleStart: time.sampleIndex, sampleCount: UInt64(bytes / 8)) { dst in
            dst.copyMemory(from: UnsafeRawPointer(iq.base), byteCount: bytes)
            return bytes
        }
    }

    func closeTap() async { ring.finish() }
}

/// Persistence path: every ladder row is folded into a `PersistenceAccumulator`, and a snapshot of
/// the whole histogram is emitted at the subscriber's own rate. The two rates are independent: the
/// histogram takes every row the ladder produces while the display needs only a couple of frames a
/// second.
///
/// Every frame is the entire state, so LATEST_WINS costs a subscriber nothing but freshness.
/// Unchecked Sendable: `nextEmit` and `started` are touched only from `write`, on the DSP thread.
final class PersistenceFrameSink: SpectrumSink, @unchecked Sendable {
    let ring: FrameRing
    let accumulator: PersistenceAccumulator
    /// Capture samples between emitted frames.
    let emitInterval: UInt64
    private var nextEmit: UInt64 = 0
    private var started = false

    init(ring: FrameRing, accumulator: PersistenceAccumulator, emitInterval: UInt64) {
        self.ring = ring
        self.accumulator = accumulator
        self.emitInterval = max(1, emitInterval)
    }

    func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz _: UInt64, spanHz _: UInt64, looks _: Int) {
        accumulator.add(row: row)
        let now = time.sampleIndex
        if !started {
            started = true
            // The first frame waits an interval: emitting on the first row would send a histogram
            // with a single row in it, which looks like one spectrum row rather than a persistence
            // display.
            nextEmit = now &+ emitInterval
            return
        }
        // A rewound or jumped timeline must not stall the stream.
        if nextEmit > now &+ emitInterval { nextEmit = now &+ emitInterval }
        guard now >= nextEmit else { return }
        let scheduled = nextEmit &+ emitInterval
        nextEmit = scheduled > now ? scheduled : now &+ emitInterval
        let bytes = accumulator.bins * accumulator.levels * 2
        ring.write(sampleStart: now, sampleCount: accumulator.rows) { dst in
            accumulator.snapshot(into: UnsafeMutableRawBufferPointer(start: dst, count: bytes))
        }
    }
}
