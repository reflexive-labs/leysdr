// SPDX-License-Identifier: Apache-2.0

import LeylineProto
import XCTest

@testable import LeylineClient

final class BandsTests: XCTestCase {
    func testSeedFileLoadsAndEveryBandHasAStep() {
        let bands = Bands.builtIn
        XCTAssertFalse(
            bands.isEmpty, "bands.json is missing from the resource bundle (make bands-json)")
        for b in bands {
            XCTAssertGreaterThan(b.stepHz, 0, "\(b.name) has no step")
            XCTAssertGreaterThan(b.maxHz, b.minHz, b.name)
            XCTAssertFalse(b.aliases.isEmpty, "\(b.name) has no alias")
        }
        XCTAssertNotNil(Bands.resolve("2m"))
        XCTAssertNotNil(Bands.resolve("2 m amateur"))
        XCTAssertEqual(Bands.resolve("2M")?.name, Bands.resolve("2m")?.name)
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let json = #"[{"name":"x","aliases":["x"],"min_hz":100,"max_hz":200,"mode":"nfm"}]"#
        let bands = try Bands.decode(Data(json.utf8))
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands[0].stepHz, 0)
        XCTAssertEqual(bands[0].fineStepHz, 100)
        XCTAssertFalse(bands[0].isGroup)
    }

    func testModeFollowsFrequencyOnHF() {
        let hf = Band(
            name: "40 m amateur", aliases: ["40m"], minHz: 7_000_000, maxHz: 7_300_000,
            mode: "usb/lsb", bandwidthHz: 2_800, stepHz: 1_000)
        XCTAssertEqual(hf.mode(at: 7_100_000), .lsb)
        let twenty = Band(
            name: "20 m amateur", aliases: ["20m"], minHz: 14_000_000, maxHz: 14_350_000,
            mode: "usb/lsb", bandwidthHz: 2_800, stepHz: 1_000)
        XCTAssertEqual(twenty.mode(at: 14_200_000), .usb)
        XCTAssertEqual(hf.modeWord, "USB/LSB")
        let air = Band(
            name: "airband", aliases: ["air"], minHz: 118_000_000, maxHz: 137_000_000, mode: "am",
            bandwidthHz: 10_000, stepHz: 25_000)
        XCTAssertEqual(air.mode(at: 121_500_000), .am)
        XCTAssertEqual(air.fineStepHz, 2_500)
    }

    func testDefaultModeAndGroupsAreNeverAnswered() {
        let bands = [
            Band(
                name: "GMRS 462 MHz", aliases: ["gmrs-462"], minHz: 462_537_500, maxHz: 462_737_500,
                mode: "nfm", bandwidthHz: 20_000, stepHz: 12_500),
            Band(
                name: "GMRS", aliases: ["gmrs"], minHz: 462_537_500, maxHz: 467_737_500,
                mode: "nfm", bandwidthHz: 20_000, stepHz: 12_500, parts: ["gmrs-462", "gmrs-467"]),
        ]
        XCTAssertEqual(Bands.band(containing: 462_600_000, in: bands)?.name, "GMRS 462 MHz")
        XCTAssertNil(
            Bands.band(containing: 465_000_000, in: bands),
            "the gap between two parts belongs to no band")
        XCTAssertEqual(Bands.defaultMode(at: 465_000_000, in: bands), .nfm)
        XCTAssertTrue(
            Bands.builtIn.contains { $0.isGroup }, "bands.json has no group, so plain drops nothing"
        )
        XCTAssertLessThan(Bands.plain.count, Bands.builtIn.count)
    }

    func testModeWordsAndWidths() {
        XCTAssertEqual(Leyline_V1_DemodMode.named("nfm"), .nfm)
        XCTAssertEqual(Leyline_V1_DemodMode.named("usb/lsb"), nil)
        XCTAssertEqual(Leyline_V1_DemodMode.wfm.defaultBandwidthHz, 200_000)
        for m: Leyline_V1_DemodMode in [.am, .nfm, .wfm, .usb, .lsb, .cw] {
            XCTAssertEqual(
                m.offeredBandwidthsHz.first, m.defaultBandwidthHz,
                "\(m.word): the first width offered is the default")
        }
    }

    func testNeighboursAreTheNearestBandsOnEitherSide() {
        let air = Band(
            name: "airband", aliases: ["air"], minHz: 118_000_000, maxHz: 137_000_000, mode: "am",
            bandwidthHz: 10_000, stepHz: 25_000)
        let twoM = Band(
            name: "2 m amateur", aliases: ["2m"], minHz: 144_000_000, maxHz: 148_000_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 5_000)
        let marine = Band(
            name: "marine VHF", aliases: ["marine"], minHz: 156_000_000, maxHz: 162_025_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 25_000)
        let group = Band(
            name: "VHF", aliases: ["vhf"], minHz: 118_000_000, maxHz: 162_025_000, mode: "nfm",
            bandwidthHz: 12_500, stepHz: 25_000, parts: ["air", "2m", "marine"])
        let bands = [marine, group, air, twoM]
        let n = Bands.neighbours(of: twoM.minHz...twoM.maxHz, in: bands)
        XCTAssertEqual(n.below?.name, "airband")
        XCTAssertEqual(n.above?.name, "marine VHF")
        let gap = Bands.neighbours(of: 150_000_000...151_000_000, in: bands)
        XCTAssertEqual(
            gap.below?.name, "2 m amateur", "a slice between two bands still has both neighbours")
        XCTAssertEqual(gap.above?.name, "marine VHF")
        XCTAssertNil(
            Bands.neighbours(of: air.minHz...air.maxHz, in: bands).below, "nothing below the lowest"
        )
        XCTAssertNil(
            Bands.neighbours(of: marine.minHz...marine.maxHz, in: bands).above,
            "nothing above the highest")
        let real = Bands.neighbours(of: 144_000_000...148_000_000)
        XCTAssertNotNil(real.below)
        XCTAssertNotNil(real.above)
        XCTAssertFalse(real.below!.isGroup)
    }

    func testSnappedLandsOnTheBandsGrid() {
        let twoM = Band(
            name: "2 m amateur", aliases: ["2m"], minHz: 144_000_000, maxHz: 148_000_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 5_000)
        XCTAssertEqual(twoM.snapped(146_521_234), 146_520_000)
        XCTAssertEqual(twoM.snapped(146_522_500), 146_525_000, "halfway rounds up")
        XCTAssertEqual(twoM.snapped(147_999_999), 148_000_000)
        XCTAssertEqual(twoM.snapped(143_000_000), 144_000_000, "below the band is its low edge")
        let gmrs = Band(
            name: "GMRS 462 MHz", aliases: ["gmrs-462"], minHz: 462_537_500, maxHz: 462_737_500,
            mode: "nfm", bandwidthHz: 20_000, stepHz: 12_500)
        XCTAssertEqual(
            gmrs.snapped(462_560_000), 462_562_500, "the grid starts at the low edge, not at zero")
        let none = Band(
            name: "x", aliases: ["x"], minHz: 100, maxHz: 200, mode: "nfm", bandwidthHz: 10,
            stepHz: 0)
        XCTAssertEqual(none.snapped(150), 150)
    }

    func testNeighboursAbutOnlyWhenTheGapIsSmall() {
        let twoM = Band(
            name: "2 m amateur", aliases: ["2m"], minHz: 144_000_000, maxHz: 148_000_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 5_000)
        let marine = Band(
            name: "marine VHF", aliases: ["marine"], minHz: 156_000_000, maxHz: 162_025_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 25_000)
        let noaa = Band(
            name: "NOAA weather", aliases: ["noaa"], minHz: 162_400_000, maxHz: 162_550_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 25_000)
        XCTAssertFalse(
            Bands.abut(twoM.minHz...twoM.maxHz, marine), "8 MHz is not next door to a 4 MHz band")
        XCTAssertTrue(Bands.abut(marine.minHz...marine.maxHz, noaa), "375 kHz is, for a 6 MHz band")
        XCTAssertFalse(Bands.abut(noaa.minHz...noaa.maxHz, marine), "and not for a 150 kHz one")
        XCTAssertTrue(Bands.abut(twoM.minHz...twoM.maxHz, twoM), "overlap is a gap of nothing")
    }

    func testBandsOutOfTheRadiosReachAreNamedSo() {
        var r820t = Leyline_V1_FrequencyRange()
        r820t.minHz = 24_000_000
        r820t.maxHz = 1_766_000_000
        let forty = Band(
            name: "40 m amateur", aliases: ["40m"], minHz: 7_000_000, maxHz: 7_300_000,
            mode: "usb/lsb", bandwidthHz: 2_800, stepHz: 1_000)
        let twoM = Band(
            name: "2 m amateur", aliases: ["2m"], minHz: 144_000_000, maxHz: 148_000_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 5_000)
        let high = Band(
            name: "x", aliases: ["x"], minHz: 2_000_000_000, maxHz: 2_100_000_000, mode: "nfm",
            bandwidthHz: 12_500, stepHz: 5_000)
        XCTAssertFalse(Bands.tunable(forty, ranges: [r820t]))
        XCTAssertTrue(Bands.tunable(twoM, ranges: [r820t]))
        XCTAssertTrue(
            Bands.tunable(forty, ranges: []), "a radio that did not say offers everything")
        XCTAssertEqual(
            Bands.outOfRangeWords(forty, ranges: [r820t]),
            "below what this radio tunes (24 – 1766 MHz)")
        XCTAssertEqual(
            Bands.outOfRangeWords(high, ranges: [r820t]),
            "above what this radio tunes (24 – 1766 MHz)")
        XCTAssertNil(Bands.outOfRangeWords(twoM, ranges: [r820t]))
        var e4kLow = Leyline_V1_FrequencyRange()
        e4kLow.minHz = 52_000_000
        e4kLow.maxHz = 1_100_000_000
        var e4kHigh = Leyline_V1_FrequencyRange()
        e4kHigh.minHz = 1_250_000_000
        e4kHigh.maxHz = 2_200_000_000
        let gap = Band(
            name: "g", aliases: ["g"], minHz: 1_150_000_000, maxHz: 1_200_000_000, mode: "nfm",
            bandwidthHz: 12_500, stepHz: 5_000)
        XCTAssertEqual(
            Bands.outOfRangeWords(gap, ranges: [e4kLow, e4kHigh]),
            "outside what this radio tunes (52 – 2200 MHz)")
        XCTAssertTrue(Bands.tunable(high, ranges: [e4kLow, e4kHigh]))
    }
}
