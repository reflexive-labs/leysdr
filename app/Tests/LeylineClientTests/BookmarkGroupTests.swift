// SPDX-License-Identifier: Apache-2.0

// Bookmarks that share a frequency (docs/plans/app.md, MC-5): grouped into one row in the
// file's order, and the heard tone naming the entry that is talking.

import LeylineProto
import XCTest

@testable import LeylineClient

final class BookmarkGroupTests: XCTestCase {
    private func bookmark(
        _ name: String, _ hz: UInt64, tone: String = "", mode: Leyline_V1_DemodMode = .nfm
    ) -> Bookmark {
        var b = Bookmark(id: "bm_\(name)", name: name, hz: hz, mode: mode)
        b.tone = tone
        return b
    }

    private func pl(_ hz: Double) -> SubAudibleTone {
        .ctcss(standardHz: hz, measuredHz: hz + 0.04)
    }

    // MARK: Grouping

    func testEntriesOnOneFrequencyAreOneGroupInTheFilesOrder() throws {
        // The store lists by frequency and then name; a group's entries keep the order they were
        // added in (their ids), so the repeater, added first, leads although `Club net` sorts
        // before it.
        var store = BookmarkStore(
            path: NSTemporaryDirectory() + "ley-groups-\(UUID().uuidString)/bookmarks.json")
        try store.load()
        try store.add(name: "Club repeater", hz: 146_940_000, mode: .nfm)
        try store.add(name: "Calling", hz: 146_520_000, mode: .nfm)
        try store.add(name: "Club net", hz: 146_940_000, mode: .nfm)
        try store.add(name: "Evening net", hz: 147_180_000, mode: .nfm)
        let groups = BookmarkGroup.grouped(store.list)
        XCTAssertEqual(
            groups.map { $0.entries.map(\.name) },
            [
                ["Calling"], ["Club repeater", "Club net"], ["Evening net"],
            ])
        let club = groups[1]
        XCTAssertEqual(club.lead.name, "Club repeater", "the first entry added leads")
        XCTAssertEqual(club.id, club.lead.id, "the row keeps the first entry's identity")
        XCTAssertEqual(club.hz, 146_940_000)
        XCTAssertEqual(club.others, 1)
        XCTAssertTrue(club.isMerged)
        XCTAssertEqual(club.countWords, "+1")
        XCTAssertEqual(club.words, "Club repeater +1")
        XCTAssertNil(groups[0].countWords, "a bookmark alone says no count")
        XCTAssertEqual(groups[0].words, "Calling")
        XCTAssertFalse(groups[0].isMerged)
        XCTAssertEqual(
            BookmarkGroup.at(146_940_000, in: store.list)?.lead.name, "Club repeater",
            "the tuned frequency's group leads with the same entry")
    }

    /// A CHIRP import adds its rows top to bottom, so the file's first row on a frequency leads:
    /// `fixtures/chirp/club.csv` lists the repeater before the net.
    func testACHIRPImportsFirstRowLeads() throws {
        var store = BookmarkStore(
            path: NSTemporaryDirectory() + "ley-groups-\(UUID().uuidString)/bookmarks.json")
        try store.load()
        let csv = """
            Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,Mode
            0,Club repeater,146.940000,-,0.600000,Tone,127.3,127.3,NFM
            1,Club net,146.940000,-,0.600000,Tone,100.0,100.0,NFM
            """
        _ = try CHIRP.apply(try CHIRP.parse(csv).rows, to: &store, tag: "club")
        let group = try XCTUnwrap(BookmarkGroup.at(146_940_000, in: store.list))
        XCTAssertEqual(group.entries.map(\.name), ["Club repeater", "Club net"])
        XCTAssertEqual(group.words, "Club repeater +1")
    }

    func testGroupingKeepsTheFilesOrderWhateverOrderItIsGiven() {
        let list = [
            bookmark("B", 146_940_000), bookmark("X", 146_520_000), bookmark("A", 146_940_000),
            bookmark("C", 146_940_000),
        ]
        let groups = BookmarkGroup.grouped(list)
        XCTAssertEqual(
            groups.map { $0.entries.map(\.name) }, [["A", "B", "C"], ["X"]],
            "each group where its first entry given was, its entries by id")
        XCTAssertEqual(groups[0].words, "A +2")
        XCTAssertEqual(
            BookmarkGroup(entries: [bookmark("Z", 1), bookmark("M", 1)])?.lead.name, "M")
        XCTAssertTrue(BookmarkGroup.grouped([]).isEmpty)
        XCTAssertNil(BookmarkGroup(entries: []))
    }

    /// One frequency is one channel whatever the modes: the entries in NFM and AM on one
    /// frequency are one row, and the lead's mode is the one a click tunes.
    func testDifferentModesOnOneFrequencyAreStillOneGroup() {
        let list = [
            bookmark("Club", 146_940_000, mode: .nfm), bookmark("Air", 146_940_000, mode: .am),
        ]
        let groups = BookmarkGroup.grouped(list)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.map(\.mode), [.am, .nfm])
        XCTAssertEqual(groups[0].lead.mode, .am)
    }

    func testTheGroupAtAFrequency() {
        let list = [
            bookmark("Calling", 146_520_000), bookmark("Club net", 146_940_000),
            bookmark("Club repeater", 146_940_000),
        ]
        XCTAssertEqual(
            BookmarkGroup.at(146_940_000, in: list)?.entries.map(\.name),
            ["Club net", "Club repeater"])
        XCTAssertEqual(BookmarkGroup.at(146_520_000, in: list)?.words, "Calling")
        XCTAssertNil(BookmarkGroup.at(146_525_000, in: list), "exactly, not within a channel")
    }

    // MARK: The heard tone

    func testTheHeardToneNamesTheEntryWithThatTone() throws {
        let group = try XCTUnwrap(
            BookmarkGroup(entries: [
                bookmark("Club net", 146_940_000, tone: "100.0"),
                bookmark("Club repeater", 146_940_000, tone: "127.3"),
            ]))
        XCTAssertEqual(group.speaker(heard: pl(127.3))?.name, "Club repeater")
        XCTAssertEqual(group.speaker(heard: pl(100.0))?.name, "Club net")
        XCTAssertNil(group.speaker(heard: pl(88.5)), "no entry has the heard tone")
        XCTAssertNil(group.speaker(heard: nil))
        XCTAssertEqual(group.entry(heard: pl(127.3)).name, "Club repeater")
        XCTAssertEqual(group.entry(heard: pl(88.5)).name, "Club net", "else the first entry")
        XCTAssertEqual(group.entry(heard: nil).name, "Club net")
    }

    func testTwoEntriesOnOneToneNameTheFirst() throws {
        let group = try XCTUnwrap(
            BookmarkGroup(entries: [
                bookmark("A", 146_940_000), bookmark("B", 146_940_000, tone: "100.0"),
                bookmark("C", 146_940_000, tone: "100.0"),
            ]))
        XCTAssertEqual(group.speaker(heard: pl(100.0))?.name, "B")
    }

    func testAnEntryWithNoToneOrARefusedOneMatchesNothing() {
        XCTAssertFalse(bookmark("A", 1, tone: "").toneMatches(pl(100.0)))
        XCTAssertFalse(bookmark("A", 1, tone: "100").toneMatches(pl(100.0)), "not CHIRP's spelling")
        XCTAssertFalse(bookmark("A", 1, tone: "D024N").toneMatches(.dcs(code: 24, inverted: false)))
        XCTAssertTrue(bookmark("A", 1, tone: "100.0").toneMatches(pl(100.0)))
    }

    // MARK: Matching a tone

    func testCTCSSMatchesTheStandardToneExactly() throws {
        XCTAssertTrue(try Tone.parse("127.3").matches(pl(127.3)))
        XCTAssertTrue(
            try Tone.parse("127.3").matches(.ctcss(standardHz: 127.3, measuredHz: 126.9)),
            "by the standard tone classified, not the measurement")
        XCTAssertFalse(try Tone.parse("127.3").matches(pl(123.0)), "the neighbour below")
        XCTAssertFalse(try Tone.parse("127.3").matches(pl(131.8)), "the neighbour above")
        XCTAssertFalse(try Tone.parse("100.0").matches(.dcs(code: 100, inverted: false)))
        for hz in Tone.ctcssTable {
            let tone = Tone.ctcss(hz: hz)
            XCTAssertTrue(tone.matches(pl(hz)), tone.spelling)
            XCTAssertEqual(
                Tone.ctcssTable.filter { tone.matches(pl($0)) }, [hz],
                "\(tone.spelling) matches itself alone")
        }
    }

    /// The wire carries a DCS code's octal digits as decimal (023 is 23); the polarity must
    /// agree too, and an inverted code's normal alias is a different code.
    func testDCSMatchesTheCodeAndItsPolarity() throws {
        XCTAssertTrue(try Tone.parse("D023N").matches(.dcs(code: 23, inverted: false)))
        XCTAssertTrue(try Tone.parse("D754I").matches(.dcs(code: 754, inverted: true)))
        XCTAssertFalse(try Tone.parse("D023N").matches(.dcs(code: 23, inverted: true)))
        XCTAssertFalse(try Tone.parse("D023I").matches(.dcs(code: 23, inverted: false)))
        XCTAssertFalse(
            try Tone.parse("D023N").matches(.dcs(code: 0o023, inverted: false)),
            "19, the code's value, is not the wire's 23")
        XCTAssertFalse(
            try Tone.parse("D023I").matches(.dcs(code: 47, inverted: false)),
            "D023I's alias is a different code")
        XCTAssertFalse(try Tone.parse("D023N").matches(pl(100.0)))
        for code in Tone.dcsCodes {
            let tone = Tone.dcs(code: code, inverted: false)
            let wire = Int(String(code, radix: 8)) ?? -1
            XCTAssertTrue(tone.matches(.dcs(code: wire, inverted: false)), tone.spelling)
        }
    }
}
