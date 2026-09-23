// SPDX-License-Identifier: Apache-2.0

// The audio ladder without a daemon (`AudioLevels.swift`): bands summed in power and corrected
// for the window, the ladder's scale, and the bars' ballistics. The first and last tests mirror
// `TestLevelsBandSumsInPower` and `TestLevelsBallistics` in go/internal/cli/levels_test.go, so
// the app and `ley levels` are held to the same numbers.

import XCTest

@testable import LeylineClient

final class AudioLevelsTests: XCTestCase {
    func testBandsSumInPower() {
        let binHz = 10.0
        // A hundred bins at -90 dB with a -20 dB tone at 500 Hz, as the daemon's Hann window
        // leaves it: the peak bin at the tone's level and a quarter of the power either side.
        var row = [Float](repeating: -90, count: 100)
        row[49] = -26.02
        row[50] = -20
        row[51] = -26.02
        let band = BandLevels.Band(centreHz: 500, edge: BandLevels.octaveEdge)
        // 354 to 707 Hz: the tone plus 32 bins of floor 55 dB under it. The tone's three bins
        // add to one and a half times its power, which the window correction takes back out.
        XCTAssertEqual(BandLevels.level(of: band, in: row, binHz: binHz), -20, accuracy: 0.1)

        // Two equal bins are twice the energy: 3 dB over either, less the 1.76 dB the window
        // spread them by.
        var flat = [Float](repeating: -120, count: 100)
        flat[50] = -40
        flat[51] = -40
        XCTAssertEqual(BandLevels.level(of: band, in: flat, binHz: binHz), -38.75, accuracy: 0.01)

        // A band narrower than a bin reads the bin its centre falls in, corrected.
        let third = pow(2, 1.0 / 6)
        let narrow = BandLevels.Band(centreHz: 63, edge: third)
        XCTAssertEqual(BandLevels.level(of: narrow, in: row, binHz: 40), -91.76, accuracy: 0.01)

        // Corrected like every other band, so bands too narrow to split do not step against
        // their neighbours on one floor: 63 and 100 each hold one bin of a 23 Hz row, and 80
        // borrows the nearer.
        let bands = [63.0, 80, 100].map { BandLevels.Band(centreHz: $0, edge: third) }
        for i in 1..<bands.count {
            XCTAssertEqual(
                BandLevels.level(of: bands[i - 1], in: flat, binHz: 23),
                BandLevels.level(of: bands[i], in: flat, binHz: 23), accuracy: 0.01,
                "\(bands[i - 1].label) and \(bands[i].label) step on a flat floor")
        }

        // A row with no bin spacing has no level, and the scale stops at the floor.
        XCTAssertEqual(
            BandLevels.level(of: band, in: [Float](repeating: 0, count: 8), binHz: 0),
            BandLevels.floorDB)
    }

    func testMeasureFillsTheOctavesInPlace() {
        var levels = BandLevels()
        let labels = ["63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        XCTAssertEqual(levels.bands.map(\.label), labels)
        XCTAssertEqual(levels.levelsDB, [Double](repeating: BandLevels.floorDB, count: 9))
        XCTAssertEqual(levels.bands[4].loHz, 1000 / 2.0.squareRoot(), accuracy: 1e-9)
        // A 48 kHz audio rate at 1024 bins: 23.4 Hz a bin, and a -10 dB tone at 1 kHz.
        let binHz = 24_000.0 / 1024
        var row = [Float](repeating: -100, count: 1024)
        let bin = Int((1000 / binHz).rounded())
        row[bin - 1] = -16.02
        row[bin] = -10
        row[bin + 1] = -16.02
        levels.measure(row, binHz: binHz)
        XCTAssertEqual(levels.levelsDB[4], -10, accuracy: 0.2, "the 1 kHz band reads the tone")
        XCTAssertLessThan(levels.levelsDB[8], -70, "16 kHz reads the floor")
        levels.reset()
        XCTAssertEqual(levels.levelsDB[4], BandLevels.floorDB)
    }

    func testBandLabelsAreAnEqualisers() {
        XCTAssertEqual(BandLevels.Band(centreHz: 63, edge: 2).label, "63")
        XCTAssertEqual(BandLevels.Band(centreHz: 1000, edge: 2).label, "1k")
        XCTAssertEqual(BandLevels.Band(centreHz: 1250, edge: 2).label, "1.25k")
        XCTAssertEqual(BandLevels.Band(centreHz: 16000, edge: 2).label, "16k")
    }

    func testTheScaleIsFineAboveTheKneeAndCoarseBelow() {
        XCTAssertEqual(LevelScale.fraction(0), 1)
        XCTAssertEqual(LevelScale.fraction(-60), 0)
        // Four fine steps above the knee and 3.6 coarse ones below it: the knee sits at 3.6/7.6.
        XCTAssertEqual(LevelScale.fraction(-24), 3.6 / 7.6, accuracy: 1e-9)
        XCTAssertEqual(LevelScale.fraction(-18), 4.6 / 7.6, accuracy: 1e-9)
        XCTAssertEqual(LevelScale.fraction(6), 1, "over full scale draws a full bar")
        XCTAssertEqual(LevelScale.fraction(-120), 0)
        XCTAssertEqual(LevelScale.fraction(.nan), 0)
    }

    func testBallistics() {
        let frame = 0.05
        var b = LevelBar()
        b.update(-20, elapsed: frame)
        XCTAssertEqual(b.levelDB, -20, "attack is instant")
        XCTAssertEqual(b.capDB, -20)
        // Release is 20 dB a second: a second of silence takes the bar down 20 dB.
        for _ in 0..<20 { b.update(-60, elapsed: frame) }
        XCTAssertEqual(b.levelDB, -40, accuracy: 0.01)
        XCTAssertEqual(b.capDB, -20, "a second after the peak the cap still hangs")
        // It hangs 1.5 s and then falls at 10 dB a second: another second is half a second's
        // fall below where it hung.
        for _ in 0..<20 { b.update(-60, elapsed: frame) }
        XCTAssertEqual(b.capDB, -25, accuracy: 0.01)
        // A louder row takes both up at once, wherever they were.
        b.update(-3, elapsed: frame)
        XCTAssertEqual(b.levelDB, -3)
        XCTAssertEqual(b.capDB, -3)
        b.reset()
        XCTAssertEqual(b.levelDB, BandLevels.floorDB)
        XCTAssertEqual(b.capDB, BandLevels.floorDB)
    }

    func testBallisticsRunOnTheCallersClock() {
        var b = LevelBar()
        b.update(-20, atSeconds: 100)
        b.update(-60, atSeconds: 101)
        XCTAssertEqual(b.levelDB, -40, accuracy: 1e-9, "one second of the clock, 20 dB")
        b.update(-60, atSeconds: 101)
        XCTAssertEqual(b.levelDB, -40, accuracy: 1e-9, "no time passed, no release")
        b.update(-60, atSeconds: 50)
        XCTAssertEqual(b.levelDB, -40, accuracy: 1e-9, "a clock that ran backwards is no time")
        b.update(.nan, atSeconds: 51)
        XCTAssertEqual(b.levelDB, -60, accuracy: 1e-9, "NaN is silence")
    }
}
