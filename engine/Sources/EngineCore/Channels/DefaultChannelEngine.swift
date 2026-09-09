// Control-plane half of a channel. Owns the `ChannelDSPCore`, swaps it atomically on structural
// changes, and fans telemetry out to subscribers.

import Foundation
import Synchronization

/// The handle a capture's DSP thread reads each block: the channel's current core, or nil while
/// the channel is out of capture. Lock held only for the reference copy.
public final class ChannelSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var core: ChannelDSPCore?

    public init(core: ChannelDSPCore?) { self.core = core }

    /// Hot path: copy the reference under the lock, release, return.
    public func load() -> ChannelDSPCore? {
        lock.lock(); defer { lock.unlock() }
        return core
    }

    /// Control plane: swap in a new core (or nil to pause).
    public func store(_ newCore: ChannelDSPCore?) {
        lock.lock(); core = newCore; lock.unlock()
    }
}

/// Default `ChannelEngine`. Created by `DefaultCaptureEngine.addChannel`; the capture owns the slot.
public actor DefaultChannelEngine: ChannelEngine {
    public nonisolated let id: ChannelID
    public nonisolated let captureID: CaptureID
    /// Read by the capture's DSP thread.
    public nonisolated let slot: ChannelSlot
    private nonisolated let audioRateBox = Atomic<UInt32>(0)
    /// Internal so tests can overflow the ring directly; production pushes come from `ChannelDSPCore`.
    nonisolated let telemetryQueue = ChannelTelemetryQueue()
    private nonisolated let hub = TelemetryHub()

    private var currentConfig: ChannelConfig
    private var currentState: ChannelState = .active
    private var captureRate: UInt64
    private var centerHz: UInt64
    /// Absolute frequency the channel follows across retunes: `center + offset` at creation/update.
    private var absoluteHz: Int64
    private var sinkTable: [any AudioSink] = []
    private var drainTask: Task<Void, Never>?
    private var closed = false

    /// Builds the first core synchronously; the capture engine registers `slot` afterwards.
    /// - Throws: `INVALID_ARGUMENT`, `OFFSET_OUT_OF_CAPTURE`, `MODE_UNSUPPORTED`.
    public init(id: ChannelID = ChannelID(), captureID: CaptureID, captureRate: UInt64, centerHz: UInt64, config: ChannelConfig) throws {
        self.id = id
        self.captureID = captureID
        self.captureRate = captureRate
        self.centerHz = centerHz
        currentConfig = config
        absoluteHz = Int64(centerHz) + config.offsetHz
        let core = try ChannelDSPCore(captureRate: captureRate, config: config, telemetry: telemetryQueue)
        slot = ChannelSlot(core: core)
        audioRateBox.store(core.audioRate, ordering: .relaxed)
        let queue = telemetryQueue
        let hub = self.hub
        drainTask = Task.detached {
            for await _ in queue.poke {
                while let rec = queue.pop() { hub.publish(rec) }
            }
            while let rec = queue.pop() { hub.publish(rec) }
            hub.finishAll()
        }
    }

    public nonisolated var audioRate: UInt32 { audioRateBox.load(ordering: .relaxed) }
    public var config: ChannelConfig { currentConfig }
    public var state: ChannelState { currentState }
    public var sinks: [any AudioSink] { sinkTable }
    /// Blocks processed by the current core (0 while out of capture).
    public var blocksProcessed: UInt64 { slot.load()?.blocks ?? 0 }

    /// Applies a new configuration. Squelch/AGC-only changes adjust the running core in place;
    /// anything structural builds a new core and swaps it (one block of filter warm-up). While the
    /// channel is `.outOfCapture`, every write that leaves the offset alone is stored for the rebuild
    /// on re-entry; only an offset change is validated against the capture right away.
    public func update(_ config: ChannelConfig) async throws {
        guard !closed else { throw EngineError.channelNotFound(id.description) }
        let old = currentConfig
        let structural = old.offsetHz != config.offsetHz || old.bandwidthHz != config.bandwidthHz || old.mode != config.mode
        if config.mode == .rawIQ, sinkTable.contains(where: { $0 is PCMOnlyAudioSink }) {
            throw EngineError.invalidArgument("cannot switch to raw IQ while a system audio sink is attached", target: id.description)
        }
        if !structural {
            // Squelch/AGC-only: adjust the running core in place. Out of capture there is no core;
            // the values are kept for the rebuild that happens once the channel fits again, and
            // the channel stays `.outOfCapture` at its absolute frequency.
            if let core = slot.load() {
                core.setSquelch(thresholdDB: config.squelchDB)
                core.setAGC(config.agc)
            }
            currentConfig = config
            return
        }
        // `absoluteHz` is the source of truth: only an explicit offset change moves it. A mode or
        // bandwidth change on a channel the capture has moved away from keeps its frequency.
        let offsetChanged = old.offsetHz != config.offsetHz
        let offset = offsetChanged ? config.offsetHz : absoluteHz - Int64(centerHz)
        // Validate before mutating: a rejected config must leave the channel (and its reported state) untouched.
        _ = try ChannelPlan.plan(captureRate: captureRate, mode: config.mode, bandwidthHz: config.bandwidthHz)
        // The offset-independent bound the channelizer enforces at build time, applied now so a
        // stored config can never fail later at re-entry.
        guard config.bandwidthHz > 0, UInt64(config.bandwidthHz) <= captureRate else {
            throw EngineError.invalidArgument("bandwidth \(config.bandwidthHz) Hz must be in 1...\(captureRate)", target: id.string)
        }
        if !offsetChanged, slot.load() == nil {
            // Out of capture and the offset is untouched: the channel is already outside the
            // capture, so re-checking the stale offset would only reject a mode/bandwidth change
            // that has nothing to do with it. Store the config; the rebuild on re-entry
            // (`captureMoved`) uses it, and the channel stays `.outOfCapture` until then.
            var stored = config
            stored.offsetHz = offset
            currentConfig = stored
            return
        }
        try Channelizer.checkOffset(offset, bandwidthHz: config.bandwidthHz, captureRate: captureRate)
        currentConfig = config
        absoluteHz = Int64(centerHz) + offset
        try rebuild(offsetHz: offset)
    }

    public func attach(_ sink: any AudioSink) async throws {
        guard !closed else { throw EngineError.channelNotFound(id.description) }
        // A raw-IQ channel hands cf32 blocks to its sinks; a PCM-only sink cannot take them.
        if sink is PCMOnlyAudioSink, currentConfig.mode == .rawIQ {
            throw EngineError.invalidArgument("system audio requires a demodulated channel", target: id.description)
        }
        sinkTable.append(sink)
        slot.load()?.setSinks(sinkTable)
    }

    public func detach(_ id: SinkID) async {
        guard let i = sinkTable.firstIndex(where: { $0.id == id }) else { return }
        let sink = sinkTable.remove(at: i)
        slot.load()?.setSinks(sinkTable)
        await sink.closeSink()
    }

    /// The capture retuned: recompute the offset from the absolute frequency. If the channel no
    /// longer fits, it goes `.outOfCapture` (core removed, sinks kept); it resumes when it fits again.
    public func captureMoved(newCenterHz: UInt64) async {
        centerHz = newCenterHz
        let offset = absoluteHz - Int64(newCenterHz)
        // The reported offset follows the absolute frequency even when the channel no longer fits,
        // so a later structural update rebuilds at the right place.
        currentConfig.offsetHz = offset
        do {
            try Channelizer.checkOffset(offset, bandwidthHz: currentConfig.bandwidthHz, captureRate: captureRate)
            try rebuild(offsetHz: offset)
        } catch {
            slot.store(nil)
            currentState = .outOfCapture
        }
    }

    /// The capture's sample rate changed: re-plan the chain at the new rate.
    public func captureRateChanged(_ rate: UInt64) async {
        captureRate = rate
        await captureMoved(newCenterHz: centerHz)
    }

    /// Fan-out stream of meter/squelch telemetry. Ends when the channel is removed.
    public nonisolated func telemetry() -> AsyncStream<ChannelTelemetry> {
        hub.subscribe().stream
    }

    /// Fan-out stream plus this subscriber's fan-out drop counter (see `ChannelTelemetrySubscription`).
    public nonisolated func telemetrySubscription() -> ChannelTelemetrySubscription {
        hub.subscribe()
    }

    /// Records evicted from the telemetry ring because the drain task fell behind (drop-oldest).
    public nonisolated var telemetryDropped: Int { telemetryQueue.dropped }

    /// Tears down: pauses processing, closes sinks, ends telemetry streams.
    public func close() async {
        guard !closed else { return }
        closed = true
        slot.store(nil)
        let sinks = sinkTable
        sinkTable = []
        for s in sinks { await s.closeSink() }
        telemetryQueue.finish()
        _ = await drainTask?.value
    }

    private func rebuild(offsetHz: Int64) throws {
        var cfg = currentConfig
        cfg.offsetHz = offsetHz
        currentConfig = cfg
        let core = try ChannelDSPCore(captureRate: captureRate, config: cfg, telemetry: telemetryQueue)
        core.setSinks(sinkTable)
        audioRateBox.store(core.audioRate, ordering: .relaxed)
        slot.store(core)
        currentState = .active
    }
}

/// One subscriber's view of a channel's telemetry fan-out: the stream and the count of records the
/// fan-out buffer (drop-oldest, `TelemetryHub.capacity` slots) discarded because this subscriber fell
/// behind. Together with `ChannelEngine.telemetryDropped` (ring evictions) it accounts for every
/// record the subscriber never saw, so a consumer can widen its sequence gap by the same amount.
public final class ChannelTelemetrySubscription: Sendable {
    public let stream: AsyncStream<ChannelTelemetry>
    private let droppedCount = Atomic<Int>(0)

    init(stream: AsyncStream<ChannelTelemetry>) {
        self.stream = stream
    }

    /// Cumulative records this subscriber lost to its own fan-out buffer overflowing.
    public var dropped: Int { droppedCount.load(ordering: .relaxed) }

    fileprivate func countDrop() {
        droppedCount.add(1, ordering: .relaxed)
    }
}

/// Lock-guarded set of telemetry subscribers. Publishing happens on the drain task, never on the DSP thread.
/// Each subscriber's buffer is drop-oldest; a drop is counted on that subscriber's `ChannelTelemetrySubscription`.
final class TelemetryHub: @unchecked Sendable {
    /// Per-subscriber buffer depth before the oldest unread record is discarded (and counted).
    static let capacity = 256
    private let lock = NSLock()
    private var subscribers: [UUID: (continuation: AsyncStream<ChannelTelemetry>.Continuation, subscription: ChannelTelemetrySubscription)] = [:]
    private var finished = false

    func subscribe() -> ChannelTelemetrySubscription {
        let (stream, continuation) = AsyncStream<ChannelTelemetry>.makeStream(bufferingPolicy: .bufferingNewest(Self.capacity))
        let subscription = ChannelTelemetrySubscription(stream: stream)
        let key = UUID()
        lock.lock()
        if finished {
            lock.unlock()
            continuation.finish()
            return subscription
        }
        subscribers[key] = (continuation, subscription)
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.subscribers[key] = nil; self.lock.unlock()
        }
        return subscription
    }

    func publish(_ rec: ChannelTelemetryRecord) {
        let event: ChannelTelemetry
        switch rec.kind {
        case .meter:
            event = .meter(time: rec.time, powerDBFS: Double(rec.powerDBFS), snrDB: Double(rec.snrDB),
                           squelchOpen: rec.squelchOpen,
                           audioDBFS: Double(rec.audioDBFS), audioPeakDBFS: Double(rec.audioPeakDBFS))
        case .squelch:
            event = .squelch(time: rec.time, open: rec.squelchOpen, openSamples: rec.openSamples,
                             peakSNRDB: Double(rec.peakSNRDB), peakPowerDBFS: Double(rec.peakPowerDBFS))
        }
        lock.lock()
        let subs = Array(subscribers.values)
        lock.unlock()
        for (c, sub) in subs {
            // `bufferingNewest` discards the oldest buffered record when full: count it against this subscriber.
            if case .dropped = c.yield(event) { sub.countDrop() }
        }
    }

    func finishAll() {
        lock.lock()
        finished = true
        let subs = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for (c, _) in subs { c.finish() }
    }
}
