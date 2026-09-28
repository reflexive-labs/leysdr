// SPDX-License-Identifier: Apache-2.0

import LeylineProto
import XCTest

@testable import LeylineClient

final class BookmarksTests: XCTestCase {
    private func tempPath() -> String {
        let dir = NSTemporaryDirectory() + "ley-bookmarks-\(UUID().uuidString)"
        return dir + "/bookmarks.json"
    }

    func testMissingFileIsEmptyAndSaveRoundTrips() throws {
        var store = BookmarkStore(path: tempPath())
        store.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        try store.load()
        XCTAssertTrue(store.list.isEmpty)

        let b = try store.add(
            name: "Local repeater", hz: 146_940_000, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertTrue(b.id.hasPrefix("bm_"))
        XCTAssertEqual(b.updatedNs, 1_700_000_000_000_000_000)
        try store.add(name: "WX1", hz: 162_550_000, mode: .nfm)
        try store.save()

        var again = BookmarkStore(path: store.path)
        try again.load()
        XCTAssertEqual(again.list.map(\.name), ["Local repeater", "WX1"], "listed by frequency")
        XCTAssertEqual(again.bookmarks[b.id]?.mode, .nfm)
        XCTAssertEqual(again.bookmarks[b.id]?.id, b.id, "the map key becomes the id")

        // The on-disk shape is the one ley bookmarks reads: a map under "bookmarks".
        let data = try Data(contentsOf: URL(fileURLWithPath: store.path))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let map = try XCTUnwrap(obj["bookmarks"] as? [String: Any])
        let entry = try XCTUnwrap(map[b.id] as? [String: Any])
        XCTAssertEqual(entry["mode"] as? String, "NFM")
        XCTAssertEqual(entry["bandwidth_hz"] as? Int, 12_500)
        XCTAssertEqual(entry["hz"] as? Int, 146_940_000)
    }

    func testAddUpdatesTheSameNameOnTheSameFrequency() throws {
        var store = BookmarkStore(path: tempPath())
        try store.load()
        let first = try store.add(name: "WX1", hz: 162_550_000, mode: .nfm)
        let second = try store.add(name: "WX1", hz: 162_550_000, mode: .am, bandwidthHz: 8_000)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.list.count, 1)
        XCTAssertEqual(store.list[0].mode, .am)
        XCTAssertThrowsError(try store.add(name: "  ", hz: 1, mode: .nfm)) {
            XCTAssertEqual($0 as? BookmarkError, .emptyName)
        }
        // A bookmark carries the mode to restore, so there is no mode to leave out; ley
        // bookmarks refuses the same call with "a bookmark needs a mode".
        XCTAssertThrowsError(try store.add(name: "No mode", hz: 1, mode: .unspecified)) {
            XCTAssertEqual($0 as? BookmarkError, .unspecifiedMode)
        }
        XCTAssertNil(store.list.first { $0.name == "No mode" })
    }

    func testUpdateKeepsTheNameAndFrequency() throws {
        var store = BookmarkStore(path: tempPath())
        store.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        try store.load()
        let a = try store.add(name: "Repeater", hz: 146_940_000, mode: .nfm, bandwidthHz: 12_500)
        store.now = { Date(timeIntervalSince1970: 1_700_000_001) }
        let b = try store.updateBookmark(a.id, mode: .am, bandwidthHz: 10_000)
        XCTAssertEqual(b.id, a.id)
        XCTAssertEqual(b.name, "Repeater")
        XCTAssertEqual(b.hz, 146_940_000)
        XCTAssertEqual(b.mode, .am)
        XCTAssertEqual(b.bandwidthHz, 10_000)
        XCTAssertEqual(b.updatedNs, 1_700_000_001_000_000_000)
        XCTAssertEqual(store.list.count, 1)
        XCTAssertThrowsError(try store.updateBookmark(a.id, mode: .unspecified, bandwidthHz: 0))
        let moved = try store.updateBookmark(a.id, hz: 146_520_000, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertEqual(moved.hz, 146_520_000, "replaced where the radio is")
        XCTAssertEqual(moved.name, "Repeater")
        XCTAssertEqual(moved.id, a.id)
    }

    func testRenameKeepsTheIdAndFrequency() throws {
        var store = BookmarkStore(path: tempPath())
        store.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        try store.load()
        let a = try store.add(name: "146.520 MHz", hz: 146_520_000, mode: .nfm, bandwidthHz: 12_500)
        store.now = { Date(timeIntervalSince1970: 1_700_000_001) }
        let renamed = try store.renameBookmark(a.id, to: "  N0TEST 2 m Simplex\n")
        XCTAssertEqual(renamed.id, a.id)
        XCTAssertEqual(renamed.name, "N0TEST 2 m Simplex", "the name is trimmed")
        XCTAssertEqual(renamed.hz, 146_520_000)
        XCTAssertEqual(renamed.mode, .nfm)
        XCTAssertEqual(renamed.bandwidthHz, 12_500)
        XCTAssertEqual(renamed.updatedNs, 1_700_000_001_000_000_000, "the stamp moves")
        XCTAssertEqual(store.list.count, 1, "renamed in place, not added beside")
        XCTAssertThrowsError(try store.renameBookmark(a.id, to: " ")) {
            XCTAssertEqual($0 as? BookmarkError, .emptyName)
        }
        XCTAssertThrowsError(try store.renameBookmark("bm_nothing", to: "X")) {
            XCTAssertEqual($0 as? BookmarkError, .noSuchBookmark("bm_nothing", candidates: []))
        }
    }

    func testRemoveByIdNameOrUniqueLooseName() throws {
        var store = BookmarkStore(path: tempPath())
        try store.load()
        let a = try store.add(name: "Tower", hz: 121_500_000, mode: .am)
        try store.add(name: "tower", hz: 118_100_000, mode: .am)
        try store.add(name: "WX1", hz: 162_550_000, mode: .nfm)

        XCTAssertEqual(try store.remove(a.id).name, "Tower")
        XCTAssertEqual(try store.remove("wx1").name, "WX1", "a loose name that matches one")
        XCTAssertEqual(try store.remove("tower").hz, 118_100_000, "an exact name wins")
        try store.add(name: "Padded", hz: 155_000_000, mode: .nfm)
        XCTAssertEqual(try store.remove("  Padded\n").name, "Padded", "the argument is trimmed")
        XCTAssertThrowsError(try store.remove("nothing")) {
            XCTAssertEqual($0 as? BookmarkError, .noSuchBookmark("nothing", candidates: []))
        }
    }

    func testMalformedFileIsAnErrorNotAnEmptyStore() throws {
        let path = tempPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        var store = BookmarkStore(path: path)
        XCTAssertThrowsError(try store.load())
    }

    // The list somebody built by hand survives a file the store cannot parse: the mutators
    // refuse until a load succeeds, so nothing writes the whole file back over it.
    func testMalformedFileIsNeverWrittenOver() throws {
        let path = tempPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let original = Data("{ \"bookmarks\": { \"bm_1\": { half of a file".utf8)
        try original.write(to: URL(fileURLWithPath: path))

        var store = BookmarkStore(path: path)
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(store.loaded)
        XCTAssertThrowsError(try store.add(name: "New", hz: 146_520_000, mode: .nfm)) {
            XCTAssertEqual($0 as? BookmarkError, .notLoaded(path))
        }
        XCTAssertThrowsError(try store.remove("New")) {
            XCTAssertEqual($0 as? BookmarkError, .notLoaded(path))
        }
        XCTAssertThrowsError(try store.save()) {
            XCTAssertEqual($0 as? BookmarkError, .notLoaded(path))
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)), original,
            "the file is byte for byte what it was")

        // Once the file reads, the store writes again.
        try Data("{\"bookmarks\":{}}".utf8).write(to: URL(fileURLWithPath: path))
        try store.load()
        XCTAssertTrue(store.loaded)
        try store.add(name: "New", hz: 146_520_000, mode: .nfm)
        try store.save()
        XCTAssertEqual(store.list.map(\.name), ["New"])
    }

    // A write that fails leaves no stray .tmp file beside the bookmarks file. Turning the
    // file into a directory after the load is the cheapest way to make the rename fail.
    func testAFailedSaveLeavesNoTempFile() throws {
        let path = tempPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("{\"bookmarks\":{}}".utf8).write(to: URL(fileURLWithPath: path))

        var store = BookmarkStore(path: path)
        try store.load()
        try store.add(name: "WX1", hz: 162_550_000, mode: .nfm)

        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(
            atPath: path + "/occupied", withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.save(), "a directory cannot be replaced by a file")

        let left = try FileManager.default.contentsOfDirectory(atPath: dir).filter {
            $0.hasSuffix(".tmp")
        }
        XCTAssertEqual(left, [], "no temp file was left behind")
    }

    // The entry every unknown-key test starts from, byte for byte the literal
    // go/pkg/bookmarks/bookmarks_test.go loads, so the two stores are held to one file: three
    // keys neither store knows (`tone` is not known until U6), beside the five it does.
    private static let foreignKeyFixture = """
        {"bookmarks": {"bm_01J8ZZZZZZZZZZZZZZZZZZZZZ1": {"name": "Local repeater", "hz": 146940000, "mode": "NFM", "bandwidth_hz": 12500, "updated_ns": 1700000000000000000, "tone": "100.0", "lists": ["x"], "zzz": {"a": 1}}}}
        """
    private static let foreignKeyID = "bm_01J8ZZZZZZZZZZZZZZZZZZZZZ1"

    private func storeOverFixture() throws -> BookmarkStore {
        let path = tempPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(Self.foreignKeyFixture.utf8).write(to: URL(fileURLWithPath: path))
        var store = BookmarkStore(path: path)
        store.now = { Date(timeIntervalSince1970: 1_700_000_001) }
        try store.load()
        return store
    }

    private func rawEntries(at path: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(obj["bookmarks"] as? [String: [String: Any]])
    }

    private func assertForeignKeysSurvive(
        _ entry: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(entry["tone"] as? String, "100.0", file: file, line: line)
        XCTAssertEqual(entry["lists"] as? [String], ["x"], file: file, line: line)
        XCTAssertEqual(entry["zzz"] as? [String: Int], ["a": 1], file: file, line: line)
    }

    func testUnknownKeysSurviveLoadAddAndSave() throws {
        var store = try storeOverFixture()
        let first = try XCTUnwrap(store.bookmarks[Self.foreignKeyID])
        XCTAssertEqual(first.name, "Local repeater")
        XCTAssertEqual(first.extra.keys.sorted(), ["lists", "tone", "zzz"])
        XCTAssertEqual(first.extra["tone"], .string("100.0"))
        XCTAssertEqual(first.extra["lists"], .array([.string("x")]))
        XCTAssertEqual(first.extra["zzz"], .object(["a": .number(1)]))

        let second = try store.add(name: "WX1", hz: 162_550_000, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertTrue(second.extra.isEmpty, "a new bookmark starts with nothing foreign")
        try store.save()

        let entries = try rawEntries(at: store.path)
        assertForeignKeysSurvive(try XCTUnwrap(entries[Self.foreignKeyID]))
        let fresh = try XCTUnwrap(entries[second.id])
        XCTAssertEqual(
            fresh.keys.sorted(), ["bandwidth_hz", "hz", "mode", "name", "updated_ns"],
            "exactly the five known keys, nothing invented")
    }

    func testUnknownKeysSurviveAddInPlace() throws {
        var store = try storeOverFixture()
        let updated = try store.add(
            name: "Local repeater", hz: 146_940_000, mode: .am, bandwidthHz: 8_000)
        XCTAssertEqual(updated.id, Self.foreignKeyID, "the same name on the same frequency")
        XCTAssertEqual(updated.mode, .am)
        try store.save()

        let entry = try XCTUnwrap(try rawEntries(at: store.path)[Self.foreignKeyID])
        XCTAssertEqual(entry["mode"] as? String, "AM")
        XCTAssertEqual(entry["bandwidth_hz"] as? Int, 8_000)
        assertForeignKeysSurvive(entry)
    }

    func testUnknownKeysSurviveUpdateAndRename() throws {
        var store = try storeOverFixture()
        try store.updateBookmark(
            Self.foreignKeyID, hz: 146_520_000, mode: .nfm, bandwidthHz: 25_000)
        try store.renameBookmark(Self.foreignKeyID, to: "Simplex")
        try store.save()

        let entry = try XCTUnwrap(try rawEntries(at: store.path)[Self.foreignKeyID])
        XCTAssertEqual(entry["name"] as? String, "Simplex")
        XCTAssertEqual(entry["hz"] as? Int, 146_520_000)
        XCTAssertEqual(entry["bandwidth_hz"] as? Int, 25_000)
        assertForeignKeysSurvive(entry)
    }

    // `tone` is foreign today and a known key after U6: the raw text is written back as the
    // string it arrived as, so the day it becomes known nothing needs migrating. The integer
    // under `zzz` comes back as `1`, not `1.0`, for the same reason.
    func testUnknownValuesAreWrittenBackAsTheyArrived() throws {
        var store = try storeOverFixture()
        try store.add(name: "WX1", hz: 162_550_000, mode: .nfm)
        try store.save()
        let text = try String(contentsOfFile: store.path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"100.0\""), "the tone stays a string: \(text)")
        XCTAssertNotNil(
            text.range(of: #""a"\s*:\s*1\s*\}"#, options: .regularExpression),
            "a whole number stays whole: \(text)")
    }

    func testJSONValueRoundTripsEveryShape() throws {
        let text = #"{"n":1,"f":1.5,"s":"x","b":true,"z":null,"l":[1,"two"],"o":{"k":false}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(
            value,
            .object([
                "n": .number(1), "f": .number(1.5), "s": .string("x"), "b": .bool(true),
                "z": .null, "l": .array([.number(1), .string("two")]),
                "o": .object(["k": .bool(false)]),
            ]))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let again = try enc.encode(value)
        XCTAssertEqual(
            String(decoding: again, as: UTF8.self),
            #"{"b":true,"f":1.5,"l":[1,"two"],"n":1,"o":{"k":false},"s":"x","z":null}"#)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: again), value)
    }

    func testNearestAndDefaultPath() throws {
        var store = BookmarkStore(path: tempPath())
        try store.load()
        try store.add(name: "A", hz: 146_520_000, mode: .nfm)
        try store.add(name: "B", hz: 146_940_000, mode: .nfm)
        XCTAssertEqual(store.nearest(to: 146_800_000)?.name, "B")
        XCTAssertEqual(
            BookmarkStore.defaultPath(environment: ["LEYLINE_BOOKMARKS": "/x/b.json"]), "/x/b.json")
        let p = BookmarkStore.defaultPath(environment: [
            "HOME": "/home/u", "XDG_DATA_HOME": "/home/u/.data",
        ])
        XCTAssertTrue(p.hasSuffix("/bookmarks.json"), p)
        XCTAssertTrue(p.contains("/home/u"), p)
    }
}
