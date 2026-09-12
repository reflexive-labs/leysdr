// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import EngineCore

final class RingsTests: XCTestCase {
    func testFloatRingPushPopWrap() {
        let ring = FloatRing(capacity: 8)
        let a: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(a.withUnsafeBufferPointer { ring.push($0) }, 6)
        XCTAssertEqual(ring.available, 6)
        var out = [Float](repeating: 0, count: 4)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.pop(into: $0) }, 4)
        XCTAssertEqual(out, [1, 2, 3, 4])
        // Wraps around the end of storage.
        let b: [Float] = [7, 8, 9, 10, 11]
        XCTAssertEqual(b.withUnsafeBufferPointer { ring.push($0) }, 5)
        XCTAssertEqual(ring.available, 7)
        var out2 = [Float](repeating: 0, count: 7)
        XCTAssertEqual(out2.withUnsafeMutableBufferPointer { ring.pop(into: $0) }, 7)
        XCTAssertEqual(out2, [5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(ring.available, 0)
        XCTAssertEqual(ring.dropped, 0)
    }

    func testFloatRingDropsWhenFull() {
        let ring = FloatRing(capacity: 4)
        let a: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(a.withUnsafeBufferPointer { ring.push($0) }, 4)
        XCTAssertEqual(ring.dropped, 2)
        XCTAssertEqual(ring.free, 0)
        var out = [Float](repeating: 0, count: 8)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.pop(into: $0) }, 4)
        XCTAssertEqual(Array(out[0 ..< 4]), [1, 2, 3, 4])
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.pop(into: $0) }, 0)
        ring.clear()
        XCTAssertEqual(ring.available, 0)
    }

    func testFloatRingRequestFlushTakesEffectOnConsumerPop() {
        let ring = FloatRing(capacity: 8)
        let a: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(a.withUnsafeBufferPointer { ring.push($0) }, 4)
        ring.requestFlush()
        // Data stays until the consumer pops: the request itself never touches `head`.
        XCTAssertEqual(ring.available, 4)
        var out = [Float](repeating: 0, count: 8)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.pop(into: $0) }, 0)
        XCTAssertEqual(ring.available, 0)
        // The flag is one-shot; later data flows normally.
        XCTAssertEqual(a.withUnsafeBufferPointer { ring.push($0) }, 4)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.pop(into: $0) }, 4)
        XCTAssertEqual(Array(out[0 ..< 4]), [1, 2, 3, 4])
    }

    func testFloatRingConcurrentProducerConsumer() {
        let ring = FloatRing(capacity: 1024)
        let total = 200_000
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var received: [Float] = [] }
        let box = Box()
        box.received.reserveCapacity(total)
        let consumer = Thread {
            var buf = [Float](repeating: 0, count: 100)
            var got = 0
            var spins = 0
            while got < total && spins < 50_000_000 {
                let n = buf.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
                if n == 0 { spins += 1; continue }
                box.received.append(contentsOf: buf[0 ..< n])
                got += n
            }
            done.signal()
        }
        consumer.start()
        var chunk = [Float](repeating: 0, count: 64)
        var sent = 0
        let deadline = Date().addingTimeInterval(20)
        while sent < total {
            let n = min(64, total - sent)
            // Back-pressure: the ring never blocks, so the producer spins until the consumer drains.
            // A consumer that has stopped draining must fail the test rather than hang it.
            if ring.free < n {
                if Date() > deadline {
                    XCTFail("consumer stopped draining: \(sent) of \(total) samples pushed")
                    return
                }
                continue
            }
            for i in 0 ..< n { chunk[i] = Float(sent + i) }
            let pushed = chunk.withUnsafeBufferPointer { ring.push(UnsafeBufferPointer(rebasing: $0[0 ..< n])) }
            sent += pushed
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(ring.dropped, 0)
        let received = box.received
        XCTAssertEqual(received.count, total)
        for i in stride(from: 0, to: total, by: 997) { XCTAssertEqual(received[i], Float(i)) }
    }

    private func time(_ i: UInt64) -> SampleTime { SampleTime(captureID: CaptureID(), sampleIndex: i) }

    func testBlockRingOverrunAndOrder() {
        let ring = BlockRing(slots: 2, blockCapacity: 4)
        XCTAssertNil(ring.peek())
        XCTAssertFalse(ring.wait(timeoutMs: 1))
        for k in 0 ..< 2 {
            let (buf, idx) = ring.acquire()!
            buf.floats[0] = Float(k)
            ring.commit(index: idx, count: 3, time: time(UInt64(k * 4)))
        }
        XCTAssertNil(ring.acquire())
        XCTAssertEqual(ring.overruns, 1)
        XCTAssertEqual(ring.available, 2)
        XCTAssertTrue(ring.wait(timeoutMs: 1))
        let first = ring.peek()!
        XCTAssertEqual(first.buffer.count, 3)
        XCTAssertEqual(first.buffer.floats[0], 0)
        XCTAssertEqual(first.time.sampleIndex, 0)
        ring.release()
        XCTAssertEqual(ring.available, 1)
        // Slot freed: producer can write again and the ring wraps.
        let (buf, idx) = ring.acquire()!
        buf.floats[0] = 9
        ring.commit(index: idx, count: 4, time: time(8))
        XCTAssertEqual(ring.peek()!.buffer.floats[0], 1)
        ring.release()
        XCTAssertEqual(ring.peek()!.buffer.floats[0], 9)
        XCTAssertEqual(ring.peek()!.time.sampleIndex, 8)
        ring.release()
        ring.release() // no-op when empty
        XCTAssertNil(ring.peek())
    }

    func testBlockRingWaitWakesOnCommit() {
        let ring = BlockRing(slots: 4, blockCapacity: 16)
        let t = Thread {
            usleep(20_000)
            let (_, idx) = ring.acquire()!
            ring.commit(index: idx, count: 16, time: self.time(0))
        }
        t.start()
        XCTAssertTrue(ring.wait(timeoutMs: 2000))
        XCTAssertNotNil(ring.peek())
    }
}
