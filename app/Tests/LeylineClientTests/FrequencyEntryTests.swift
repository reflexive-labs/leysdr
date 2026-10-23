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

    func testTheFieldTruncatesAndNeverRounds() {
        XCTAssertEqual(FrequencyEntry.fieldText(146_940_186), "146.9401")
        XCTAssertEqual(FrequencyEntry.fieldText(146_940_199), "146.9401")
        XCTAssertEqual(FrequencyEntry.fieldText(146_939_999), "146.9399")
        XCTAssertEqual(FrequencyEntry.fieldText(999_999_999), "999.9999")
        XCTAssertEqual(FrequencyEntry.fieldText(146_940_000), "146.9400")
    }

    func testTheFieldAtItsEdgesAndPastAGigahertz() {
        XCTAssertEqual(FrequencyEntry.fieldText(0), "0.0000")
        XCTAssertEqual(FrequencyEntry.fieldText(99), "0.0000")
        XCTAssertEqual(FrequencyEntry.fieldText(500_000), "0.5000")
        XCTAssertEqual(FrequencyEntry.fieldText(1_000_000_000), "1000.0000")
        XCTAssertEqual(FrequencyEntry.fieldText(1_296_000_150), "1296.0001")
        XCTAssertEqual(FrequencyEntry.fieldText(6_000_000_000), "6000.0000")
        XCTAssertEqual(FrequencyEntry.fieldText(UInt64.max), "18446744073709.5516")
    }

    func testExactWordsCarryEveryHertz() {
        XCTAssertEqual(FrequencyEntry.exactWords(146_940_186), "146.940186 MHz")
        XCTAssertEqual(FrequencyEntry.exactWords(146_940_199), "146.940199 MHz")
        XCTAssertEqual(FrequencyEntry.exactWords(462_612_500), "462.6125 MHz")
        XCTAssertEqual(FrequencyEntry.exactWords(146_520_000), "146.520 MHz")
        XCTAssertEqual(FrequencyEntry.exactWords(146_000_001), "146.000001 MHz")
        XCTAssertEqual(FrequencyEntry.exactWords(1_296_000_150), "1296.00015 MHz")
        XCTAssertEqual(FrequencyEntry.exactWords(530_000), "0.530 MHz")
        XCTAssertEqual(FrequencyEntry.exactWords(0), "0.000 MHz")
    }

    func testATypedFrequencyTunesExactly() {
        XCTAssertEqual(FrequencyEntry.hz(whole: "146", fraction: "940186"), 146_940_186)
        XCTAssertEqual(FrequencyEntry.hz(whole: "146", fraction: "9401"), 146_940_100)
        XCTAssertEqual(FrequencyEntry.hz(whole: "146", fraction: "94"), 146_940_000)
        XCTAssertEqual(FrequencyEntry.hz(whole: "146", fraction: ""), 146_000_000)
        XCTAssertEqual(FrequencyEntry.hz(whole: "", fraction: "5"), 500_000)
        XCTAssertEqual(FrequencyEntry.hz(whole: "1296", fraction: "00015"), 1_296_000_150)
        XCTAssertEqual(FrequencyEntry.hz(whole: "0146", fraction: "52"), 146_520_000)
    }

    func testATypedFrequencyThatIsNotOneIsRefused() {
        XCTAssertNil(FrequencyEntry.hz(whole: "-146", fraction: "94"), "a sign")
        XCTAssertNil(FrequencyEntry.hz(whole: "146", fraction: "-94"))
        XCTAssertNil(FrequencyEntry.hz(whole: "146", fraction: "9401861"), "past the hertz")
        XCTAssertNil(FrequencyEntry.hz(whole: "14a", fraction: ""))
        XCTAssertNil(FrequencyEntry.hz(whole: "", fraction: ""))
        XCTAssertNil(FrequencyEntry.hz(whole: "99999999999999999999", fraction: ""), "past UInt64")
        XCTAssertNil(FrequencyEntry.hz(whole: "18446744073709", fraction: "999999"))
    }

    func testTheTunableRange() {
        XCTAssertTrue(FrequencyEntry.tunableHz.contains(500_000))
        XCTAssertFalse(FrequencyEntry.tunableHz.contains(499_999))
        XCTAssertTrue(FrequencyEntry.tunableHz.contains(6_000_000_000))
        XCTAssertFalse(FrequencyEntry.tunableHz.contains(6_000_000_001))
    }

    func testReturnWithNoEditKeepsTheExactHertz() {
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "146", fraction: "9401", loadedHz: 146_940_186), .keep,
            "the four decimals shown are not a frequency to tune to")
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "146", fraction: "5200", loadedHz: 146_520_000), .keep)
    }

    func testReturnAfterAnEditTunesWhatWasTyped() {
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "146", fraction: "9400", loadedHz: 146_940_186),
            .tune(146_940_000), "a digit typed over the shown ones")
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "146", fraction: "940186", loadedHz: 146_520_000),
            .tune(146_940_186))
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "146", fraction: "9401", loadedHz: nil),
            .tune(146_940_100), "with no radio, what is typed")
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "146", fraction: "940186", loadedHz: 146_940_186), .keep,
            "the exact hertz typed out is where the radio is")
    }

    func testReturnOnANumberThatIsNoFrequencyIsRefused() {
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "0", fraction: "0000", loadedHz: 146_520_000), .refused)
        XCTAssertEqual(
            FrequencyEntry.commit(whole: "7000", fraction: "0000", loadedHz: nil), .refused)
    }
}
