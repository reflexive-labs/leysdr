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

    func testAudioBufferIsRefusedRatherThanCountedAsAnOverrun() {
        let core = CaptureDSPCore(captureID: CaptureID(), sampleRate: 48_000, centerHz: 0)
        let storage = SampleStorage(capacity: 1024, format: .f32)
        core.deliver(storage.view(), at: SampleTime(captureID: core.captureID, sampleIndex: 0))
        XCTAssertEqual(core.stats.unsupportedBlocks, 1)
        XCTAssertEqual(core.stats.overruns, 0, "a misrouted device must not read as a full ring")
        XCTAssertEqual(core.stats.blocksReceived, 0)
        XCTAssertEqual(core.ring.available, 0, "the refused block took no ring slot")
        XCTAssertEqual(core.deliveredEnd, 0, "the capture timeline did not move")
        core.finish()
    }
}

/// A device whose `startStreaming` / `setSampleRate` throw `DEVICE_IO` while the matching flag is
/// set. Counts lifecycle calls so tests can assert the engine unwound (or restored) properly.
final class FailingDevice: RadioDevice, @unchecked Sendable {
    let descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "failing", serial: "f",
                                      tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                      sampleRates: [2_400_000, 1_024_000], nativeFormat: .cf32)
    var gains: [GainState] { [] }
    let failStartStreaming = LockedValue(false)
    let failSetSampleRate = LockedValue(false)
    let opens = LockedValue(0)
    let closes = LockedValue(0)
    let streamStarts = LockedValue(0)
    let streamStops = LockedValue(0)

    func open() async throws { opens.value += 1 }
    func close() async { closes.value += 1 }
    func tune(centerHz: UInt64) async throws {}
    func setSampleRate(_ hz: UInt64) async throws {
        if failSetSampleRate.value { throw EngineError.deviceIO("rate refused", target: descriptor.id.description) }
    }
    func setGain(element: String, value: GainValue) async throws { throw EngineError.gainElementUnknown(element, target: "") }
    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        if failStartStreaming.value { throw EngineError.deviceIO("stream refused", target: descriptor.id.description) }
        streamStarts.value += 1
    }
    func stopStreaming() async { streamStops.value += 1 }
}

final class CaptureLifecycleTests: XCTestCase {
    func testFailedStartUnwindsAndRetrySucceeds() async throws {
        let device = FailingDevice()
        device.failStartStreaming.value = true
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        await assertCode("DEVICE_IO") { try await capture.start() }
        XCTAssertFalse(capture.core.isRunning, "DSP thread joined after a failed start")
        XCTAssertEqual(device.opens.value, 1)
        XCTAssertEqual(device.closes.value, 1, "device closed after a failed start")
        XCTAssertEqual(device.streamStarts.value, 0)
        XCTAssertEqual(device.streamStops.value, 0, "no stopStreaming for a stream that never began")
        var snap = await capture.snapshot
        XCTAssertFalse(snap.detached)

        // Fault cleared: the same engine starts from scratch.
        device.failStartStreaming.value = false
        try await capture.start()
        XCTAssertTrue(capture.core.isRunning)
        XCTAssertEqual(device.opens.value, 2)
        XCTAssertEqual(device.streamStarts.value, 1)
        snap = await capture.snapshot
        XCTAssertFalse(snap.detached)
        await capture.stop()
        XCTAssertFalse(capture.core.isRunning)
        XCTAssertEqual(device.streamStops.value, 1)
        XCTAssertEqual(device.closes.value, 2)
    }

    func testStopIsSafeOnHalfStartedEngine() async throws {
        let device = FailingDevice()
        device.failStartStreaming.value = true
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        await assertCode("DEVICE_IO") { try await capture.start() }
        await capture.stop()
        XCTAssertFalse(capture.core.isRunning)
        XCTAssertEqual(device.closes.value, 1, "stop() does not close a device start() already released")
        XCTAssertEqual(device.streamStops.value, 0)
    }

    func testFailedSetSampleRateRestoresStream() async throws {
        let device = FailingDevice()
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        try await capture.start()
        XCTAssertEqual(device.streamStarts.value, 1)
        device.failSetSampleRate.value = true
        await assertCode("DEVICE_IO") { try await capture.setSampleRate(1_024_000) }
        XCTAssertEqual(device.streamStops.value, 1)
        XCTAssertEqual(device.streamStarts.value, 2, "stream restarted at the old rate")
        let snap = await capture.snapshot
        XCTAssertFalse(snap.detached)
        XCTAssertEqual(snap.sampleRate, 2_400_000, "rate unchanged after the device refused it")
        XCTAssertEqual(capture.core.sampleRate, 2_400_000)
        XCTAssertTrue(capture.core.isRunning)
        await capture.stop()
        XCTAssertEqual(device.streamStops.value, 2)
    }

    func testFailedSetSampleRateWithDeadStreamDetaches() async throws {
        let device = FailingDevice()
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        try await capture.start()
        device.failSetSampleRate.value = true
        device.failStartStreaming.value = true
        await assertCode("DEVICE_IO") { try await capture.setSampleRate(1_024_000) }
        XCTAssertEqual(device.streamStarts.value, 1, "restart was attempted and refused")
        let snap = await capture.snapshot
        XCTAssertTrue(snap.detached, "capture reports detached when the stream cannot be restored")
        XCTAssertEqual(snap.sampleRate, 2_400_000)
        await assertCode("DEVICE_DETACHED") { try await capture.setSampleRate(2_400_000) }
        await capture.stop()
        XCTAssertEqual(device.streamStops.value, 1, "no second stopStreaming for a stream that never restarted")
    }

    func testFailedRestartAfterRateChangeDetaches() async throws {
        let device = FailingDevice()
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        try await capture.start()
        device.failStartStreaming.value = true
        await assertCode("DEVICE_IO") { try await capture.setSampleRate(1_024_000) }
        let snap = await capture.snapshot
        XCTAssertTrue(snap.detached)
        XCTAssertEqual(snap.sampleRate, 1_024_000, "device accepted the rate; only the stream is gone")
        await capture.stop()
    }
}

final class CaptureDeviceLossTests: XCTestCase {
    /// `deviceLost` stops the dead stream and reports detached without touching the DSP thread,
    /// channels or the sample index; `deviceRebound` adopts the new device on the same thread.
    func testDeviceLostThenReboundReusesDSPThread() async throws {
        let first = FailingDevice()
        let capture = DefaultCaptureEngine(device: first, centerHz: 100_000_000, sampleRate: 2_400_000)
        try await capture.start()
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .nfm))
        XCTAssertEqual(capture.core.threadStartCount, 1)
        XCTAssertEqual(capture.deviceID, first.descriptor.id)

        await capture.deviceLost()
        var snap = await capture.snapshot
        XCTAssertTrue(snap.detached, "capture reports detached after device loss")
        XCTAssertEqual(first.streamStops.value, 1, "the dead stream is stopped once")
        XCTAssertEqual(first.closes.value, 0, "a lost device is not closed by the engine")
        XCTAssertTrue(capture.core.isRunning, "DSP thread survives device loss")
        let channels = await capture.channels
        XCTAssertEqual(channels.map(\.id), [channel.id], "channels are kept across loss")
        await assertCode("DEVICE_DETACHED") { try await capture.retune(centerHz: 101_000_000) }
        await assertCode("DEVICE_DETACHED") { try await capture.setSampleRate(1_024_000) }

        // Losing an already-lost device is a no-op.
        await capture.deviceLost()
        XCTAssertEqual(first.streamStops.value, 1)

        let second = FailingDevice()
        try await capture.deviceRebound(second)
        snap = await capture.snapshot
        XCTAssertFalse(snap.detached, "rebound clears detached")
        XCTAssertEqual(snap.centerHz, 100_000_000)
        XCTAssertEqual(snap.sampleRate, 2_400_000)
        XCTAssertEqual(capture.deviceID, second.descriptor.id, "the engine now reports the new device")
        XCTAssertEqual(second.opens.value, 1)
        XCTAssertEqual(second.streamStarts.value, 1, "stream restarted on the new device")
        XCTAssertEqual(first.streamStarts.value, 1, "the lost device is never restarted")
        XCTAssertTrue(capture.core.isRunning)
        XCTAssertEqual(capture.core.threadStartCount, 1, "rebound reuses the running DSP thread")
        let kept = await capture.channels
        XCTAssertEqual(kept.map(\.id), [channel.id])
        try await capture.retune(centerHz: 101_000_000)

        // `started` is set by the rebound: stop() closes the new device and joins the thread.
        await capture.stop()
        XCTAssertFalse(capture.core.isRunning)
        XCTAssertEqual(second.streamStops.value, 1)
        XCTAssertEqual(second.closes.value, 1, "stop() closes the rebound device")
        XCTAssertEqual(first.closes.value, 0)
    }

    /// A rebind that fails to stream leaves the capture detached; a later rebind can still succeed.
    func testFailedReboundStaysDetached() async throws {
        let first = FailingDevice()
        let capture = DefaultCaptureEngine(device: first, centerHz: 100_000_000, sampleRate: 2_400_000)
        try await capture.start()
        await capture.deviceLost()

        let refusing = FailingDevice()
        refusing.failStartStreaming.value = true
        await assertCode("DEVICE_IO") { try await capture.deviceRebound(refusing) }
        var snap = await capture.snapshot
        XCTAssertTrue(snap.detached, "still detached after a failed rebind")
        XCTAssertTrue(capture.core.isRunning, "DSP thread kept for the next attempt")

        let good = FailingDevice()
        try await capture.deviceRebound(good)
        snap = await capture.snapshot
        XCTAssertFalse(snap.detached)
        XCTAssertEqual(good.streamStarts.value, 1)
        XCTAssertEqual(capture.core.threadStartCount, 1)
        await capture.stop()
        XCTAssertEqual(good.closes.value, 1)
    }

    /// A rebound on an engine that was never started (or whose thread was joined) spawns the thread.
    func testReboundStartsThreadWhenNotRunning() async throws {
        let first = FailingDevice()
        let capture = DefaultCaptureEngine(device: first, centerHz: 100_000_000, sampleRate: 2_400_000)
        XCTAssertFalse(capture.core.isRunning)
        try await capture.deviceRebound(first)
        XCTAssertTrue(capture.core.isRunning)
        XCTAssertEqual(capture.core.threadStartCount, 1)
        XCTAssertEqual(first.streamStarts.value, 1)
        let snap = await capture.snapshot
        XCTAssertFalse(snap.detached)
        await capture.stop()
    }
}
