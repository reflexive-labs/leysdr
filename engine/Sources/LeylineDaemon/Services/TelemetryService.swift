// leyline.v1.Telemetry: fans channel meters / squelch transitions and capture activity into one
// sequenced stream per subscriber (sample timebase on every message). Delivery is drop-oldest:
// records the engine evicted before this subscriber drained them advance `seq` without being
// sent, so a slow subscriber sees a gap in `seq` for every reading it missed.

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct TelemetryService: Leyline_V1_Telemetry.SimpleServiceProtocol {
    let store: SessionStore
    static let activityIntervalNs: UInt64 = 1_000_000_000

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

        // Each merged item carries the number of records evicted ahead of it (a `seq` gap to open).
        let (merged, sink) = AsyncStream<(msg: Leyline_V1_TelemetryMsg, gap: UInt64)>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let events = await store.events(scope: captureFilter.map { .capture($0) } ?? .daemon)
        let st = self.store
        let capFilter = captureFilter
        let chanFilter = channelFilter

        let drains = ChannelDrains()
        defer { drains.cancelAll() }
        func track(_ id: ChannelID, _ engine: any ChannelEngine) {
            guard chanFilter == nil || chanFilter == id else { return }
            drains.start(id) {
                var seenDropped = engine.telemetryDropped
                var gap: UInt64 = 0
                for await t in engine.telemetry() {
                    if Task.isCancelled { return }
                    // Evictions since this drain's previous record become a gap on the merged stream;
                    // a gap accrued behind a filtered-out record carries over to the next one sent.
                    let nowDropped = engine.telemetryDropped
                    gap += UInt64(max(0, nowDropped - seenDropped))
                    seenDropped = nowDropped
                    var msg = Leyline_V1_TelemetryMsg()
                    switch t {
                    case .meter(let time, let power, let snr, let open):
                        guard wants(.meter) else { continue }
                        msg.time = ProtoMapping.sampleTime(time)
                        msg.meter.channelID = id.string
                        msg.meter.powerDbfs = power
                        msg.meter.snrDb = snr
                        msg.meter.squelchOpen = open
                    case .squelch(let time, let open):
                        guard wants(.squelchTransition) else { continue }
                        msg.time = ProtoMapping.sampleTime(time)
                        msg.squelch.channelID = id.string
                        msg.squelch.open = open
                    }
                    sink.yield((msg, gap))
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
                                sink.yield((msg, 0))
                            }
                        }
                    }
                }
                var seq: UInt64 = 0
                for await item in merged {
                    var msg = item.msg
                    seq += item.gap + 1
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

