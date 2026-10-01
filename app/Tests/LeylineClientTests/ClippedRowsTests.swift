// SPDX-License-Identifier: Apache-2.0

// The waterfall's clipping marks on numbers (plans/app.md, M2-8): which held rows a reading
// flags, that a new row in a reused slot starts unflagged, and the floor the reading must reach.
// And the rows the time gutter's kept bars stand against: which held rows a recording's parts hold,
// on their own capture only, as runs of row age that move down as rows arrive.

import LeylineProto
import XCTest

@testable import LeylineClient

final class ClippedRowsTests: XCTestCase {
    /// Rows `0..<n`, each 1000 samples after the last, starting at `start`.
    private func rows(_ n: Int, capacity: Int = 8, start: UInt64 = 0) -> ClippedRows {
        var r = ClippedRows(capacity: capacity)
        for i in 0..<n { r.append(sampleIndex: start + UInt64(i) * 1000) }
        return r
    }

    private func flagged(_ r: ClippedRows) -> [UInt64] {
        (max(0, r.count - r.capacity)..<r.count).compactMap { row in
            let slot = row % r.capacity
            return r.flags[slot] == 1 ? r.sampleIndex[slot] : nil
        }
    }

    func testMarksTheRowsInsideTheInterval() {
        var r = rows(6)
        XCTAssertEqual(r.markClipped(from: 1500, to: 4000), 3)
        XCTAssertEqual(flagged(r), [2000, 3000, 4000])
    }

    func testAnIntervalWithNoRowsMarksNothing() {
        var r = rows(6)
        XCTAssertEqual(r.markClipped(from: 1100, to: 1900), 0)
        XCTAssertEqual(r.markClipped(from: 4000, to: 3000), 0)
        XCTAssertEqual(flagged(r), [])
    }

    func testAReusedSlotStartsUnflagged() {
        var r = rows(8)
        r.markClipped(from: 0, to: 1000)
        XCTAssertEqual(flagged(r), [0, 1000])
        // Rows 8 and 9 take slots 0 and 1; the rows that were flagged there are gone.
        r.append(sampleIndex: 8000)
        r.append(sampleIndex: 9000)
        XCTAssertEqual(flagged(r), [])
        XCTAssertEqual(r.flags, [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testOnlyHeldRowsAreCompared() {
        // Twelve rows through a ring of eight: rows 0 to 3 have been overwritten.
        var r = rows(12)
        XCTAssertEqual(r.markClipped(from: 0, to: 5000), 2)
        XCTAssertEqual(flagged(r), [4000, 5000])
    }

    func testResetClearsFlagsAndCount() {
        var r = rows(4)
        r.markClipped(from: 0, to: 3000)
        r.reset()
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.flags, [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(r.markClipped(from: 0, to: 3000), 0)
    }

    private func level(clipped: UInt64, total: UInt64) -> Leyline_V1_CaptureLevel {
        .with {
            $0.clippedSamples = clipped
            $0.totalSamples = total
        }
    }

    private func time(_ index: UInt64) -> Leyline_V1_SampleTime {
        .with { $0.sampleIndex = index }
    }

    func testAReadingAtTheFloorMarksItsInterval() {
        var r = rows(8)
        // 1 in 10 000 is the floor; the interval is the 2500 samples ending at 5000.
        XCTAssertEqual(r.mark(level(clipped: 1, total: 10_000), at: time(5000)), 6)
        var s = rows(8)
        XCTAssertEqual(s.mark(level(clipped: 1, total: 2500), at: time(5000)), 3)
        XCTAssertEqual(flagged(s), [3000, 4000, 5000])
    }

    func testAReadingUnderTheFloorMarksNothing() {
        var r = rows(8)
        XCTAssertEqual(r.mark(level(clipped: 1, total: 20_000), at: time(5000)), 0)
        XCTAssertEqual(r.mark(level(clipped: 0, total: 0), at: time(5000)), 0)
        XCTAssertEqual(flagged(r), [])
    }

    func testAnIntervalLongerThanTheClockStartsAtZero() {
        var r = rows(4)
        XCTAssertEqual(r.mark(level(clipped: 100, total: 600_000), at: time(1500)), 2)
        XCTAssertEqual(flagged(r), [0, 1000])
    }

    private func part(_ n: Int, _ from: UInt64, _ to: UInt64, capture: String? = "cap_a")
        -> RecordingPart
    {
        RecordingPart(
            part: n, file: "p\(n).wav", startSample: from, endSample: to, samples: 0, bytes: 0,
            captureID: capture)
    }

    func testPartsHoldTheRowsOnTheirCaptureAsRunsOfAge() {
        var r = ClippedRows(capacity: 8)
        // Three rows of an earlier capture on the same sample numbers, then five of this one:
        // ages 0...4 are cap_a's 4000, 3000, 2000, 1000, 0; ages 5...7 cap_old's 2000, 1000, 0.
        for i in 0..<3 { r.append(sampleIndex: UInt64(i) * 1000, captureID: "cap_old") }
        for i in 0..<5 { r.append(sampleIndex: UInt64(i) * 1000, captureID: "cap_a") }
        XCTAssertEqual(
            r.keptRuns([part(1, 1000, 2000), part(2, 3500, 9000)]), [0..<1, 2..<4],
            "cap_old's 1000 and 2000 are another time")
        XCTAssertEqual(flagged(r), [], "a kept row is not a clipped one")
        // Read again after part 2 was dropped: its bar goes.
        XCTAssertEqual(r.keptRuns([part(1, 1000, 2000)]), [2..<4])
        XCTAssertEqual(r.keptRuns([part(1, 1000, 2000, capture: nil)]), [], "no capture, no bar")
        XCTAssertEqual(r.keptRuns([part(1, 0, 9000, capture: "cap_old")]), [5..<8])
        XCTAssertEqual(r.keptRuns([part(1, 20_000, 30_000)]), [], "after every held row")
    }

    func testARunFollowsTheRingAsRowsArrive() {
        var r = ClippedRows(capacity: 4)
        XCTAssertEqual(r.keptRuns([part(1, 0, 3000)]), [], "no rows, no runs")
        for i in 0..<4 { r.append(sampleIndex: UInt64(i) * 1000, captureID: "cap_a") }
        XCTAssertEqual(r.keptRuns([part(1, 0, 1000)]), [2..<4])
        // One more row pushes the oldest out of the ring: the run moves down and shortens.
        r.append(sampleIndex: 4000, captureID: "cap_a")
        XCTAssertEqual(r.keptRuns([part(1, 0, 1000)]), [3..<4])
        r.reset()
        XCTAssertEqual(r.keptRuns([part(1, 0, 9000)]), [])
        XCTAssertEqual(r.captureID, ["", "", "", ""])
    }
}
