import XCTest
@testable import EngineCore

/// Collects rows on the DSP thread; test-only sink.
final class CollectingSpectrumSink: SpectrumSink, @unchecked Sendable {
    var rows: [(bins: Int, index: UInt64, peakBin: Int, peakDB: Float)] = []
    func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64) {
        var best = 0
        for i in 1 ..< row.count where row[i] > row[best] { best = i }
        rows.append((row.count, time.sampleIndex, best, row[best]))
    }
}

final class DSPSpectrumTests: XCTestCase {
    func testFFTPlanMatchesDFT() {
        let n = 64
        let plan = FFTPlan(size: n)
        var re = (0 ..< n).map { Float(sin(Double($0) * 0.3) + 0.2 * cos(Double($0) * 1.1)) }
        var im = (0 ..< n).map { Float(cos(Double($0) * 0.7)) }
        var oRe = [Float](repeating: 0, count: n), oIm = oRe
        plan.forward(inRe: &re, inIm: &im, outRe: &oRe, outIm: &oIm)
        for k in 0 ..< n {
            var sr = 0.0, si = 0.0
            for t in 0 ..< n {
                let a = -2 * Double.pi * Double(k * t) / Double(n)
                sr += Double(re[t]) * cos(a) - Double(im[t]) * sin(a)
                si += Double(re[t]) * sin(a) + Double(im[t]) * cos(a)
            }
            XCTAssertEqual(Double(oRe[k]), sr, accuracy: 1e-3)
            XCTAssertEqual(Double(oIm[k]), si, accuracy: 1e-3)
        }
    }

    func testFullScaleToneReadsZeroDBFSAtRightBin() {
        let n = 1024, rate = 1_024_000.0
        let analyzer = SpectrumAnalyzer(size: n)
        // Bin spacing is 1 kHz; a tone at +100 kHz lands at shifted index n/2 + 100.
        let iq = DSPTest.storage(DSPTest.complexTone(frequencyHz: 100_000, rate: rate, count: n))
        var row = [Float](repeating: 0, count: n)
        row.withUnsafeMutableBufferPointer { analyzer.analyze(iq.view(), into: $0) }
        let peak = row.indices.max { row[$0] < row[$1] }!
        XCTAssertEqual(peak, n / 2 + 100)
        XCTAssertEqual(row[peak], 0, accuracy: 0.05)
        // Negative frequency lands below DC; far bins are deep in the Hann sidelobes.
        let neg = DSPTest.storage(DSPTest.complexTone(frequencyHz: -256_000, rate: rate, count: n, amplitude: 0.1))
        row.withUnsafeMutableBufferPointer { analyzer.analyze(neg.view(), into: $0) }
        let p2 = row.indices.max { row[$0] < row[$1] }!
        XCTAssertEqual(p2, n / 2 - 256)
        XCTAssertEqual(row[p2], -20, accuracy: 0.05)
        XCTAssertLessThan(row[0], -80)
    }

    func testLadderRoundingAndRates() async {
        let ladder = DefaultSpectrumLadder()
        XCTAssertEqual(DefaultSpectrumLadder.roundBins(100), 256)
        XCTAssertEqual(DefaultSpectrumLadder.roundBins(1024), 1024)
        XCTAssertEqual(DefaultSpectrumLadder.roundBins(1025), 2048)
        XCTAssertEqual(DefaultSpectrumLadder.roundBins(1 << 20), 16384)
        let sink = CollectingSpectrumSink()
        let sub = await ladder.subscribe(bins: 3000, rowsPerSecond: 100, accumulation: .snapshot, policy: .latestWins, sink: sink)
        XCTAssertEqual(sub.actualBins, 4096)
        XCTAssertEqual(sub.actualRate, 30)
        let sub2 = await ladder.subscribe(bins: 0, rowsPerSecond: 0, accumulation: .snapshot, policy: .latestWins, sink: sink)
        XCTAssertEqual(sub2.actualBins, 256)
        XCTAssertEqual(sub2.actualRate, 30)
        XCTAssertEqual(ladder.subscriberCount, 2)
        await ladder.cancel(sub)
        await ladder.cancel(sub2)
        XCTAssertEqual(ladder.subscriberCount, 0)
        // Denormal / tiny rates clamp up to the floor rather than producing an unrepresentable interval.
        XCTAssertEqual(DefaultSpectrumLadder.roundRate(1e-300), DefaultSpectrumLadder.minRowsPerSecond)
        XCTAssertEqual(DefaultSpectrumLadder.roundRate(0.05), 0.1)
        XCTAssertEqual(DefaultSpectrumLadder.roundRate(0.5), 0.5)
        XCTAssertEqual(DefaultSpectrumLadder.roundRate(.nan), 30)
        XCTAssertEqual(DefaultSpectrumLadder.roundRate(-.infinity), 30)
        XCTAssertEqual(DefaultSpectrumLadder.roundRate(.infinity), 30)
    }

    /// A subscription at the floor rate over the widest span still gets its first row and a finite
    /// schedule (the interval conversion saturates instead of trapping).
    func testLadderTinyRateStillDeliversRows() async {
        let ladder = DefaultSpectrumLadder()
        let sink = CollectingSpectrumSink()
        let sub = await ladder.subscribe(bins: 256, rowsPerSecond: 1e-300, accumulation: .snapshot, policy: .latestWins, sink: sink)
        XCTAssertEqual(sub.actualRate, 0.1)
        let iq = DSPTest.storage(DSPTest.complexTone(frequencyHz: 1_000, rate: 48_000, count: 256))
        let cap = CaptureID()
        ladder.process(block: iq.view(), at: SampleTime(captureID: cap, sampleIndex: 0), centerHz: 0, spanHz: UInt64.max)
        ladder.process(block: iq.view(), at: SampleTime(captureID: cap, sampleIndex: 256), centerHz: 0, spanHz: UInt64.max)
        XCTAssertEqual(sink.rows.count, 1, "first row immediately; the next is a saturated interval away")
        await ladder.cancel(sub)
    }

    func testLadderRateLimitsBySampleTime() async {
        let ladder = DefaultSpectrumLadder()
        let fast = CollectingSpectrumSink(), slow = CollectingSpectrumSink()
        _ = await ladder.subscribe(bins: 512, rowsPerSecond: 30, accumulation: .snapshot, policy: .latestWins, sink: fast)
        _ = await ladder.subscribe(bins: 512, rowsPerSecond: 5, accumulation: .snapshot, policy: .gapMarked, sink: slow)
        let rate: UInt64 = 2_400_000, block = 16384
        let iq = DSPTest.storage(DSPTest.complexTone(frequencyHz: 600_000, rate: Double(rate), count: block))
        let cap = CaptureID()
        var index: UInt64 = 0
        let blocks = Int(rate) / block // one second
        for _ in 0 ..< blocks {
            ladder.process(block: iq.view(), at: SampleTime(captureID: cap, sampleIndex: index), centerHz: 100_000_000, spanHz: rate)
            index += UInt64(block)
        }
        XCTAssertEqual(fast.rows.count, 30, accuracy: 1)
        XCTAssertEqual(slow.rows.count, 5, accuracy: 1)
        XCTAssertTrue(fast.rows.allSatisfy { $0.bins == 512 && $0.peakBin == 256 + 128 })
        XCTAssertEqual(fast.rows[0].peakDB, 0, accuracy: 0.1)
        // Rows are spaced at least one interval apart in sample time.
        for (a, b) in zip(slow.rows, slow.rows.dropFirst()) { XCTAssertGreaterThanOrEqual(b.index - a.index, rate / 5 - UInt64(block)) }
    }

    /// Three subscriptions ordered [1024, 4096, 1024]: the later 1024 subscriber must get the
    /// same full-span row as the first, not a slice of the 4096-point spectrum computed between them.
    func testLadderSameSizeRowsSurviveInterleavedSizes() async {
        final class FullRowSink: SpectrumSink, @unchecked Sendable {
            var rows: [[Float]] = []
            func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64) {
                rows.append(Array(row))
            }
        }
        let ladder = DefaultSpectrumLadder()
        let a = FullRowSink(), b = FullRowSink(), c = FullRowSink()
        _ = await ladder.subscribe(bins: 1024, rowsPerSecond: 30, accumulation: .snapshot, policy: .latestWins, sink: a)
        _ = await ladder.subscribe(bins: 4096, rowsPerSecond: 30, accumulation: .snapshot, policy: .latestWins, sink: b)
        _ = await ladder.subscribe(bins: 1024, rowsPerSecond: 30, accumulation: .snapshot, policy: .latestWins, sink: c)
        let rate: UInt64 = 2_400_000
        // Tone in the upper half of the span: a 1024-slice of the 4096 row would miss it.
        let iq = DSPTest.storage(DSPTest.complexTone(frequencyHz: 900_000, rate: Double(rate), count: 16384))
        ladder.process(block: iq.view(), at: SampleTime(captureID: CaptureID(), sampleIndex: 0), centerHz: 0, spanHz: rate)
        XCTAssertEqual(a.rows.count, 1)
        XCTAssertEqual(b.rows.count, 1)
        XCTAssertEqual(c.rows.count, 1)
        XCTAssertEqual(a.rows[0].count, 1024)
        XCTAssertEqual(b.rows[0].count, 4096)
        XCTAssertEqual(c.rows[0], a.rows[0])
        let peak = c.rows[0].indices.max { c.rows[0][$0] < c.rows[0][$1] }!
        XCTAssertEqual(peak, 512 + 384)
    }

    func testLadderSkipsSizesLargerThanBlock() async {
        let ladder = DefaultSpectrumLadder()
        let sink = CollectingSpectrumSink()
        _ = await ladder.subscribe(bins: 16384, rowsPerSecond: 30, accumulation: .snapshot, policy: .latestWins, sink: sink)
        let iq = DSPTest.storage(DSPTest.complexTone(frequencyHz: 0, rate: 48_000, count: 8192))
        ladder.process(block: iq.view(), at: SampleTime(captureID: CaptureID(), sampleIndex: 0), centerHz: 0, spanHz: 48_000)
        XCTAssertEqual(sink.rows.count, 0)
    }

    func testPowerMeterAndSquelch() {
        var meter = PowerMeter(rate: 48_000)
        let tone = DSPTest.storage(DSPTest.complexTone(frequencyHz: 1_000, rate: 48_000, count: 4800))
        let cap = CaptureID()
        let quiet = DSPTest.storage(DSPTest.complexTone(frequencyHz: 1_000, rate: 48_000, count: 4800, amplitude: 0.001))
        XCTAssertEqual(meter.measure(tone.view()), 0, accuracy: 0.01)
        XCTAssertTrue(meter.snrDB.isNaN) // < 1 s of data
        for _ in 0 ..< 10 { meter.measure(quiet.view()) }
        XCTAssertEqual(meter.powerDBFS, -60, accuracy: 0.01)
        XCTAssertEqual(meter.floorDBFS, -60, accuracy: 0.01)
        meter.measure(tone.view())
        XCTAssertEqual(meter.snrDB, 60, accuracy: 0.05)

        var squelch = Squelch(thresholdDB: -30)
        XCTAssertFalse(squelch.isOpen)
        XCTAssertTrue(squelch.update(powerDB: -20))
        XCTAssertTrue(squelch.isOpen)
        XCTAssertFalse(squelch.update(powerDB: -31)) // inside hysteresis: stays open
        XCTAssertTrue(squelch.update(powerDB: -32.5))
        XCTAssertFalse(squelch.isOpen)
        XCTAssertFalse(squelch.update(powerDB: -30)) // needs to exceed threshold
        XCTAssertTrue(Squelch(thresholdDB: .nan).isOpen)
    }
}

extension DSPSpectrumTests {
    /// Feed `blocks` blocks through a ladder, making only the blocks in `burst` carry a tone. The
    /// row rate is set so one row spans every block, which is the case a waterfall cares about: a
    /// transmission shorter than a row.
    private func burstRun(accumulation: SpectrumAccumulation, blocks: Int, burst: Range<Int>) async -> [Float] {
        let ladder = DefaultSpectrumLadder()
        let sink = CollectingSpectrumSink()
        let rate: Double = 256_000
        let size = 256
        // One row per `blocks` blocks: rowsPerSecond = rate / (blocks * size).
        let rows = rate / Double(blocks * size)
        let cap = CaptureID()
        _ = await ladder.subscribe(bins: size, rowsPerSecond: rows, accumulation: accumulation,
                                   policy: .latestWins, sink: sink)
        let quiet = DSPTest.storage(DSPTest.complexTone(frequencyHz: 0, rate: rate, count: size, amplitude: 0.000_01))
        let loud = DSPTest.storage(DSPTest.complexTone(frequencyHz: 64_000, rate: rate, count: size, amplitude: 1))
        for b in 0 ..< (blocks * 3) {
            let block = burst.contains(b % blocks) ? loud : quiet
            ladder.process(block: block.view(), at: SampleTime(captureID: cap, sampleIndex: UInt64(b * size)),
                           centerHz: 100_000_000, spanHz: UInt64(rate))
        }
        return sink.rows.map(\.peakDB)
    }

    /// A burst shorter than a row is what a waterfall exists to show, and one periodogram per row
    /// covers a fraction of a percent of it. MAX looks across the row and finds the burst; SNAPSHOT
    /// only finds it when the row boundary happens to land inside it.
    func testMaxAccumulationCatchesABurstSnapshotMisses() async {
        // The burst is 2 blocks of a 32-block row: 6% of the row.
        let maxed = await burstRun(accumulation: .max, blocks: 32, burst: 5 ..< 7)
        let snapped = await burstRun(accumulation: .snapshot, blocks: 32, burst: 5 ..< 7)
        XCTAssertFalse(maxed.isEmpty, "expected rows under MAX")
        XCTAssertFalse(snapped.isEmpty, "expected rows under SNAPSHOT")
        // Every MAX row sees the burst: a full-scale tone peaks near 0 dBFS.
        for (i, db) in maxed.enumerated() {
            XCTAssertGreaterThan(db, -10, "MAX row \(i) missed the burst (peak \(db) dBFS)")
        }
        // SNAPSHOT samples one block per row; the burst is 6% of the row, so it does not.
        for (i, db) in snapped.enumerated() {
            XCTAssertLessThan(db, -40, "SNAPSHOT row \(i) should not have landed on the burst (peak \(db) dBFS)")
        }
    }

    /// MEAN dilutes a short burst rather than hiding it: it is the honest average of the row, and
    /// it must sit well under the burst's own level and well over the quiet floor.
    func testMeanAccumulationDilutesABurst() async {
        let meaned = await burstRun(accumulation: .mean, blocks: 32, burst: 5 ..< 7)
        XCTAssertFalse(meaned.isEmpty)
        for (i, db) in meaned.enumerated() {
            XCTAssertLessThan(db, -5, "MEAN row \(i) must not read like a continuous carrier (\(db) dBFS)")
            XCTAssertGreaterThan(db, -30, "MEAN row \(i) must still see the burst (\(db) dBFS)")
        }
    }

    /// The looks the daemon takes are an answer, and SNAPSHOT still means exactly one.
    func testSubscriptionReportsItsLooks() async {
        let ladder = DefaultSpectrumLadder()
        let sink = CollectingSpectrumSink()
        let snap = await ladder.subscribe(bins: 256, rowsPerSecond: 4, accumulation: .snapshot, policy: .latestWins, sink: sink)
        XCTAssertEqual(snap.looksPerRow, 1)
        XCTAssertEqual(snap.accumulation, .snapshot)
        let maxed = await ladder.subscribe(bins: 256, rowsPerSecond: 4, accumulation: .max, policy: .latestWins, sink: sink)
        XCTAssertEqual(maxed.looksPerRow, DefaultSpectrumLadder.maxLooksPerRow)
        XCTAssertEqual(maxed.accumulation, .max)
    }
}
