// SPDX-License-Identifier: GPL-3.0-or-later

// Scan jobs: one sweep of a range, its steps and the Scan it writes (docs/dev/engine-internals.md,
// "Jobs service and lease lifecycle").

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

extension JobStore {
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
        // The gains the sweep pins at, when the request says, in order; `gains` wins over `gain`
        // (`jobs.proto`, `ScanConfig`), as a recording's do. `auto: false` is the write that means
        // "manual, keep the last level", which for a sweep is the same as leaving that stage unset.
        let writes = config.gains.isEmpty ? (config.hasGain ? [config.gain] : []) : config.gains
        let requests: [GainRequest] = writes.compactMap { write in
            switch write.value {
            case .db(let db): return GainRequest(element: write.element, value: .db(db))
            case .auto(true): return GainRequest(element: write.element, value: .auto)
            default: return nil
            }
        }
        let allocation = await allocator.allocate(.exclusiveCapture(rangeHz: range, deviceID: deviceID, takeOver: config.takeOver, gains: requests), for: id)
        guard case .capture(let lease) = allocation else {
            if case .declined(let code, let reason) = allocation {
                await finish(id, state: .failed, detail: reason, code: code)
            } else {
                await finish(id, state: .failed, detail: "no radio could be allocated", code: EngineError.Code.noDevice)
            }
            return
        }
        // Allocating suspends -- it creates or borrows a capture -- and a cancel in that window has
        // already returned. Hand the radio back at once rather than sweeping for a job nobody is
        // waiting on: the lease is what locks every other client out of the device.
        guard entries[id]?.proto.state == .running else {
            await lease.release()
            return
        }
        if let failure = await lease.pinFailure {
            // A sweep at a gain other than the one asked for is not the measurement that was
            // requested, so it does not run.
            await lease.release()
            await finish(id, state: .failed, detail: "the gain asked for could not be set: \(failure.message)", code: failure.code)
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
        // A stopped sweep still keeps what it found: a user who interrupts one gets the
        // part that ran, and the Scan records how far it got.
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
            // ran to the end, so it completed; `covered` records which parts of the range it really
            // looked at, and the detail reports how many steps came up short.
            let short = result.steps - result.stepsDone
            await finish(id, state: .completed,
                         detail: "\(result.hits.count) found; \(short) of \(result.steps) steps saw too few rows to trust and were left out")
        } else {
            let clipped = plan.clipped ? ", clipped to what the radio can tune" : ""
            let steps = result.steps == 1 ? "1 step" : "\(result.steps) steps"
            await finish(id, state: .completed, detail: "\(result.hits.count) found in \(steps)\(clipped)")
        }
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
        // request as though it had been searched would claim coverage that was never measured.
        // `stepsDone` is a count of steps that succeeded, not a prefix of them, so the coverage
        // comes from the windows the runner really analysed.
        if let lo = result.covered.first?.lowHz, let hi = result.covered.last?.highHz {
            scan.covered.minHz = lo
            scan.covered.maxHz = hi
        }
        e.scan = scan
        entries[id] = e
    }
}
