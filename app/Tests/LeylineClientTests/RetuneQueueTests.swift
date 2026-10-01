// SPDX-License-Identifier: Apache-2.0

// One centre move at a time: a move asked for while one is in flight waits, the last one asked
// wins, a superseded move's offset is never written, and the queue is released only after the
// last waiting move has run.

import XCTest

@testable import LeylineClient

@MainActor
final class RetuneQueueTests: XCTestCase {
    private func move(_ centre: Int64, offset: Int64 = 0) -> RetuneQueue.Move {
        RetuneQueue.Move(centre: centre, offset: offset, captureID: "cap_1", channelID: "chan_1")
    }

    func testAMoveWithNothingInFlightStarts() {
        let q = RetuneQueue()
        XCTAssertEqual(q.request(move(100)), .start)
        XCTAssertNil(q.waiting, "a started move does not wait")
    }

    func testMovesAskedForDuringOneWaitAndTheLastWins() async {
        let q = RetuneQueue()
        var centres: [Int64] = []
        var offsets: [Int64] = []
        var handovers: [(Int64, Int64)] = []
        var answers: [RetuneQueue.Request] = []
        await q.perform(
            move(100, offset: 1),
            moveCentre: { m in
                centres.append(m.centre)
                XCTAssertEqual(q.centreInFlight, m.centre, "the centre is held while it is written")
                // Two clicks land while the first centre waits for its event.
                if m.centre == 100 {
                    answers.append(q.request(self.move(200, offset: 2)))
                    answers.append(q.request(self.move(300, offset: 3)))
                }
            },
            writeOffset: { offsets.append($0.offset) },
            onNext: { from, to in handovers.append((from.centre, to.centre)) })
        XCTAssertEqual(
            answers, [.queued(superseded: nil), .queued(superseded: move(200, offset: 2))])
        XCTAssertEqual(centres, [100, 300], "the superseded move's centre is never written")
        XCTAssertEqual(offsets, [3], "only the last move's offset is written")
        XCTAssertEqual(handovers.map(\.0), [100])
        XCTAssertEqual(handovers.map(\.1), [300])
        XCTAssertNil(q.centreInFlight, "released once nothing waits")
        XCTAssertNil(q.waiting)
    }

    func testARequestDuringTheLastMoveRunsBeforeTheQueueIsReleased() async {
        let q = RetuneQueue()
        var centres: [Int64] = []
        var offsets: [Int64] = []
        await q.perform(
            move(100, offset: 1),
            moveCentre: { m in
                centres.append(m.centre)
                if m.centre == 100 { _ = q.request(self.move(200, offset: 2)) }
                if m.centre == 200 { _ = q.request(self.move(400, offset: 4)) }
            },
            writeOffset: { offsets.append($0.offset) })
        XCTAssertEqual(centres, [100, 200, 400])
        XCTAssertEqual(offsets, [4])
        XCTAssertNil(q.centreInFlight)
    }

    func testAMoveWithNothingWaitingWritesItsOffset() async {
        let q = RetuneQueue()
        var offsets: [Int64] = []
        await q.perform(
            move(100, offset: 7), moveCentre: { _ in },
            writeOffset: {
                offsets.append($0.offset)
            })
        XCTAssertEqual(offsets, [7])
    }

    func testAHeldCentreMakesMovesWait() {
        let q = RetuneQueue()
        q.hold(centre: 100)
        XCTAssertEqual(q.request(move(200)), .queued(superseded: nil))
        XCTAssertEqual(q.waiting, move(200))
    }

    func testReleaseIfCentreLeavesANewerCentreAlone() {
        let q = RetuneQueue()
        q.hold(centre: 100)
        q.hold(centre: 200)
        q.release(ifCentre: 100)
        XCTAssertEqual(q.centreInFlight, 200, "a wait for an older centre does not release a newer")
        q.release(ifCentre: 200)
        XCTAssertNil(q.centreInFlight)
        q.hold(centre: 300)
        q.release()
        XCTAssertNil(q.centreInFlight)
    }
}
