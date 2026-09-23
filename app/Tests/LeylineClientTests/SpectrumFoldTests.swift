// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import LeylineClient

final class SpectrumFoldTests: XCTestCase {
    /// A flat floor at -100 with two carriers, one twice as wide as its neighbour's shoulders.
    private func row(bins: Int = 256, floor: Float = -100) -> [Float] {
        var r = [Float](repeating: floor, count: bins)
        r[64] = -60  // a carrier
        r[63] = -70
        r[65] = -70  // its shoulders
        r[200] = -40  // the strongest
        r[201] = -40  // a run of equal bins counts once
        r[10] = -90  // 10 dB up: noise, not a peak
        return r
    }

    func testMedianIsTheFloor() {
        XCTAssertEqual(SpectrumFold.medianDB(row()), -100)
        XCTAssertTrue(SpectrumFold.medianDB([]).isNaN)
    }

    func testLoudestBinsMatchesLeySpectrum() {
        let r = row()
        let peaks = SpectrumFold.loudestBins(
            r, centerHz: 146_000_000, spanHz: 2_560_000, n: 5,
            minDB: -100 + SpectrumFold.peakAboveFloorDB)
        XCTAssertEqual(
            peaks.map(\.db), [-40, -60], "loudest first; shoulders and the noise bump are dropped")
        // bin 200 of 256 over 2.56 MHz: left edge 144.72 MHz, 10 kHz bins, centre of the bin.
        XCTAssertEqual(peaks[0].centerHz, 144_720_000 + 2_005_000)
        XCTAssertEqual(SpectrumFold.strongest(r, centerHz: 146_000_000, spanHz: 2_560_000)?.db, -40)
        XCTAssertNil(
            SpectrumFold.strongest([Float](repeating: -100, count: 64), centerHz: 1, spanHz: 64),
            "a flat row has no peak")
    }

    func testPeaksCloserThanTheGapMergeIntoTheLouder() {
        var r = [Float](repeating: -100, count: 128)
        r[50] = -30
        r[52] = -35  // two bins away: inside three bins, a shoulder
        r[90] = -50
        let peaks = SpectrumFold.loudestBins(r, centerHz: 0, spanHz: 128_000, n: 5, minDB: -85)
        XCTAssertEqual(peaks.map(\.db), [-30, -50])
    }

    func testAutoSquelchIsTenDBAboveTheScaledFloor() {
        // 2048 bins over 2.4 MSPS: 1171.875 Hz bins; a 12.5 kHz channel holds 10.67 of them,
        // 10.28 dB more noise than one bin. Floor -100 + 10.28 = -89.72; threshold -79.72 → -80.
        let r = [Float](repeating: -100, count: 2048)
        let (t, f) = SpectrumFold.autoSquelch(r, sampleRate: 2_400_000, bandwidthHz: 12_500)
        XCTAssertEqual(f, -89.72, accuracy: 0.01)
        XCTAssertEqual(t, -80)
        XCTAssertTrue(
            SpectrumFold.autoSquelch([], sampleRate: 2_400_000, bandwidthHz: 12_500).thresholdDB
                .isNaN)
    }

    func testMaxHoldKeepsTheLoudestAndResetsOnShape() {
        var hold = MaxHold()
        hold.fold([-100, -50, -100])
        hold.fold([-90, -60, -100])
        XCTAssertEqual(hold.levelsDB, [-90, -50, -100])
        XCTAssertEqual(hold.rows, 2)
        hold.fold([-10, -10])
        XCTAssertEqual(hold.levelsDB, [-10, -10], "a new bin count starts over")
        XCTAssertEqual(hold.rows, 1)
        hold.reset()
        XCTAssertTrue(hold.levelsDB.isEmpty)
        XCTAssertEqual(hold.rows, 0)
        hold.fold([-80, -70])
        XCTAssertEqual(hold.levelsDB, [-80, -70], "the first row after clear is the new hold")
        XCTAssertEqual(hold.rows, 1)
    }

    func testChannelFloorScalesTheBinFloorToTheWidth() {
        // 2.4 MS/s over 2048 bins is 1171.875 Hz a bin; a 12.5 kHz channel holds 10.67 of them.
        let floor = SpectrumFold.channelFloorDB(
            binFloorDB: -64, bins: 2048, sampleRate: 2_400_000, bandwidthHz: 12_500)
        XCTAssertEqual(floor, -64 + 10 * log10(12_500 / 1171.875), accuracy: 1e-9)
        XCTAssertTrue(
            SpectrumFold.channelFloorDB(
                binFloorDB: .nan, bins: 2048, sampleRate: 2_400_000, bandwidthHz: 12_500
            ).isNaN)
        XCTAssertTrue(
            SpectrumFold.channelFloorDB(
                binFloorDB: -64, bins: 0, sampleRate: 2_400_000, bandwidthHz: 12_500
            ).isNaN)
        // The auto squelch is the same floor plus 10, rounded.
        let bins = [Float](repeating: -64, count: 2048)
        let (threshold, f) = SpectrumFold.autoSquelch(
            bins, sampleRate: 2_400_000, bandwidthHz: 12_500)
        XCTAssertEqual(f, floor, accuracy: 1e-9)
        XCTAssertEqual(threshold, (floor + 10).rounded())
    }

    /// 2.4 MS/s, rows 1/30 s apart, as the feed folds them.
    private let rate: UInt64 = 2_400_000
    private func fold(_ f: inout HeldFloor, _ median: Float, seconds: Double) -> Float {
        f.fold(medianDB: median, atSample: UInt64(seconds * Double(rate)), sampleRate: rate)
    }

    func testHeldFloorFallsAtOnce() {
        var f = HeldFloor()
        XCTAssertEqual(fold(&f, -80.4, seconds: 0), -80, "the first median is taken at once")
        XCTAssertEqual(fold(&f, -83, seconds: 0.1), -80, "inside the slack")
        XCTAssertEqual(fold(&f, -86, seconds: 0.2), -86, "more than 4 dB under: at once")
    }

    func testHeldFloorIgnoresAThreeSecondRise() {
        var f = HeldFloor()
        _ = fold(&f, -80, seconds: 0)
        // A keyed handheld clipping the radio lifts the median 10 dB for three seconds.
        for i in 1...90 { XCTAssertEqual(fold(&f, -70, seconds: Double(i) / 30), -80) }
        XCTAssertEqual(fold(&f, -80, seconds: 3.1), -80)
        // A second over after a pause is timed from its own start, not the first one's.
        for i in 0..<120 { XCTAssertEqual(fold(&f, -70, seconds: 4 + Double(i) / 30), -80) }
    }

    func testHeldFloorFollowsASixSecondRise() {
        var f = HeldFloor()
        _ = fold(&f, -80, seconds: 0)
        var floor = f.floorDB
        for i in 1...180 {
            floor = fold(&f, -70.2, seconds: 1 + Double(i) / 30)
            if Double(i) / 30 < 5 { XCTAssertEqual(floor, -80, "held at \(Double(i) / 30) s") }
        }
        XCTAssertEqual(floor, -70, "risen after 5 s over the slack")
    }

    func testHeldFloorDoesNotRiseWithoutARate() {
        var f = HeldFloor()
        _ = f.fold(medianDB: -80, atSample: 0, sampleRate: 0)
        XCTAssertEqual(f.fold(medianDB: -60, atSample: 100_000_000, sampleRate: 0), -80)
        XCTAssertEqual(f.fold(medianDB: -90, atSample: 0, sampleRate: 0), -90, "it still falls")
        XCTAssertEqual(f.fold(medianDB: .nan, atSample: 0, sampleRate: rate), -90)
    }

    func testHeldFloorResetRetakesAtOnce() {
        var f = HeldFloor()
        _ = fold(&f, -80, seconds: 0)
        _ = fold(&f, -70, seconds: 1)
        f.reset()
        XCTAssertTrue(f.floorDB.isNaN)
        XCTAssertEqual(fold(&f, -70, seconds: 1.1), -70, "a gain move or retune re-takes it")
    }

    func testLevelWordsPrintWholeDBAndTheMarginOverTheFloor() {
        XCTAssertEqual(
            SpectrumFold.levelWords(levelDB: -52.3, floorDB: -78.2),
            "\u{2212}52 dBFS · 26 dB over the floor")
        XCTAssertEqual(
            SpectrumFold.levelWords(levelDB: -81.4, floorDB: -78),
            "\u{2212}81 dBFS · \u{2212}3 dB over the floor", "under the floor, no plus above it")
        XCTAssertEqual(
            SpectrumFold.levelWords(levelDB: -52.6, floorDB: -78.4),
            "\u{2212}53 dBFS · 25 dB over the floor", "the margin of the two rounded numbers")
        XCTAssertEqual(
            SpectrumFold.levelWords(levelDB: -0.3, floorDB: -0.2),
            "0 dBFS · 0 dB over the floor", "no negative zero")
    }

    func testLevelWordsAreDashesWithoutALevelOrAFloor() {
        let dashes = "— dBFS · — dB over the floor"
        XCTAssertEqual(SpectrumFold.levelWords(levelDB: -52, floorDB: .nan), dashes)
        XCTAssertEqual(SpectrumFold.levelWords(levelDB: -.infinity, floorDB: -78), dashes)
        XCTAssertEqual(SpectrumFold.levelWords(levelDB: .nan, floorDB: -78), dashes)
    }
}
