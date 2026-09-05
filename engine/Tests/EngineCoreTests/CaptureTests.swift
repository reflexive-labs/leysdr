import Foundation
import Synchronization
import XCTest
@testable import EngineCore

/// A device that delivers `blocks` cf32 blocks from its own thread as fast as the ring accepts.
final class BurstDevice: RadioDevice, @unchecked Sendable {
    let descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "burst", serial: "b",
                                      tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                      sampleRates: [2_400_000], nativeFormat: .cf32)
    var gains: [GainState] { [] }
    let blocks: Int
    let blockSize: Int
    private let storage: SampleStorage
    private var index: UInt64 = 0
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)

    init(blocks: Int, blockSize: Int = 16384) {
        self.blocks = blocks
        self.blockSize = blockSize
        storage = SampleStorage(capacity: blockSize, format: .cf32)
    }

    func open() async throws {}
    func close() async {}
    func tune(centerHz: UInt64) async throws {}
    func setSampleRate(_ hz: UInt64) async throws {}
    func setGain(element: String, value: GainValue) async throws { throw EngineError.gainElementUnknown(element, target: "") }

    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        let t = Thread { [self] in
            for _ in 0 ..< blocks {
                deliver(storage.view(), SampleTime(captureID: captureID, sampleIndex: index))
                index &+= UInt64(blockSize)
                // Pace lightly so the 64-slot ring never fills.
                var ts = timespec(tv_sec: 0, tv_nsec: 200_000)
                nanosleep(&ts, nil)
            }
            done.signal()
        }
        thread = t
        t.start()
    }

    func stopStreaming() async { done.wait() }
}

final class RecordingTap: CaptureTap, @unchecked Sendable {
    let id = StreamID()
    private let lock = NSLock()
    private(set) var times: [UInt64] = []
    private(set) var counts: [Int] = []
    func write(iq: SampleBuffer, at time: SampleTime) {
        lock.lock(); times.append(time.sampleIndex); counts.append(iq.count); lock.unlock()
    }
    var closed = false
    func closeTap() async { closed = true }
}

final class CaptureTests: XCTestCase {
    func testTapReceivesEveryBlockInOrder() async throws {
        let device = BurstDevice(blocks: 200)
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        let tap = RecordingTap()
        await capture.addTap(tap)
        try await capture.start()
        // Wait until every block has been processed (the device thread delivers 200 then stops).
        let deadline = Date().addingTimeInterval(10)
        while capture.stats.blocksProcessed < 200, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await capture.stop()
        let stats = capture.stats
        XCTAssertEqual(stats.blocksReceived, 200)
        XCTAssertEqual(stats.blocksProcessed, 200)
        XCTAssertEqual(stats.overruns, 0)
        XCTAssertEqual(tap.times.count, 200)
        for (i, t) in tap.times.enumerated() { XCTAssertEqual(t, UInt64(i) * 16384) }
        XCTAssertTrue(tap.counts.allSatisfy { $0 == 16384 })
        XCTAssertTrue(tap.closed)
        XCTAssertFalse(capture.core.isRunning)
    }

    func testAnchorSetAfterFirstBlock() async throws {
        let device = BurstDevice(blocks: 3)
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        let before = capture.core.anchor
        XCTAssertEqual(before.hostTimeNsAtSampleZero, 0)
        let now = realtimeNowNs()
        try await capture.start()
        var anchor: CaptureAnchor?
        for await a in capture.anchorEvents { anchor = a; break }
        await capture.stop()
        let a = try XCTUnwrap(anchor)
        XCTAssertEqual(a.sampleRate, 2_400_000)
        // Sample zero maps to "now minus one block" — within a second of the start call.
        XCTAssertLessThan(abs(a.hostTimeNsAtSampleZero - now), 1_000_000_000)
        let snap = await capture.snapshot
        XCTAssertEqual(snap.anchor, a)
    }

    func testOverrunsCountedWhenRingNotDrained() {
        let core = CaptureDSPCore(captureID: CaptureID(), sampleRate: 2_400_000, centerHz: 0)
        let storage = SampleStorage(capacity: 16384, format: .cu8)
        let id = core.captureID
        for i in 0 ..< 100 {
            core.deliver(storage.view(), at: SampleTime(captureID: id, sampleIndex: UInt64(i) * 16384))
        }
        XCTAssertEqual(core.stats.blocksReceived, 100)
        XCTAssertEqual(core.stats.overruns, 100 - CaptureDSPCore.ringSlots)
        XCTAssertEqual(core.ring.available, CaptureDSPCore.ringSlots)
        // Converted cu8 zeros are -1.0 floats in the first slot.
        let (block, _) = core.ring.peek()!
        XCTAssertEqual(block.floats[0], -1, accuracy: 1e-6)
        XCTAssertEqual(block.count, 16384)
        core.finish()
    }
}
