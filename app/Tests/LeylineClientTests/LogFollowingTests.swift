// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import LeylineClient

final class LogFollowingTests: XCTestCase {
    func testItOpensFollowingAndScrollsToWhatArrives() {
        var f = LogFollowing()
        XCTAssertTrue(f.following)
        XCTAssertFalse(f.showsJump)
        XCTAssertTrue(f.arrived(2), "following, the log scrolls to new records")
        XCTAssertEqual(f.unseen, 0)
        XCTAssertFalse(f.arrived(0), "nothing arrived, nothing moves")
    }

    func testScrollingUpStopsFollowingAndCountsWhatArrives() {
        var f = LogFollowing()
        f.personScrolled(atBottom: false)
        XCTAssertFalse(f.following)
        XCTAssertTrue(f.showsJump)
        XCTAssertEqual(f.jumpWords, "Latest")
        XCTAssertFalse(f.arrived(3), "what the person reads does not move")
        XCTAssertFalse(f.arrived(1))
        XCTAssertEqual(f.unseen, 4)
        XCTAssertEqual(f.jumpWords, "4 new")
    }

    func testTheJumpButtonResumes() {
        var f = LogFollowing()
        f.personScrolled(atBottom: false)
        _ = f.arrived(5)
        f.jump()
        XCTAssertTrue(f.following)
        XCTAssertEqual(f.unseen, 0)
        XCTAssertFalse(f.showsJump)
        XCTAssertTrue(f.arrived(1))
    }

    func testScrollingBackToTheBottomByHandResumes() {
        var f = LogFollowing()
        f.personScrolled(atBottom: false)
        _ = f.arrived(2)
        f.personScrolled(atBottom: true)
        XCTAssertTrue(f.following)
        XCTAssertEqual(f.unseen, 0)
    }

    /// Content growing, rows dropping off the top and the log's own scrolls are not the person:
    /// they never stop following, and reaching the bottom resumes it.
    func testGeometryWithNoPersonOnlyResumes() {
        var f = LogFollowing()
        _ = f.arrived(1)
        f.settled(atBottom: false)
        XCTAssertTrue(f.following, "a record arriving below is not the person scrolling up")
        XCTAssertTrue(f.pending)
        f.settled(atBottom: true)
        XCTAssertFalse(f.pending)

        f.personScrolled(atBottom: false)
        _ = f.arrived(1)
        f.settled(atBottom: false)
        XCTAssertFalse(f.following, "rows dropping off the top do not resume it")
        XCTAssertEqual(f.unseen, 1)
        f.settled(atBottom: true)
        XCTAssertTrue(f.following, "a window grown to show the bottom resumes it")
        XCTAssertEqual(f.unseen, 0)
    }

    func g(_ offset: Double, _ content: Double) -> LogFollowing.Geometry {
        LogFollowing.Geometry(offset: offset, contentHeight: content, viewportHeight: 400)
    }

    /// A hand on the scroll view that moves it up stops following; content growing under it,
    /// mid-gesture too, does not; a wheel with no phase counts when nothing else changed.
    func testWhoMovedTheLog() {
        var f = LogFollowing()
        f.settled(atBottom: true)
        XCTAssertFalse(f.moved(from: g(600, 1000), to: g(600, 1022), hand: .touching))
        XCTAssertTrue(f.following, "a record landing below a hand is not the hand")
        XCTAssertTrue(f.moved(from: g(600, 1022), to: g(500, 1022), hand: .touching))
        XCTAssertFalse(f.following)
        XCTAssertTrue(f.moved(from: g(500, 1022), to: g(622, 1022), hand: .touching))
        XCTAssertTrue(f.following, "back at the bottom by hand")
        // Records land under the hand on its way down: short of the bottom, still following.
        XCTAssertFalse(f.moved(from: g(622, 1022), to: g(622, 1100), hand: .touching))
        XCTAssertFalse(f.moved(from: g(622, 1100), to: g(640, 1100), hand: .touching))
        XCTAssertTrue(f.following, "a move toward the bottom never stops following")
        f.personScrolled(atBottom: false)
        XCTAssertFalse(f.moved(from: g(300, 1100), to: g(400, 1100), hand: .touching))
        XCTAssertFalse(f.following, "down but short of the bottom does not resume")

        // A wheel's step with no phase: the offset moved up and nothing else did. A row's shift
        // as the scroll view settles under a landing record is not one.
        var w = LogFollowing()
        w.settled(atBottom: true)
        XCTAssertFalse(w.moved(from: g(600, 1000), to: g(578, 1000), hand: .none))
        XCTAssertTrue(w.following)
        XCTAssertTrue(w.moved(from: g(578, 1000), to: g(500, 1000), hand: .none))
        XCTAssertFalse(w.following)
        // While following, a scroll of the log's own to a new record is not the person.
        var o = LogFollowing()
        _ = o.arrived(1)
        XCTAssertFalse(o.moved(from: g(578, 1000), to: g(560, 1000), hand: .none))
        XCTAssertTrue(o.following)
    }

    /// The bounce back from past the bottom, with records landing, is not the person.
    func testCoastingNeverStopsFollowing() {
        var f = LogFollowing()
        f.settled(atBottom: true)
        XCTAssertFalse(f.moved(from: g(7277.5, 7954), to: g(7275.5, 7954), hand: .coasting))
        XCTAssertTrue(f.following)
        f.personScrolled(atBottom: false)
        XCTAssertTrue(f.moved(from: g(500, 1000), to: g(600, 1000), hand: .coasting))
        XCTAssertTrue(f.following, "momentum that reaches the bottom resumes")
    }

    func testAtBottomHasATolerance() {
        XCTAssertTrue(LogFollowing.atBottom(offset: 600, contentHeight: 1000, viewportHeight: 400))
        XCTAssertTrue(LogFollowing.atBottom(offset: 595, contentHeight: 1000, viewportHeight: 400))
        XCTAssertFalse(LogFollowing.atBottom(offset: 560, contentHeight: 1000, viewportHeight: 400))
        XCTAssertTrue(
            LogFollowing.atBottom(offset: 0, contentHeight: 100, viewportHeight: 400),
            "content shorter than the viewport is at the bottom")
    }

    func testArrivalsAreTheRecordsNewerThanTheNewestBefore() {
        // Newest first, as RecordLog holds them.
        XCTAssertEqual(LogFollowing.arrivals(["e", "d", "c", "b"], since: "c"), 2)
        XCTAssertEqual(
            LogFollowing.arrivals(["c", "b", "a"], since: "c"), 0, "history landed below")
        XCTAssertEqual(
            LogFollowing.arrivals(["c", "b"], since: nil), 0, "an empty log opens at the bottom")
        XCTAssertEqual(
            LogFollowing.arrivals(["z", "y"], since: "c"), 2, "the newest before is gone")
    }
}
