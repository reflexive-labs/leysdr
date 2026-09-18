// SPDX-License-Identifier: Apache-2.0

// Last value per (target, parameter); distinct parameters and targets each keep their own; tags
// climb; a drain leaves nothing.

@testable import LeylineClient
import LeylineProto
import XCTest

final class PendingWritesTests: XCTestCase {
    func testLastValuePerParameterWins() {
        var p = PendingWrites()
        let t1 = p.set(.offsetHz(1000), target: "chan_1")
        let t2 = p.set(.offsetHz(2000), target: "chan_1")
        let t3 = p.set(.offsetHz(3000), target: "chan_1")
        XCTAssertLessThan(t1, t2)
        XCTAssertLessThan(t2, t3)
        XCTAssertEqual(p.count, 1)
        let out = p.drain()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].offsetHz, 3000)
        XCTAssertEqual(out[0].tag, t3)
        XCTAssertEqual(out[0].targetID, "chan_1")
        XCTAssertTrue(p.isEmpty)
    }

    func testDistinctParametersAndTargetsKeepTheirOwn() {
        var p = PendingWrites()
        p.set(.offsetHz(1000), target: "chan_1")
        p.set(.squelchDb(-60), target: "chan_1")
        p.set(.centerHz(100_000_000), target: "cap_1")
        p.set(.offsetHz(5000), target: "chan_2")
        XCTAssertEqual(p.count, 4)
        let out = p.drain()
        XCTAssertEqual(out.map(\.targetID), ["chan_1", "chan_1", "cap_1", "chan_2"], "oldest key first")
        XCTAssertEqual(out[1].squelchDb, -60)
    }

    func testEmptyParameterIsDropped() {
        var p = PendingWrites()
        var w = Leyline_V1_ParamWrite()
        w.targetID = "chan_1"
        XCTAssertNil(ParamKind(w.param))
        XCTAssertTrue(p.drain().isEmpty)
    }
}
