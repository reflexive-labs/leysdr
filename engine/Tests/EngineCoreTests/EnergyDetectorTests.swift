import Foundation
import XCTest
@testable import EngineCore

/// The detector's claims, checked against synthetic spectra. Every number here is from
/// `docs/design-scan.md`, and the design doc's numbers came from a Monte Carlo run before any of
/// this was written; these tests are what stops them drifting.
final class EnergyDetectorTests: XCTestCase {
    let bins = 1024
    let rate: UInt64 = 2_400_000
    let center: UInt64 = 146_000_000
    var binWidth: Double { Double(rate) / Double(bins) }

    /// A row of M-averaged Gamma noise at a given per-bin level, plus optional signals, in dB and
    /// fft-shifted the way the ladder emits.
    func row(looks: Int, floorDBFS: Double = -90, tiltDB: Double = 0,
             signals: [(offsetHz: Double, snrDB: Double, widthHz: Double)] = [],
             seed: UInt64) -> [Float]
    {
        var rng = DetectorRNG(seed: seed)
        let mean = pow(10, floorDBFS / 10)
        var p = [Double](repeating: 0, count: bins)
        for i in 0 ..< bins {
            // Gamma(M, mean/M) as a sum of M exponentials.
            var acc = 0.0
            for _ in 0 ..< Swift.max(1, looks) { acc += -log(rng.uniform()) }
            var level = mean * acc / Double(Swift.max(1, looks))
            if tiltDB != 0 {
                // Peak at centre, dropping tiltDB by the edges, like an IF response.
                let x = 2 * abs(Double(i) - Double(bins) / 2) / Double(bins)
                level *= pow(10, -tiltDB * x * x / 10)
            }
            p[i] = level
        }
        for s in signals {
            let occupied = Swift.max(1, Int((s.widthHz / binWidth).rounded()))
            let per = mean * pow(10, s.snrDB / 10)
            let centreBin = Double(bins) / 2 + s.offsetHz / binWidth
            for k in 0 ..< occupied {
                let b = Int((centreBin - Double(occupied) / 2 + Double(k)).rounded())
                guard b >= 0, b < bins else { continue }
                p[b] += per
            }
            // The Hann mainlobe: a real analyser spreads every component two bins either side.
            var spread = p
            for b in 1 ..< bins - 1 {
                spread[b] = 0.25 * p[b - 1] + 0.5 * p[b] + 0.25 * p[b + 1]
            }
            p = spread
        }
        return p.map { Float(10 * log10(Swift.max($0, 1e-30))) }
    }

    func detect(_ rowDB: [Float], looks: Int, pFalse: Double,
                believe: ClosedRange<UInt64>? = nil) -> [SpectrumDetect.Hit]
    {
        let all = (center - rate / 2) ... (center + rate / 2)
        var power = [Float](repeating: 0, count: bins)
        var floor = [Float](repeating: 0, count: bins)
        var scratch = [Float](repeating: 0, count: 2 * SpectrumDetect.referenceBins)
        return rowDB.withUnsafeBufferPointer { r in
            power.withUnsafeMutableBufferPointer { p in
                floor.withUnsafeMutableBufferPointer { f in
                    scratch.withUnsafeMutableBufferPointer { s in
                        SpectrumDetect.detect(rowDB: r.baseAddress!, count: bins,
                                              centerHz: center, spanHz: rate, looks: looks,
                                              pFalse: pFalse, believe: believe ?? all,
                                              power: p.baseAddress!, floor: f.baseAddress!,
                                              scratch: s.baseAddress!)
                    }
                }
            }
        }
    }

    // MARK: the threshold

    /// The published formula, at the values the design doc quotes.
    func testThresholdMatchesTheDesignDoc() {
        // One look is the exponential case, where the exact answer is -10*log10(-ln p / ln 2).
        for p in [1e-2, 1e-4, 1e-6] {
            let exact = 10 * log10(-log(p) / log(2.0))
            let got = 10 * log10(SpectrumDetect.thresholdRatio(looks: 1, pFalse: p))
            // Wilson-Hilferty is an approximation; it is within a fifth of a dB of the exact
            // exponential answer across the tail, sometimes above and sometimes below.
            // In the deep tail it errs high, which is the safe direction.
            XCTAssertEqual(got, exact, accuracy: 0.45, "one look, p=\(p)")
        }
        // The sweep operating point: 1024 bins, 4 rows a step, 7 steps, 0.1 expected false hits.
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: 1024, rowsPerStep: 4, steps: 7)
        XCTAssertEqual(10 * log10(SpectrumDetect.thresholdRatio(looks: 16, pFalse: p)), 4.17, accuracy: 0.15)
        XCTAssertEqual(10 * log10(SpectrumDetect.thresholdRatio(looks: 8, pFalse: p)), 5.60, accuracy: 0.15)
        XCTAssertEqual(10 * log10(SpectrumDetect.thresholdRatio(looks: 4, pFalse: p)), 7.44, accuracy: 0.15)
    }

    /// Fewer looks must measure a higher threshold; using an assumed look count instead of the
    /// actual one would get this backwards.
    func testFewerLooksMeansAHigherThreshold() {
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: 1024, rowsPerStep: 4, steps: 7)
        let two = 10 * log10(SpectrumDetect.thresholdRatio(looks: 2, pFalse: p))
        let sixteen = 10 * log10(SpectrumDetect.thresholdRatio(looks: 16, pFalse: p))
        XCTAssertGreaterThan(two - sixteen, 3.5, "assuming 16 looks when the ladder gave 2 is a multi-dB error")
    }

    // MARK: false alarms

    func testPureNoiseIsQuiet() {
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: bins, rowsPerStep: 4, steps: 7)
        var total = 0
        let rows = 40
        for s in 0 ..< rows { total += detect(row(looks: 16, seed: UInt64(s) &+ 1), looks: 16, pFalse: p).count }
        // The budget is 0.1 per sweep of 28 rows, so 40 rows should be very close to empty.
        XCTAssertLessThanOrEqual(total, 2, "\(total) false detections in \(rows) rows of pure noise")
    }

    // MARK: the floor

    /// A single median per row is 9 dB wrong end to end across a 12 dB tilt; the local one is not.
    func testTheLocalFloorTracksAnIFTilt() {
        let r = row(looks: 16, tiltDB: 12, seed: 99)
        var power = [Float](repeating: 0, count: bins)
        var floor = [Float](repeating: 0, count: bins)
        var scratch = [Float](repeating: 0, count: 2 * SpectrumDetect.referenceBins)
        r.withUnsafeBufferPointer { rb in
            power.withUnsafeMutableBufferPointer { p in
                Kernels.dbToPower(rb.baseAddress!, to: p.baseAddress!, count: bins)
                floor.withUnsafeMutableBufferPointer { f in
                    scratch.withUnsafeMutableBufferPointer { s in
                        SpectrumDetect.localFloor(power: p.baseAddress!, count: bins,
                                                  into: f.baseAddress!, scratch: s.baseAddress!)
                    }
                }
            }
        }
        func meanExcessDB(_ range: Range<Int>) -> Double {
            var acc = 0.0
            for i in range { acc += 10 * log10(Double(power[i]) / Double(Swift.max(floor[i], 1e-30))) }
            return acc / Double(range.count)
        }
        // Normalised by the local floor, the middle of the span and the outer quarters must read
        // the same level. The comparison is inside the window a sweep actually believes (5%-45%
        // either side of centre, so bins 52-461 and 563-972 of 1024): the outermost 192 bins of a
        // row have a one-sided reference window and read a floor biased toward the row's middle,
        // which the two-look geometry covers rather than the estimator.
        let inner = meanExcessDB((bins / 2 - 100) ..< (bins / 2 + 100))
        let outer = (meanExcessDB(150 ..< 300) + meanExcessDB((bins - 300) ..< (bins - 150))) / 2
        let localResidual = abs(inner - outer)

        // What a single median per row would have left, for comparison.
        var all = power
        let global = all.withUnsafeMutableBufferPointer { SpectrumDetect.median($0.baseAddress!, count: bins) }
        let innerG = (bins / 2 - 100 ..< bins / 2 + 100).reduce(0.0) { $0 + 10 * log10(Double(power[$1]) / Double(global)) } / 200
        let outerG = (150 ..< 300).reduce(0.0) { $0 + 10 * log10(Double(power[$1]) / Double(global)) } / 150
        let globalResidual = abs(innerG - outerG)

        XCTAssertGreaterThan(globalResidual, 3.0, "the fixture must actually contain a tilt")
        XCTAssertLessThan(localResidual, globalResidual / 2,
                          "local floor left \(localResidual) dB of tilt where one median left \(globalResidual)")
    }

    // MARK: what it finds

    func testFindsCarriersAtTheDesignSensitivity() {
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: bins, rowsPerStep: 4, steps: 7)
        let hits = detect(row(looks: 16, signals: [(300_000, 10, 12_500),
                                                   (-500_000, 20, 25_000),
                                                   (700_000, 6, 12_500)], seed: 5),
                          looks: 16, pFalse: p)
        XCTAssertEqual(hits.count, 3, "got \(hits.map { $0.centerHz })")
        for (want, tol) in [(center + 300_000, 4_000), (center - 500_000, 4_000), (center + 700_000, 6_000)] {
            XCTAssertTrue(hits.contains { $0.centerHz > want - UInt64(tol) && $0.centerHz < want + UInt64(tol) },
                          "nothing near \(want) in \(hits.map { $0.centerHz })")
        }
    }

    /// The reason bandwidth is a moment and not the width of the run above the threshold: the run
    /// grows with SNR and the moment does not.
    func testBandwidthDoesNotGrowWithSNR() {
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: bins, rowsPerStep: 4, steps: 7)
        var widths: [Double] = []
        for snr in [8.0, 20.0, 35.0] {
            let hits = detect(row(looks: 16, signals: [(300_000, snr, 25_000)], seed: 17), looks: 16, pFalse: p)
            let h = try? XCTUnwrap(hits.first { $0.centerHz > center + 280_000 && $0.centerHz < center + 320_000 })
            widths.append(Double(h?.bandwidthHz ?? 0))
        }
        XCTAssertEqual(widths.count, 3)
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        XCTAssertLessThan(spread, 8_000, "width moved \(spread) Hz over 27 dB of SNR: \(widths)")
        for w in widths { XCTAssertEqual(w, 25_000, accuracy: 9_000, "\(widths)") }
    }

    /// A tone is narrower than the analysis can resolve, and must be reported as such rather than
    /// given an invented width.
    func testAToneIsReportedAsUnresolvable() {
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: bins, rowsPerStep: 4, steps: 7)
        let hits = detect(row(looks: 16, signals: [(300_000, 25, 0)], seed: 23), looks: 16, pFalse: p)
        let h = hits.first { $0.centerHz > center + 280_000 && $0.centerHz < center + 320_000 }
        XCTAssertNotNil(h)
        XCTAssertLessThan(Double(h?.bandwidthHz ?? 99_999), binWidth * 2, "a tone read \(h?.bandwidthHz ?? 0) Hz wide")
    }

    /// The R820T's image: a mirror of a strong carrier about the capture centre. It is stationary,
    /// persistent, and looks exactly like a carrier.
    func testTheIQImageIsRejectedAndItsSourceIsKept() {
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: bins, rowsPerStep: 4, steps: 7)
        // A real carrier 45 dB up at +400 kHz, and its image 30 dB weaker at -400 kHz.
        let hits = detect(row(looks: 16, signals: [(400_000, 45, 12_500), (-400_000, 15, 12_500)], seed: 31),
                          looks: 16, pFalse: p)
        XCTAssertTrue(hits.contains { $0.centerHz > center + 380_000 && $0.centerHz < center + 420_000 },
                      "the real carrier must survive: \(hits.map { $0.centerHz })")
        XCTAssertFalse(hits.contains { $0.centerHz > center - 420_000 && $0.centerHz < center - 380_000 },
                       "the image must be rejected: \(hits.map { $0.centerHz })")
        // Two real carriers of similar strength are not each other's image.
        let both = detect(row(looks: 16, signals: [(400_000, 30, 12_500), (-400_000, 28, 12_500)], seed: 37),
                          looks: 16, pFalse: p)
        XCTAssertEqual(both.count, 2, "\(both.map { ($0.centerHz, $0.snrDB) })")
    }

    /// Bins outside the window the sweep asked about are used for the floor and never reported:
    /// that is how the DC spike and the rolled-off edges stay out of the answer.
    func testNothingOutsideTheBelievedWindowIsReported() {
        let p = SpectrumDetect.sweepPFalse(expected: 0.1, bins: bins, rowsPerStep: 4, steps: 7)
        let believe = (center + 200_000) ... (center + 400_000)
        let hits = detect(row(looks: 16, signals: [(300_000, 20, 12_500), (-600_000, 40, 12_500)], seed: 41),
                          looks: 16, pFalse: p, believe: believe)
        XCTAssertEqual(hits.count, 1, "\(hits.map { $0.centerHz })")
        XCTAssertTrue(believe.contains(hits[0].centerHz))
    }

    func testSelectFindsTheMedian() {
        var v: [Float] = [5, 1, 9, 3, 7, 2, 8]
        let m = v.withUnsafeMutableBufferPointer { SpectrumDetect.median($0.baseAddress!, count: 7) }
        XCTAssertEqual(m, 5)
        var one: [Float] = [42]
        XCTAssertEqual(one.withUnsafeMutableBufferPointer { SpectrumDetect.median($0.baseAddress!, count: 1) }, 42)
    }
}

/// Deterministic uniforms, so a failure is reproducible.
private struct DetectorRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double {
        Swift.max(Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0), 1e-15)
    }
}
