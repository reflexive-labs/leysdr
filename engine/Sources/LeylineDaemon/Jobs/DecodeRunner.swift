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
    private let onStatus: @Sendable (Leyline_V1_JobState, String) async -> Void
    private let log: Logger

    private var seq: UInt64 = 0
    private var rssiDBFS = Double.nan
    private var snrDB = Double.nan
    private var task: Task<Void, Never>?
    /// The plugin the drain is feeding. Held outside the actor because the drain runs as its own
    /// task: a pipe write must never park the actor that is also stamping records.
    private let currentPlugin = Mutex<PluginProcess?>(nil)
    private var stopped = false

    init(jobID: JobID, installed: DecoderRegistry.Installed, lease: any ChannelLease, hub: RecordHub,
         writer: RecordWriter?, store: SessionStore, frequencyHz: UInt64, captureRateHz: UInt64,
         tap: AudioTap, onStatus: @escaping @Sendable (Leyline_V1_JobState, String) async -> Void)
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
        self.onStatus = onStatus
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
        var wait = Self.firstRestartSeconds
        var restarts = 0
        while !Task.isCancelled {
            let status = await runPlugin()
            if Task.isCancelled || stopped { break }
            restarts += 1
            // A coverage gap the job says out loud. The transcript's own Gap list arrives with D.15.
            await onStatus(.degraded, "the decoder exited (status \(status)); restarting in \(Int(wait)) s (restart \(restarts))")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            wait = Swift.min(wait * 2, Self.maxRestartSeconds)
            if Task.isCancelled || stopped { break }
            await onStatus(.running, "decoding with \(installed.manifest.name)")
        }
        meter.cancel()
        health.cancel()
        drain.cancel()
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
        await onStatus(.running, "decoding with \(installed.manifest.name)")
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
        for await _ in audio.poke {
            if Task.isCancelled { return }
            while let f = audio.next(s16: false) {
                seq += 1
                var frame = Leyline_V1_Frame()
                frame.streamID = streamID
                frame.seq = seq
                frame.time.captureID = lease.captureID.string
                frame.time.sampleIndex = f.sampleStart
                frame.payload = f.payload
                // GAP_MARKED: what the ring dropped is stated rather than hidden, so a decoder
                // knows its bit clock has a hole in it (invariant 3).
                if f.droppedSamples > 0 {
                    frame.gap.fromSample = lastEnd
                    frame.gap.toSample = f.sampleStart
                }
                lastEnd = f.sampleStart + f.sampleCount
                guard let process = currentPlugin.withLock({ $0 }) else { continue }
                do {
                    try process.write(frame)
                } catch {
                    // The plugin died between the check and the write; the restart loop is already
                    // on it and this frame is part of the gap it costs.
                    continue
                }
            }
        }
    }

    // MARK: Stamping

    /// The daemon's own fields (DEC-1): a record id, the job, the channel, the sequence and the
    /// levels the engine measured. A plugin's values for these are overwritten.
    private func emit(_ incoming: Leyline_V1_DecodeRecord) async {
        var rec = incoming
        seq += 1
        rec.recordID = "rec_" + ULID().string
        rec.jobID = jobID.string
        rec.seq = seq
        rec.channelID = lease.channelID.string
        rec.rssiDbfs = rssiDBFS
        rec.snrDb = snrDB
        if rec.protocol.isEmpty { rec.protocol = installed.manifest.name }
        if rec.time.captureID.isEmpty { rec.time.captureID = lease.captureID.string }
        await hub.publish(rec)
        await writer?.append(rec)
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
            if case .meter(_, let power, let snr, _, _, _) = t {
                noteMeter(power: power, snr: snr)
            }
        }
    }

    /// OUT_OF_CAPTURE degrades the job and the channel coming back restores it. The state is read
    /// from the channel engine rather than from the event stream: the engine is the thing that
    /// knows, and the event is only its echo.
    private func followChannel() async {
        var last: ChannelState?
        while !Task.isCancelled {
            let state = await lease.engine.state
            if state != last {
                last = state
                switch state {
                case .outOfCapture:
                    await onStatus(.degraded, "the capture moved away from \(fmtMHz(frequencyHz)); waiting for it to come back")
                case .active:
                    await onStatus(.running, "decoding with \(installed.manifest.name)")
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: The descriptor

    /// Named once, for the life of the runner: the plugin sees one stream, restarts included.
    private nonisolated let streamID = "plug_" + ULID().string

    private func descriptor() async -> Leyline_V1_StreamDescriptor {
        var d = Leyline_V1_StreamDescriptor()
        d.streamID = streamID
        d.kind = .audio
        // The one delivery policy a decoder can reason about: what was lost is named (invariant 3).
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
        // Where the channel is and how wide the radio around it is, so a plugin that wants to say
        // where a packet sat can.
        d.centerHz = frequencyHz
        d.spanHz = captureRateHz
        d.grpc = true
        return d
    }

    private nonisolated func fmtMHz(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }
}
