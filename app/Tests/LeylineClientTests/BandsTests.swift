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

    // MARK: Plans

    private func band(_ alias: String) throws -> Band {
        try XCTUnwrap(Bands.resolve(alias), "\(alias) is not in bands.json")
    }

    func testSeedCarriesEveryAlphaPlanAndPartsAnswerThroughTheirGroup() throws {
        // The counts are the design's table (docs/design/channels.md, "The plan is data in the
        // band table"); marine is "about 100" there and entered in full in Go.
        XCTAssertEqual(try band("noaa").channels.count, 7)
        XCTAssertEqual(try band("gmrs").channels.count, 22)
        XCTAssertEqual(try band("murs").channels.count, 5)
        XCTAssertEqual(try band("cb").channels.count, 40)
        XCTAssertGreaterThanOrEqual(try band("marine").channels.count, 100)
        XCTAssertEqual(try band("2m").channels.count, 2)
        XCTAssertEqual(try band("air").channels.count, 1)
        let half = try band("gmrs-462")
        XCTAssertTrue(half.channels.isEmpty, "a part carries no plan of its own")
        XCTAssertEqual(half.plan(in: Bands.builtIn).count, 22, "its group's plan answers")
        XCTAssertEqual(try band("70cm").plan(in: Bands.builtIn).count, 0)
        let json = #"[{"name":"x","aliases":["x"],"min_hz":100,"max_hz":200,"mode":"nfm"}]"#
        let bare = try Bands.decode(Data(json.utf8))
        XCTAssertEqual(bare[0].channels, [], "a seed without the key still decodes")
        let wx3 = try XCTUnwrap(try band("noaa").channels.first { $0.name == "WX3" })
        XCTAssertEqual(wx3.id, "wx3", "the id is the plan-prefixed alias")
        XCTAssertEqual(wx3.hz, 162_475_000)
        XCTAssertEqual(wx3.decoder, "same")
        XCTAssertEqual(wx3.mode, "", "the band's mode is left to the band")
        XCTAssertEqual(wx3.bandwidthHz, 0)
    }

    func testChannelAtIsTheNearestWithinSixKilohertz() throws {
        let hit = try XCTUnwrap(Plans.channel(at: 162_475_000))
        XCTAssertEqual(hit.channel.name, "WX3")
        XCTAssertEqual(hit.band.name, "NOAA weather")
        let five = try XCTUnwrap(Plans.channel(at: 462_662_500))
        XCTAssertEqual(five.channel.name, "ch5")
        XCTAssertEqual(five.band.id, "gmrs", "a group's plan answers under the group")
        XCTAssertEqual(Plans.channel(at: 462_664_000)?.channel.name, "ch5")
        XCTAssertEqual(Plans.channel(at: 462_660_000)?.channel.name, "ch5")
        XCTAssertEqual(
            Plans.channel(at: 162_481_000)?.channel.name, "WX3", "6 kHz away is still on it")
        XCTAssertNil(
            Plans.channel(at: 162_482_000), "7 kHz from WX3 and 18 kHz from WX4 is on neither")
        XCTAssertNil(Plans.channel(at: 100_000_000, in: []))
    }

    func testEqualDistancesResolveToTheEarlierEntry() throws {
        // Marine's US variants share a frequency with the ITU entry entered after them
        // (docs/design/channels.md, "Bands are the spine of the sidebar").
        XCTAssertEqual(Plans.name(at: 157_100_000), "22A")
        let ais = try XCTUnwrap(Plans.channel(at: 161_975_000))
        XCTAssertEqual(ais.channel.name, "87B")
        XCTAssertEqual(ais.channel.decoder, "ais")
        XCTAssertEqual(Plans.name(at: 161_975_000), "87B")
    }

    func testNameAtIsTheRadioPrintedNameOrNothing() {
        XCTAssertEqual(Plans.name(at: 146_520_000), "calling")
        XCTAssertNil(Plans.name(at: 146_940_000), "a repeater output with no plan entry")
        XCTAssertEqual(Plans.name(at: 462_662_500), "ch5")
    }

    func testANameResolvesInBandContextAndAnAliasGlobally() throws {
        let marine = try band("marine")
        XCTAssertEqual(Plans.resolve("16", in: marine)?.hz, 156_800_000)
        XCTAssertEqual(Plans.resolve("06", in: marine)?.hz, 156_300_000)
        XCTAssertEqual(
            Plans.resolve("06", in: marine), Plans.resolve("6", in: marine),
            "radios print the leading zero either way")
        XCTAssertEqual(Plans.resolve("MARINE16", in: marine)?.name, "16")
        XCTAssertEqual(Plans.resolve("24 coast", in: marine)?.hz, 161_800_000)
        XCTAssertNil(Plans.resolve("99", in: marine))
        XCTAssertNil(Plans.resolve("", in: marine))
        XCTAssertEqual(
            Plans.resolve("5", in: try band("gmrs-462"))?.hz, 462_662_500,
            "a part resolves through its group's plan")
        XCTAssertNil(Plans.resolve("5", in: try band("70cm")), "no plan, no channel")
        let wx3 = try XCTUnwrap(Plans.resolveGlobal("wx3"))
        XCTAssertEqual(wx3.channel.name, "WX3")
        XCTAssertEqual(wx3.band.name, "NOAA weather")
        XCTAssertEqual(Plans.resolveGlobal("marine16")?.channel.hz, 156_800_000)
        XCTAssertEqual(
            Plans.resolveGlobal("MARINE")?.channel.hz, 156_800_000,
            "a channel may carry an alias equal to its band's; the two lookups are separate")
        XCTAssertEqual(Plans.resolveGlobal("ch5")?.band.id, "gmrs")
        XCTAssertNil(Plans.resolveGlobal("16"), "bare digits never resolve without a band")
        XCTAssertNil(Plans.resolveGlobal("nothing-here"))
    }

    func testChannelModeAndWidthFallBackToTheBands() throws {
        let murs = try band("murs")
        let one = try XCTUnwrap(murs.channels.first { $0.name == "1" })
        XCTAssertEqual(murs.bandwidth(of: one), 11_250)
        XCTAssertEqual(murs.mode(of: one), .nfm)
        let fiveMURS = try XCTUnwrap(murs.channels.first { $0.name == "5" })
        XCTAssertEqual(fiveMURS.bandwidthHz, 20_000, "MURS 4 and 5 carry their own width")
        XCTAssertEqual(murs.bandwidth(of: fiveMURS), 20_000)
        let noaa = try band("noaa")
        let wx1 = try XCTUnwrap(noaa.channels.first)
        XCTAssertEqual(noaa.mode(of: wx1), .nfm, "the band's when the channel has none")
        XCTAssertEqual(noaa.bandwidth(of: wx1), noaa.bandwidthHz)
        let twenty = try band("20m")
        if let ch = twenty.channels.first {
            XCTAssertEqual(twenty.mode(of: ch), Band.sideband(at: ch.hz))
        }
        var own = wx1
        own.mode = "am"
        XCTAssertEqual(noaa.mode(of: own), .am, "the channel's own mode wins")
    }

    func testTicksAreShortPlansInsideTheBandsOwnRange() throws {
        XCTAssertEqual(Plans.ticks(for: try band("noaa")).count, 7)
        let half = Plans.ticks(for: try band("gmrs-462"))
        XCTAssertEqual(half.count, 15, "the group's channels in the 462 MHz half only")
        XCTAssertTrue(half.allSatisfy { $0.hz <= 462_737_500 })
        XCTAssertEqual(Plans.ticks(for: try band("gmrs")).count, 22)
        XCTAssertEqual(
            Plans.ticks(for: try band("marine")), [], "a hundred ticks would read as texture")
        XCTAssertEqual(Plans.ticks(for: try band("70cm")), [])
    }
}
