// SPDX-License-Identifier: GPL-3.0-or-later

// The job table. A table of watches, not a workflow engine: no retry DAG, no replay.
//
// Jobs and their scans live in memory and are lost on restart, because an ad-hoc scan is ephemeral
// by design -- persistence follows intent (invariant 8), and nobody typing `ley scan` has declared
// an intent to keep anything. The one job that has declared it, a decode job started with `keep`,
// is written to `kept-jobs.json` beside the record store and resumed at the next boot under the
// same id, its records appending to the same files. The rest of the durable job store (recurring
// scans, watch jobs, transcripts) is not built yet (docs/plans/build-order.md).

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

actor JobStore {
    /// Finished jobs kept so a client can re-read one. Bounded: this is memory, not a store.
    static let keepFinished = 16
    /// How long CancelJob waits for a sweep to settle before answering anyway. The teardown it is
    /// waiting on is uncancellable USB work -- `device.open` on the way in, `stopStreaming`'s own
    /// 1 s + 3 s budget on the way out -- so this is a bound on the answer, not on the work.
    static let cancelWaitSeconds = 3.0
    /// Per-subscriber detection buffer depth before the oldest undelivered reading is discarded
    /// (and counted).
    static let detectionCapacity = 64

    struct Entry {
        var proto: Leyline_V1_Job
        var scan: Leyline_V1_Scan?
        var task: Task<Void, Never>?
        /// The connection that asked for it. When that connection goes, so does the job: a sweep
        /// with no reader only ties up the radio.
        var ownerClientID: String
        /// A decode job's runner (audio or IQ), holding its plugin, lease and store writer. Nil for
        /// every other kind.
        var decode: (any DecodeRunning)?
        /// A record job's runner, holding its lease, gate and part writer. Nil for every other kind.
        var record: (any RecordRunning)?
        /// `keep`: persistence follows intent (invariant 8). A kept job outlives its client.
        var keep = false
    }

    /// Live states. A decode job sits in DEGRADED while its capture has moved away from it, and is
    /// no more finished there than it is while RUNNING.
    static func isLive(_ state: Leyline_V1_JobState) -> Bool {
        state == .running || state == .degraded
    }

    let store: SessionStore
    let allocator: SessionCaptureAllocator
    /// Decoders as installed on disk, and the kept-records store (docs/design/decoders.md).
    let decoders: DecoderRegistry
    let records: RecordStore
    /// Where recordings are written (docs/design/recording.md, "Files").
    let recordings: RecordingStore
    let hub = RecordHub()
    let log = Logger(label: "leyline.jobs")
    var entries: [JobID: Entry] = [:]
    var order: [JobID] = []
    private var detectionSinks: [UUID: (filter: CaptureID?,
                                        continuation: AsyncStream<(Leyline_V1_Detection, SampleTime)>.Continuation,
                                        subscription: DetectionSubscription)] = [:]
    /// Set by cancelAll: the daemon is going down, and a kept job ending now is to be resumed,
    /// not forgotten.
    private var shuttingDown = false

    init(store: SessionStore, allocator: SessionCaptureAllocator, decoders: DecoderRegistry,
         records: RecordStore, recordings: RecordingStore)
    {
        self.store = store
        self.allocator = allocator
        self.decoders = decoders
        self.records = records
        self.recordings = recordings
    }

    // MARK: Kept jobs across a restart

    /// One kept decode job as the file holds it: enough to start it again as the same job.
    struct KeptJob: Codable, Sendable {
        var jobID: String
        var createdAtNs: Int64
        /// The DecodeConfig in proto3 JSON, so the file carries no shape of its own.
        var config: String
        var createdBy: KeptClient

        struct KeptClient: Codable, Sendable {
            var clientID: String
            var kind: String
            var label: String
            enum CodingKeys: String, CodingKey {
                case clientID = "client_id"
                case kind, label
            }
        }

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
            case createdAtNs = "created_at_ns"
            case config
            case createdBy = "created_by"
        }
    }

    private struct KeptFile: Codable {
        var jobs: [KeptJob]
    }

    /// `kept-jobs.json` beside the record store, which is where a kept job's records already are.
    nonisolated var keptJobsPath: String { records.directory + "/kept-jobs.json" }

    /// Rewrites the file from the live kept jobs. Called when one starts and when one ends, not
    /// on shutdown: a kept job the daemon took down with itself is exactly the one to bring back.
    func persistKept() {
        var kept: [KeptJob] = []
        for id in order {
            guard let e = entries[id], e.keep, Self.isLive(e.proto.state), case .decode(let config) = e.proto.config else { continue }
            let by = e.proto.createdBy
            kept.append(KeptJob(jobID: id.string, createdAtNs: e.proto.createdAtNs,
                                config: (try? config.jsonString()) ?? "{}",
                                createdBy: .init(clientID: by.clientID, kind: by.kind, label: by.label)))
        }
        do {
            try FileManager.default.createDirectory(atPath: records.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(KeptFile(jobs: kept)).write(to: URL(fileURLWithPath: keptJobsPath), options: .atomic)
        } catch {
            log.warning("could not write \(keptJobsPath): \(error); kept jobs will not survive a restart")
        }
    }

    /// The kept jobs the last daemon left running, from disk. Advisory: a missing or unreadable
    /// file is an empty list.
    private func readKept() -> [KeptJob] {
        guard let data = FileManager.default.contents(atPath: keptJobsPath) else { return [] }
        do {
            return try JSONDecoder().decode(KeptFile.self, from: data).jobs
        } catch {
            log.warning("\(keptJobsPath) does not parse (\(error)); no kept jobs resumed")
            return []
        }
    }

    /// Brings back the kept jobs the last daemon was running, once a radio is here to run them
    /// on. Returns at once; the wait for a radio (an rtl_tcp reconnect takes seconds) happens on
    /// its own task, bounded, and a job whose radio never comes fails the way it would have
    /// failed at start, with the reason in its status.
    func resumeKept() {
        let kept = readKept()
        guard !kept.isEmpty else { return }
        log.info("resuming \(kept.count) kept decode job(s) from \(keptJobsPath)")
        Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(Self.resumeWaitSeconds))
            while await self.store.snapshot(scope: .daemon).devices.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            for job in kept {
                await self.resume(job)
            }
        }
    }

    /// How long a resume waits for a radio before starting the jobs anyway.
    static let resumeWaitSeconds = 20.0

    private func resume(_ kept: KeptJob) async {
        guard let id = JobID(string: kept.jobID) else {
            log.warning("kept job \(kept.jobID): not a job id; dropped")
            return
        }
        guard let config = try? Leyline_V1_DecodeConfig(jsonString: kept.config) else {
            log.warning("kept job \(kept.jobID): its config does not parse; dropped")
            return
        }
        let by = ClientContext(id: kept.createdBy.clientID, kind: kept.createdBy.kind, label: kept.createdBy.label)
        do {
            _ = try await startDecode(config: config, by: by, resuming: (id: id, createdAtNs: kept.createdAtNs))
        } catch {
            // A decoder that is no longer installed, most likely. Logged once, then dropped: the
            // file is rewritten from what is live, and this is not.
            log.warning("kept job \(kept.jobID) could not be resumed: \(error)")
            persistKept()
        }
    }

    // MARK: Detections on the telemetry plane

    /// Live detections, optionally filtered to one capture. Drop-oldest: a subscriber that falls
    /// behind loses the oldest readings, and the count on the returned subscription lets the
    /// telemetry plane widen its `seq` gap by exactly what was lost.
    func detections(captureID: CaptureID?) -> DetectionSubscription {
        let (stream, continuation) = AsyncStream<(Leyline_V1_Detection, SampleTime)>.makeStream(bufferingPolicy: .bufferingNewest(Self.detectionCapacity))
        let subscription = DetectionSubscription(stream: stream)
        let key = UUID()
        detectionSinks[key] = (captureID, continuation, subscription)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropDetectionSink(key) }
        }
        return subscription
    }

    private func dropDetectionSink(_ key: UUID) { detectionSinks[key] = nil }

    private func publish(_ d: Leyline_V1_Detection, at time: SampleTime, captureID: CaptureID) {
        for sink in detectionSinks.values where sink.filter == nil || sink.filter == captureID {
            if case .dropped = sink.continuation.yield((d, time)) { sink.subscription.countDrop() }
        }
    }

    // MARK: The table

    func snapshot() -> [Leyline_V1_Job] { order.compactMap { entries[$0]?.proto } }

    func job(_ id: JobID) -> Leyline_V1_Job? { entries[id]?.proto }

    func scan(_ id: ScanID) -> Leyline_V1_Scan? {
        for e in entries.values {
            if let s = e.scan, s.scanID == id.string { return s }
        }
        return nil
    }

    func cancel(_ id: JobID) async -> Leyline_V1_Job? {
        guard let e = entries[id] else { return nil }
        e.task?.cancel()
        // A decode job's teardown is the runner's: the plugin goes, the store writer is closed and
        // the channel and any capture it built go back.
        if let runner = e.decode {
            await runner.stop()
            await finish(id, state: .cancelled, detail: "cancelled")
            return entries[id]?.proto
        }
        // A record job's is the same shape: the open part is closed and the manifest records how it
        // ended, so a cancelled recording is complete rather than damaged, and that is the normal
        // way an open-ended one stops.
        if let runner = e.record {
            // A daemon going down under a recording is not the client cancelling one, and the
            // manifest records which. A restart ends a recording rather than resuming it
            // (docs/design/recording.md).
            await runner.stop(endedBy: shuttingDown ? "restart" : "cancelled")
            let detail = entries[id].map { $0.proto.statusDetail } ?? ""
            // A recording that heard nothing was discarded and ended COMPLETED with the detail
            // that says so (docs/design/recording.md, "Nothing heard"); that detail stands.
            let kept = detail.hasPrefix("recorded ") || detail == RecordRunner.nothingHeard
            await finish(id, state: entries[id]?.proto.state == .completed ? .completed : .cancelled,
                         detail: kept ? detail : "stopped; the recording is complete")
            return entries[id]?.proto
        }
        // Wait for the sweep to put down what it found before answering. Without this the caller
        // reads the Scan while the sweep is still writing it, and an interrupted scan looks empty
        // rather than partial. Awaiting here is safe: an actor is re-entrant at an await, so the
        // task's own calls back into this store still run.
        //
        // Bounded, because the teardown path is not: a task inside `device.open()` or
        // `stopStreaming()` cannot be cancelled and can take seconds of USB work. Past the bound
        // the job is answered as cancelled and the task finishes on its own -- a stale answer to
        // CancelJob is better than an RPC that never returns, and a daemon shutdown must not hang
        // on it either.
        // Poll the job's own state rather than awaiting the task. `Task.value` is not
        // cancellation-aware, so racing it in a task group does not bound anything: the group
        // still awaits the parked child on the way out, and a measured `withTimeout(1.0)` around
        // six seconds of uncancellable work returned after six. This loop is bounded by
        // construction.
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.cancelWaitSeconds))
        while entries[id].map({ Self.isLive($0.proto.state) }) == true, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if entries[id].map({ Self.isLive($0.proto.state) }) == true {
            await finish(id, state: .cancelled, detail: "cancelled")
        }
        return entries[id]?.proto
    }

    /// Ends every job a departing client owned. A sweep outliving its reader would hold the radio
    /// with nobody to hand the answer to.
    func clientGone(_ clientID: String) async {
        // A kept decode job is exactly the one that outlives its client (invariant 8).
        for (id, e) in entries where e.ownerClientID == clientID && Self.isLive(e.proto.state) && !e.keep {
            _ = await cancel(id)
        }
    }

    func cancelAll() async {
        // The daemon is going down: what ends here is not forgotten, it is resumed at the next boot.
        shuttingDown = true
        // Cancel every task first, then wait: a shutdown with several sweeps running should not
        // serialise their teardowns.
        for e in entries.values where Self.isLive(e.proto.state) { e.task?.cancel() }
        for id in entries.keys where entries[id].map({ Self.isLive($0.proto.state) }) == true {
            _ = await cancel(id)
        }
        await hub.finishAll()
    }

    func detected(_ hit: ScanHit, captureID: CaptureID) {
        publish(proto(hit, captureID: captureID), at: hit.lastSeen, captureID: captureID)
    }

    func setDetail(_ id: JobID, _ detail: String) async {
        guard var e = entries[id], Self.isLive(e.proto.state) else { return }
        e.proto.statusDetail = detail
        entries[id] = e
        await store.publishJob(e.proto)
    }

    func finish(_ id: JobID, state: Leyline_V1_JobState, detail: String, code: String? = nil) async {
        guard var e = entries[id] else { return }
        guard Self.isLive(e.proto.state) else { return }
        e.proto.state = state
        // The prose and the machine code go to different fields: `status_detail` is human-readable
        // text, `error` the code a client branches on.
        e.proto.statusDetail = detail
        if let code {
            var err = Leyline_V1_ErrorDetail()
            err.code = code
            err.message = detail
            err.target = id.string
            e.proto.error = err
        }
        if state != .completed, var scan = e.scan {
            scan.completedAtNs = realtimeNs()
            e.scan = scan
        }
        entries[id] = e
        // A kept job that ended by a cancel or a failure is over; one the shutdown ended is not.
        if e.keep, !shuttingDown { persistKept() }
        await store.publishJob(e.proto)
    }

    func proto(_ h: ScanHit, captureID: CaptureID) -> Leyline_V1_Detection {
        var d = Leyline_V1_Detection()
        // Stable within a scan: the frequency is what identifies a detection, and a ULID would
        // change every time the same carrier was re-reported.
        d.detectionID = "det_\(h.centerHz)"
        d.captureID = captureID.string
        d.centerHz = h.centerHz
        d.bandwidthHz = h.bandwidthHz
        d.snrDb = h.snrDB
        d.floorDbfs = h.floorDBFS
        d.looks = h.looks
        d.looksPossible = h.looksPossible
        d.firstSeen = ProtoMapping.sampleTime(h.firstSeen)
        d.lastSeen = ProtoMapping.sampleTime(h.lastSeen)
        // Invariant 12: v0 is energy detection and does not classify modulation.
        d.modulationGuess = ""
        d.guessConfidence = 0
        return d
    }

    /// The largest fitting SI unit, matching how every other frequency in the CLI reads.
    nonisolated func fmtMHz(_ hz: UInt64) -> String {
        if hz >= 1_000_000_000 { return String(format: "%.3f GHz", Double(hz) / 1e9) }
        if hz >= 1_000_000 { return String(format: "%.3f MHz", Double(hz) / 1e6) }
        if hz >= 1000 { return String(format: "%.3f kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }

    // MARK: Record jobs (docs/design/recording.md)

    /// Whether the job is still one the daemon is working on. The record extension checks it
    /// around every suspension, exactly as the scan and decode paths do.
    func jobIsLive(_ id: JobID) -> Bool { entries[id].map { Self.isLive($0.proto.state) } == true }

    /// Puts a record job in the table. `keep` is true for every recording: a job that outlives the
    /// client that started it is what `ley record --detach` means, and the foreground form cancels
    /// explicitly on Ctrl-C. Nothing is written to `kept-jobs.json` -- that file resumes decode
    /// jobs, and a recording ends at a restart rather than resuming
    /// (docs/design/recording.md, "Retune, detach and restart").
    func setRecordEntry(_ id: JobID, job: Leyline_V1_Job, task: Task<Void, Never>, client: ClientContext) {
        entries[id] = Entry(proto: job, scan: nil, task: task, ownerClientID: client.id, decode: nil,
                            record: nil, keep: true)
        order.append(id)
        trim()
    }

    func setRecordRunner(_ id: JobID, _ runner: any RecordRunning) { entries[id]?.record = runner }

    /// Who asked for the recording, as the manifest records it.
    func recordingClient(_ id: JobID) -> RecordingClient {
        let by = entries[id]?.proto.createdBy
        return RecordingClient(clientID: by?.clientID ?? "", kind: by?.kind ?? "", label: by?.label ?? "")
    }

    /// What the runner reports. A terminal state carries its code; RUNNING and DEGRADED are the
    /// job moving between having its capture and waiting for it back.
    func setRecordStatus(_ id: JobID, state: Leyline_V1_JobState, detail: String, code: String?) async {
        guard var e = entries[id], Self.isLive(e.proto.state) else { return }
        if !Self.isLive(state) {
            await finish(id, state: state, detail: detail, code: code)
            return
        }
        e.proto.state = state
        e.proto.statusDetail = detail
        entries[id] = e
        await store.publishJob(e.proto)
    }

    func finishRecord(_ id: JobID, state: Leyline_V1_JobState, detail: String, code: String? = nil) async {
        await finish(id, state: state, detail: detail, code: code)
    }

    /// Repairs whatever the last daemon left half-written, at boot (docs/design/recording.md,
    /// "Retune, detach and restart"), and brings the store back inside its cap.
    func repairRecordings() async {
        let closed = await recordings.repairUnfinished()
        if !closed.isEmpty {
            log.info("closed \(closed.count) recording(s) the last daemon was still writing: ended by a daemon restart")
        }
        await recordings.retain()
    }

    func trim() {
        var finished = order.filter { entries[$0]?.proto.state != .running }
        while finished.count > Self.keepFinished {
            let drop = finished.removeFirst()
            entries[drop] = nil
            order.removeAll { $0 == drop }
        }
    }
}

/// One subscriber's view of the detection fan-out: the stream, and the count of readings its own
/// drop-oldest buffer discarded because it fell behind. A consumer diffs `dropped` between readings
/// and widens its sequence gap by the delta, so a slow client sees in `seq` exactly what it missed.
final class DetectionSubscription: Sendable {
    let stream: AsyncStream<(Leyline_V1_Detection, SampleTime)>
    private let droppedCount = Atomic<Int>(0)

    init(stream: AsyncStream<(Leyline_V1_Detection, SampleTime)>) {
        self.stream = stream
    }

    var dropped: Int { droppedCount.load(ordering: .relaxed) }

    func countDrop() { droppedCount.add(1, ordering: .relaxed) }
}
