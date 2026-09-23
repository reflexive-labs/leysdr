// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import LeylineClient

final class FrequencyEntryTests: XCTestCase {
    func testFieldAlwaysExposesTheHundredsOfHertzDigit() {
        XCTAssertEqual(FrequencyEntry.fieldParts(462_612_500).major, "462.6125")
        XCTAssertEqual(
            FrequencyEntry.fieldParts(462_612_000).major, "462.6120",
            "an off-channel three-decimal value must not look like GMRS CH3")
        XCTAssertEqual(FrequencyEntry.fieldParts(146_520_000).major, "146.5200")
    }

    func testSubHundredHertzRemainderStaysSeparate() {
        let parts = FrequencyEntry.fieldParts(462_612_534)
        XCTAssertEqual(parts.major, "462.6125")
        XCTAssertEqual(parts.minor, "34")
    }
}
