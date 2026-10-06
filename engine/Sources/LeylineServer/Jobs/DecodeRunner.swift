// SPDX-License-Identifier: GPL-3.0-or-later

// One decode job's moving parts: the channel's audio into the plugin, the plugin's records out
// (docs/design/decoders.md, "Decisions": "A decode job is a job").
//
// Nothing here runs on the DSP thread (invariant 4). The only hot-path code is the AudioFrameSource
// callback the channel already owns; the drain task pops what it left in the ring and writes it to
// the plugin, and the reader task stamps what comes back.

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

actor DecodeRunner {
    /// How long after a plugin exits before it is spawned again, and the ceiling the wait doubles
    /// to. A decoder that crashes on every frame should not spin the CPU.
    static let firstRestartSeconds: Double = 1
    static let maxRestartSeconds: Double = 30

    private let jobID: JobID
    private let installed: DecoderRegistry.Installed
    private let lease: any ChannelLease
    private let hub: RecordHub
    private let writer: RecordWriter?
    private let store: SessionStore
    private let frequencyHz: UInt64
    private let captureRateHz: UInt64
    private let tap: AudioTap
    /// The daemon-side record filter and where a passing record fires (docs/design/decoders.md,
    /// "Predicates and delivery"). An empty predicate matches everything; notify nil is delivery
    /// with no side channel. Both are read off the DecodeConfig in JobStore.startDecode.
    private let predicate: Leyline_V1_Predicate
    private let notify: Leyline_V1_NotifyTarget?
    private let notifier = Notifier()
    private let onStatus: @Sendable (Leyline_V1_JobState, String) async -> Void
    private let log: Logger

    /// The record sequence: 1-based and contiguous per job, so it continues from what a kept job's
    /// store already holds when the job is resumed after a restart.
    private var seq: UInt64
    /// Record count and last-record time, for the detail it publishes while RUNNING.
    private var liveness = DecodeLiveness()
    /// The DEGRADED detail while the channel is out of its capture, nil while it is in. Every
    /// RUNNING the runner would publish goes through `publishRunning`, which reads this, because
    /// the record count moving is not the channel coming back: records still arrive after the
    /// move, and the count's two-second republish would otherwise put a degraded job back to
    /// RUNNING while the capture is still away.
    private var awayDetail: String?
    private var rssiDBFS = Double.nan
    private var snrDB = Double.nan
    private var task: Task<Void, Never>?
    /// The plugin the drain is feeding. Held outside the actor because the drain runs as its own
    /// task: a pipe write must never park the actor that is also stamping records.
    private let currentPlugin = Mutex<PluginProcess?>(nil)
    private var stopped = false

    init(jobID: JobID, installed: DecoderRegistry.Installed, lease: any ChannelLease, hub: RecordHub,
         writer: RecordWriter?, store: SessionStore, frequencyHz: UInt64, captureRateHz: UInt64,
         tap: AudioTap, predicate: Leyline_V1_Predicate, notify: Leyline_V1_NotifyTarget?,
         onStatus: @escaping @Sendable (Leyline_V1_JobState, String) async -> Void,
         seqStart: UInt64 = 0)
    {
        self.jobID = jobID
        self.installed = installed
        self.lease = lease
        self.hub = hub
        self.writer = writer
        self.store = store
        self.frequencyHz = frequencyHz
        self.captureRateHz = captureRateHz
        self.tap = tap
        self.predicate = predicate
        self.notify = notify
        self.onStatus = onStatus
        seq = seqStart
        log = Logger(label: "leyline.jobs.decode")
    }

    func start() {
        task = Task { [weak self] in await self?.loop() }
    }

    /// Ends the job: the plugin goes, the store writer is closed and the radio goes back.
    func stop() async {
        task?.cancel()
        await teardown()
    }

    /// The same hand-back without cancelling the loop, for the paths that are already inside it.
    /// Idempotent: cancel, a failure and shutdown can all arrive.
    private func teardown() async {
        guard !stopped else { return }
        stopped = true
        if let plugin = currentPlugin.withLock({ $0 }) { await plugin.stop() }
        currentPlugin.withLock { $0 = nil }
        await writer?.close()
        await lease.release()
    }

    // MARK: The loop

    private func loop() async {
        let engine = lease.engine
        let audio = AudioFrameSource(captureRate: captureRateHz, audioRate: engine.audioRate, tap: tap)
        do {
            try await engine.attach(audio.sink)
        } catch {
            await onStatus(.failed, "the channel would not take the decoder's sink: \(error)")
            await teardown()
            return
        }
        let meter = Task { [weak self] in await self?.followMeter() }
        let health = Task { [weak self] in await self?.followChannel() }
        // One drain for the life of the job, not one per plugin: `AudioFrameSource.poke` has a
        // single iterator, and a second `for await` on it would see a finished stream and feed a
        // restarted plugin nothing. Frames written while no plugin is up are dropped, and the ring
        // reports what was lost as a Gap on the next frame that lands.
        let drain = Task { [weak self] in await self?.drain(audio: audio) }
        let counting = Task { [weak self] in await self?.followRecords() }
        var wait = Self.firstRestartSeconds
        var restarts = 0
        while !Task.isCancelled {
            let status = await runPlugin()
            if Task.isCancelled || stopped { break }
            restarts += 1
            // A coverage gap the job reports. A transcript's own Gap list arrives with the watch
            // job, which is not built yet (docs/plans/build-order.md).
            await onStatus(.degraded, "the decoder exited (status \(status)); restarting in \(Int(wait)) s (restart \(restarts))")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            wait = Swift.min(wait * 2, Self.maxRestartSeconds)
            if Task.isCancelled || stopped { break }
            await publishRunning(liveness.detail(decoder: installed.manifest.name))
        }
        meter.cancel()
        health.cancel()
        drain.cancel()
        counting.cancel()
        audio.wake()
        await engine.detach(audio.sink.id)
        audio.finish()
    }

    /// Spawns the plugin and pumps it until it exits or the job is cancelled. Returns its status.
    private func runPlugin() async -> Int32 {
        let process = PluginProcess(name: installed.manifest.name, executable: installed.executablePath,
                                    args: installed.manifest.args, directory: installed.directory)
        do {
            try await process.start(descriptor: descriptor())
        } catch {
            await onStatus(.failed, (error as? EngineError)?.message ?? "\(error)")
            await teardown()
            return -1
        }
        currentPlugin.withLock { $0 = process }
        await publishRunning(liveness.detail(decoder: installed.manifest.name))
        let status = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { [weak self] in
                for await record in process.records {
                    await self?.emit(record)
                }
                return nil
            }
            group.addTask {
                for await code in process.exits { return code }
                return 0
            }
            var out: Int32 = 0
            while let next = await group.next() {
                if let code = next {
                    out = code
                    break
                }
            }
            group.cancelAll()
            return out
        }
        await process.stop()
        currentPlugin.withLock { $0 = nil }
        return status
    }

    /// Audio out of the ring and into whichever plugin is up, one frame at a time. Nonisolated: it
    /// is the one part of the job that should never wait on the actor.
    private nonisolated func drain(audio: AudioFrameSource) async {
        var seq: UInt64 = 0
        var lastEnd: UInt64 = 0
        // The earliest sample the plugin has not seen, held open across dropped frames so the next
        // frame that lands reports the whole gap at once (invariant 3). nil when nothing is owed.
        var lostFrom: UInt64?
        for await _ in audio.poke {
            if Task.isCancelled { return }
            while let f = audio.next(s16: false) {
                // The ring dropped samples ahead of this frame: a hole from the last frame's end.
                if f.droppedSamples > 0, lostFrom == nil { lostFrom = lastEnd }
                let end = f.sampleStart + f.sampleCount
                defer { lastEnd = end }
                guard let process = currentPlugin.withLock({ $0 }) else {
                    // No plugin up (a restart is in flight): the frame is lost and the gap stays open.
                    if lostFrom == nil { lostFrom = f.sampleStart }
                    continue
                }
                seq += 1
                var frame = Leyline_V1_Frame()
                frame.streamID = streamID
                frame.seq = seq
                frame.time.captureID = lease.captureID.string
                frame.time.sampleIndex = f.sampleStart
                frame.payload = f.payload
                if let from = lostFrom {
                    frame.gap.fromSample = from
                    frame.gap.toSample = f.sampleStart
                }
                do {
                    switch try process.write(frame) {
                    case .written:
                        lostFrom = nil
                    case .droppedFull:
                        // The plugin has stopped reading. Drop the frame and keep the gap open. Not
                        // reading is not a failure: a decoder may legitimately ignore this audio.
                        if lostFrom == nil { lostFrom = f.sampleStart }
                    }
                } catch is PluginStalled {
                    // A frame stalled half-written: the stream is unsalvageable, so replace the
                    // plugin. The restart loop is what respawns; stopping it makes runPlugin return.
                    if lostFrom == nil { lostFrom = f.sampleStart }
                    await process.stop()
                    continue
                } catch {
                    // The plugin died between the check and the write; the restart loop handles it.
                    if lostFrom == nil { lostFrom = f.sampleStart }
                    continue
                }
            }
        }
    }

    // MARK: Stamping

    /// The daemon's own fields: a record id, the job, the channel, the sequence and the levels the
    /// engine measured. A plugin's values for these are overwritten.
    private func emit(_ incoming: Leyline_V1_DecodeRecord) async {
        var rec = incoming
        if rec.protocol.isEmpty { rec.protocol = installed.manifest.name }
        if rec.time.captureID.isEmpty { rec.time.captureID = lease.captureID.string }
        // The predicate filters delivery (docs/design/decoders.md, "Predicates and delivery"): a
        // record that does not match reaches neither the hub nor the store nor the notifier. An
        // empty predicate matches everything, so `ley decode` delivers all. Judged before the seq
        // is spent, so a delivered record's seq stays contiguous -- a hole is a lost record, never
        // a filtered one -- and the promoted fields it tests are the plugin's, set already.
        guard matches(rec, predicate) else { return }
        seq += 1
        rec.recordID = "rec_" + ULID().string
        rec.jobID = jobID.string
        rec.seq = seq
        rec.channelID = lease.channelID.string
        rec.rssiDbfs = rssiDBFS
        rec.snrDb = snrDB
        await hub.publish(rec)
        await writer?.append(rec)
        if liveness.noteRecord(), awayDetail == nil {
            await publishRunning(liveness.publish(decoder: installed.manifest.name))
        }
        // Off the hot path and fire-and-forget: a slow webhook or shell hook must never stall the
        // reader, so the notifier runs in its own task with the record it saw (invariant 4 is about
        // the DSP thread; this is well clear of it, but a stall here would still back the reader up).
        if let notify {
            let record = rec
            Task { [notifier] in await notifier.fire(record, notify) }
        }
    }

    private func noteMeter(power: Double, snr: Double) {
        rssiDBFS = power
        snrDB = snr
    }

    /// The channel's own telemetry, for the levels every record is stamped with. A meter reading is
    /// 100 ms old at worst and a packet is longer than that.
    private func followMeter() async {
        let subscription = lease.engine.telemetrySubscription()
        for await t in subscription.stream {
            if Task.isCancelled { return }
            if case .meter(_, let power, let snr, _, _, _, _, _) = t {
                noteMeter(power: power, snr: snr)
            }
        }
    }

    /// OUT_OF_CAPTURE degrades the job and the channel coming back restores it. The state is read
    /// from the channel engine rather than from the event stream: the engine holds the state, and
    /// the event only reports it.
    private func followChannel() async {
        var last: ChannelState?
        while !Task.isCancelled {
            let state = await lease.engine.state
            if state != last {
                last = state
                switch state {
                case .outOfCapture:
                    let detail = "the capture moved away from \(fmtMHz(frequencyHz)); waiting for it to come back"
                    awayDetail = detail
                    await onStatus(.degraded, detail)
                case .active:
                    awayDetail = nil
                    await publishRunning(liveness.detail(decoder: installed.manifest.name))
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// RUNNING with `detail`, or DEGRADED with the away detail while the channel is out of its
    /// capture. A plugin restart replaced the away detail with its own, so the restart's RUNNING
    /// puts the away detail back rather than claiming the job is decoding.
    private func publishRunning(_ detail: String) async {
        if let awayDetail {
            await onStatus(.degraded, awayDetail)
        } else {
            await onStatus(.running, detail)
        }
    }

    /// Republishes the running detail while the count moves, every DecodeLiveness.interval, so a
    /// busy decoder's count is current without a Job event per record.
    private func followRecords() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: DecodeLiveness.interval)
            if Task.isCancelled || stopped { return }
            if liveness.moved, awayDetail == nil {
                await publishRunning(liveness.publish(decoder: installed.manifest.name))
            }
        }
    }

    // MARK: The descriptor

    /// Named once, for the life of the runner: the plugin sees one stream, restarts included.
    private nonisolated let streamID = "plug_" + ULID().string

    private func descriptor() async -> Leyline_V1_StreamDescriptor {
        var d = Leyline_V1_StreamDescriptor()
        d.streamID = streamID
        d.kind = .audio
        // GAP_MARKED, so the decoder is told what was lost (invariant 3).
        d.policy = .gapMarked
        var audio = Leyline_V1_AudioParams()
        audio.sampleRate = lease.engine.audioRate
        audio.format = .f32
        audio.tap = tap == .demod ? .tapDemod : .tapAudio
        // Both taps carry the same units, so the descriptor answers the channel's full-scale
        // deviation whichever one the manifest asked for.
        let config = await lease.engine.config
        audio.fullScaleDeviationHz = UInt32(DemodulatorFactory.fullScaleDeviationHz(
            mode: config.mode, bandwidthHz: config.bandwidthHz).rounded())
        d.audio = audio
        // Where the channel is and how wide the radio around it is, so a plugin can report the
        // frequency a packet was on.
        d.centerHz = frequencyHz
        d.spanHz = captureRateHz
        d.grpc = true
        return d
    }

    private nonisolated func fmtMHz(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }
}
