// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import EngineCore

final class PersistenceTests: XCTestCase {
    private func acc(bins: Int = 8, levels: Int = 16, floor: Double = -100, range: Double = 100,
                     halfLife: Int = 1_000_000) -> PersistenceAccumulator
    {
        PersistenceAccumulator(bins: bins, levels: levels, floorDB: floor, rangeDB: range, halfLifeRows: halfLife)
    }

    /// Read the histogram back as counts, so a test can assert on the shape rather than on bytes.
    private func read(_ a: PersistenceAccumulator) -> [[Int]] {
        var bytes = [UInt8](repeating: 0, count: a.bins * a.levels * 2)
        let n = bytes.withUnsafeMutableBytes { a.snapshot(into: $0) }
        XCTAssertEqual(n, a.bins * a.levels * 2)
        var out = [[Int]](repeating: [Int](repeating: 0, count: a.levels), count: a.bins)
        for b in 0 ..< a.bins {
            for l in 0 ..< a.levels {
                let i = (b * a.levels + l) * 2
                out[b][l] = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            }
        }
        return out
    }

    private func feed(_ a: PersistenceAccumulator, _ row: [Float], times: Int = 1) {
        for _ in 0 ..< times {
            row.withUnsafeBufferPointer { a.add(row: $0) }
        }
    }

    /// A steady carrier piles up in one level bucket, while noise of the same average level
    /// spreads across several. That difference makes an intermittent signal visible on a
    /// persistence display and invisible on a live spectrum.
    func testSteadyCarrierConcentratesAndNoiseSpreads() {
        let a = acc()
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 200 {
            var row = [Float](repeating: 0, count: 8)
            for i in row.indices {
                // bin 0 is a rock-steady carrier; the rest wander over ~20 dB.
                row[i] = i == 0 ? -30 : Float(-70 + Double.random(in: -10 ... 10, using: &rng))
            }
            feed(a, row)
        }
        let h = read(a)
        let carrierOccupied = h[0].filter { $0 > 0 }.count
        let noiseOccupied = h[3].filter { $0 > 0 }.count
        XCTAssertEqual(carrierOccupied, 1, "a steady carrier belongs in one bucket, got \(h[0])")
        XCTAssertGreaterThan(noiseOccupied, 2, "noise should spread across buckets, got \(h[3])")
        XCTAssertEqual(h[0].max(), 200, "every row should have been counted")
    }

    /// A signal that stops fades out of the picture. Without decay the display would show an hour
    /// ago as though it were now, and the display would no longer show typical activity.
    func testCountsDecay() {
        let a = acc(halfLife: 10)
        feed(a, [Float](repeating: -30, count: 8), times: 10)
        let before = read(a)[0].max()!
        XCTAssertGreaterThan(before, 0)
        // Feed rows well below the carrier's bucket; the old bucket must fall away.
        feed(a, [Float](repeating: -90, count: 8), times: 60)
        let after = read(a)[0]
        let carrierBucket = Int((-30.0 - -100.0) / 100.0 * 16)
        XCTAssertLessThan(after[carrierBucket], before, "a signal that stopped must decay")
        XCTAssertGreaterThan(after.max()!, 0, "the new level is still accumulating")
    }

    /// Counts saturate rather than wrap. A count that rolled over would draw a permanently present
    /// signal as an empty cell.
    func testCountsSaturate() {
        let a = acc(bins: 1, levels: 4, halfLife: 1_000_000)
        feed(a, [-30], times: 70_000)
        let h = read(a)[0]
        XCTAssertEqual(h.max(), Int(UInt16.max), "want saturation at \(UInt16.max), got \(h)")
    }

    /// Levels outside the axis are clamped into it rather than dropped: a reader must be able to
    /// tell "pinned at the top" from "nothing here".
    func testOutOfRangeLevelsClamp() {
        let a = acc(bins: 2, levels: 4, floor: -50, range: 20)
        feed(a, [10, -200])           // far above the top, far below the floor
        let h = read(a)
        XCTAssertEqual(h[0][3], 1, "a level over the top pins to the last bucket: \(h[0])")
        XCTAssertEqual(h[1][0], 1, "a level under the floor pins to the first: \(h[1])")
    }

    /// A row whose length differs from the histogram's is folded by nearest bin, so the ladder's
    /// size and the requested resolution need not match.
    func testMismatchedRowLength() {
        let a = acc(bins: 4, levels: 8)
        feed(a, [Float](repeating: -30, count: 16))
        let h = read(a)
        for b in 0 ..< 4 {
            XCTAssertEqual(h[b].reduce(0, +), 1, "bin \(b) should have one count")
        }
        XCTAssertEqual(a.rows, 1)
    }

    /// Nearest, not floor: a mapping that truncated would draw every bin from its lower-frequency
    /// neighbour, sliding a narrow carrier down the display by up to a source bin.
    func testMismatchedRowFoldsToTheNearestBin() {
        let a = acc(bins: 3, levels: 16)
        // Four source bins into three: bin 2 sits at 2.67 source bins, so the carrier in the last
        // source bin is its nearest, and source bin 2 (quiet) is the truncated answer.
        feed(a, [-90, -90, -90, -30])
        let h = read(a)
        XCTAssertEqual(h[2][11], 1, "bin 2 must take the carrier from source bin 3: \(h[2])")
        XCTAssertEqual(h[0][1], 1)
        XCTAssertEqual(h[1][1], 1)
    }

    func testPeakTracksTheLargestCount() {
        let a = acc(bins: 2, levels: 4)
        feed(a, [-30, -90], times: 5)
        XCTAssertEqual(a.peak, 5)
    }
}
