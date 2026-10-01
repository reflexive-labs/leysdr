// SPDX-License-Identifier: GPL-3.0-or-later

// A rejected capture_sample_rate write still moves the engine: the device may refuse the rate and
// then fail to stream again (capture detached), or come back at the old rate. Either way the store
// must re-emit the capture and its channels so watchers learn the actual state without a GetState.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// A registry-hosted virtual device whose `setSampleRate` throws while `failSetSampleRate` is set and
/// whose `startStreaming` throws for the next `failStartStreamingTimes` calls (then succeeds).
/// Unchecked Sendable: the descriptor and hook are read and written only under `lock`; the rest are `LockedValue`s.
final class RateRefusingDevice: VirtualDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "rate-refusing", serial: "rate-refusing-1",
                                               tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                               sampleRates: [2_400_000, 1_024_000], nativeFormat: .cf32)
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    let failSetSampleRate = LockedValue(false)
    let failStartStreamingTimes = LockedValue(0)
    let streamStarts = LockedValue(0)
    let closes = LockedValue(0)

    var descriptor: DeviceDescriptor { lock.lock(); defer { lock.unlock() }; return _descriptor }
    var gains: [GainState] { [] }

    func assignID(_ id: DeviceID) { lock.lock(); _descriptor.id = id; lock.unlock() }
    func setState(_ state: DeviceState) {
        lock.lock(); _descriptor.state = state; let hook = _onStateChange; lock.unlock()
        hook?(state)
    }
    func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) { lock.lock(); _onStateChange = hook; lock.unlock() }

    func open() async throws {}
    func close() async { closes.value += 1 }
    func tune(centerHz: UInt64) async throws {}
    func setSampleRate(_ hz: UInt64) async throws {
        if failSetSampleRate.value { throw EngineError.deviceIO("rate refused", target: descriptor.id.string) }
    }
    func setGain(element: String, value: GainValue) async throws { throw EngineError.gainElementUnknown(element, target: "") }
    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        if failStartStreamingTimes.value > 0 {
            failStartStreamingTimes.value -= 1
            throw EngineError.deviceIO("stream refused", target: descriptor.id.string)
        }
        streamStarts.value += 1
    }
    func stopStreaming() async {}
}

final class FailedRateWriteDaemonTests: XCTestCase {
    /// Polls `cond` every 20 ms until it holds or `timeoutMs` elapses.
    private func eventually(timeoutMs: Int = 3000, _ cond: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0 ..< (timeoutMs / 20) {
            if try await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await cond()
    }

    private struct Fixture {
        let capture: Leyline_V1_Capture
        let channel: Leyline_V1_Channel
        let events: EventCollector
    }

    /// Attaches `device`, waits for the store to mirror it, opens a watch, and creates one capture
    /// (2.4 MSPS) with one NFM channel on it.
    private func setUp(_ c: DaemonClients, device: RateRefusingDevice) async throws -> Fixture {
        let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
        let mirrored = try await eventually {
            let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            return s.devices.contains(where: { $0.deviceID == d.id.string })
        }
        XCTAssertTrue(mirrored, "session store mirrors the attached device")
        let events = await EventCollector.start(c.control, daemon: c.daemon)

        var cc = Leyline_V1_CreateCaptureRequest()
        cc.deviceID = d.id.string
        cc.centerHz = 146_520_000
        let capture = try await c.control.createCapture(cc, metadata: testMetadata)
        XCTAssertEqual(capture.sampleRate, 2_400_000)
        XCTAssertEqual(capture.state, .captureActive)
        var cch = Leyline_V1_CreateChannelRequest()
        cch.captureID = capture.captureID
        cch.offsetHz = 100_000
        cch.mode = .nfm
        let channel = try await c.control.createChannel(cch, metadata: testMetadata)
        XCTAssertEqual(channel.state, .channelActive)
        // createChannel emits the capture then the channel: once the channel event is here the
        // watch has caught up, so counts taken afterwards only cover what the write emits.
        let created = await events.waitFor { ev in
            if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID }
            return false
        }
        XCTAssertNotNil(created, "channel event from createChannel")
        return Fixture(capture: capture, channel: channel, events: events)
    }

    /// Writes `capture_sample_rate` under `tag`; returns the summary (the write is expected to fail).
    private func writeRate(_ c: DaemonClients, captureID: String, tag: UInt64, hz: UInt64) async throws -> Leyline_V1_WriteSummary {
        try await c.control.writeParams(metadata: testMetadata) { writer in
            var w = Leyline_V1_ParamWrite()
            w.tag = tag
            w.targetID = captureID
            w.captureSampleRate = hz
            try await writer.write(w)
        }
    }

    /// The device refuses the rate and the restore attempt fails too: the write is rejected AND the
    /// watch stream carries a Capture event with CAPTURE_DETACHED (plus the channel's state), so a
    /// client learns the capture is gone without a GetState.
    func testRejectedRateWriteEmitsDetachedCapture() async throws {
        try await withDaemon { c in
            let device = RateRefusingDevice()
            let f = try await self.setUp(c, device: device)
            XCTAssertEqual(device.streamStarts.value, 1)
            device.failSetSampleRate.value = true
            device.failStartStreamingTimes.value = 1
            let before = await f.events.events.count

            let summary = try await self.writeRate(c, captureID: f.capture.captureID, tag: 21, hz: 1_024_000)
            XCTAssertEqual(summary.writesReceived, 1)
            XCTAssertEqual(summary.writesApplied, 0, "rate write rejected")
            let rejected = await f.events.waitFor { ev in
                if case .writeRejected(let wr)? = ev.body { return wr.tag == 21 }
                return false
            }
            XCTAssertEqual(rejected?.writeRejected.error.code, "DEVICE_IO")

            let detached = await f.events.waitFor { ev in
                if case .capture(let cap)? = ev.body { return cap.captureID == f.capture.captureID && cap.state == .captureDetached }
                return false
            }
            XCTAssertNotNil(detached, "capture event carries CAPTURE_DETACHED after the failed write")
            XCTAssertEqual(detached?.capture.sampleRate, 2_400_000, "the refused rate was never applied")
            let channelEvent = await f.events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == f.channel.channelID }
                return false
            }
            XCTAssertNotNil(channelEvent)
            let reemitted = await f.events.events.dropFirst(before).contains { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == f.channel.channelID }
                return false
            }
            XCTAssertTrue(reemitted, "the channel is re-emitted after the failed write")
            XCTAssertEqual(device.streamStarts.value, 1, "the restore attempt failed; no new stream")

            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.state, .captureDetached)
            await f.events.stop()
        }
    }

    /// The device refuses the rate but streams again at the old rate: the write is rejected, the
    /// capture event shows the unchanged rate and ACTIVE state, and the channel is re-emitted.
    func testRejectedRateWriteReemitsUnchangedCaptureAndChannels() async throws {
        try await withDaemon { c in
            let device = RateRefusingDevice()
            let f = try await self.setUp(c, device: device)
            device.failSetSampleRate.value = true
            let before = await f.events.events.count

            let summary = try await self.writeRate(c, captureID: f.capture.captureID, tag: 22, hz: 1_024_000)
            XCTAssertEqual(summary.writesApplied, 0, "rate write rejected")
            let rejected = await f.events.waitFor { ev in
                if case .writeRejected(let wr)? = ev.body { return wr.tag == 22 }
                return false
            }
            XCTAssertEqual(rejected?.writeRejected.error.code, "DEVICE_IO")

            // The re-emits precede the rejection on the stream, so everything is in by now.
            let afterWrite = await f.events.events.dropFirst(before)
            let capturesAfter = afterWrite.compactMap { ev -> Leyline_V1_Capture? in
                if case .capture(let cap)? = ev.body, cap.captureID == f.capture.captureID { return cap }
                return nil
            }
            XCTAssertEqual(capturesAfter.count, 1, "exactly one capture event follows the failed write")
            XCTAssertEqual(capturesAfter.first?.sampleRate, 2_400_000, "the capture keeps its old rate")
            XCTAssertEqual(capturesAfter.first?.state, .captureActive, "the restore succeeded")
            let channelsAfter = afterWrite.compactMap { ev -> Leyline_V1_Channel? in
                if case .channel(let ch)? = ev.body, ch.channelID == f.channel.channelID { return ch }
                return nil
            }
            XCTAssertEqual(channelsAfter.count, 1, "the channel is re-emitted exactly once")
            XCTAssertEqual(channelsAfter.first?.state, .channelActive)
            XCTAssertEqual(device.streamStarts.value, 2, "the restore restarted the device stream")

            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.sampleRate, 2_400_000)
            XCTAssertEqual(state.captures.first?.state, .captureActive)
            await f.events.stop()
        }
    }
}
