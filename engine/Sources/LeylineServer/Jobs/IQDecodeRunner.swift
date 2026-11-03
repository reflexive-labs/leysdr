// SPDX-License-Identifier: GPL-3.0-or-later

// One IQ decode job's moving parts: the capture's raw complex baseband (cf32) into the plugin, the
// plugin's records out (docs/design/decoders.md, "Multiplexing"; DecoderSignal SIGNAL_IQ). The
// sibling of DecodeRunner for a decoder that needs the signal before it is demodulated (ADS-B, the
// 433 MHz soup): there is no channel, so the decoder taps the whole capture band.
//
// Nothing here runs on the DSP thread (invariant 4). The only hot-path code is the IQFrameTap the
// capture already owns; the drain task pops what it left in the ring and writes it to the plugin,
// and the reader task stamps what comes back.
//
// The job follows its capture the way DecodeRunner follows its channel. The plugin's descriptor
// names one centre and one rate for the life of the stream, and the wire cannot change them: a
// plugin reads one StreamDescriptor and then only Frames (bulk.proto). So the job holds the plugin
// to the tuning it started on. A capture that leaves it -- retuned off the frequency, recentred
// somewhere that still covers it, set to another rate, or detached -- is treated as moved away: the
// job goes DEGRADED, its IQ is withheld and the next frame the plugin gets carries the gap. Feeding
// a recentred band under the old descriptor would put every signal at the wrong offset, and
// respawning the plugin with a new descriptor would drop its decode state and, for a decoder that
// asked for a centred capture (`needs_dedicated_capture`), decode a band it said it cannot.

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
    /// Ends the job, with the reason a recording the job writes records: "cancelled", or
    /// "restart" for a daemon going down under it.
    func stop(endedBy: String) async
}

extension DecodeRunning {
    func stop(endedBy _: String) async { await stop() }
}

extension DecodeRunner: DecodeRunning {}

actor IQDecodeRunner: DecodeRunning {
    /// Slots in the IQ frame ring: the bulk .iq stream's depth, one capture block (cf32) per slot.
    static let iqSlots = 8
    /// How often the job reads where its capture is. A frame captured within this of a retune can
    /// be fed or withheld on the wrong side of it, as a retune's in-flight samples are anyway.
    static let followInterval: Duration = .milliseconds(100)

    private let jobID: JobID
    private let installed: DecoderRegistry.Installed
    private let lease: any CaptureIQLease
    private let hub: RecordHub
    private let writer: RecordWriter?
    private let store: SessionStore
    /// The frequency the job was started for, which the capture's span must cover.
    private let frequencyHz: UInt64
    /// The daemon-side record filter and where a passing record fires (docs/design/decoders.md,
    /// "Predicates and delivery"). An empty predicate matches everything; notify nil is delivery
    /// with no side channel.
    private let predicate: Leyline_V1_Predicate
    private let notify: Leyline_V1_NotifyTarget?
    private let notifier = Notifier()
    /// The user's keys, for a plugin whose manifest names a provider.
    private let credentials: CredentialStore?
    private let onStatus: @Sendable (Leyline_V1_JobState, String) async -> Void
    /// Ends the job with a code of its own, where `onStatus(.failed, …)` would say the decoder
    /// failed. Nil falls back to that.
    private let onFailure: (@Sendable (EngineError) async -> Void)?
    private let log: Logger

    /// The capture-IQ tap and its ring, held for the life of the runner: one stream the plugin
    /// sees, restarts included. The tap fills the ring on the DSP thread; the drain empties it.
    private let ring = FrameRing(slots: IQDecodeRunner.iqSlots, slotBytes: CaptureDSPCore.blockSize * 8)
    private nonisolated let tapID = StreamID()

    /// The record sequence: 1-based and contiguous per job, so it continues from what a kept job's
    /// store already holds when the job is resumed after a restart.
    private var seq: UInt64
    /// Record count and last-record time, for the detail it publishes while RUNNING.
    private var liveness: DecodeLiveness
    /// Where the capture was when the job started: the centre and rate every descriptor the plugin
    /// gets names, restarts included. Read once, before the plugin is spawned.
    private var tuning: (centerHz: UInt64, rate: UInt64) = (0, 0)
    /// The DEGRADED detail while the capture is away from `tuning`, nil while it is there. Every
    /// RUNNING the runner would publish goes through `publishRunning`, which reads this.
    private var awayDetail: String?
    /// The same fact for the drain, which withholds frames while it is set.
    private let withheld = Mutex(false)
    /// The capture's `tuningGeneration` at the follower's last look. A change while the centre and
    /// rate still match is a retune away and back between two looks.
    private var seenGeneration: UInt64 = 0
    /// Set by the follower when that happened; the drain withholds the next frame, so the one after
    /// it carries a gap, and clears it.
    private let regap = Mutex(false)
    private var task: Task<Void, Never>?
    /// The plugin the drain is feeding. Held outside the actor because the drain runs as its own
    /// task: a pipe write must never park the actor that is also stamping records.
    private let currentPlugin = Mutex<PluginProcess?>(nil)
    private var stopped = false

    init(jobID: JobID, installed: DecoderRegistry.Installed, lease: any CaptureIQLease, hub: RecordHub,
         writer: RecordWriter?, store: SessionStore, frequencyHz: UInt64,
         predicate: Leyline_V1_Predicate, notify: Leyline_V1_NotifyTarget?,
         credentials: CredentialStore? = nil, gainNote: String? = nil,
         onStatus: @escaping @Sendable (Leyline_V1_JobState, String) async -> Void,
         onFailure: (@Sendable (EngineError) async -> Void)? = nil,
         seqStart: UInt64 = 0)
    {
        self.credentials = credentials
        self.jobID = jobID
        self.installed = installed
        self.lease = lease
        self.hub = hub
        self.writer = writer
        self.store = store
        self.frequencyHz = frequencyHz
        self.predicate = predicate
        self.notify = notify
        liveness = DecodeLiveness(note: gainNote)
        self.onStatus = onStatus
        self.onFailure = onFailure
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
        let snapshot = await lease.capture.snapshot
        tuning = (snapshot.centerHz, snapshot.sampleRate)
        seenGeneration = snapshot.tuningGeneration
        // The tap fans the capture's full-rate cf32 stream into the ring (invariant 4: it copies and
        // never blocks). One tap for the life of the job, not one per plugin.
        let tap = IQFrameTap(id: tapID, ring: ring)
        await lease.capture.addTap(tap)
        // One drain for the life of the job: `FrameRing.poke` has a single iterator, and a second
        // `for await` on it would see a finished stream and feed a restarted plugin nothing. Frames
        // written while no plugin is up are dropped, and the gap is held open until one lands.
        let drain = Task { [weak self] in await self?.drain() }
        let counting = Task { [weak self] in await self?.followRecords() }
        let following = Task { [weak self] in await self?.followCapture() }
        var wait = DecodeRunner.firstRestartSeconds
        var restarts = 0
        while !Task.isCancelled {
            let (status, said) = await runPlugin()
            if Task.isCancelled || stopped { break }
            if status == DecodeRunner.inputRefusedExitStatus {
                // The plugin cannot decode this capture, and a restart reads the same descriptor.
                // The capture goes back before the job says FAILED, so nobody sees one without the other.
                let error = DecodeRunner.inputRefused(installed.manifest.name, said: await redacted(said ?? ""))
                await teardown()
                if let onFailure { await onFailure(error) } else { await onStatus(.failed, error.message) }
                break
            }
            restarts += 1
            // A coverage gap the job reports. A transcript's own Gap list arrives with the watch
            // job, which is not built yet (docs/plans/build-order.md).
            await onStatus(.degraded, "the decoder exited (status \(status)); restarting in \(Int(wait)) s (restart \(restarts))")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            wait = Swift.min(wait * 2, DecodeRunner.maxRestartSeconds)
            if Task.isCancelled || stopped { break }
            await publishRunning(liveness.detail(decoder: installed.manifest.name))
        }
        drain.cancel()
        counting.cancel()
        following.cancel()
        ring.wake()
        await lease.capture.removeTap(id: tapID)
        ring.finish()
    }

    /// The plugin's words with its key taken out, before they reach `status_detail`.
    private func redacted(_ text: String) async -> String {
        let provider = installed.manifest.credentialProvider
        guard !provider.isEmpty, let secret = try? await credentials?.secret(provider: provider) else { return text }
        return WorkerProcess.redacting(secret, in: text)
    }

    /// Spawns the plugin and pumps it until it exits or the job is cancelled. Returns its status,
    /// and for a refused input the last line it wrote on stderr, which says why.
    private func runPlugin() async -> (status: Int32, said: String?) {
        let process = PluginProcess(name: installed.manifest.name, executable: installed.executablePath,
                                    args: await pluginArguments(for: installed.manifest, from: credentials),
                                    directory: installed.directory)
        do {
            let credential = try await pluginCredential(for: installed.manifest, from: credentials)
            try await process.start(descriptor: descriptor(), credential: credential)
        } catch {
            await onStatus(.failed, (error as? EngineError)?.message ?? "\(error)")
            await teardown()
            return (-1, nil)
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
        let said = status == DecodeRunner.inputRefusedExitStatus ? await process.lastErrorLine() : nil
        await process.stop()
        currentPlugin.withLock { $0 = nil }
        return (status, said)
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
                if withheld.withLock({ $0 }) {
                    // The capture is away from the tuning the plugin was told: the frame is not
                    // the band the descriptor names, so it is lost and the gap stays open.
                    if lostFrom == nil { lostFrom = p.sampleStart }
                    continue
                }
                if regap.withLock({ let owed = $0; $0 = false; return owed }) {
                    // The capture was retuned away and back since the follower last looked, so
                    // the plugin has had samples of another band. This frame is withheld and the
                    // next one carries the gap, which tells the plugin its stream broke.
                    if lostFrom == nil { lostFrom = p.sampleStart }
                    continue
                }
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
        if liveness.noteRecord(), awayDetail == nil {
            await publishRunning(liveness.publish(decoder: installed.manifest.name))
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
            if liveness.moved, awayDetail == nil {
                await publishRunning(liveness.publish(decoder: installed.manifest.name))
            }
        }
    }

    // MARK: Following the capture

    /// Reads where the capture is every `followInterval` and moves the job between RUNNING and
    /// DEGRADED as it leaves and regains the tuning the plugin was told. The state is read from the
    /// capture engine, which holds it, rather than from the event stream, which only reports it.
    private func followCapture() async {
        while !Task.isCancelled, !stopped {
            let snapshot = await lease.capture.snapshot
            let why = await awayReason(snapshot)
            if why == nil, awayDetail == nil, snapshot.tuningGeneration != seenGeneration {
                // Home at both looks, but retuned in between (away and back, or set again where it
                // was): treated as moved, for as long as one frame.
                regap.withLock { $0 = true }
            }
            seenGeneration = snapshot.tuningGeneration
            if why != awayDetail {
                awayDetail = why
                withheld.withLock { $0 = why != nil }
                if let why {
                    await onStatus(.degraded, why)
                } else {
                    await publishRunning(liveness.detail(decoder: installed.manifest.name))
                }
            }
            try? await Task.sleep(for: Self.followInterval)
        }
    }

    /// Why the capture is not the band the plugin's descriptor names, or nil when it is. Once the
    /// move is published the detail names who made it ("paused: the app tuned NESDR SMArt v5 to
    /// 146.520 MHz; ..."); until then, and for a move nobody is named for, it says what moved.
    private func awayReason(_ snapshot: CaptureSnapshot) async -> String? {
        let waiting = "waiting for it to come back"
        if snapshot.detached { return "the radio went away; \(waiting)" }
        let half = snapshot.sampleRate / 2
        let covers = frequencyHz + half >= snapshot.centerHz && frequencyHz <= snapshot.centerHz + half
        let away = !covers || snapshot.centerHz != tuning.centerHz || snapshot.sampleRate != tuning.rate
        guard away else { return nil }
        let moved = await store.whoMoved(lease.captureID)
        if !covers {
            if let moved { return "paused: \(moved); resumes when \(fmtMHz(frequencyHz)) is back in the capture" }
            return "the capture moved away from \(fmtMHz(frequencyHz)); \(waiting)"
        }
        if snapshot.centerHz != tuning.centerHz {
            if let moved { return "paused: \(moved); resumes when the capture is back on \(fmtMHz(tuning.centerHz))" }
            return "the capture moved from \(fmtMHz(tuning.centerHz)) to \(fmtMHz(snapshot.centerHz)); \(waiting)"
        }
        if let moved {
            return "paused: \(moved); resumes when the capture is back at " + String(format: "%.3f MSPS", Double(tuning.rate) / 1e6)
        }
        return String(format: "the capture's rate changed from %.3f to %.3f MSPS; ",
                      Double(tuning.rate) / 1e6, Double(snapshot.sampleRate) / 1e6) + waiting
    }

    /// RUNNING with `detail`, or DEGRADED with the away detail while the capture is away. A plugin
    /// restart replaced the away detail with its own, so the restart's RUNNING puts it back rather
    /// than claiming the job is decoding.
    private func publishRunning(_ detail: String) async {
        if let awayDetail {
            await onStatus(.degraded, awayDetail)
        } else {
            await onStatus(.running, detail)
        }
    }

    private nonisolated func fmtMHz(_ hz: UInt64) -> String { String(format: "%.3f MHz", Double(hz) / 1e6) }

    // MARK: The descriptor

    /// Named once, for the life of the runner: the plugin sees one stream, restarts included.
    private nonisolated let streamID = "plug_" + ULID().string

    private func descriptor() -> Leyline_V1_StreamDescriptor {
        var d = Leyline_V1_StreamDescriptor()
        d.streamID = streamID
        d.kind = .iq
        // GAP_MARKED, so the decoder is told what was lost (invariant 3).
        d.policy = .gapMarked
        var iq = Leyline_V1_IqParams()
        iq.sampleRate = tuning.rate
        iq.format = .cf32
        d.iq = iq
        // The whole band the decoder is reading: where the capture sat when the job started and
        // how wide it is. The job holds the plugin to it (`followCapture`).
        d.centerHz = tuning.centerHz
        d.spanHz = tuning.rate
        d.grpc = true
        return d
    }
}
