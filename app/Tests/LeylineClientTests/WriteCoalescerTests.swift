// SPDX-License-Identifier: Apache-2.0

// The coalescer records a write before its setter returns, so the order a caller writes in is the
// order the last value is chosen in, with no `await` between writes. The stream here is a fake
// that keeps what would have been sent.

import LeylineProto
import Synchronization
import XCTest

@testable import LeylineClient

final class WriteCoalescerTests: XCTestCase {
    /// What the fake stream was sent, and how many times it was opened.
    final class Sent: Sendable {
        let writes = Mutex<[Leyline_V1_ParamWrite]>([])
        let opens = Mutex(0)

        var all: [Leyline_V1_ParamWrite] { writes.withLock { $0 } }
        func offsets(of target: String) -> [Int64] {
            all.filter { $0.targetID == target }.map(\.offsetHz)
        }
    }

    private func coalescer(_ sent: Sent, tick: Duration = .milliseconds(5)) -> WriteCoalescer {
        WriteCoalescer(tick: tick) { body in
            sent.opens.withLock { $0 += 1 }
            try await body { write in sent.writes.withLock { $0.append(write) } }
            return Leyline_V1_WriteSummary()
        }
    }

    func testRapidSynchronousWritesEndOnTheLastOneAsked() async {
        let sent = Sent()
        let writes = coalescer(sent)
        for hz in 1...1000 { writes.offsetHz(Int64(hz), channel: "chan_1") }
        await writes.stop()
        let offsets = sent.offsets(of: "chan_1")
        XCTAssertEqual(offsets.last, 1000)
        XCTAssertEqual(
            offsets, offsets.sorted(), "a flush never sends an older value after a newer")
        XCTAssertLessThan(offsets.count, 1000, "writes in one tick are coalesced")
    }

    func testCentreThenOffsetInOneTickAreSentInThatOrder() async {
        let sent = Sent()
        let writes = coalescer(sent, tick: .milliseconds(50))
        writes.centerHz(146_000_000, capture: "cap_1")
        writes.offsetHz(520_000, channel: "chan_1")
        await writes.stop()
        XCTAssertEqual(sent.all.map(\.targetID), ["cap_1", "chan_1"])
    }

    func testEachTaskKeepsItsOwnOrderUnderConcurrentWrites() async {
        let sent = Sent()
        let writes = coalescer(sent, tick: .milliseconds(1))
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for hz in 0..<500 { writes.offsetHz(Int64(hz), channel: "chan_\(t)") }
                }
            }
        }
        await writes.stop()
        for t in 0..<8 {
            let offsets = sent.offsets(of: "chan_\(t)")
            XCTAssertEqual(offsets.last, 499, "chan_\(t) ends on its last write")
            XCTAssertEqual(offsets, offsets.sorted(), "chan_\(t) is never sent out of order")
            let tags = sent.all.filter { $0.targetID == "chan_\(t)" }.map(\.tag)
            XCTAssertEqual(tags, tags.sorted(), "tags climb in the order chan_\(t) was written")
        }
    }

    func testTagsClimbInCallOrder() async {
        let sent = Sent()
        let writes = coalescer(sent)
        let a = writes.offsetHz(1, channel: "chan_1")
        let b = writes.squelchDb(-60, channel: "chan_1")
        let c = writes.offsetHz(2, channel: "chan_1")
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        await writes.stop()
    }

    func testAWriteAfterStopOpensANewStream() async {
        let sent = Sent()
        let writes = coalescer(sent)
        writes.offsetHz(1, channel: "chan_1")
        await writes.stop()
        writes.offsetHz(2, channel: "chan_1")
        await writes.stop()
        XCTAssertEqual(sent.opens.withLock { $0 }, 2)
        XCTAssertEqual(sent.offsets(of: "chan_1"), [1, 2])
    }
}
