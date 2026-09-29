// SPDX-License-Identifier: Apache-2.0

// The CHIRP import against the fixture both parsers are held to (fixtures/chirp/README.md):
// the same rows go/pkg/chirp/chirp_test.go asserts, and the import of sample.csv normalised
// the way its `normalise` does, compared with expected.json as decoded JSON values.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class CHIRPTests: XCTestCase {
    /// `fixtures/chirp/` at the repository root, found from this file as `DaemonHarness.fixtures`
    /// finds `fixtures/`.
    private static let fixtures: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures").appendingPathComponent("chirp")

    private func tempPath() -> String {
        NSTemporaryDirectory() + "ley-chirp-\(UUID().uuidString)/bookmarks.json"
    }

    /// A loaded store on a temp path with a held clock, so the stamps are known.
    private func openStore() throws -> BookmarkStore {
        var store = BookmarkStore(path: tempPath())
        store.now = { Date(timeIntervalSince1970: 1_758_200_000) }
        try store.load()
        return store
    }

    private func parseFixture() throws -> (rows: [CHIRP.Row], skipped: [CHIRP.Skipped]) {
        let text = try String(
            contentsOf: Self.fixtures.appendingPathComponent("sample.csv"), encoding: .utf8)
        return try CHIRP.parse(text)
    }

    /// The rule both suites apply to a bookmarks file before diffing it against expected.json:
    /// entries ordered as the store lists them, the n-th counting from 1 re-keyed `bm_<n>`,
    /// every `updated_ns` set to 0, nothing else changed (`normalise` in chirp_test.go).
    private func normalise(_ path: String) throws -> JSONValue {
        var store = BookmarkStore(path: path)
        try store.load()
        var entries: [String: JSONValue] = [:]
        for (i, listed) in store.list.enumerated() {
            var bm = listed
            bm.updatedNs = 0
            let data = try JSONEncoder().encode(bm)
            entries["bm_\(i + 1)"] = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        return .object(["bookmarks": .object(entries)])
    }

    func testTheFixtureRowsMapAsTheDesignSays() throws {
        let (rows, skipped) = try parseFixture()
        XCTAssertEqual(
            skipped, [CHIRP.Skipped(line: 9, reason: "frequency \"abc\" is not a number")])
        struct Want {
            let line: Int
            let name: String
            let hz: UInt64
            let mode: Leyline_V1_DemodMode
            let bandwidthHz: UInt32
            let tone: String
            let note: String
            let duplex: String
            let offsetHz: Int64
            let fromBand: Bool
        }
        let wants = [
            Want(
                line: 2, name: "Club", hz: 146_940_000, mode: .nfm, bandwidthHz: 25_000,
                tone: "100.0", note: "club repeater", duplex: "-", offsetHz: -600_000,
                fromBand: false),
            Want(
                line: 3, name: "Simplex", hz: 146_520_000, mode: .nfm, bandwidthHz: 12_500,
                tone: "", note: "", duplex: "", offsetHz: 0, fromBand: false),
            Want(
                line: 4, name: "Tsql", hz: 147_000_000, mode: .nfm, bandwidthHz: 25_000,
                tone: "123.0", note: "", duplex: "+", offsetHz: 600_000, fromBand: false),
            Want(
                line: 5, name: "Dcs", hz: 442_100_000, mode: .nfm, bandwidthHz: 25_000,
                tone: "D023N", note: "", duplex: "+", offsetHz: 5_000_000, fromBand: false),
            Want(
                line: 6, name: "Cross", hz: 443_500_000, mode: .nfm, bandwidthHz: 25_000,
                tone: "D754N", note: "", duplex: "+", offsetHz: 5_000_000, fromBand: false),
            Want(
                line: 7, name: "", hz: 462_662_500, mode: .nfm, bandwidthHz: 12_500, tone: "",
                note: "", duplex: "", offsetHz: 0, fromBand: false),
            Want(
                line: 8, name: "", hz: 445_925_000, mode: .nfm, bandwidthHz: 12_500, tone: "",
                note: "", duplex: "", offsetHz: 0, fromBand: false),
            Want(
                line: 10, name: "Digital", hz: 145_670_000, mode: .nfm, bandwidthHz: 12_500,
                tone: "", note: "", duplex: "", offsetHz: 0, fromBand: true),
            Want(
                line: 11, name: "Club", hz: 146_940_000, mode: .nfm, bandwidthHz: 25_000,
                tone: "100.0", note: "club repeater", duplex: "-", offsetHz: -600_000,
                fromBand: false),
        ]
        XCTAssertEqual(rows.count, wants.count)
        for (r, w) in zip(rows, wants) {
            XCTAssertEqual(r.line, w.line)
            XCTAssertEqual(r.name, w.name, "line \(w.line)")
            XCTAssertEqual(r.hz, w.hz, "line \(w.line)")
            XCTAssertEqual(r.mode, w.mode, "line \(w.line)")
            XCTAssertEqual(r.bandwidthHz, w.bandwidthHz, "line \(w.line)")
            XCTAssertEqual(r.tone, w.tone, "line \(w.line)")
            XCTAssertEqual(r.note, w.note, "line \(w.line)")
            XCTAssertEqual(r.duplex, w.duplex, "line \(w.line)")
            XCTAssertEqual(r.offsetHz, w.offsetHz, "line \(w.line)")
            XCTAssertEqual(r.modeFromBand, w.fromBand, "line \(w.line)")
            // The DV row says where its mode came from; every other row has nothing to say.
            XCTAssertEqual(r.modeFromBand, r.warnings.count == 1, "line \(w.line): \(r.warnings)")
        }
        let dv = try XCTUnwrap(rows[7].warnings.first)
        XCTAssertTrue(dv.contains("\"DV\"") && dv.contains("nfm"), dv)
        XCTAssertTrue(dv.contains("the 2 m amateur band's default"), dv)
    }

    func testTheImportOfTheFixtureEqualsExpectedJSON() throws {
        let (rows, skipped) = try parseFixture()
        var store = try openStore()
        let result = try CHIRP.apply(rows, to: &store, tag: "sample")
        XCTAssertEqual(result.added.count, 8)
        XCTAssertEqual(result.updated.count, 1)
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(result.warnings.map(\.line), [10], "the DV row's warning, and no other")
        // Apply writes nothing: the caller saves.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        try store.save()

        let got = try normalise(store.path)
        let want = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: Self.fixtures.appendingPathComponent("expected.json")))
        XCTAssertEqual(
            got, want, "the import of sample.csv is not expected.json after normalisation")

        // The names: the row's own, the plan channel's where the name is blank, else the frequency.
        var names: [UInt64: String] = [:]
        for bm in store.list { names[bm.hz] = bm.name }
        XCTAssertEqual(names[462_662_500], "ch5")
        XCTAssertEqual(names[445_925_000], "445.925 MHz")
        XCTAssertEqual(names[146_940_000], "Club")
    }

    func testASecondImportAddsNothingAndTheTagSetDoesNotGrow() throws {
        let (rows, _) = try parseFixture()
        var store = try openStore()
        _ = try CHIRP.apply(rows, to: &store, tag: "sample")
        try store.save()
        let first = try normalise(store.path)

        let again = try CHIRP.apply(rows, to: &store, tag: "sample")
        XCTAssertEqual(again.added.count, 0)
        XCTAssertEqual(again.updated.count, rows.count)
        try store.save()
        XCTAssertEqual(try normalise(store.path), first, "a second import changed the file")
        for bm in store.list {
            XCTAssertEqual(bm.tags, ["sample"], bm.name)
        }
    }

    func testABlankColumnNeverClearsATypedToneOrNote() throws {
        var store = try openStore()
        let club = try store.add(name: "Club", hz: 146_940_000, mode: .nfm)
        try store.setTone(club.id, to: "71.9")
        try store.setNote(club.id, to: "typed")
        try store.addTags(club.id, ["home"])

        var row = CHIRP.Row(line: 2, name: "Club", hz: 146_940_000, mode: .nfm, bandwidthHz: 25_000)
        let result = try CHIRP.apply([row], to: &store, tag: "sample")
        XCTAssertEqual(result.added.count, 0)
        let updated = try XCTUnwrap(result.updated.first)
        XCTAssertEqual(updated.id, club.id)
        XCTAssertEqual(updated.tone, "71.9")
        XCTAssertEqual(updated.note, "typed")
        XCTAssertEqual(updated.tags, ["home", "sample"])
        XCTAssertEqual(updated.bandwidthHz, 25_000, "the mode and width are always the row's")

        // A tone the row carries replaces the typed one: the file is what the radio has.
        row.tone = "100.0"
        XCTAssertEqual(
            try CHIRP.apply([row], to: &store, tag: "sample").updated.first?.tone, "100.0")
    }

    func testABadToneIsAWarningNotASkip() throws {
        let csv =
            "Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,RxDtcsCode,CrossMode,Mode\n"
            + "0,Odd,146.940000,-,0.600000,Tone,99.9,88.5,023,NN,023,Tone->Tone,FM\n"
            + "1,Inv,146.960000,-,0.600000,DTCS,88.5,88.5,023,RN,023,Tone->Tone,FM\n"
            + "2,None,146.980000,-,0.600000,Cross,88.5,88.5,023,NN,023,->Tone,FM\n"
        let (rows, skipped) = try CHIRP.parse(csv)
        XCTAssertEqual(skipped, [])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].tone, "")
        XCTAssertEqual(rows[0].warnings.count, 1)
        XCTAssertTrue(rows[0].warnings[0].contains("\"99.9\""), "a tone off the table is a warning")
        XCTAssertEqual(rows[1].tone, "D023I", "R in the transmit polarity is an inverted code")
        XCTAssertEqual(rows[1].warnings, [])
        XCTAssertEqual(rows[2].tone, "", "a cross mode that transmits nothing has no tone")
        XCTAssertEqual(rows[2].warnings, [])
    }

    func testColumnsAreFoundByNameAndQuotedFieldsRead() throws {
        // Another column order, a column this version does not read, CRLF line ends, a quoted
        // comment holding a comma and a doubled quote, and a blank line at the end.
        let csv =
            "Name,Mode,Frequency,Extra,Comment\r\n"
            + "A,AM,121.500000,x,\"tower, \"\"north\"\"\"\r\n"
            + "\r\n"
        let (rows, skipped) = try CHIRP.parse(csv)
        XCTAssertEqual(skipped, [])
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.line, 2)
        XCTAssertEqual(r.name, "A")
        XCTAssertEqual(r.hz, 121_500_000)
        XCTAssertEqual(r.mode, .am)
        XCTAssertEqual(r.bandwidthHz, 10_000)
        XCTAssertEqual(r.tone, "")
        XCTAssertEqual(r.note, "tower, \"north\"")
    }

    func testHeaderRulesAndABadFrequency() throws {
        XCTAssertThrowsError(try CHIRP.parse("Name,Mode\nA,FM\n")) {
            XCTAssertEqual($0 as? CHIRPError, .noFrequencyColumn)
        }
        XCTAssertThrowsError(try CHIRP.parse("")) {
            XCTAssertEqual($0 as? CHIRPError, .noFrequencyColumn, "an empty file has no header")
        }
        let (rows, skipped) = try CHIRP.parse("Location,Name,Frequency\n")
        XCTAssertEqual(rows, [], "a header with nothing under it is an empty import")
        XCTAssertEqual(skipped, [])

        let (bad, badSkipped) = try CHIRP.parse("Name,Frequency\nA,146.52\nB,abc\nC,\nD,-1\n")
        XCTAssertEqual(bad.map(\.name), ["A"])
        XCTAssertEqual(
            badSkipped,
            [
                CHIRP.Skipped(line: 3, reason: "frequency \"abc\" is not a number"),
                CHIRP.Skipped(line: 4, reason: "frequency is blank"),
                CHIRP.Skipped(line: 5, reason: "frequency \"-1\" is not above 0"),
            ])
        // A BOM on the first header cell, which a spreadsheet leaves when it re-saves the file.
        XCTAssertEqual(try CHIRP.parse("\u{FEFF}Frequency\n146.52\n").rows.map(\.hz), [146_520_000])
        XCTAssertEqual(
            CHIRP.refusalWords(file: "notes.csv"),
            "notes.csv has no Frequency column; is it a CHIRP CSV export?")
    }

    func testSummaryWords() throws {
        var store = try openStore()
        let (rows, skipped) = try parseFixture()
        var result = try CHIRP.apply(rows, to: &store, tag: "sample")
        result.skipped = skipped + result.skipped
        XCTAssertEqual(
            CHIRP.summary(result, file: "sample.csv"),
            "Imported 9 from sample.csv: 8 added, 1 updated, 1 skipped")
    }
}
