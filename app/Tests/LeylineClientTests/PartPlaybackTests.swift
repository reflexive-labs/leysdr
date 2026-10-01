// SPDX-License-Identifier: Apache-2.0

// The window's playback of a part: it ends on its tombstone, or after the deadline when the
// mirror never listed it; Play all moves on with the live sink still detached; the sink goes back
// on after the last part only if it was on before the first.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class PartPlaybackTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let deadline: TimeInterval = 3
    private let part1 = "ley://recordings/job_1/1"
    private let part2 = "ley://recordings/job_1/2"

    /// One part started as the session starts one: replace, playing, then the RPC's answer.
    private func start(_ p: inout PartPlayback, _ uri: String, id: String, sinkAttached: Bool)
        -> String?
    {
        let old = p.replace(sinkAttached: sinkAttached)
        p.playing(uri, row: nil)
        p.started(id: id, at: t0)
        return old
    }

    func testAPlaybackListedAndThenDroppedHasEnded() {
        var p = PartPlayback()
        _ = start(&p, part1, id: "pb_1", sinkAttached: true)
        XCTAssertNil(p.observe(listed: true, now: t0, dropAfter: deadline))
        XCTAssertTrue(p.seen)
        XCTAssertEqual(
            p.observe(listed: false, now: t0.addingTimeInterval(0.25), dropAfter: deadline), "pb_1",
            "a tombstone ends it at once")
        XCTAssertEqual(p.end("pb_1"), .finished)
        XCTAssertNil(p.playingURI)
        XCTAssertNil(p.playbackID)
        XCTAssertTrue(p.takeReattach(), "the sink was attached before the part")
        XCTAssertFalse(p.takeReattach(), "asked once")
    }

    func testAPlaybackNeverListedEndsOnlyAfterTheDeadline() {
        var p = PartPlayback()
        _ = start(&p, part1, id: "pb_1", sinkAttached: false)
        XCTAssertNil(p.observe(listed: false, now: t0.addingTimeInterval(2.9), dropAfter: deadline))
        XCTAssertEqual(
            p.observe(listed: false, now: t0.addingTimeInterval(3.1), dropAfter: deadline), "pb_1")
    }

    func testPlayAllMovesOnAndKeepsTheSinkStateFromBeforeTheFirstPart() {
        var p = PartPlayback()
        p.queue = PlayQueue()
        XCTAssertEqual(p.queue.start(parts: [part1, part2]), part1)
        _ = start(&p, part1, id: "pb_1", sinkAttached: true)
        XCTAssertEqual(p.end("pb_1"), .next(part2))
        XCTAssertEqual(p.playingURI, part2, "held on the next part between the two")
        // The session starts the next part; the sink is detached by now, which must not count.
        XCTAssertNil(start(&p, part2, id: "pb_2", sinkAttached: false))
        XCTAssertEqual(p.end("pb_2"), .finished)
        XCTAssertTrue(p.takeReattach(), "the sink was attached before the first part")
    }

    func testANewPartReplacesThePlayingOneAndKeepsTheSinkState() {
        var p = PartPlayback()
        _ = start(&p, part1, id: "pb_1", sinkAttached: true)
        XCTAssertEqual(start(&p, part2, id: "pb_2", sinkAttached: false), "pb_1")
        XCTAssertNil(p.end("pb_1"), "the old playback's tombstone is not this one ending")
        XCTAssertEqual(p.playingURI, part2)
        XCTAssertEqual(p.end("pb_2"), .finished)
        XCTAssertTrue(p.takeReattach())
    }

    func testARefusedStartClearsThePartAndTheQueue() {
        var p = PartPlayback()
        _ = p.queue.start(parts: [part1, part2])
        _ = p.replace(sinkAttached: true)
        var row = Leyline_V1_SampleTime()
        row.sampleIndex = 42
        p.playing(part1, row: row)
        XCTAssertEqual(p.playingRowStart, row)
        p.failed()
        XCTAssertNil(p.playingURI)
        XCTAssertNil(p.playingRowStart)
        XCTAssertTrue(p.queue.pending.isEmpty)
        XCTAssertTrue(p.takeReattach(), "the sink is put back after a refusal too")
    }

    func testAnotherPlaybacksEndIsIgnored() {
        var p = PartPlayback()
        _ = start(&p, part1, id: "pb_1", sinkAttached: false)
        XCTAssertNil(p.end("pb_other"))
        XCTAssertEqual(p.playbackID, "pb_1")
        var idle = PartPlayback()
        XCTAssertNil(idle.observe(listed: false, now: t0, dropAfter: deadline))
    }
}
