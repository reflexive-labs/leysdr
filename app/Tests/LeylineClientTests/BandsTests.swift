// SPDX-License-Identifier: Apache-2.0

import LeylineProto
import XCTest
@testable import LeylineClient

final class BandsTests: XCTestCase {
    func testSeedFileLoadsAndEveryBandHasAStep() {
        let bands = Bands.builtIn
        XCTAssertFalse(bands.isEmpty, "bands.json is missing from the resource bundle (make bands-json)")
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
        let hf = Band(name: "40 m amateur", aliases: ["40m"], minHz: 7_000_000, maxHz: 7_300_000, mode: "usb/lsb", bandwidthHz: 2_800, stepHz: 1_000)
        XCTAssertEqual(hf.mode(at: 7_100_000), .lsb)
        let twenty = Band(name: "20 m amateur", aliases: ["20m"], minHz: 14_000_000, maxHz: 14_350_000, mode: "usb/lsb", bandwidthHz: 2_800, stepHz: 1_000)
        XCTAssertEqual(twenty.mode(at: 14_200_000), .usb)
        XCTAssertEqual(hf.modeWord, "USB/LSB")
        let air = Band(name: "airband", aliases: ["air"], minHz: 118_000_000, maxHz: 137_000_000, mode: "am", bandwidthHz: 10_000, stepHz: 25_000)
        XCTAssertEqual(air.mode(at: 121_500_000), .am)
        XCTAssertEqual(air.fineStepHz, 2_500)
    }

    func testDefaultModeAndGroupsAreNeverAnswered() {
        let bands = [
            Band(name: "GMRS 462 MHz", aliases: ["gmrs-462"], minHz: 462_537_500, maxHz: 462_737_500, mode: "nfm", bandwidthHz: 20_000, stepHz: 12_500),
            Band(name: "GMRS", aliases: ["gmrs"], minHz: 462_537_500, maxHz: 467_737_500, mode: "nfm", bandwidthHz: 20_000, stepHz: 12_500, parts: ["gmrs-462", "gmrs-467"]),
        ]
        XCTAssertEqual(Bands.band(containing: 462_600_000, in: bands)?.name, "GMRS 462 MHz")
        XCTAssertNil(Bands.band(containing: 465_000_000, in: bands), "the gap between two parts belongs to no band")
        XCTAssertEqual(Bands.defaultMode(at: 465_000_000, in: bands), .nfm)
        XCTAssertEqual(Bands.plain.filter(\.isGroup).count, 0)
    }

    func testSampleRateIsTheSmallestThatCoversTheBand() {
        let twoM = Band(name: "2 m amateur", aliases: ["2m"], minHz: 144_000_000, maxHz: 148_000_000, mode: "nfm", bandwidthHz: 12_500, stepHz: 5_000)
        XCTAssertEqual(Bands.sampleRate(for: twoM, offered: [1_024_000, 2_400_000]), 2_400_000, "nothing covers 4 MHz, so the largest")
        let noaa = Band(name: "NOAA weather", aliases: ["noaa"], minHz: 162_400_000, maxHz: 162_550_000, mode: "nfm", bandwidthHz: 12_500, stepHz: 25_000)
        XCTAssertEqual(Bands.sampleRate(for: noaa, offered: [2_400_000, 1_024_000, 250_000]), 250_000)
        XCTAssertNil(Bands.sampleRate(for: noaa, offered: []))
    }

    func testModeWordsAndWidths() {
        XCTAssertEqual(Leyline_V1_DemodMode.named("nfm"), .nfm)
        XCTAssertEqual(Leyline_V1_DemodMode.named("usb/lsb"), nil)
        XCTAssertEqual(Leyline_V1_DemodMode.wfm.defaultBandwidthHz, 200_000)
        for m: Leyline_V1_DemodMode in [.am, .nfm, .wfm, .usb, .lsb, .cw] {
            XCTAssertEqual(m.offeredBandwidthsHz.first, m.defaultBandwidthHz, "\(m.word): the first width offered is the default")
        }
    }
}
