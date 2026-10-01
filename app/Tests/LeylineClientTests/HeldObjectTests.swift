// SPDX-License-Identifier: Apache-2.0

// The window's capture and channel between an RPC's response and the mirror's event: the RPC's
// copy stands in for the gap, an id is let go only after the mirror had it and lost it, and one
// the mirror never carries is let go after the deadline.

import Foundation
import XCTest

@testable import LeylineClient

final class HeldObjectTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let deadline: TimeInterval = 3

    func testTheResponseStandsInUntilTheEventArrives() {
        var held = HeldObject<String>()
        held.made("from the RPC", id: "chan_1", at: t0)
        XCTAssertEqual(held.current { _ in nil }, "from the RPC")
        XCTAssertEqual(
            held.observe(inMirror: false, now: t0.addingTimeInterval(0.05), dropAfter: deadline),
            .waiting, "the gap between response and event is not a deletion")
        XCTAssertEqual(
            held.observe(inMirror: true, now: t0.addingTimeInterval(0.1), dropAfter: deadline),
            .present)
        XCTAssertNil(held.pending, "the mirror's copy replaces the RPC's")
        XCTAssertEqual(held.current { _ in "from the mirror" }, "from the mirror")
    }

    func testAnObjectSeenAndThenMissingIsLost() {
        var held = HeldObject<String>()
        held.made("x", id: "cap_1", at: t0)
        _ = held.observe(inMirror: true, now: t0, dropAfter: deadline)
        XCTAssertEqual(
            held.observe(inMirror: false, now: t0.addingTimeInterval(0.1), dropAfter: deadline),
            .lost, "a tombstone is acted on at once, without the deadline")
        XCTAssertEqual(held.id, "cap_1", "the caller drops it")
    }

    func testAnObjectNeverSeenIsLetGoOnlyAfterTheDeadline() {
        var held = HeldObject<String>()
        held.made("x", id: "cap_1", at: t0)
        XCTAssertEqual(
            held.observe(inMirror: false, now: t0.addingTimeInterval(2.9), dropAfter: deadline),
            .waiting)
        XCTAssertEqual(
            held.observe(inMirror: false, now: t0.addingTimeInterval(3.1), dropAfter: deadline),
            .neverArrived)
    }

    func testADisconnectAsksTheNextSnapshotAgain() {
        var held = HeldObject<String>()
        held.made("x", id: "cap_1", at: t0)
        _ = held.observe(inMirror: true, now: t0, dropAfter: deadline)
        held.disconnected()
        XCTAssertFalse(held.seen)
        XCTAssertEqual(
            held.observe(inMirror: false, now: t0.addingTimeInterval(1), dropAfter: deadline),
            .waiting, "an object not yet seen since the reconnect is waited on")
        XCTAssertEqual(
            held.observe(inMirror: false, now: t0.addingTimeInterval(4), dropAfter: deadline),
            .neverArrived, "and let go once the deadline from when it was taken has passed")
    }

    func testAnAdoptedObjectHasNoCopyOfItsOwn() {
        var held = HeldObject<String>()
        held.adopted(id: "cap_2", at: t0)
        XCTAssertEqual(held.id, "cap_2")
        XCTAssertNil(held.current { _ in nil })
        XCTAssertEqual(held.current { $0 == "cap_2" ? "listed" : nil }, "listed")
    }

    func testDropForgetsTheIdAndTheCopy() {
        var held = HeldObject<String>()
        held.made("x", id: "chan_1", at: t0)
        _ = held.observe(inMirror: true, now: t0, dropAfter: deadline)
        held.drop()
        XCTAssertNil(held.id)
        XCTAssertNil(held.pending)
        XCTAssertFalse(held.seen)
        XCTAssertEqual(held.observe(inMirror: false, now: t0, dropAfter: deadline), .waiting)
    }
}
