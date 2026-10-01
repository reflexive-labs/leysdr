// SPDX-License-Identifier: Apache-2.0

import LeylineProto
import XCTest

@testable import LeylineClient

final class SidebarTests: XCTestCase {
    private func band(_ alias: String) throws -> Band {
        try XCTUnwrap(Bands.resolve(alias), "\(alias) is not in bands.json")
    }

    private func range(_ lo: UInt64, _ hi: UInt64) -> Leyline_V1_FrequencyRange {
        var r = Leyline_V1_FrequencyRange()
        r.minHz = lo
        r.maxHz = hi
        return r
    }

    /// The R820T's reach, the radio the design's newcomer owns.
    private var rtlsdr: [Leyline_V1_FrequencyRange] { [range(24_000_000, 1_766_000_000)] }

    private func bookmark(_ name: String, _ hz: UInt64) -> Bookmark {
        Bookmark(id: "bm_\(name)", name: name, hz: hz, mode: .nfm)
    }

    // MARK: The fold

    func testSidebarListsEachGroupOnceInPlaceOfItsParts() throws {
        let rows = Bands.sidebar()
        XCTAssertEqual(rows.filter { $0.id == "gmrs" }.count, 1)
        XCTAssertEqual(rows.filter { $0.id == "murs" }.count, 1)
        let parts = Set(Bands.builtIn.flatMap(\.parts))
        XCTAssertFalse(parts.isEmpty, "bands.json has no group parts")
        for row in rows {
            XCTAssertFalse(parts.contains(row.id), "\(row.name) is a part and has no row")
        }
        let groups = Bands.builtIn.filter(\.isGroup).count
        let plainNonPart = Bands.builtIn.filter { !$0.isGroup && !parts.contains($0.id) }.count
        XCTAssertEqual(rows.count, plainNonPart + groups)
        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThanOrEqual(a.minHz, b.minHz, "\(a.name) before \(b.name)")
        }
        let plainInRows = rows.filter { !$0.isGroup }.map(\.id)
        let plainInTable = Bands.plain.filter { !parts.contains($0.id) }.map(\.id)
        XCTAssertEqual(plainInRows, plainInTable, "the plain bands keep the table's order")
    }

    func testAFrequencyFilesUnderItsPartsGroupElseItsBand() {
        XCTAssertEqual(Bands.sidebarRow(for: 462_662_500)?.id, "gmrs")
        XCTAssertEqual(Bands.sidebarRow(for: 467_600_000)?.id, "gmrs", "the 467 MHz half too")
        XCTAssertEqual(Bands.sidebarRow(for: 146_520_000)?.id, "2m")
        XCTAssertNil(Bands.sidebarRow(for: 500_000_000), "no band, so the bookmark is Other")
        XCTAssertNil(Bands.sidebarRow(for: 465_000_000), "the gap between two parts is no band")
        let half = Bands.band(containing: 462_662_500)
        XCTAssertEqual(half?.id, "gmrs-462")
        XCTAssertEqual(Bands.group(of: half!)?.id, "gmrs")
        XCTAssertNil(Bands.group(of: Bands.band(containing: 146_520_000)!))
    }

    // MARK: The out-of-range line

    func testOutOfRangeBandsFoldToOneLineThatNamesTheSide() {
        let rows = Bands.sidebar()
        let below = rows.filter { !Bands.tunable($0, ranges: rtlsdr) }
        XCTAssertGreaterThan(below.count, 1, "the seed has HF bands under 24 MHz")
        XCTAssertTrue(below.allSatisfy { $0.maxHz < 24_000_000 })
        let fold = OutOfRangeFold(rows: rows, ranges: rtlsdr)
        XCTAssertEqual(fold?.bands, below)
        XCTAssertEqual(fold?.words, "\(below.count) bands below what this radio tunes")
        // AM broadcast, 160 m, 80 m, 40 m, 20 m and 15 m; CB at 26.965 MHz and 10 m are inside.
        XCTAssertEqual(below.count, 6)

        let narrow = OutOfRangeFold(rows: rows, ranges: [range(100_000_000, 200_000_000)])
        XCTAssertTrue(try XCTUnwrap(narrow).words.hasSuffix(" bands outside what this radio tunes"))
        XCTAssertTrue(narrow!.bands.contains { $0.id == "gmrs" })
        XCTAssertTrue(narrow!.bands.contains { $0.id == "am" })
        XCTAssertFalse(narrow!.bands.contains { $0.id == "2m" })

        XCTAssertNil(OutOfRangeFold(rows: rows, ranges: [range(1, 3_000_000_000)]))
        XCTAssertNil(OutOfRangeFold(rows: rows, ranges: []), "a radio that did not say offers all")

        // A floor at 1.75 MHz leaves AM broadcast (to 1.7 MHz) out and reaches 160 m at 1.8.
        let one = OutOfRangeFold(rows: rows, ranges: [range(1_750_000, 3_000_000_000)])
        XCTAssertEqual(one?.words, "1 band below what this radio tunes")
        let above = OutOfRangeFold(rows: rows, ranges: [range(1, 300_000_000)])
        XCTAssertEqual(above?.words, "\(above!.bands.count) bands above what this radio tunes")
    }

    // MARK: The filter

    func testAPlanNameFindsItsChannelFromAnyBand() throws {
        let index = SidebarIndex(bookmarks: [], tunedHz: 146_520_000, ranges: rtlsdr)
        let hits = index.matches("ch5")
        guard case .channel(let ch, let row)? = hits.first?.kind else {
            return XCTFail("the first match is a channel, got \(String(describing: hits.first))")
        }
        XCTAssertEqual(ch.name, "ch5")
        XCTAssertEqual(row.id, "gmrs")
        XCTAssertEqual(hits.first?.rowName, "GMRS")
        XCTAssertEqual(hits.first?.hz, 462_662_500)
        XCTAssertEqual(hits.first?.id, "gmrs/ch5")
        XCTAssertFalse(hits.first!.disabled)
    }

    func testTheTunedBandsMatchesComeFirstThenFrequencyOrder() {
        // Marine tuned, so its 16 leads; the rest follow the sidebar's frequency order, which
        // puts CB's 16 at 27.155 MHz before GMRS's ch16 at 462.575 MHz (docs/design/channels.md,
        // "Bands are the spine of the sidebar": "then the sidebar's frequency order").
        let index = SidebarIndex(bookmarks: [], tunedHz: 156_800_000, ranges: rtlsdr)
        // `16` is also a prefix of the 160 m band's name, and a band row comes last.
        let hits = index.matches("16")
        XCTAssertEqual(hits.map(\.label), ["16", "16", "ch16", "160 m amateur"])
        XCTAssertEqual(hits.map(\.rowName), ["marine VHF", "CB", "GMRS", "160 m amateur"])
        XCTAssertEqual(index.firstTarget("16")?.hz, 156_800_000)
        let untuned = SidebarIndex(bookmarks: [], tunedHz: nil, ranges: rtlsdr)
        XCTAssertEqual(
            untuned.matches("16").map(\.rowName), ["CB", "marine VHF", "GMRS", "160 m amateur"])
    }

    func testAMatchIsAPrefixOfANameOrAlias() {
        let index = SidebarIndex(bookmarks: [], tunedHz: nil, ranges: [])
        let five = index.matches("5").map(\.label)
        XCTAssertTrue(five.contains("5"), "\(five)")
        XCTAssertTrue(five.contains("5A"), "\(five)")
        XCTAssertTrue(five.contains("5 coast"), "\(five)")
        XCTAssertTrue(five.contains("ch5"), "GMRS ch5 carries the alias 5: \(five)")
        XCTAssertFalse(five.contains("ch15"), "a prefix, never a substring: \(five)")
        XCTAssertEqual(index.matches("zz"), [])
        XCTAssertEqual(index.matches(""), [])
        XCTAssertEqual(index.matches("   "), [])
        XCTAssertNil(index.firstTarget(""))
        let wx = index.matches("WX")
        XCTAssertEqual(
            wx.prefix(7).map(\.label), ["WX2", "WX4", "WX5", "WX3", "WX6", "WX7", "WX1"],
            "the seven channels by frequency")
        XCTAssertEqual(wx.last?.label, "NOAA weather", "the band row, by its alias wx, comes last")
        XCTAssertEqual(wx.count, 8)
        XCTAssertEqual(index.matches("wx").map(\.id), wx.map(\.id), "case does not matter")
    }

    func testABookmarkComesBeforeAChannelOnTheSameFrequency() {
        let twoM = Band(
            name: "2 m amateur", aliases: ["2m"], minHz: 144_000_000, maxHz: 148_000_000,
            mode: "nfm", bandwidthHz: 12_500, stepHz: 5_000,
            channels: [PlanChannel(name: "Clubhouse", aliases: ["2m-club"], hz: 146_940_000)])
        let index = SidebarIndex(
            bands: [twoM], bookmarks: [bookmark("Club", 146_940_000)], tunedHz: nil, ranges: [])
        let hits = index.matches("club")
        XCTAssertEqual(hits.map(\.label), ["Club", "Clubhouse"])
        guard case .bookmark(let bm, let row)? = hits.first?.kind else {
            return XCTFail("a bookmark first, got \(String(describing: hits.first))")
        }
        XCTAssertEqual(bm.name, "Club")
        XCTAssertEqual(row?.id, "2m")
        XCTAssertEqual(hits.first?.id, "bm_Club")
        XCTAssertEqual(index.firstTarget("club")?.label, "Club")
    }

    func testADisabledRowIsListedAndNeverTheReturnTarget() throws {
        let index = SidebarIndex(
            bookmarks: [bookmark("Net", 7_200_000), bookmark("Net night", 146_500_000)],
            tunedHz: nil, ranges: rtlsdr)
        let hits = index.matches("net")
        XCTAssertEqual(hits.map(\.label), ["Net", "Net night"], "by frequency, disabled included")
        XCTAssertTrue(hits[0].disabled, "40 m is below what an RTL-SDR tunes")
        XCTAssertEqual(hits[0].rowName, "40 m amateur")
        XCTAssertFalse(hits[1].disabled)
        XCTAssertEqual(
            index.firstTarget("net")?.label, "Net night", "Return skips the disabled row")
        XCTAssertTrue(try XCTUnwrap(index.matches("40m").first).disabled, "the band row too")
        XCTAssertNil(index.firstTarget("40m"))
        let other = SidebarIndex(
            bookmarks: [bookmark("Far", 2_000_000_000)], tunedHz: nil, ranges: rtlsdr)
        XCTAssertEqual(other.matches("far").first?.rowName, "Other")
        XCTAssertTrue(
            other.matches("far").first!.disabled, "Other is disabled where the radio cannot reach")
    }

    func testAChannelOutsideTheRadiosReachIsDisabledInsideAReachableGroup() throws {
        let narrow = [range(462_660_000, 462_665_000)]
        let index = SidebarIndex(bookmarks: [], tunedHz: nil, ranges: narrow)
        let hits = index.matches("ch")
        let channel5 = try XCTUnwrap(hits.first { $0.label == "ch5" })
        let channel6 = try XCTUnwrap(hits.first { $0.label == "ch6" })
        XCTAssertFalse(channel5.disabled, "the radio reaches ch5 inside the GMRS group")
        XCTAssertTrue(channel6.disabled, "the group is reachable but the radio cannot tune ch6")
        XCTAssertEqual(index.firstTarget("ch")?.label, "ch5")
    }

    func testABandQueryListsItsEntriesBeforeTheBandRow() throws {
        // Return tunes the first row and a band as a click would (docs/design/channels.md,
        // "Bands are the spine of the sidebar"); entries sort before their band row, so the
        // first target of a band's name is its lowest channel, WX2 at 162.400 MHz for NOAA.
        let index = SidebarIndex(bookmarks: [], tunedHz: nil, ranges: rtlsdr)
        let hits = index.matches("noaa")
        XCTAssertEqual(hits.count, 8, "every WX channel carries a noaaN alias, then the band")
        guard case .band(let band)? = hits.last?.kind else {
            return XCTFail("the band row last, got \(String(describing: hits.last))")
        }
        XCTAssertEqual(band.id, "noaa")
        XCTAssertEqual(hits.last?.id, "noaa")
        XCTAssertNil(hits.last?.hz, "a band row tunes as a click, not to a frequency")
        XCTAssertEqual(hits.last?.rowName, "NOAA weather")
        XCTAssertEqual(index.firstTarget("noaa")?.label, "WX2")
        XCTAssertEqual(index.firstTarget("noaa")?.hz, 162_400_000)
        let tuned = SidebarIndex(bookmarks: [], tunedHz: 162_475_000, ranges: rtlsdr)
        XCTAssertEqual(
            tuned.matches("noaa").map(\.id), hits.map(\.id),
            "tuned on NOAA the same eight lead and keep their order")
    }

    func testABookmarkFilesUnderTheTunedGroupWhenItsHalfIsTuned() {
        let index = SidebarIndex(
            bookmarks: [bookmark("Farm", 467_600_000), bookmark("Fast", 27_015_000)],
            tunedHz: 462_662_500, ranges: rtlsdr)
        XCTAssertEqual(
            index.matches("fa").map(\.label), ["Farm", "Fast"],
            "the 467 MHz bookmark leads because GMRS is the tuned row")
        XCTAssertEqual(index.matches("fa").first?.rowName, "GMRS")
    }

    // MARK: Naming

    func testANewBookmarkIsNamedAfterItsChannelElseTheFrequency() {
        XCTAssertEqual(BookmarkNaming.name(for: 462_662_500), "ch5")
        XCTAssertEqual(BookmarkNaming.name(for: 146_520_000), "calling")
        XCTAssertEqual(BookmarkNaming.name(for: 146_940_000), "146.940 MHz")
        // 500 Hz off ch5 is still on it: the one 6 kHz tolerance, which is
        // what makes a bookmark dropped a little off a channel take the channel's name.
        XCTAssertEqual(BookmarkNaming.name(for: 462_662_000), "ch5")
        XCTAssertEqual(BookmarkNaming.name(for: 445_925_000), "445.925 MHz", "70 cm has no plan")
        XCTAssertEqual(BookmarkNaming.name(for: 462_662_500, in: []), "462.6625 MHz")
        XCTAssertEqual(BookmarkNaming.frequencyWords(88_500_000), "88.500 MHz")
        XCTAssertEqual(BookmarkNaming.frequencyWords(1_766_000_000), "1.766 GHz")
        XCTAssertEqual(BookmarkNaming.frequencyWords(530_000), "530.0 kHz")
        XCTAssertEqual(BookmarkNaming.frequencyWords(500), "500 Hz")
    }
}
