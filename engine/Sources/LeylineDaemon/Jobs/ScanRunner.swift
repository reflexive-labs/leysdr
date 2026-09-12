// SPDX-License-Identifier: GPL-3.0-or-later

// The sweep. Daemon-side, because a client-driven one cannot work: the write coalescer keeps
// last-value-per-parameter on a 20 ms tick and would silently eat steps, and the ladder stamps
// rows with the centre in force when the row was computed, so nothing outside the daemon can tell
// which frequency a row belongs to. See docs/design/scan.md.

import EngineCore
import Foundation
import LeylineProto
import Logging

/// What a sweep found at one frequency, accumulated across the steps that saw it.
struct ScanHit: Sendable {
    var centerHz: UInt64
    var bandwidthHz: UInt32
    var snrDB: Double
    var floorDBFS: Double
    var looks: UInt32
    var looksPossible: UInt32
    var firstSeen: SampleTime
    var lastSeen: SampleTime
}

/// Collects rows from the ladder without doing any work on the DSP thread.
///
/// `write` runs on the hot path (invariant 4): it copies into a preallocated slot and returns. All
/// the analysis -- a local median per bin over 192 reference bins, grouping, moments -- happens on
/// the sweep's own task, which is where it belongs.
final class RowCollector: SpectrumSink, @unchecked Sendable {
    /// One collected row. The dB samples live in raw storage rather than a Swift Array because an
    /// Array is copy-on-write: handing a slot's Array to the draining task makes the storage
    /// shared, and the DSP thread's next write to that slot then allocates a fresh copy -- on the
    /// hot path, which invariant 4 forbids. Raw buffers cannot be shared by accident.
    struct Row {
        var db: UnsafeMutablePointer<Float>
        var bins: Int
        var time: SampleTime
        var centerHz: UInt64
        var spanHz: UInt64
        var looks: Int

        var values: UnsafeBufferPointer<Float> { UnsafeBufferPointer(start: db, count: bins) }
    }

    private let lock = NSLock()
    private let bins: Int
    private let depth: Int
    private let storage: UnsafeMutablePointer<Float>
    private var slots: [Row]
    private var write = 0
    private var read = 0
    private var count = 0

    init(bins: Int, depth: Int = 8) {
        self.bins = bins
        self.depth = depth
        let base = UnsafeMutablePointer<Float>.allocate(capacity: bins * depth)
        base.initialize(repeating: 0, count: bins * depth)
        storage = base
        slots = (0 ..< depth).map { i in
            Row(db: base.advanced(by: i * bins), bins: bins,
                time: SampleTime(captureID: CaptureID(), sampleIndex: 0),
                centerHz: 0, spanHz: 0, looks: 0)
        }
    }

    deinit {
        storage.deinitialize(count: bins * depth)
        storage.deallocate()
    }

    func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64, looks: Int) {
        let sp = Signpost.begin(.sweepRow)
        defer { Signpost.end(.sweepRow, sp) }
        lock.lock()
        defer { lock.unlock() }
        // Drop-oldest: a sweep that fell behind wants the newest rows, and the step boundary is
        // decided by sample index, not by row order.
        if count == depth {
            read = (read + 1) % depth
            count -= 1
        }
        let n = Swift.min(row.count, bins)
        if let src = row.baseAddress {
            slots[write].db.update(from: src, count: n)
        }
        slots[write].time = time
        slots[write].centerHz = centerHz
        slots[write].spanHz = spanHz
        slots[write].looks = looks
        write = (write + 1) % depth
        count += 1
    }

    /// Takes everything collected so far. The returned rows point into the collector's own
    /// storage, which the producer may overwrite once `depth` more rows have arrived -- consume
    /// them before the next drain, which is what the sweep does.
    func drain() -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        var out: [Row] = []
        out.reserveCapacity(count)
        while count > 0 {
            out.append(slots[read])
            read = (read + 1) % depth
            count -= 1
        }
        return out
    }
}

/// Runs one sweep and accumulates a Scan.
enum ScanRunner {
    /// Bins per row. 1024 at 2.4 MSPS is 2.34 kHz, which resolves a 12.5 kHz channel comfortably
    /// and keeps the CFAR reference window (192 bins, 450 kHz) well inside a quarter-band.
    static let bins = 1024
    /// Looks averaged into a row. The ladder takes at most one per block, so this is chosen by the
    /// row rate and then verified: the threshold is computed from what actually arrived.
    static let targetLooks = 16
    /// Expected false detections in a whole sweep. The threshold is derived from this, the bin
    /// count, the rows per step and the number of steps.
    static let falseAlarmBudget = 0.1
    /// A detection in one step is the same signal as one in another when their centres are within
    /// this much of each other, or within a bandwidth.
    static let mergeToleranceHz: UInt64 = 5_000

    private static let log = Logger(label: "leyline.jobs.scan")

    struct Progress: Sendable {
        var step: Int
        var steps: Int
        var found: Int
    }

    /// What a sweep found, and whether it got all the way through.
    struct Result: Sendable {
        var hits: [ScanHit]
        var floors: [Leyline_V1_NoiseFloorSegment]
        /// Steps that ran to the end of their dwell.
        var stepsDone: Int
        var steps: Int
        /// The windows the sweep actually looked at, merged. Not the request and not the plan:
        /// what was measured. A step that produced no believable row contributes nothing.
        var covered: [SweepPlan.Window]
        /// Why the sweep stopped early, when it was not cancellation. Empty on a clean run.
        var failure: EngineError?
        var complete: Bool { stepsDone >= steps && failure == nil }
    }

    /// Sweeps and returns what it found, calling `onStep` after each one and `onHit` as they are
    /// found. Cancellation stops the sweep and returns the partial answer rather than throwing it
    /// away: somebody who interrupts a long sweep still wants what it had.
    static func sweep(lease: any CaptureLease, plan: SweepPlan, dwellMs: UInt32,
                      onStep: @Sendable (Progress) async -> Void,
                      onHit: @Sendable (ScanHit) async -> Void) async -> Result
    {
        let collector = RowCollector(bins: bins)
        let ladder = lease.spectrum
        // Enough rows per second that `targetLooks` blocks land in each: the ladder takes one look
        // per block, so the row interval must be that many blocks long.
        let blocksPerSecond = Double(plan.sampleRateHz) / Double(CaptureDSPCore.blockSize)
        let rows = Swift.max(0.5, blocksPerSecond / Double(targetLooks))
        let sub = await ladder.subscribe(bins: bins, rowsPerSecond: rows, accumulation: .mean,
                                         policy: .latestWins, sink: collector)
        defer { Task { await ladder.cancel(sub) } }

        let dwellNs = UInt64(Swift.max(50, dwellMs)) * 1_000_000
        let rowIntervalNs = UInt64(1_000_000_000.0 / Swift.max(0.01, sub.actualRate))
        // Rows the dwell is meant to yield. Fixed up front so the threshold is the same for every
        // row of a step: it spends a whole sweep's false-alarm budget, and a budget that moved as
        // rows arrived would make the first row of a step stricter than the last.
        let rowsPerStep = Int(Swift.max(2, dwellNs / Swift.max(1, rowIntervalNs)))

        var merged: [ScanHit] = []
        var floors: [Leyline_V1_NoiseFloorSegment] = []
        var power = [Float](repeating: 0, count: sub.actualBins)
        var floorBuf = [Float](repeating: 0, count: sub.actualBins)
        var scratch = [Float](repeating: 0, count: 2 * SpectrumDetect.referenceBins)
        // The newest sample index any row has reported. The capture timeline is monotonic across a
        // retune -- the anchor is not republished and the index does not reset -- so this is what
        // makes the settle window exact arithmetic instead of a guess about wall-clock timing.
        var newestIndex: UInt64 = 0

        var stepsDone = 0
        var analysed: [SweepPlan.Window] = []
        // What each step actually looked at, and how many rows it got. The denominator of the
        // evidence ratio is computed from this at the end rather than accrued as the sweep goes:
        // a signal first seen in step 5 was still looked for by steps 1 to 4, and crediting only
        // the steps that ran after it appeared is how a half-missed carrier reads 8/8.
        var looked: [(windows: [SweepPlan.Window], rows: Int)] = []
        var failure: EngineError?
        for (index, step) in plan.steps.enumerated() {
            if Task.isCancelled { break }
            for row in collector.drain() { newestIndex = Swift.max(newestIndex, row.time.sampleIndex) }
            let hopAt = Swift.max(newestIndex, await lease.sampleIndex)
            do {
                try await lease.retune(centerHz: step.centerHz)
            } catch {
                // The radio went away mid-sweep. Everything found before that is still true, and
                // has already been published on telemetry; throwing it away here would leave a
                // subscriber holding detections the Scan denies.
                failure = (error as? EngineError) ?? EngineError.deviceIO("\(error)", target: "")
                break
            }
            let settle = await lease.settleSamples
            // Everything up to the hop was captured at the previous frequency, and so is
            // everything the driver and the ring already held. One more row interval on top,
            // because a row is stamped with the block that completed it and reaches back a whole
            // interval: a row whose stamp clears the settle window can still contain samples from
            // inside it, and those are the ones that put a carrier at the wrong frequency.
            let believeFrom = hopAt + settle + UInt64(plan.sampleRateHz) / UInt64(Swift.max(1, Int(sub.actualRate.rounded())))

            var believedRows = 0
            var stepHits: [ScanHit] = []
            var stepFloors: [Double] = []
            var stepWindows: [SweepPlan.Window] = []
            let pFalse = SpectrumDetect.sweepPFalse(expected: falseAlarmBudget, bins: sub.actualBins,
                                                    rowsPerStep: rowsPerStep, steps: plan.steps.count)
            // A backstop, not the schedule: the step ends when it has its rows. Twice the settle
            // and dwell plus a second covers a device that is slower than its own arithmetic says.
            let deadline = ContinuousClock.now.advanced(
                by: .nanoseconds(Int64(2 * (settleNs(settle, rate: plan.sampleRateHz) + dwellNs) + 1_000_000_000)))

            while believedRows < rowsPerStep, ContinuousClock.now < deadline, !Task.isCancelled {
                // Sleep, not checkCancellation: a cancelled sweep leaves the loop through the
                // condition above and returns what it has.
                try? await Task.sleep(nanoseconds: 20_000_000)
                for row in collector.drain() {
                    newestIndex = Swift.max(newestIndex, row.time.sampleIndex)
                    guard row.centerHz == step.centerHz, row.looks > 0, row.bins > 0,
                          row.time.sampleIndex >= believeFrom else { continue }
                    believedRows += 1
                    for raw in [step.low, step.high] {
                        // A step's window is what the radio can see from there; the answer is
                        // what was asked for. Without the intersection a narrow request reports
                        // signals from either side of it, which is a scan answering a question
                        // nobody put.
                        let window = raw.clamped(to: plan.covered)
                        guard window.highHz > window.lowHz else { continue }
                        if !stepWindows.contains(window) { stepWindows.append(window) }
                        let hits = power.withUnsafeMutableBufferPointer { p in
                            floorBuf.withUnsafeMutableBufferPointer { f in
                                scratch.withUnsafeMutableBufferPointer { sc in
                                    SpectrumDetect.detect(rowDB: row.db, count: row.bins,
                                                              centerHz: row.centerHz, spanHz: row.spanHz,
                                                              looks: row.looks, pFalse: pFalse,
                                                          believe: window.lowHz ... (window.highHz - 1),
                                                          power: p.baseAddress!, floor: f.baseAddress!,
                                                          scratch: sc.baseAddress!)
                                }
                            }
                        }
                        let windowFloor = floorBuf.withUnsafeMutableBufferPointer { f in
                            scratch.withUnsafeMutableBufferPointer { sc in
                                SpectrumDetect.windowFloorDBFS(floor: f.baseAddress!, count: row.bins,
                                                               centerHz: row.centerHz, spanHz: row.spanHz,
                                                               believe: window.lowHz ... (window.highHz - 1),
                                                               scratch: sc.baseAddress!)
                            }
                        }
                        if windowFloor.isFinite { stepFloors.append(windowFloor) }
                        for h in hits {
                            fold(h, at: row.time, into: &stepHits)
                        }
                    }
                }
            }
            if believedRows == 0 {
                Self.log.warning("scan step \(index + 1)/\(plan.steps.count) at \(step.centerHz) Hz saw no rows it could believe")
            }
            if believedRows > 0 {
                analysed.append(contentsOf: stepWindows)
                looked.append((stepWindows, believedRows))
            }
            for h in stepHits {
                await onHit(h)
                merge(h, into: &merged)
            }
            if !stepFloors.isEmpty {
                let median = stepFloors.sorted()[stepFloors.count / 2]
                floors.append(segment(step, floorDBFS: median))
            }
            if believedRows >= rowsPerStep { stepsDone += 1 }
            await onStep(Progress(step: index + 1, steps: plan.steps.count, found: merged.count))
        }
        // Every row of every step whose window covered this frequency is a chance the signal had
        // to appear, whether or not that step found it.
        for i in merged.indices {
            var chances = 0
            for step in looked where step.windows.contains(where: { $0.contains(merged[i].centerHz) }) {
                chances += step.rows
            }
            merged[i].looksPossible = UInt32(Swift.max(Int(merged[i].looks), chances))
        }
        return Result(hits: merged, floors: floors, stepsDone: stepsDone, steps: plan.steps.count,
                      covered: union(analysed), failure: failure)
    }

    /// The settle window in nanoseconds, for the dwell deadline.
    private static func settleNs(_ samples: UInt64, rate: UInt64) -> UInt64 {
        rate == 0 ? 0 : samples * 1_000_000_000 / rate
    }

    /// Folds a hit into a step's list, keeping the strongest reading and counting the looks.
    ///
    /// One look per row, not per run: a wide signal with a notch wider than the join gap arrives
    /// as two runs from the same row, and counting both would put `looks` above `looks_possible`.
    private static func fold(_ h: SpectrumDetect.Hit, at time: SampleTime, into list: inout [ScanHit]) {
        if let i = list.firstIndex(where: { near($0.centerHz, h.centerHz, $0.bandwidthHz) }) {
            if list[i].lastSeen.sampleIndex != time.sampleIndex { list[i].looks += 1 }
            list[i].lastSeen = time
            if h.snrDB > list[i].snrDB {
                list[i].snrDB = h.snrDB
                list[i].centerHz = h.centerHz
                list[i].bandwidthHz = h.bandwidthHz
                list[i].floorDBFS = h.floorDBFS
            }
            return
        }
        list.append(ScanHit(centerHz: h.centerHz, bandwidthHz: h.bandwidthHz, snrDB: h.snrDB,
                            floorDBFS: h.floorDBFS, looks: 1, looksPossible: 1,
                            firstSeen: time, lastSeen: time))
    }

    /// Merges one step's hit into the sweep's list. Almost every frequency is analysed from two
    /// tuner positions, so the same carrier arrives twice and the counts add.
    private static func merge(_ h: ScanHit, into list: inout [ScanHit]) {
        if let i = list.firstIndex(where: { near($0.centerHz, h.centerHz, Swift.min($0.bandwidthHz, h.bandwidthHz)) }) {
            list[i].looks += h.looks
            if h.firstSeen.sampleIndex < list[i].firstSeen.sampleIndex { list[i].firstSeen = h.firstSeen }
            if h.lastSeen.sampleIndex > list[i].lastSeen.sampleIndex { list[i].lastSeen = h.lastSeen }
            if h.snrDB > list[i].snrDB {
                list[i].snrDB = h.snrDB
                list[i].centerHz = h.centerHz
                list[i].bandwidthHz = h.bandwidthHz
                list[i].floorDBFS = h.floorDBFS
            }
            return
        }
        list.append(h)
    }

    /// Two readings are the same signal when their centres are within half the narrower one's
    /// width, or a few kHz for anything narrow.
    ///
    /// Using the wider bandwidth would let a wide broadcast carrier swallow a legitimately
    /// separate neighbouring station within normal international channel spacing; the narrower
    /// bandwidth avoids that.
    private static func near(_ a: UInt64, _ b: UInt64, _ bandwidthHz: UInt32) -> Bool {
        let tol = Swift.max(mergeToleranceHz, UInt64(bandwidthHz) / 2)
        return a > b ? a - b <= tol : b - a <= tol
    }

    /// Merges overlapping windows into a minimal cover.
    private static func union(_ windows: [SweepPlan.Window]) -> [SweepPlan.Window] {
        let sorted = windows.filter { $0.highHz > $0.lowHz }.sorted { $0.lowHz < $1.lowHz }
        var out: [SweepPlan.Window] = []
        for w in sorted {
            if var last = out.last, w.lowHz <= last.highHz {
                last.highHz = Swift.max(last.highHz, w.highHz)
                out[out.count - 1] = last
            } else {
                out.append(w)
            }
        }
        return out
    }

    private static func segment(_ step: SweepPlan.Step, floorDBFS: Double) -> Leyline_V1_NoiseFloorSegment {
        var s = Leyline_V1_NoiseFloorSegment()
        s.range.minHz = step.low.lowHz
        s.range.maxHz = step.high.highHz
        s.floorDbfs = floorDBFS
        return s
    }
}
