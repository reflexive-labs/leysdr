// The job table. A table of watches, not a workflow engine: no retry DAG, no replay.
//
// v0 holds jobs and their scans in memory and loses them on restart, because the only job type
// that exists is an ad-hoc scan and an ad-hoc scan is ephemeral by design -- persistence follows
// intent (invariant 8), and nobody typing `ley scan` has declared an intent to keep anything.
// Durable jobs and the resource store arrive together at Milestone D.15.

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

    private struct Entry {
        var proto: Leyline_V1_Job
        var scan: Leyline_V1_Scan?
        var task: Task<Void, Never>?
        /// The connection that asked for it. When that connection goes, so does the job: a sweep
        /// nobody is reading is just a radio nobody can use.
        var ownerClientID: String
    }

    private let store: SessionStore
    private let allocator: SessionCaptureAllocator
    private let log = Logger(label: "leyline.jobs")
    private var entries: [JobID: Entry] = [:]
    private var order: [JobID] = []
    private var detectionSinks: [UUID: (filter: CaptureID?,
                                        continuation: AsyncStream<(Leyline_V1_Detection, SampleTime)>.Continuation,
                                        subscription: DetectionSubscription)] = [:]

    init(store: SessionStore, allocator: SessionCaptureAllocator) {
        self.store = store
        self.allocator = allocator
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
        // Wait for the sweep to put down what it found before answering. Without this the caller
        // reads the Scan while the sweep is still writing it, and an interrupted scan looks empty
        // rather than partial. Awaiting here is safe: an actor is re-entrant at an await, so the
        // task's own calls back into this store still run.
        //
        // Bounded, because the teardown path is not: a task inside `device.open()` or
        // `stopStreaming()` cannot be cancelled and can take seconds of USB work. Past the bound
        // the job is answered as cancelled and the task finishes on its own -- a stale answer to
        // CancelJob is better than an RPC that never returns, and worse than neither is a daemon
        // shutdown that hangs on it.
        // Poll the job's own state rather than awaiting the task. `Task.value` is not
        // cancellation-aware, so racing it in a task group does not bound anything: the group
        // still awaits the parked child on the way out, and a measured `withTimeout(1.0)` around
        // six seconds of uncancellable work returned after six. This loop is bounded by
        // construction.
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.cancelWaitSeconds))
        while entries[id]?.proto.state == .running, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if entries[id]?.proto.state == .running {
            await finish(id, state: .cancelled, detail: "cancelled")
        }
        return entries[id]?.proto
    }

    /// Ends every job a departing client owned. A sweep outliving its reader would hold the radio
    /// with nobody to hand the answer to.
    func clientGone(_ clientID: String) async {
        for (id, e) in entries where e.ownerClientID == clientID && e.proto.state == .running {
            _ = await cancel(id)
        }
    }

    func cancelAll() async {
        // Cancel every task first, then wait: a shutdown with several sweeps running should not
        // serialise their teardowns.
        for e in entries.values where e.proto.state == .running { e.task?.cancel() }
        for id in entries.keys where entries[id]?.proto.state == .running {
            _ = await cancel(id)
        }
    }

    // MARK: Starting a scan

    func startScan(config: Leyline_V1_ScanConfig, by client: ClientContext) async throws -> Leyline_V1_Job {
        if case .recurring = config.schedule {
            throw EngineError.invalidArgument("a recurring scan needs a job store that survives a restart, which does not exist yet; use once",
                                              target: "")
        }
        guard config.hasRange, config.range.maxHz > config.range.minHz else {
            throw EngineError.invalidArgument("a scan needs a frequency range with max above min", target: "")
        }
        let id = JobID()
        let scanID = ScanID()
        var job = Leyline_V1_Job()
        job.jobID = id.string
        job.state = .running
        job.createdAtNs = realtimeNs()
        job.createdBy = client.proto
        job.config = .scan(config)
        job.resultUris = ["ley://scans/\(scanID.string)"]
        job.statusDetail = "starting"

        var scan = Leyline_V1_Scan()
        scan.scanID = scanID.string
        scan.config = config
        scan.startedAtNs = job.createdAtNs

        // The task goes in before the first suspension. An actor is re-entrant at an await, so a
        // CancelJob or a departing client arriving while `publishJob` runs would otherwise find no
        // task on the entry, cancel nothing, and mark a sweep cancelled that is about to start.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id, config: config)
        }
        entries[id] = Entry(proto: job, scan: scan, task: task, ownerClientID: client.id)
        order.append(id)
        trim()
        await store.publishJob(job)
        return job
    }

    private func run(_ id: JobID, config: Leyline_V1_ScanConfig) async {
        // Cancelled before the sweep got the actor back: nothing has been allocated yet, so there
        // is nothing to do but leave the terminal state alone.
        guard entries[id]?.proto.state == .running else { return }
        let range = config.range.minHz ... config.range.maxHz
        let deviceID = config.deviceID.isEmpty ? nil : DeviceID(string: config.deviceID)
        if !config.deviceID.isEmpty, deviceID == nil {
            await finish(id, state: .failed, detail: "no device with id \(config.deviceID)", code: EngineError.Code.deviceNotFound)
            return
        }
        let allocation = await allocator.allocate(.exclusiveCapture(rangeHz: range, deviceID: deviceID, takeOver: config.takeOver), for: id)
        guard case .capture(let lease) = allocation else {
            if case .declined(let code, let reason) = allocation {
                await finish(id, state: .failed, detail: reason, code: code)
            } else {
                await finish(id, state: .failed, detail: "no radio could be allocated", code: EngineError.Code.noDevice)
            }
            return
        }
        // Allocating suspends -- it creates or borrows a capture -- and a cancel in that window has
        // already answered. Hand the radio back at once rather than sweeping for a job nobody is
        // waiting on: the lease is what locks every other client out of the device.
        guard entries[id]?.proto.state == .running else {
            await lease.release()
            return
        }
        let device = await store.deviceDescriptor(for: lease.captureID)
        guard let plan = SweepPlan.plan(minHz: range.lowerBound, maxHz: range.upperBound,
                                        sampleRateHz: lease.sampleRateHz,
                                        tuningRanges: device?.tuningRanges ?? [])
        else {
            await lease.release()
            await finish(id, state: .failed, detail: "this radio cannot tune any of that range", code: EngineError.Code.freqOutOfRange)
            return
        }
        guard plan.analysedHz > 0 else {
            await lease.release()
            let centre = plan.steps.first?.centerHz ?? range.lowerBound
            await finish(id, state: .failed,
                         detail: "all of that range sits within \(fmtMHz(UInt64(SweepPlan.guardFraction * Double(lease.sampleRateHz)))) of \(fmtMHz(centre)), where this radio's own DC spike is; a scan does not look there",
                         code: EngineError.Code.blindSpot)
            return
        }
        await setDetail(id, plan.steps.count == 1 ? "sweeping 1 step" : "sweeping \(plan.steps.count) steps")
        await setStep(id, plan: plan)

        let captureID = lease.captureID
        let dwell = config.dwellMs == 0 ? 250 : config.dwellMs
        let result = await ScanRunner.sweep(
            lease: lease, plan: plan, dwellMs: dwell,
            onStep: { [weak self] p in
                await self?.setDetail(id, "step \(p.step)/\(p.steps), \(p.found) found")
            },
            onHit: { [weak self] hit in
                await self?.detected(hit, captureID: captureID)
            })
        let gains = await lease.pinnedGains
        // The radio goes back before the job reaches a terminal state. A detached release
        // would let the next scan see a capture that is still leased and be declined, and the
        // await is safe in a cancelled task because release checks no cancellation of its own.
        await lease.release()
        // A stopped sweep still keeps what it found: somebody who interrupts one wants the
        // part that ran, and a Scan that says how far it got is honest about the rest.
        await store(id, result: result, plan: plan, gains: gains, captureID: captureID)
        if let e = result.failure {
            await finish(id, state: .failed,
                         detail: "\(e.message) after \(result.stepsDone) of \(result.steps) steps, \(result.hits.count) found",
                         code: e.code)
        } else if Task.isCancelled {
            // The step it was in, not the ones it finished: "0 of 1" reads as having done
            // nothing, when a partial step can have found everything there was.
            await finish(id, state: .cancelled,
                         detail: "stopped in step \(Swift.min(result.stepsDone + 1, result.steps)) of \(result.steps), \(result.hits.count) found")
        } else if !result.complete {
            // Not stopped: some step ran out of time before it had the rows it planned on, and
            // `stepsDone` counts the ones that succeeded rather than a prefix of them. The scan
            // ran to the end, so it completed; `covered` says which parts of the range it really
            // looked at, and the detail says how many steps came up short.
            let short = result.steps - result.stepsDone
            await finish(id, state: .completed,
                         detail: "\(result.hits.count) found; \(short) of \(result.steps) steps saw too few rows to trust and were left out")
        } else {
            let clipped = plan.clipped ? ", clipped to what the radio can tune" : ""
            let steps = result.steps == 1 ? "1 step" : "\(result.steps) steps"
            await finish(id, state: .completed, detail: "\(result.hits.count) found in \(steps)\(clipped)")
        }
    }

    private func detected(_ hit: ScanHit, captureID: CaptureID) {
        publish(proto(hit, captureID: captureID), at: hit.lastSeen, captureID: captureID)
    }

    private func setStep(_ id: JobID, plan: SweepPlan) {
        guard var e = entries[id], var scan = e.scan else { return }
        // The advance the geometry uses, stated rather than measured off the step positions: the
        // first gap is between the low end-cap and the first interior centre, which is edge+guard
        // and not edge-guard, so measuring it reported a step 25% too wide.
        scan.config.stepHz = UInt32(((SweepPlan.edgeFraction - SweepPlan.guardFraction) * Double(plan.sampleRateHz)).rounded())
        // How finely it looked, which is what every dB in the message is per. A client should not
        // have to know the geometry constants and the bin count to print a floor.
        scan.resolutionHz = UInt32((Double(plan.sampleRateHz) / Double(ScanRunner.bins)).rounded())
        e.scan = scan
        entries[id] = e
    }

    private func setDetail(_ id: JobID, _ detail: String) async {
        guard var e = entries[id], e.proto.state == .running else { return }
        e.proto.statusDetail = detail
        entries[id] = e
        await store.publishJob(e.proto)
    }

    /// Writes what the sweep found into the job's Scan, complete or not.
    private func store(_ id: JobID, result: ScanRunner.Result, plan: SweepPlan,
                       gains: [GainState], captureID: CaptureID)
    {
        guard var e = entries[id], var scan = e.scan else { return }
        scan.detections = result.hits.map { proto($0, captureID: captureID) }
        scan.noiseFloor = result.floors
        scan.completedAtNs = realtimeNs()
        scan.gains = gains.map(ProtoMapping.gainState)
        // What was actually looked at, always -- not only when the sweep was cut short. A radio
        // that cannot reach all of a range, a request that falls partly in the tuner's blind spot
        // and a sweep somebody stopped all leave coverage behind, and a client that printed the
        // request as though it had been searched would be claiming what nobody measured.
        // `stepsDone` is a count of steps that succeeded, not a prefix of them, so the coverage
        // comes from the windows the runner really analysed.
        if let lo = result.covered.first?.lowHz, let hi = result.covered.last?.highHz {
            scan.covered.minHz = lo
            scan.covered.maxHz = hi
        }
        e.scan = scan
        entries[id] = e
    }

    private func finish(_ id: JobID, state: Leyline_V1_JobState, detail: String, code: String? = nil) async {
        guard var e = entries[id] else { return }
        guard e.proto.state == .running else { return }
        e.proto.state = state
        // The prose and the machine code go to different fields: `status_detail` is the sentence a
        // person reads, `error` the code a client branches on.
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
        await store.publishJob(e.proto)
    }

    private func proto(_ h: ScanHit, captureID: CaptureID) -> Leyline_V1_Detection {
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
        // Invariant 12: v0 is energy detection and has no opinion about modulation.
        d.modulationGuess = ""
        d.guessConfidence = 0
        return d
    }

    /// The largest fitting SI unit, matching how every other frequency in the CLI reads.
    private nonisolated func fmtMHz(_ hz: UInt64) -> String {
        if hz >= 1_000_000_000 { return String(format: "%.3f GHz", Double(hz) / 1e9) }
        if hz >= 1_000_000 { return String(format: "%.3f MHz", Double(hz) / 1e6) }
        if hz >= 1000 { return String(format: "%.3f kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }

    private func trim() {
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
