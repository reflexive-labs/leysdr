// leyline.v1.Telemetry: fans channel meters / squelch transitions and capture activity into one
// sequenced stream per subscriber (sample timebase on every message). Delivery is drop-oldest:
// records lost before this subscriber drained them -- evicted from the channel's telemetry ring,
// discarded by the engine's per-subscriber fan-out buffer, or discarded by the merged buffer here --
// advance `seq` without being sent, so a slow subscriber sees a gap in `seq` for every reading it missed.

import EngineCore
import Foundation
import GRPCCore
import LeylineProto
import Synchronization

struct TelemetryService: Leyline_V1_Telemetry.SimpleServiceProtocol {
    let store: SessionStore
    static let activityIntervalNs: UInt64 = 1_000_000_000
    /// Merged-stream depth per subscription before the oldest undelivered item is discarded (and counted).
    static let mergedCapacity = 64

    func subscribe(request: Leyline_V1_TelemetrySubscription, response: RPCWriter<Leyline_V1_TelemetryMsg>, context: ServerContext) async throws {
        let client = ClientContext.current
        var captureFilter: CaptureID?
        var channelFilter: ChannelID?
        try await mapErrors {
            switch request.scope {
            case .captureID(let s)?:
                guard let id = CaptureID(string: s), await store.captureEngine(id) != nil else { throw EngineError.captureNotFound(s) }
                captureFilter = id
            case .channelID(let s)?:
                guard let id = ChannelID(string: s), let ch = await store.channelEngine(id) else { throw EngineError.channelNotFound(s) }
                channelFilter = id
                captureFilter = ch.captureID
            case .daemon?, nil:
                break
            }
        }
        let want = Set(request.types)
        @Sendable func wants(_ t: Leyline_V1_TelemetryType) -> Bool { want.isEmpty || want.contains(t) }

        await store.streamOpened(client)
        defer { Task { await store.streamClosed(client) } }

        // Each merged item carries the number of records lost ahead of it (a `seq` gap to open). The
        // merged buffer is drop-oldest too: a discarded item is folded into `mergedLost` (itself plus
        // the gap it carried) and the consumer adds the delta to the next `seq` it assigns.
        let (merged, sink) = AsyncStream<(msg: Leyline_V1_TelemetryMsg, gap: UInt64)>.makeStream(bufferingPolicy: .bufferingNewest(Self.mergedCapacity))
        let mergedLost = Atomic<UInt64>(0)
        @Sendable func yieldMerged(_ msg: Leyline_V1_TelemetryMsg, gap: UInt64) {
            if case .dropped(let lost) = sink.yield((msg, gap)) {
                mergedLost.add(lost.gap + 1, ordering: .relaxed)
            }
        }
        let events = await store.events(scope: captureFilter.map { .capture($0) } ?? .daemon)
        let st = self.store
        let capFilter = captureFilter
        let chanFilter = channelFilter

        let drains = ChannelDrains()
        defer { drains.cancelAll() }
        func track(_ id: ChannelID, _ engine: any ChannelEngine) {
            guard chanFilter == nil || chanFilter == id else { return }
            drains.start(id) {
                let subscription = engine.telemetrySubscription()
                var seenDropped = engine.telemetryDropped
                var seenHubDropped = subscription.dropped
                var gap: UInt64 = 0
                for await t in subscription.stream {
                    if Task.isCancelled { return }
                    // Ring evictions and fan-out drops since this drain's previous record become a gap on
                    // the merged stream; a gap accrued behind a filtered-out record carries over to the
                    // next one sent.
                    let nowDropped = engine.telemetryDropped
                    gap += UInt64(max(0, nowDropped - seenDropped))
                    seenDropped = nowDropped
                    let nowHubDropped = subscription.dropped
                    gap += UInt64(max(0, nowHubDropped - seenHubDropped))
                    seenHubDropped = nowHubDropped
                    var msg = Leyline_V1_TelemetryMsg()
                    switch t {
                    case .meter(let time, let power, let snr, let open, let audio, let audioPeak):
                        guard wants(.meter) else { continue }
                        msg.time = ProtoMapping.sampleTime(time)
                        msg.meter.channelID = id.string
                        msg.meter.powerDbfs = power
                        msg.meter.snrDb = snr
                        msg.meter.squelchOpen = open
                        // -inf is a real answer (digital silence) but does not survive JSON, so it
                        // is floored; NaN passes through untouched and means "not measured".
                        msg.meter.audioDbfs = audio.isInfinite ? -200 : audio
                        msg.meter.audioPeakDbfs = audioPeak.isInfinite ? -200 : audioPeak
                    case .squelch(let time, let open, let openSamples, let peakSNR, let peakPower):
                        guard wants(.squelchTransition) else { continue }
                        msg.time = ProtoMapping.sampleTime(time)
                        msg.squelch.channelID = id.string
                        msg.squelch.open = open
                        // The close edge carries the summary of what just ended; the open edge
                        // carries the same zero and NaN the engine handed us, so a client can tell
                        // "no summary" from "a transmission of zero length".
                        msg.squelch.durationSamples = openSamples
                        msg.squelch.peakSnrDb = peakSNR
                        msg.squelch.peakAudioDbfs = peakPower
                    case .subAudible(let time, let r):
                        guard wants(.subAudible) else { continue }
                        msg.time = ProtoMapping.sampleTime(time)
                        msg.subAudible.channelID = id.string
                        msg.subAudible.kind = r.detected ? .subAudibleCtcss : .subAudibleNone
                        msg.subAudible.toneHz = r.toneHz
                        msg.subAudible.standardToneHz = r.standardToneHz
                        msg.subAudible.deviationHz = r.deviationHz
                        msg.subAudible.toneSnrDb = r.toneSNRDB
                        msg.subAudible.confidence = r.confidence
                    }
                    yieldMerged(msg, gap: gap)
                    gap = 0
                }
            }
        }
        for (id, engine) in await st.channelEngines(captureID: capFilter) { track(id, engine) }

        // RPC cancellation is not task cancellation in grpc-swift: end the merged stream ourselves so a
        // subscriber that goes away (or a daemon shutdown, which finishes `events`) ends the RPC even
        // while no telemetry is flowing.
        try await withRPCCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await ev in events {
                        if Task.isCancelled { return }
                        guard case .channel(let ch)? = ev.body, ch.state == .channelActive,
                              let id = ChannelID(string: ch.channelID), let engine = await st.channelEngine(id) else { continue }
                        track(id, engine)
                    }
                    sink.finish()
                }
                if wants(.captureActivity), chanFilter == nil {
                    group.addTask {
                        while !Task.isCancelled {
                            try await Task.sleep(nanoseconds: Self.activityIntervalNs)
                            for cap in await st.snapshot(scope: capFilter.map { .capture($0) } ?? .daemon).captures {
                                var msg = Leyline_V1_TelemetryMsg()
                                msg.time.captureID = cap.captureID
                                msg.time.sampleIndex = await st.captureEngine(CaptureID(string: cap.captureID)!)?.stats.samplesProcessed ?? 0
                                msg.activity.captureID = cap.captureID
                                msg.activity.snapshot.lastInteractiveWriteNs = cap.activity.lastInteractiveWriteNs
                                msg.activity.snapshot.liveAudioSinks = cap.activity.liveAudioSinks
                                yieldMerged(msg, gap: 0)
                            }
                        }
                    }
                }
                var seq: UInt64 = 0
                var seenMergedLost: UInt64 = 0
                for await item in merged {
                    var msg = item.msg
                    // Items the merged buffer discarded before this one was dequeued widen the gap.
                    let nowMergedLost = mergedLost.load(ordering: .relaxed)
                    seq += item.gap + (nowMergedLost - seenMergedLost) + 1
                    seenMergedLost = nowMergedLost
                    msg.seq = seq
                    try await response.write(msg)
                }
                group.cancelAll()
            }
        } onCancelRPC: {
            sink.finish()
        }
    }
}

/// Per-subscription channel drain tasks (one per channel engine), cancelled when the RPC ends.
private final class ChannelDrains: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ChannelID: Task<Void, Never>] = [:]

    func start(_ id: ChannelID, _ body: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard tasks[id] == nil else { return }
        tasks[id] = Task { await body() }
    }

    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }
}

