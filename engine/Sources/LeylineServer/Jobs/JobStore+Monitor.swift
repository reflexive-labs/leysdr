// SPDX-License-Identifier: GPL-3.0-or-later

// Monitor jobs: the stationary band-watch (docs/design/band-watching.md).

import EngineCore
import Foundation
import LeylineProto
import Logging
import Synchronization

extension JobStore {
    // MARK: Starting a monitor

    /// The stationary band-watch, the non-sweeping sibling of a scan (docs/design/band-watching.md).
    /// It parks one capture on a band and runs the detector continuously, streaming detections on
    /// the telemetry plane exactly as a scan does. It reuses the allocator, the lease lifecycle and
    /// the detection fan-out unchanged; the only new machinery is the stationary MonitorRunner.
    /// A monitor is ephemeral like a scan -- it dies with its client, on cancel, or at its duration
    /// (invariant 8: nobody watching a band interactively has declared an intent to keep anything).
    func startMonitor(config: Leyline_V1_MonitorConfig, by client: ClientContext) async throws -> Leyline_V1_Job {
        guard config.hasRange, config.range.maxHz > config.range.minHz else {
            throw EngineError.invalidArgument("a monitor needs a frequency range with max above min", target: "")
        }
        guard config.durationMs >= 0 else {
            throw EngineError.invalidArgument("a monitor's duration cannot be negative; 0 watches until cancelled", target: "")
        }
        let id = JobID()
        var job = Leyline_V1_Job()
        job.jobID = id.string
        job.state = .running
        job.createdAtNs = realtimeNs()
        job.createdBy = client.proto
        job.config = .monitor(config)
        job.statusDetail = "starting"

        // The task goes in before the first suspension, the same actor-reentrancy care as a scan:
        // a CancelJob or a departing client arriving while `publishJob` runs would otherwise find
        // no task to cancel and mark a watch cancelled that is about to start.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runMonitor(id, config: config)
        }
        entries[id] = Entry(proto: job, scan: nil, task: task, ownerClientID: client.id)
        order.append(id)
        trim()
        await store.publishJob(job)
        return job
    }

    private func runMonitor(_ id: JobID, config: Leyline_V1_MonitorConfig) async {
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
        // Allocating suspends, and a cancel in that window has already returned: hand the radio
        // back rather than watching for a job nobody is waiting on.
        guard entries[id]?.proto.state == .running else {
            await lease.release()
            return
        }

        // Park the band in one analysable quarter-band, off the DC hole. The detector ignores the
        // middle of the span (the RTL-SDR DC spike, `guardFraction` of Fs either side) and the
        // edges (`edgeFraction`+), so the whole requested band must sit on one side of centre,
        // inside [guardFraction, edgeFraction] of Fs off it. Begin it 10% of Fs above centre --
        // clear of the guard -- then verify the far edge stays inside `edgeFraction`. Using the
        // same fractions as SweepPlan is what makes the detector's own clamp match this placement.
        let fs = Double(lease.sampleRateHz)
        let guardHz = SweepPlan.guardFraction * fs
        let edgeHz = SweepPlan.edgeFraction * fs
        let centreD = Double(range.lowerBound) - 0.10 * fs
        let centre = centreD > 0 ? UInt64(centreD.rounded()) : 0
        let loOff = Double(range.lowerBound) - Double(centre)
        let hiOff = Double(range.upperBound) - Double(centre)
        // Decline before the retune, so a band that cannot fit never moves the radio. INVALID_ARGUMENT
        // fits: the request is for a band one capture cannot hold, and a sweep can.
        guard centre > 0, loOff >= guardHz, hiOff <= edgeHz else {
            await lease.release()
            await finish(id, state: .failed,
                         detail: "band \(fmtMHz(range.upperBound - range.lowerBound)) wide is too wide to watch in one capture; use ley scan, which sweeps",
                         code: EngineError.Code.invalidArgument)
            return
        }

        // The sample index at the moment of the tune: the settle window is measured from here.
        let hopAt = await lease.sampleIndex
        do {
            try await lease.retune(centerHz: centre)
        } catch {
            await lease.release()
            let e = (error as? EngineError) ?? EngineError.deviceIO("\(error)", target: "")
            await finish(id, state: .failed, detail: "could not tune \(fmtMHz(centre)): \(e.message)", code: e.code)
            return
        }
        await setDetail(id, "watching \(fmtMHz(range.lowerBound))-\(fmtMHz(range.upperBound))")

        let captureID = lease.captureID
        let started = ContinuousClock.now
        let result = await MonitorRunner.run(
            lease: lease, believe: range.lowerBound ... range.upperBound, centerHz: centre,
            hopAt: hopAt, durationMs: config.durationMs,
            onHit: { [weak self] hit in
                await self?.detected(hit, captureID: captureID)
            })
        // The radio goes back before the job reaches a terminal state, on cancel and success alike:
        // a detached release would let the next job see a still-leased capture and be declined.
        await lease.release()

        let elapsed = Int(started.duration(to: ContinuousClock.now).components.seconds)
        let carriers = result.hits.count
        let noun = carriers == 1 ? "carrier" : "carriers"
        if let e = result.failure {
            await finish(id, state: .failed, detail: "\(e.message) after \(elapsed) s, \(carriers) \(noun)", code: e.code)
        } else if Task.isCancelled {
            await finish(id, state: .cancelled, detail: "stopped after \(elapsed) s, \(carriers) \(noun)")
        } else {
            await finish(id, state: .completed, detail: "watched \(elapsed) s, \(carriers) \(noun)")
        }
    }
}
