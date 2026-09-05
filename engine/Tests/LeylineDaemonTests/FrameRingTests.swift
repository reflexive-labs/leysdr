import Foundation
import XCTest
@testable import LeylineDaemon

/// FrameRing is latest-wins: a full ring evicts the oldest frame and the writer-side seq exposes the gap.
final class FrameRingTests: XCTestCase {
    private func push(_ ring: FrameRing, _ i: Int) {
        ring.write(sampleStart: UInt64(i * 100), sampleCount: 100) { p in
            p.storeBytes(of: UInt8(i), as: UInt8.self)
            return 1
        }
    }

    func testFullRingDropsOldestAndSeqShowsGap() {
        let ring = FrameRing(slots: 4, slotBytes: 8)
        for i in 1...6 { push(ring, i) }
        XCTAssertEqual(ring.available, 4)
        XCTAssertEqual(ring.dropped, 2)
        var got: [FrameRing.Popped] = []
        while let p = ring.pop() { got.append(p) }
        XCTAssertEqual(got.map { Int($0.payload[0]) }, [3, 4, 5, 6], "oldest frames evicted, newest kept")
        XCTAssertEqual(got.map(\.seq), [3, 4, 5, 6], "seq is writer-side so evicted frames leave a gap")
        XCTAssertEqual(got.first?.droppedSamples, 200, "dropped samples reported once, on the next pop")
        XCTAssertEqual(got.first?.sampleStart, 300)
        XCTAssertEqual(got.dropFirst().map(\.droppedSamples), [0, 0, 0])
        XCTAssertNil(ring.pop())
        // After a stall the reader resyncs to live rather than replaying the whole backlog.
        for i in 7...20 { push(ring, i) }
        XCTAssertEqual(ring.pop()?.seq, 17)
    }

    func testNoDropsWhenReaderKeepsUp() {
        let ring = FrameRing(slots: 2, slotBytes: 8)
        for i in 1...10 {
            push(ring, i)
            let p = ring.pop()
            XCTAssertEqual(p?.seq, UInt64(i))
            XCTAssertEqual(p?.droppedSamples, 0)
        }
        XCTAssertEqual(ring.dropped, 0)
    }
}
