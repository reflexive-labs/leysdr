// SPDX-License-Identifier: Apache-2.0

// The sidebar's bookmark order (docs/plans/app.md, MC-6): by frequency with ties by name, or by
// name with ties by frequency, a merged row by its first entry.

import XCTest

@testable import LeylineClient

final class BookmarkSortTests: XCTestCase {
    private func bookmark(_ name: String, _ hz: UInt64) -> Bookmark {
        Bookmark(id: "bm_\(name)_\(hz)", name: name, hz: hz, mode: .nfm)
    }

    private func rows(_ sort: BookmarkSort, _ list: [Bookmark]) -> [String] {
        sort.sorted(BookmarkGroup.grouped(list)).map(\.words)
    }

    private var list: [Bookmark] {
        [
            bookmark("Zulu", 146_700_000), bookmark("Club net", 146_940_000),
            bookmark("Club repeater", 146_940_000), bookmark("alpha", 147_100_000),
            bookmark("Bravo", 146_520_000),
        ]
    }

    func testFrequencyIsLowToHigh() {
        XCTAssertEqual(
            rows(.frequency, list), ["Bravo", "Zulu", "Club net +1", "alpha"])
    }

    func testNameIsAToZWithoutCase() {
        XCTAssertEqual(rows(.name, list), ["alpha", "Bravo", "Club net +1", "Zulu"])
    }

    func testAMergedRowSortsByItsFirstEntry() {
        // `Club net` leads its frequency, so the row sorts as C, before `Delta`, whatever its
        // second entry's name.
        let list = [
            bookmark("Club net", 146_940_000), bookmark("Zed", 146_940_000),
            bookmark("Delta", 146_520_000),
        ]
        XCTAssertEqual(rows(.name, list), ["Club net +1", "Delta"])
        XCTAssertEqual(rows(.frequency, list), ["Delta", "Club net +1"])
    }

    func testTiesBreakByTheOtherKey() {
        // One name on two frequencies: by name, the lower frequency first.
        let sameName = [bookmark("Net", 147_000_000), bookmark("Net", 146_000_000)]
        XCTAssertEqual(
            BookmarkSort.name.sorted(BookmarkGroup.grouped(sameName)).map(\.hz),
            [146_000_000, 147_000_000])
        XCTAssertEqual(
            BookmarkSort.frequency.sorted(BookmarkGroup.grouped(sameName)).map(\.hz),
            [146_000_000, 147_000_000])
    }

    func testTheControlSwitchesBetweenTheTwo() {
        XCTAssertEqual(BookmarkSort.frequency.next, .name)
        XCTAssertEqual(BookmarkSort.name.next, .frequency)
        XCTAssertEqual(BookmarkSort.frequency.words, "Sorted by frequency")
        XCTAssertEqual(BookmarkSort(rawValue: "name"), .name)
        XCTAssertNil(BookmarkSort(rawValue: "Name"), "the defaults hold the raw value only")
    }
}
