// SPDX-License-Identifier: Apache-2.0

// A bookmark's tone spelling: the same cases go/pkg/leyline/tone_test.go holds ParseTone to, so
// both clients accept and refuse one file's tones the same way.

import XCTest

@testable import LeylineClient

final class ToneTests: XCTestCase {
    func testParseAcceptsCHIRPSpellingsAndPrintsThemBack() throws {
        let cases: [(spelling: String, tone: Tone, words: String)] = [
            ("100.0", .ctcss(hz: 100.0), "PL 100.0"),
            ("67.0", .ctcss(hz: 67.0), "PL 67.0"),
            ("254.1", .ctcss(hz: 254.1), "PL 254.1"),
            ("69.3", .ctcss(hz: 69.3), "PL 69.3"),
            ("D023N", .dcs(code: 0o023, inverted: false), "DCS 023"),
            ("D754I", .dcs(code: 0o754, inverted: true), "DCS 754 inverted"),
        ]
        for c in cases {
            let tone = try Tone.parse(c.spelling)
            XCTAssertEqual(tone, c.tone, c.spelling)
            XCTAssertEqual(tone.spelling, c.spelling, "the spelling it read")
            XCTAssertEqual(tone.words, c.words, c.spelling)
        }
    }

    func testParseRefusesEverythingElseWithTheSharedSentence() {
        let bad = [
            "100", "100.05", "100.00", "D023", "PL 100.0", "023N", "D999N", "D024N", "d023n",
            "D023X", "", " 100.0", "100.1", "D+23N", "D 23N",
        ]
        for s in bad {
            XCTAssertThrowsError(try Tone.parse(s), s) { error in
                XCTAssertEqual(
                    (error as? ToneError)?.message,
                    "tone must be a CTCSS tone such as 100.0 or a DCS code such as D023N", s)
            }
        }
    }

    func testTheCTCSSTableHasFiftyAscendingTonesThatRoundTrip() throws {
        XCTAssertEqual(Tone.ctcssTable.count, 50)
        for (a, b) in zip(Tone.ctcssTable, Tone.ctcssTable.dropFirst()) {
            XCTAssertLessThan(a, b, "ascending")
        }
        for hz in Tone.ctcssTable {
            XCTAssertEqual(try Tone.parse(Tone.ctcss(hz: hz).spelling), .ctcss(hz: hz))
        }
    }

    func testTheDCSTableHasTheHundredAndFourStandardCodes() throws {
        XCTAssertEqual(Tone.dcsCodes.count, 104)
        for (a, b) in zip(Tone.dcsCodes, Tone.dcsCodes.dropFirst()) {
            XCTAssertLessThan(a, b, "ascending")
        }
        for code in Tone.dcsCodes {
            let tone = Tone.dcs(code: code, inverted: false)
            XCTAssertEqual(try Tone.parse(tone.spelling), tone)
        }
    }
}
