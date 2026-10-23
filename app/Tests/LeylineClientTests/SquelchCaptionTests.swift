// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import LeylineClient

final class SquelchCaptionTests: XCTestCase {
    private func words(_ squelch: Double, _ power: Double, open: Bool, short: Bool = false)
        -> String
    {
        SquelchCaption.words(squelchDB: squelch, powerDB: power, open: open, short: short)
    }

    func testTheLongCaptionSaysWhereTheLevelSitsAgainstTheMarker() {
        XCTAssertEqual(words(-53, -20, open: true), "open · 33 dB above the marker")
        XCTAssertEqual(words(-53, -65, open: false), "muted · 12 dB below the marker")
        XCTAssertEqual(words(.nan, -20, open: true), "open · squelch off")
        XCTAssertEqual(words(-53, .nan, open: false), "no signal measured yet")
    }

    func testTheShortCaptionKeepsTheStateAndTheNumber() {
        XCTAssertEqual(words(-53, -20, open: true, short: true), "open · 33 dB")
        XCTAssertEqual(words(-53, -65, open: false, short: true), "muted · 12 dB")
        XCTAssertEqual(words(.nan, -20, open: true, short: true), "open · off")
        XCTAssertEqual(words(-53, .nan, open: true, short: true), "no signal yet")
    }

    func testEveryShortCaptionIsShorterThanItsLongOne() {
        for (squelch, power, open) in [(-53.0, -20.0, true), (-53, -65, false), (.nan, -20, true)] {
            XCTAssertLessThan(
                words(squelch, power, open: open, short: true).count,
                words(squelch, power, open: open).count)
        }
    }
}
