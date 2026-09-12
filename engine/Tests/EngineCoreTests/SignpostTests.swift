// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import EngineCore

/// The Instruments templates and the S1/S2 spike measurements key on these strings, so a rename is
/// a breaking change to the tooling rather than a cosmetic one.
final class SignpostTests: XCTestCase {
    func testNamesAreDistinct() {
        let names = Signpost.Name.allCases.map { $0.staticName.description }
        XCTAssertEqual(Set(names).count, names.count, "signpost names must be unique: \(names)")
    }

    func testNamesAreStable() {
        XCTAssertEqual(Set(Signpost.Name.allCases.map { $0.staticName.description }),
                       ["blockIngest", "channelProcess", "ladderPass", "ringOverrun", "demodulate",
                        "fft", "audioWrite", "frameRingWrite", "persistenceAdd", "sweepRow"])
    }
}
