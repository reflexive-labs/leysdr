// The shared FFT ladder (docs/engine-internals.md, "Spectrum ladder"). Subscriptions are an
// immutable table swapped under an NSLock; the DSP thread copies the reference once per block.

import Foundation

/// Ladder of fixed FFT sizes fanned out to rate-limited subscribers.
public final class DefaultSpectrumLadder: SpectrumLadder, @unchecked Sendable {
    /// Sizes the ladder computes.
    public static let sizes = [256, 512, 1024, 2048, 4096, 8192, 16384]
    /// Highest row rate any subscriber receives.
    public static let maxRowsPerSecond: Double = 30

    /// Round a request to the nearest ladder size ≥ `bins`, capped at 16384.
    public static func roundBins(_ bins: Int) -> Int {
        sizes.first { $0 >= bins } ?? sizes.last!
    }

    /// Clamp a requested rate to `(0, 30]`.
    public static func roundRate(_ rowsPerSecond: Double) -> Double {
        guard rowsPerSecond.isFinite, rowsPerSecond > 0 else { return maxRowsPerSecond }
        return min(rowsPerSecond, maxRowsPerSecond)
    }

    final class Entry {
        let subscription: SpectrumSubscription
        let policy: DeliveryPolicy
        let sizeIndex: Int
        let sink: any SpectrumSink
        /// Sample index at/after which the next row is due (DSP thread only).
        var nextDue: UInt64 = 0

        init(subscription: SpectrumSubscription, policy: DeliveryPolicy, sizeIndex: Int, sink: any SpectrumSink) {
            self.subscription = subscription
            self.policy = policy
            self.sizeIndex = sizeIndex
            self.sink = sink
        }
    }

    private let lock = NSLock()
    private var table: [Entry] = []
    private let analyzers: [SpectrumAnalyzer]
    /// One row buffer per ladder size: a size computed once per block must stay intact for every
    /// later same-size subscriber even after a different size has been analyzed in between.
    private let rows: [UnsafeMutableBufferPointer<Float>]
    private var computed: [Bool]

    public init() {
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
    public var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return table.count
    }

    public func subscribe(bins: Int, rowsPerSecond: Double, policy: DeliveryPolicy, sink: any SpectrumSink) async -> SpectrumSubscription {
        let size = DefaultSpectrumLadder.roundBins(bins)
        let sub = SpectrumSubscription(id: StreamID(), actualBins: size, actualRate: DefaultSpectrumLadder.roundRate(rowsPerSecond))
        let entry = Entry(subscription: sub, policy: policy, sizeIndex: DefaultSpectrumLadder.sizes.firstIndex(of: size)!, sink: sink)
        lock.lock()
        table = table + [entry]
        lock.unlock()
        return sub
    }

    public func cancel(_ subscription: SpectrumSubscription) async {
        lock.lock()
        table = table.filter { $0.subscription.id != subscription.id }
        lock.unlock()
    }

    /// One ladder pass over the most recent block. `spanHz` is the capture sample rate.
    /// Hot path: lock held only to copy the table reference; each size computed at most once.
    public func process(block: SampleBuffer, at time: SampleTime, centerHz: UInt64, spanHz: UInt64) {
        lock.lock()
        let entries = table
        lock.unlock()
        guard !entries.isEmpty, spanHz > 0 else { return }
        let sp = Signpost.begin(.ladderPass)
        defer { Signpost.end(.ladderPass, sp) }
        for i in computed.indices { computed[i] = false }
        let now = time.sampleIndex
        for e in entries {
            guard now >= e.nextDue else { continue }
            let analyzer = analyzers[e.sizeIndex]
            guard block.count >= analyzer.size else { continue }
            let row = rows[e.sizeIndex]
            if !computed[e.sizeIndex] {
                analyzer.analyze(block, into: row)
                computed[e.sizeIndex] = true
            }
            let interval = UInt64((Double(spanHz) / e.subscription.actualRate).rounded())
            // Schedule from the previous due point so rate stays exact under jitter, but never
            // fall more than one interval behind (LATEST_WINS semantics for skipped ticks).
            let scheduled = e.nextDue &+ interval
            e.nextDue = scheduled > now ? scheduled : now &+ interval
            e.sink.write(row: UnsafeBufferPointer(row), at: time, centerHz: centerHz, spanHz: spanHz)
        }
    }
}
