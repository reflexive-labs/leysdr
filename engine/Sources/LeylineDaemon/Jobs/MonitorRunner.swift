// SPDX-License-Identifier: GPL-3.0-or-later

// The stationary watch. A monitor parks one capture on a band and runs the energy detector
// continuously, so it never time-shares and cannot miss a transmission by being tuned elsewhere.
// That is the difference from a sweep, which walks a series of centres. It is
// ScanRunner with the step/retune loop removed: one "step" that lasts the whole duration, over a
// lease already tuned to the right centre. It reuses the same RowCollector, the same detector
// signatures, the same fold/near identity test, and it publishes detections the same way, so a
// monitor's DETECTION stream has the same form as a scan's. See docs/design/band-watching.md
// (the stationary sibling of ley scan) and docs/design/scan.md (the detector, the 5-45% analysed
// window, the DC hole).

import EngineCore
import Foundation
import LeylineProto
import Logging

/// Watches one stationary band and reports the carriers on it, streaming as they come and go.
enum MonitorRunner {
    /// Bins per row and looks per row: the same choices a sweep makes, so the detector's threshold
    /// and its CFAR floor window mean exactly what they mean in a scan.
    static let bins = ScanRunner.bins
    static let targetLooks = ScanRunner.targetLooks
    /// Expected false detections spread over the rows of one budget window. A monitor has no
    /// whole-sweep budget to spend -- it can run until cancelled -- so the threshold is set from a
    /// fixed per-`budgetWindowSeconds` budget rather than a per-run one, and held fixed for the
    /// run so it does not drift as rows arrive.
    static let falseAlarmBudget = ScanRunner.falseAlarmBudget
    static let budgetWindowSeconds = 60.0

    private static let log = Logger(label: "leyline.jobs.monitor")

    /// What a watch found, and whether it ran to the end.
    struct Result: Sendable {
        var hits: [ScanHit]
        /// Median local floor across the believed window, for the status line. NaN if it saw none.
        var floorDBFS: Double
        /// Rows the detector actually believed -- the denominator of every hit's evidence ratio.
        var believedRows: Int
        /// Why the watch stopped early, when it was not the duration or a cancel. Empty otherwise.
        var failure: EngineError?
    }

    /// Watches `believe` from a `lease` already tuned to `centerHz`, until `durationMs` elapses
    /// (0 = until cancelled) or the task is cancelled. `hopAt` is the capture's sample index at the
    /// moment it was tuned, so the settle window after the tune is discarded by the same arithmetic
    /// a sweep uses after a hop. `onHit` is called as carriers are found or updated, so a carrier
    /// that stays up re-publishes with a growing last_seen -- which is what lets the client time it.
    static func run(lease: any CaptureLease, believe: ClosedRange<UInt64>, centerHz: UInt64,
                    hopAt: UInt64, durationMs: Int64,
                    onHit: @Sendable (ScanHit) async -> Void) async -> Result
    {
        let collector = RowCollector(bins: bins)
        let ladder = lease.spectrum
        // Enough rows per second that `targetLooks` blocks land in each: the ladder takes one look
        // per block, so the row interval must be that many blocks long. The same rate a sweep uses.
        let blocksPerSecond = Double(lease.sampleRateHz) / Double(CaptureDSPCore.blockSize)
        let rows = Swift.max(0.5, blocksPerSecond / Double(targetLooks))
        let sub = await ladder.subscribe(bins: bins, rowsPerSecond: rows, accumulation: .mean,
                                         policy: .latestWins, sink: collector)
        defer { Task { await ladder.cancel(sub) } }

        // Discard everything captured before the tune settled. The driver and the capture's own
        // ring still hold samples from the previous centre, and a row stamped past the settle
        // window can still reach a whole interval back into it -- the samples that would put a
        // carrier at the wrong frequency. The capture timeline is monotonic, so this is exact.
        let settle = await lease.settleSamples
        let rowSamples = UInt64(lease.sampleRateHz) / UInt64(Swift.max(1, Int(sub.actualRate.rounded())))
        let believeFrom = hopAt + settle + rowSamples

        // Fixed for the run, from a per-minute false-alarm budget rather than a per-run one.
        let rowsInWindow = Int(Swift.max(2, (sub.actualRate * budgetWindowSeconds).rounded()))
        let pFalse = SpectrumDetect.sweepPFalse(expected: falseAlarmBudget, bins: sub.actualBins,
                                                rowsPerStep: rowsInWindow, steps: 1)

        var power = [Float](repeating: 0, count: sub.actualBins)
        var floorBuf = [Float](repeating: 0, count: sub.actualBins)
        var scratch = [Float](repeating: 0, count: 2 * SpectrumDetect.referenceBins)

        var hits: [ScanHit] = []
        var floors: [Double] = []
        var believedRows = 0
        // A monitor never retunes, so no operation inside the loop can surface a device error: rows
        // simply stop arriving if the radio goes away, and the watch ends at its duration. The
        // field stays for symmetry with a sweep's Result and to leave room for a future liveness
        // check, but it is always nil today.
        let failure: EngineError? = nil

        // 0 = until cancelled. ContinuousClock, like CancelJob's bounded waits.
        let deadline: ContinuousClock.Instant? = durationMs > 0
            ? ContinuousClock.now.advanced(by: .nanoseconds(Int64(durationMs) * 1_000_000)) : nil

        while !Task.isCancelled {
            if let deadline, ContinuousClock.now >= deadline { break }
            // Sleep, not checkCancellation: a cancelled watch leaves through the condition above and
            // returns what it has, so the radio goes back at once and the partial answer survives.
            try? await Task.sleep(nanoseconds: 20_000_000)
            for row in collector.drain() {
                guard row.centerHz == centerHz, row.looks > 0, row.bins > 0,
                      row.time.sampleIndex >= believeFrom else { continue }
                believedRows += 1
                let found = power.withUnsafeMutableBufferPointer { p in
                    floorBuf.withUnsafeMutableBufferPointer { f in
                        scratch.withUnsafeMutableBufferPointer { sc in
                            SpectrumDetect.detect(rowDB: row.db, count: row.bins,
                                                  centerHz: row.centerHz, spanHz: row.spanHz,
                                                  looks: row.looks, pFalse: pFalse,
                                                  believe: believe,
                                                  power: p.baseAddress!, floor: f.baseAddress!,
                                                  scratch: sc.baseAddress!)
                        }
                    }
                }
                let windowFloor = floorBuf.withUnsafeMutableBufferPointer { f in
                    scratch.withUnsafeMutableBufferPointer { sc in
                        SpectrumDetect.windowFloorDBFS(floor: f.baseAddress!, count: row.bins,
                                                       centerHz: row.centerHz, spanHz: row.spanHz,
                                                       believe: believe, scratch: sc.baseAddress!)
                    }
                }
                if windowFloor.isFinite { floors.append(windowFloor) }
                for h in found {
                    // Fold keeping first/last seen and peak SNR, as a sweep folds within one step,
                    // then re-publish the carrier's current state: each believed row was a chance
                    // to detect it, so `looks_possible` is the believed-row count.
                    ScanRunner.fold(h, at: row.time, into: &hits)
                    if let i = hits.firstIndex(where: { ScanRunner.near($0.centerHz, h.centerHz, $0.bandwidthHz) }) {
                        hits[i].looksPossible = UInt32(believedRows)
                        await onHit(hits[i])
                    }
                }
            }
        }
        for i in hits.indices { hits[i].looksPossible = UInt32(Swift.max(Int(hits[i].looks), believedRows)) }
        if believedRows == 0 {
            Self.log.warning("monitor at \(centerHz) Hz saw no rows it could believe")
        }
        let floor = floors.isEmpty ? Double.nan : floors.sorted()[floors.count / 2]
        return Result(hits: hits, floorDBFS: floor, believedRows: believedRows, failure: failure)
    }
}
