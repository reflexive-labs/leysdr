// SPDX-License-Identifier: GPL-3.0-or-later

// One IQ decode job's moving parts: the capture's raw complex baseband (cf32) into the plugin, the
// plugin's records out (docs/design/decoders.md, "Multiplexing"; DecoderSignal SIGNAL_IQ). The
// sibling of DecodeRunner for a decoder that needs the signal before it is demodulated (ADS-B, the
// 433 MHz soup): there is no channel, so the decoder taps the whole capture band.
//
// Nothing here runs on the DSP thread (invariant 4). The only hot-path code is the IQFrameTap the
// capture already owns; the drain task pops what it left in the ring and writes it to the plugin,
// and the reader task stamps what comes back.

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

/// What the job table holds a decode job's runner as, so the audio and IQ runners share one slot
/// and one cancel path (JobStore.cancel).
protocol DecodeRunning: AnyObject, Sendable {
    func start() async
    func stop() async
}

extension DecodeRunner: DecodeRunning {}

actor IQDecodeRunner: DecodeRunning {
    /// Slots in the IQ frame ring: the bulk .iq stream's depth, one capture block (cf32) per slot.
    static let iqSlots = 8

    private let jobID: JobID
    private let installed: DecoderRegistry.Installed
    private let lease: any CaptureIQLease
    private let hub: RecordHub
    private let writer: RecordWriter?
    private let store: SessionStore
    /// The daemon-side record filter and where a passing record fires (docs/design/decoders.md,
    /// "Predicates and delivery"). An empty predicate matches everything; notify nil is delivery
    /// with no side channel.
    private let predicate: Leyline_V1_Predicate
    private let notify: Leyline_V1_NotifyTarget?
    private let notifier = Notifier()
    private let onStatus: @Sendable (Leyline_V1_JobState, String) async -> Void
    private let log: Logger

    /// The capture-IQ tap and its ring, held for the life of the runner: one stream the plugin
    /// sees, restarts included. The tap fills the ring on the DSP thread; the drain empties it.
    private let ring = FrameRing(slots: IQDecodeRunner.iqSlots, slotBytes: CaptureDSPCore.blockSize * 8)
    private nonisolated let tapID = StreamID()

    /// The record sequence: 1-based and contiguous per job, so it continues from what a kept job's
    /// store already holds when the job is resumed after a restart.
    private var seq: UInt64
    /// Record count and last-record time, for the detail it publishes while RUNNING.
    private var liveness = DecodeLiveness()
    private var task: Task<Void, Never>?
    /// The plugin the drain is feeding. Held outside the actor because the drain runs as its own
    /// task: a pipe write must never park the actor that is also stamping records.
    private let currentPlugin = Mutex<PluginProcess?>(nil)
    private var stopped = false

    init(jobID: JobID, installed: DecoderRegistry.Installed, lease: any CaptureIQLease, hub: RecordHub,
         writer: RecordWriter?, store: SessionStore,
         predicate: Leyline_V1_Predicate, notify: Leyline_V1_NotifyTarget?,
         onStatus: @escaping @Sendable (Leyline_V1_JobState, String) async -> Void,
         seqStart: UInt64 = 0)
    {
        self.jobID = jobID
        self.installed = installed
        self.lease = lease
        self.hub = hub
        self.writer = writer
        self.store = store
        self.predicate = predicate
        self.notify = notify
        self.onStatus = onStatus
        seq = seqStart
        log = Logger(label: "leyline.jobs.decode.iq")
    }

    func start() {
        task = Task { [weak self] in await self?.loop() }
    }

    /// Ends the job: the plugin goes, the store writer is closed and the capture lease goes back.
    func stop() async {
        task?.cancel()
        ring.wake()
        await teardown()
    }

    /// The same hand-back without cancelling the loop, for the paths already inside it. Idempotent:
    /// cancel, a failure and shutdown can all arrive.
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
        // The tap fans the capture's full-rate cf32 stream into the ring (invariant 4: it copies and
        // never blocks). One tap for the life of the job, not one per plugin.
        let tap = IQFrameTap(id: tapID, ring: ring)
        await lease.capture.addTap(tap)
        // One drain for the life of the job: `FrameRing.poke` has a single iterator, and a second
        // `for await` on it would see a finished stream and feed a restarted plugin nothing. Frames
        // written while no plugin is up are dropped, and the gap is held open until one lands.
        let drain = Task { [weak self] in await self?.drain() }
        let counting = Task { [weak self] in await self?.followRecords() }
        var wait = DecodeRunner.firstRestartSeconds
        var restarts = 0
        while !Task.isCancelled {
            let status = await runPlugin()
            if Task.isCancelled || stopped { break }
            restarts += 1
            // A coverage gap the job reports. A transcript's own Gap list arrives with the watch
            // job, which is not built yet (docs/plans/build-order.md).
            await onStatus(.degraded, "the decoder exited (status \(status)); restarting in \(Int(wait)) s (restart \(restarts))")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            wait = Swift.min(wait * 2, DecodeRunner.maxRestartSeconds)
            if Task.isCancelled || stopped { break }
            await onStatus(.running, liveness.detail(decoder: installed.manifest.name))
        }
        drain.cancel()
        counting.cancel()
        ring.wake()
        // A capture that goes away simply stops the tap delivering: this enabler keeps it simple and
        // does not degrade the job on detach (there is no channel to follow); that is a follow-up
        // (docs/design/decoders.md, "Multiplexing").
        await lease.capture.removeTap(id: tapID)
        ring.finish()
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
        await onStatus(.running, liveness.detail(decoder: installed.manifest.name))
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

    /// Capture IQ out of the ring and into whichever plugin is up, one frame at a time. Nonisolated:
    /// it is the one part of the job that should never wait on the actor. Built exactly like
    /// DecodeRunner's audio drain, minus the audio-rate scaling -- the ring already carries capture
    /// sample indices.
    private nonisolated func drain() async {
        var seq: UInt64 = 0
        var lastEnd: UInt64 = 0
        // The earliest sample the plugin has not seen, held open across dropped frames so the next
        // frame that lands reports the whole gap at once (invariant 3). nil when nothing is owed.
        var lostFrom: UInt64?
        for await _ in ring.poke {
            if Task.isCancelled { return }
            while let p = ring.pop() {
                // The ring evicted frames ahead of this one: a hole from the last frame's end.
                if p.droppedSamples > 0, lostFrom == nil { lostFrom = lastEnd }
                let end = p.sampleStart + p.sampleCount
                defer { lastEnd = end }
                guard let process = currentPlugin.withLock({ $0 }) else {
                    // No plugin up (a restart is in flight): the frame is lost and the gap stays open.
                    if lostFrom == nil { lostFrom = p.sampleStart }
                    continue
                }
                seq += 1
                var frame = Leyline_V1_Frame()
                frame.streamID = streamID
                frame.seq = seq
                frame.time.captureID = lease.captureID.string
                frame.time.sampleIndex = p.sampleStart
                frame.payload = p.payload
                if let from = lostFrom {
                    frame.gap.fromSample = from
                    frame.gap.toSample = p.sampleStart
                }
                do {
                    switch try process.write(frame) {
                    case .written:
                        lostFrom = nil
                    case .droppedFull:
                        // The plugin has stopped reading. Drop the frame and keep the gap open;
                        // not reading is not a failure.
                        if lostFrom == nil { lostFrom = p.sampleStart }
                    }
                } catch is PluginStalled {
                    // A frame stalled half-written: the stream is unsalvageable, so replace the
                    // plugin. The restart loop is what respawns; stopping it makes runPlugin return.
                    if lostFrom == nil { lostFrom = p.sampleStart }
                    await process.stop()
                    continue
                } catch {
                    // The plugin died between the check and the write; the restart loop handles it.
                    if lostFrom == nil { lostFrom = p.sampleStart }
                    continue
                }
            }
        }
    }

    // MARK: Stamping

    /// The daemon's own fields: a record id, the job, the sequence. There is no channel, so
    /// `channel_id` is empty and `rssi_dbfs`/`snr_db` stay NaN -- an IQ decoder reads the whole
    /// band and there is no channel meter to stamp from (docs/design/decoders.md, section 4).
    private func emit(_ incoming: Leyline_V1_DecodeRecord) async {
        var rec = incoming
        if rec.protocol.isEmpty { rec.protocol = installed.manifest.name }
        if rec.time.captureID.isEmpty { rec.time.captureID = lease.captureID.string }
        // The predicate filters delivery: a record that does not match reaches neither the hub nor
        // the store nor the notifier. Judged before the seq is spent, so a delivered record's seq
        // stays contiguous -- a hole is a lost record, never a filtered one.
        guard matches(rec, predicate) else { return }
        seq += 1
        rec.recordID = "rec_" + ULID().string
        rec.jobID = jobID.string
        rec.seq = seq
        rec.channelID = ""
        rec.rssiDbfs = Double.nan
        rec.snrDb = Double.nan
        await hub.publish(rec)
        await writer?.settleAnchor(of: lease.captureID, in: store)
        await writer?.append(rec)
        if liveness.noteRecord() {
            await onStatus(.running, liveness.publish(decoder: installed.manifest.name))
        }
        // Off the hot path and fire-and-forget: a slow webhook or shell hook must never stall the
        // reader, so the notifier runs in its own task with the record it saw.
        if let notify {
            let record = rec
            Task { [notifier] in await notifier.fire(record, notify) }
        }
    }

    /// Republishes the running detail while the count moves, every DecodeLiveness.interval, so a
    /// busy decoder's count is current without a Job event per record.
    private func followRecords() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: DecodeLiveness.interval)
            if Task.isCancelled || stopped { return }
            if liveness.moved {
                await onStatus(.running, liveness.publish(decoder: installed.manifest.name))
            }
        }
    }

    // MARK: The descriptor

    /// Named once, for the life of the runner: the plugin sees one stream, restarts included.
    private nonisolated let streamID = "plug_" + ULID().string

    private func descriptor() async -> Leyline_V1_StreamDescriptor {
        var d = Leyline_V1_StreamDescriptor()
        d.streamID = streamID
        d.kind = .iq
        // GAP_MARKED, so the decoder is told what was lost (invariant 3).
        d.policy = .gapMarked
        var iq = Leyline_V1_IqParams()
        iq.sampleRate = lease.sampleRateHz
        iq.format = .cf32
        d.iq = iq
        // The whole band the decoder is reading: where the capture sits and how wide it is.
        d.centerHz = await lease.centerHz
        d.spanHz = lease.sampleRateHz
        d.grpc = true
        return d
    }
}
