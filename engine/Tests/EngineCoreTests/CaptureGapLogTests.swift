// SPDX-License-Identifier: GPL-3.0-or-later

// The capture's gap log: where the block ring dropped samples, by sample (MC-9).

@testable import EngineCore
import XCTest

final class CaptureGapLogTests: XCTestCase {
    func testDropsInARowAreOneGapPublishedWhenTheRingTakesABlockAgain() {
        let log = CaptureGapLog()
        log.dropped(from: 1000, samples: 100)
        log.dropped(from: 1100, samples: 50)
        XCTAssertEqual(log.count, 0, "a gap still open is not published")
        log.delivered()
        let read = log.read(from: 0)
        XCTAssertEqual(read.gaps, [CaptureGap(fromSample: 1000, samples: 150)])
        XCTAssertEqual(read.next, 1)
        XCTAssertEqual(read.missed, 0)
        log.delivered()
        XCTAssertEqual(log.count, 1, "a block with nothing dropped before it publishes nothing")
    }

    func testADropThatDoesNotFollowOnIsANewGap() {
        let log = CaptureGapLog()
        log.dropped(from: 1000, samples: 100)
        log.dropped(from: 5000, samples: 10)
        log.delivered()
        XCTAssertEqual(log.read(from: 0).gaps, [CaptureGap(fromSample: 1000, samples: 100),
                                                 CaptureGap(fromSample: 5000, samples: 10)])
        XCTAssertEqual(log.read(from: 1).gaps, [CaptureGap(fromSample: 5000, samples: 10)])
        XCTAssertEqual(log.read(from: 2).gaps, [])
    }

    func testAReaderThatLappedTheRingIsToldWhatItMissed() {
        let log = CaptureGapLog()
        let n = UInt64(CaptureGapLog.capacity) + 5
        for i in 0..<n {
            log.dropped(from: i * 100, samples: 10)
            log.delivered()
        }
        let read = log.read(from: 0)
        XCTAssertEqual(read.missed, 5)
        XCTAssertEqual(read.gaps.count, CaptureGapLog.capacity)
        XCTAssertEqual(read.gaps.first, CaptureGap(fromSample: 500, samples: 10))
        XCTAssertEqual(read.next, n)
    }

    /// The capture's own path: a full ring drops the block and the rest of its buffer, and the gap
    /// is where those samples were on the capture's timeline.
    func testAFullRingLogsTheSamplesItDropped() {
        let core = CaptureDSPCore(captureID: CaptureID(), sampleRate: 2_400_000, centerHz: 0)
        let block = UInt64(CaptureDSPCore.blockSize)
        let storage = SampleStorage(capacity: CaptureDSPCore.blockSize, format: .cu8)
        let id = core.captureID
        let slots = UInt64(CaptureDSPCore.ringSlots)
        for i in 0..<(slots + 3) {
            core.deliver(storage.view(), at: SampleTime(captureID: id, sampleIndex: i * block))
        }
        XCTAssertEqual(core.gaps.count, 0, "the gap is open until a block gets through")
        // The DSP thread catches up by one block, and the next block is taken.
        core.ring.release()
        core.deliver(storage.view(), at: SampleTime(captureID: id, sampleIndex: (slots + 3) * block))
        XCTAssertEqual(core.gaps.read(from: 0).gaps, [CaptureGap(fromSample: slots * block, samples: 3 * block)])
        core.finish()
    }
}
