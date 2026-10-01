// SPDX-License-Identifier: GPL-3.0-or-later

// Sample timebase across stream restarts: devices restart their index at 0 on every
// `startStreaming`, the capture timeline must not (docs/dev/engine-internals.md, "Timebase and anchor").

import Foundation
import XCTest
@testable import EngineCore

/// Streams 4096-sample zero blocks from its own thread; the device index restarts at 0 on every
/// `startStreaming`, like `RTLTCPDevice` and the rtl-sdr callback. Supports two rates.
/// Unchecked Sendable: mutable state is read and written under `lock` or in `LockedValue`s; `thread` is touched only by start and stop, which the test calls in order.
final class RestartingDevice: RadioDevice, @unchecked Sendable {
    let descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "restarting", serial: "r",
                                      tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                      sampleRates: [2_400_000, 1_024_000], nativeFormat: .cf32)
    var gains: [GainState] { [] }
    static let blockSize = 4096
    private let storage = SampleStorage(capacity: RestartingDevice.blockSize, format: .cf32)
    private let streaming = LockedValue(false)
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    let streamStarts = LockedValue(0)

    func open() async throws {}
    func close() async {}
    func tune(centerHz: UInt64) async throws {}
    func setSampleRate(_ hz: UInt64) async throws {}
    func setGain(element: String, value: GainValue) async throws { throw EngineError.gainElementUnknown(element, target: "") }

    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        streamStarts.value += 1
        streaming.value = true
        let t = Thread { [self] in
            var index: UInt64 = 0
            while streaming.value {
                deliver(storage.view(), SampleTime(captureID: captureID, sampleIndex: index))
                index &+= UInt64(Self.blockSize)
                var ts = timespec(tv_sec: 0, tv_nsec: 500_000)
                nanosleep(&ts, nil)
            }
            done.signal()
        }
        thread = t
        t.start()
    }

    func stopStreaming() async {
        streaming.value = false
        if thread != nil { done.wait(); thread = nil }
    }
}

/// Lock-guarded row recorder (rows are written on the DSP thread, read by the test).
/// Unchecked Sendable: mutable state is read and written only under `lock`.
final class LockedSpectrumSink: SpectrumSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(index: UInt64, spanHz: UInt64)] = []
    func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64, looks _: Int) {
        lock.lock(); stored.append((time.sampleIndex, spanHz)); lock.unlock()
    }
    var rows: [(index: UInt64, spanHz: UInt64)] { lock.lock(); defer { lock.unlock() }; return stored }
    var count: Int { rows.count }
}

final class TimebaseRestartTests: XCTestCase {
    /// Polls `cond` every 5 ms until it holds or `timeoutMs` elapses.
    private func eventually(timeoutMs: Int = 3000, _ cond: () -> Bool) async -> Bool {
        for _ in 0 ..< (timeoutMs / 5) {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func assertStrictlyIncreasing(_ xs: [UInt64], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for i in 1 ..< max(xs.count, 1) where xs[i] <= xs[i - 1] {
            XCTFail("\(what) not strictly increasing at \(i): \(xs[i - 1]) -> \(xs[i])", file: file, line: line)
            return
        }
    }

    /// After a rate change and after a rebind the device index restarts at 0, but the delivered
    /// `SampleTime` keeps increasing and a live spectrum subscription keeps producing rows.
    func testSampleTimeContinuesAcrossRateChangeAndRebound() async throws {
        let first = RestartingDevice()
        let capture = DefaultCaptureEngine(device: first, centerHz: 100_000_000, sampleRate: 2_400_000)
        let tap = RecordingTap()
        await capture.addTap(tap)
        let sink = LockedSpectrumSink()
        let sub = await capture.spectrum.subscribe(bins: 256, rowsPerSecond: 30, accumulation: .snapshot, policy: .latestWins, sink: sink)
        var anchors: [CaptureAnchor] = []
        let anchorTask = Task { for await a in capture.anchorEvents { anchors.append(a) } }
        try await capture.start()
        let ok1 = await eventually { tap.times.count >= 10 && sink.count >= 2 }
        XCTAssertTrue(ok1, "samples and rows flow at the first rate")
        let tapsBeforeRate = tap.times.count
        let rowsBeforeRate = sink.count

        // Rate change: the device restarts at index 0; the capture timeline does not.
        try await capture.setSampleRate(1_024_000)
        XCTAssertEqual(first.streamStarts.value, 2)
        let ok2 = await eventually { tap.times.count >= tapsBeforeRate + 10 }
        XCTAssertTrue(ok2, "samples flow after the rate change")
        let ok3 = await eventually { sink.count >= rowsBeforeRate + 2 }
        XCTAssertTrue(ok3, "rows keep arriving after the rate change")
        XCTAssertTrue(sink.rows.suffix(2).allSatisfy { $0.spanHz == 1_024_000 }, "new rows carry the new span")
        let tapsBeforeRebound = tap.times.count
        let rowsBeforeRebound = sink.count

        // Loss and rebind: a fresh device starting at index 0 again.
        await capture.deviceLost()
        let second = RestartingDevice()
        try await capture.deviceRebound(second)
        let ok4 = await eventually { tap.times.count >= tapsBeforeRebound + 10 }
        XCTAssertTrue(ok4, "samples flow after the rebind")
        let ok5 = await eventually { sink.count >= rowsBeforeRebound + 2 }
        XCTAssertTrue(ok5, "rows keep arriving after the rebind")
        await capture.spectrum.cancel(sub)
        await capture.stop()
        anchorTask.cancel()

        assertStrictlyIncreasing(tap.times, "tap SampleTime")
        assertStrictlyIncreasing(sink.rows.map(\.index), "row SampleTime")
        // Every block is contiguous on the capture timeline: no rewind and no gap at the restarts.
        for i in 1 ..< tap.times.count {
            XCTAssertEqual(tap.times[i], tap.times[i - 1] + UInt64(tap.counts[i - 1]), "gap or rewind at block \(i)")
        }
        XCTAssertEqual(capture.core.deliveredEnd, tap.times.last! + UInt64(tap.counts.last!))
        // Three anchors: start, rate change, rebind.
        let ok6 = await eventually { anchors.count == 3 }
        XCTAssertTrue(ok6, "one anchor per epoch, got \(anchors.count)")
        XCTAssertEqual(anchors.map(\.sampleRate), [2_400_000, 1_024_000, 1_024_000])
    }

    /// `drainPending` waits for the DSP thread to release every committed block, and reports
    /// failure instead of hanging when no thread is there to drain.
    func testDrainPendingWaitsForBacklog() async throws {
        let core = CaptureDSPCore(captureID: CaptureID(), sampleRate: 2_400_000, centerHz: 0)
        let storage = SampleStorage(capacity: 4096, format: .cf32)
        for i in 0 ..< 8 {
            core.deliver(storage.view(), at: SampleTime(captureID: core.captureID, sampleIndex: UInt64(i) * 4096))
        }
        XCTAssertEqual(core.ring.available, 8)
        let stalled = await core.drainPending(timeoutMs: 20)
        XCTAssertFalse(stalled, "nothing drains without a DSP thread")
        XCTAssertEqual(core.ring.available, 8)
        core.startThread()
        let drained = await core.drainPending(timeoutMs: 2000)
        XCTAssertTrue(drained)
        XCTAssertEqual(core.ring.available, 0)
        XCTAssertEqual(core.stats.blocksProcessed, 8)
        core.stopThread()
        core.finish()
    }

    /// The core rebases a restarted device index onto the capture timeline on the block that
    /// follows `expectNewAnchor`, and publishes the anchor from the rebased index.
    func testCoreRebasesDeviceIndexOnNewEpoch() async throws {
        let core = CaptureDSPCore(captureID: CaptureID(), sampleRate: 2_400_000, centerHz: 0)
        let storage = SampleStorage(capacity: 4096, format: .cf32)
        let id = core.captureID
        core.deliver(storage.view(), at: SampleTime(captureID: id, sampleIndex: 0))
        core.deliver(storage.view(), at: SampleTime(captureID: id, sampleIndex: 4096))
        XCTAssertEqual(core.deliveredEnd, 8192)
        core.expectNewAnchor()
        core.deliver(storage.view(), at: SampleTime(captureID: id, sampleIndex: 0))
        core.deliver(storage.view(), at: SampleTime(captureID: id, sampleIndex: 4096))
        XCTAssertEqual(core.deliveredEnd, 16384)
        var committed: [UInt64] = []
        while let (_, time) = core.ring.peek() { committed.append(time.sampleIndex); core.ring.release() }
        XCTAssertEqual(committed, [0, 4096, 8192, 12288])
        var anchors: [CaptureAnchor] = []
        core.finish()
        for await a in core.anchorEvents { anchors.append(a) }
        XCTAssertEqual(anchors.count, 2)
        // The second anchor was computed for capture index 8192 (not device index 0): sample zero
        // sits two more blocks in the past than the first anchor placed it. A reset index would
        // have put it at (or after) the first anchor's sample zero.
        let blockNs = Int64(Double(4096) / 2_400_000 * 1e9)
        XCTAssertLessThan(anchors[1].hostTimeNsAtSampleZero, anchors[0].hostTimeNsAtSampleZero - blockNs / 2)
    }

    /// A shrinking interval (rate change) or a rewound timeline leaves `nextDue` too far ahead;
    /// the ladder clamps it to one interval past `now` so rows never stall.
    func testLadderClampsDueAfterJumpOrRewind() async {
        let ladder = DefaultSpectrumLadder()
        let sink = LockedSpectrumSink()
        _ = await ladder.subscribe(bins: 256, rowsPerSecond: 10, accumulation: .snapshot, policy: .latestWins, sink: sink)
        let storage = SampleStorage(capacity: 4096, format: .cf32)
        let id = CaptureID()
        func step(_ index: UInt64, span: UInt64) {
            ladder.process(block: storage.view(), at: SampleTime(captureID: id, sampleIndex: index), centerHz: 0, spanHz: span)
        }
        step(0, span: 2_400_000)                       // row; nextDue = 240_000
        XCTAssertEqual(sink.rows.map(\.index), [0])
        step(4096, span: 1_024_000)                    // interval now 102_400: clamp nextDue to 106_496
        XCTAssertEqual(sink.count, 1)
        step(106_496, span: 1_024_000)                 // due under the clamped schedule, not at 240_000
        XCTAssertEqual(sink.rows.map(\.index), [0, 106_496])
        step(0, span: 1_024_000)                       // rewound timeline: clamp to 102_400
        XCTAssertEqual(sink.count, 2)
        step(102_400, span: 1_024_000)
        XCTAssertEqual(sink.rows.map(\.index), [0, 106_496, 102_400])
    }
}
