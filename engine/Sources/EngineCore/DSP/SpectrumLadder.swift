// SPDX-License-Identifier: GPL-3.0-or-later

// The shared FFT ladder (docs/dev/engine-internals.md, "Spectrum ladder"). Subscriptions are an
// immutable table swapped under an NSLock; the DSP thread copies the reference once per block.

import Foundation

/// Ladder of fixed FFT sizes fanned out to rate-limited subscribers.
/// Unchecked Sendable: the subscriber table is swapped under `lock`; the transform scratch belongs to the DSP thread.
package final class DefaultSpectrumLadder: SpectrumLadder, @unchecked Sendable {
    /// Sizes the ladder computes.
    package static let sizes = [256, 512, 1024, 2048, 4096, 8192, 16384]
    /// Highest row rate any subscriber receives.
    package static let maxRowsPerSecond: Double = 30

    /// Round a request to the nearest ladder size ≥ `bins`, capped at 16384.
    package static func roundBins(_ bins: Int) -> Int {
        sizes.first { $0 >= bins } ?? sizes.last!
    }

    /// Lowest row rate any subscriber receives; requests below it are clamped up so the row
    /// interval stays representable and rows keep arriving.
    package static let minRowsPerSecond: Double = 0.1

    /// Clamp a requested rate to `[minRowsPerSecond, maxRowsPerSecond]`. Non-finite or
    /// non-positive requests mean "as fast as allowed".
    package static func roundRate(_ rowsPerSecond: Double) -> Double {
        guard rowsPerSecond.isFinite, rowsPerSecond > 0 else { return maxRowsPerSecond }
        return min(max(rowsPerSecond, minRowsPerSecond), maxRowsPerSecond)
    }

    /// Most looks the ladder will take for one row. It bounds the FFT cost of a very slow row rate;
    /// looks are spread evenly across the row rather than taken back to back, so capping them
    /// thins the sampling instead of covering only the start of the row.
    package static let maxLooksPerRow = 64

    final class Entry {
        let subscription: SpectrumSubscription
        let policy: DeliveryPolicy
        let sizeIndex: Int
        let sink: any SpectrumSink
        /// Sample index at/after which the next row is due (DSP thread only).
        var nextDue: UInt64 = 0
        /// Sample index at/after which the next look is due, and the row being built. Both are
        /// nil/zero under `.snapshot`, which analyses once per row and emits the ladder's own
        /// buffer untouched. Allocated at subscribe time: the DSP thread never allocates.
        var nextLook: UInt64 = 0
        var looks: Int = 0
        /// Whether this entry has seen a block yet. An accumulating entry uses it to put its first
        /// row a whole interval out: a row emitted on the first block would contain one look and
        /// would misreport the interval it covers.
        var started = false
        let accumulator: UnsafeMutableBufferPointer<Float>?
        /// Per-entry scratch for `.mean`, which cannot convert in the shared row buffer.
        let scratch: UnsafeMutableBufferPointer<Float>?

        init(subscription: SpectrumSubscription, policy: DeliveryPolicy, sizeIndex: Int, sink: any SpectrumSink) {
            self.subscription = subscription
            self.policy = policy
            self.sizeIndex = sizeIndex
            self.sink = sink
            if subscription.accumulation == .snapshot {
                accumulator = nil
                scratch = nil
            } else {
                let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: subscription.actualBins)
                buf.initialize(repeating: 0)
                accumulator = buf
                // `.mean` converts each look out of dB before summing it. That conversion may not
                // touch the ladder's shared row buffer, which every same-size subscriber in this
                // pass reads, so each mean subscriber converts into scratch of its own.
                if subscription.accumulation == .mean {
                    let tmp = UnsafeMutableBufferPointer<Float>.allocate(capacity: subscription.actualBins)
                    tmp.initialize(repeating: 0)
                    scratch = tmp
                } else {
                    scratch = nil
                }
            }
        }

        deinit {
            accumulator?.deallocate()
            scratch?.deallocate()
        }
    }

    private let lock = NSLock()
    private var table: [Entry] = []
    private let analyzers: [SpectrumAnalyzer]
    /// One row buffer per ladder size: a size computed once per block must stay intact for every
    /// later same-size subscriber even after a different size has been analyzed in between.
    private let rows: [UnsafeMutableBufferPointer<Float>]
    private var computed: [Bool]

    package init() {
        analyzers = DefaultSpectrumLadder.sizes.map { SpectrumAnalyzer(size: $0) }
        rows = DefaultSpectrumLadder.sizes.map { size in
            let row = UnsafeMutableBufferPointer<Float>.allocate(capacity: size)
            row.initialize(repeating: 0)
            return row
        }
        computed = [Bool](repeating: false, count: DefaultSpectrumLadder.sizes.count)
    }

    deinit { for row in rows { row.deallocate() } }

    /// Active subscriptions.
    package var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return table.count
    }

    package func subscribe(bins: Int, rowsPerSecond: Double, accumulation: SpectrumAccumulation,
                          policy: DeliveryPolicy, sink: any SpectrumSink) async -> SpectrumSubscription {
        let size = DefaultSpectrumLadder.roundBins(bins)
        let rate = DefaultSpectrumLadder.roundRate(rowsPerSecond)
        let looks = accumulation == .snapshot ? 1 : DefaultSpectrumLadder.maxLooksPerRow
        let sub = SpectrumSubscription(id: StreamID(), actualBins: size, actualRate: rate,
                                       accumulation: accumulation, looksPerRow: looks)
        let entry = Entry(subscription: sub, policy: policy, sizeIndex: DefaultSpectrumLadder.sizes.firstIndex(of: size)!, sink: sink)
        lock.withLock { table = table + [entry] }
        return sub
    }

    package func cancel(_ subscription: SpectrumSubscription) async {
        lock.withLock { table = table.filter { $0.subscription.id != subscription.id } }
    }

    /// One ladder pass over the most recent block. `spanHz` is the capture sample rate.
    /// Hot path: lock held only to copy the table reference; each size computed at most once.
    package func process(block: SampleBuffer, at time: SampleTime, centerHz: UInt64, spanHz: UInt64) {
        lock.lock()
        let entries = table
        lock.unlock()
        guard !entries.isEmpty, spanHz > 0 else { return }
        let sp = Signpost.begin(.ladderPass)
        defer { Signpost.end(.ladderPass, sp) }
        for i in computed.indices { computed[i] = false }
        let now = time.sampleIndex
        for e in entries {
            // Saturate before converting: a Double above UInt64.max traps in the initializer.
            let interval = UInt64(min((Double(spanHz) / e.subscription.actualRate).rounded(), Double(UInt64.max / 2)))
            // A new anchor (rate change shrinks the interval) or a rewound/jumped timeline can
            // leave the due point more than one interval ahead of `now`; clamp so rows never stall.
            if e.nextDue > now &+ interval { e.nextDue = now &+ interval }
            let analyzer = analyzers[e.sizeIndex]

            // An accumulating subscriber takes periodograms between rows, evenly spread: a row can
            // only catch a burst in the fraction of its time that was analysed, and one
            // periodogram is 0.17% of a 250 ms row at 2.4 MSPS.
            if let acc = e.accumulator {
                if !e.started {
                    e.started = true
                    e.nextDue = now &+ interval
                    e.nextLook = now
                }
                let lookInterval = Swift.max(1 as UInt64, interval / UInt64(e.subscription.looksPerRow))
                if e.nextLook > now &+ lookInterval { e.nextLook = now }
                if now >= e.nextLook, block.count >= analyzer.size {
                    let row = rows[e.sizeIndex]
                    if !computed[e.sizeIndex] {
                        analyzer.analyze(block, into: row)
                        computed[e.sizeIndex] = true
                    }
                    fold(row: row, into: acc, scratch: e.scratch, kind: e.subscription.accumulation, first: e.looks == 0)
                    e.looks += 1
                    let scheduledLook = e.nextLook &+ lookInterval
                    e.nextLook = scheduledLook > now ? scheduledLook : now &+ lookInterval
                }
                guard now >= e.nextDue else { continue }
                // A row with no looks in it has nothing to say, so it is skipped rather than
                // emitted as whatever the accumulator last held.
                guard e.looks > 0 else {
                    let scheduled = e.nextDue &+ interval
                    e.nextDue = scheduled > now ? scheduled : now &+ interval
                    continue
                }
                finish(acc, kind: e.subscription.accumulation, looks: e.looks)
                let scheduled = e.nextDue &+ interval
                e.nextDue = scheduled > now ? scheduled : now &+ interval
                let looks = e.looks
                e.looks = 0
                e.sink.write(row: UnsafeBufferPointer(acc), at: time, centerHz: centerHz, spanHz: spanHz, looks: looks)
                continue
            }

            guard now >= e.nextDue else { continue }
            guard block.count >= analyzer.size else { continue }
            let row = rows[e.sizeIndex]
            if !computed[e.sizeIndex] {
                analyzer.analyze(block, into: row)
                computed[e.sizeIndex] = true
            }
            // Schedule from the previous due point so rate stays exact under jitter, but never
            // fall more than one interval behind (LATEST_WINS semantics for skipped ticks).
            let scheduled = e.nextDue &+ interval
            e.nextDue = scheduled > now ? scheduled : now &+ interval
            e.sink.write(row: UnsafeBufferPointer(row), at: time, centerHz: centerHz, spanHz: spanHz, looks: 1)
        }
    }

    /// Fold one look into a row being built. `.max` accumulates in dB, where the elementwise
    /// maximum is the same value as the maximum of the underlying power. `.mean` cannot: the mean
    /// of decibels is a different statistic, so the look is converted to linear power first and the
    /// row is converted back in `finish`.
    private func fold(row: UnsafeMutableBufferPointer<Float>, into acc: UnsafeMutableBufferPointer<Float>,
                      scratch: UnsafeMutableBufferPointer<Float>?, kind: SpectrumAccumulation, first: Bool)
    {
        let n = Swift.min(row.count, acc.count)
        switch kind {
        case .snapshot:
            break
        case .max:
            if first {
                Kernels.copy(row.baseAddress!, to: acc.baseAddress!, count: n)
            } else {
                Kernels.maxInPlace(acc.baseAddress!, row.baseAddress!, count: n)
            }
        case .mean:
            guard let tmp = scratch?.baseAddress else { return }
            Kernels.dbToPower(row.baseAddress!, to: tmp, count: n)
            if first {
                Kernels.copy(tmp, to: acc.baseAddress!, count: n)
            } else {
                Kernels.add(acc.baseAddress!, tmp, to: acc.baseAddress!, count: n)
            }
        }
    }

    /// Turn a completed accumulator into the dB row a sink expects.
    private func finish(_ acc: UnsafeMutableBufferPointer<Float>, kind: SpectrumAccumulation, looks: Int) {
        switch kind {
        case .snapshot, .max:
            break
        case .mean:
            let scale = 1 / Float(looks)
            Kernels.scaleAdd(acc.baseAddress!, scale: scale, offset: 0, to: acc.baseAddress!, count: acc.count)
            Kernels.powerToDB(acc.baseAddress!, to: acc.baseAddress!, count: acc.count)
        }
    }
}
