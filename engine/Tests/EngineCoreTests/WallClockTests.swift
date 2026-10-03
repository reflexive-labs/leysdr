// SPDX-License-Identifier: GPL-3.0-or-later

@testable import EngineCore
import Foundation
import XCTest

final class WallClockTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testParseClockTime() throws {
        XCTAssertTrue(try WallClock.parseClockTime("19:42") == (19, 42))
        XCTAssertTrue(try WallClock.parseClockTime("00:00") == (0, 0))
        XCTAssertTrue(try WallClock.parseClockTime("23:59") == (23, 59))
        for bad in ["24:00", "12:60", "7:42", "19:4", "1942", "19:42:00", "", ":", "ab:cd", "-1:30", "+1:30", "١٩:٤٢"] {
            XCTAssertThrowsError(try WallClock.parseClockTime(bad), bad) {
                XCTAssertEqual(($0 as? EngineError)?.code, EngineError.Code.invalidArgument, bad)
                XCTAssertTrue(($0 as? EngineError)?.message.hasSuffix("Pass a time such as --wall-clock 19:42") ?? false, bad)
            }
        }
    }

    func testOffsetToAnEarlierTimeToday() {
        // 2026-10-03 22:15:30 UTC -> 19:42:00 the same day is 2 h 33 m 30 s earlier.
        let now = Date(timeIntervalSince1970: 1_791_065_730)
        let want: Int64 = -((2 * 3600 + 33 * 60 + 30) * 1_000_000_000)
        XCTAssertEqual(WallClock.offsetNs(toHour: 19, minute: 42, now: now, timeZone: utc), want)
    }

    func testOffsetToALaterTimeTodayAndInAnotherZone() {
        // 2026-10-03 06:00:00 UTC.
        let now = Date(timeIntervalSince1970: 1_791_007_200)
        XCTAssertEqual(WallClock.offsetNs(toHour: 19, minute: 42, now: now, timeZone: utc), (13 * 3600 + 42 * 60) * 1_000_000_000)
        // The same instant is 23:00 the previous day in Los Angeles (UTC-7 in October), so 19:42
        // there is 3 h 18 m earlier.
        let la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(WallClock.offsetNs(toHour: 19, minute: 42, now: now, timeZone: la), -(3 * 3600 + 18 * 60) * 1_000_000_000)
    }

    func testNowNsAddsTheOffset() {
        WallClock.setOffsetNs(5_000_000_000)
        defer { WallClock.setOffsetNs(0) }
        let real = WallClock.realNowNs()
        let shifted = WallClock.nowNs()
        XCTAssertGreaterThanOrEqual(shifted - real, 5_000_000_000)
        XCTAssertLessThan(shifted - real, 6_000_000_000)
    }
}
