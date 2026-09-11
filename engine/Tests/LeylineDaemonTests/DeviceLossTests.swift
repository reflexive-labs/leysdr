// Device loss / rebind through the daemon: a hosted virtual device drops its link, the capture
// goes CAPTURE_DETACHED, and a re-arrival with the same identity rebinds it and resumes streaming.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// A registry-hosted virtual device that streams zero blocks from its own thread until stopped and
/// can be driven to `.disconnected` through the registry's state-change hook, like an rtl_tcp link loss.
final class RebindableDevice: VirtualDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "rebindable", serial: "rebind-1",
                                               tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                               sampleRates: [2_400_000, 1_024_000, 2_048_000], nativeFormat: .cf32)
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    private let storage = SampleStorage(capacity: 4096, format: .cf32)
    private let streaming = LockedValue(false)
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    let opens = LockedValue(0)
    let closes = LockedValue(0)
    let streamStarts = LockedValue(0)
    let streamStops = LockedValue(0)
    let blocksDelivered = LockedValue(0)

    var descriptor: DeviceDescriptor { lock.lock(); defer { lock.unlock() }; return _descriptor }
    var gains: [GainState] { [] }

    func assignID(_ id: DeviceID) { lock.lock(); _descriptor.id = id; lock.unlock() }
    func setState(_ state: DeviceState) {
        lock.lock(); _descriptor.state = state; let hook = _onStateChange; lock.unlock()
        hook?(state)
    }
    func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) { lock.lock(); _onStateChange = hook; lock.unlock() }

    /// Simulates the link dropping: delivery stops and the registry hook fires `.disconnected`.
    func dropLink() {
        streaming.value = false
        setState(.disconnected)
    }

    func open() async throws { opens.value += 1 }
    func close() async { closes.value += 1 }
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
                index &+= 4096
                blocksDelivered.value += 1
                var ts = timespec(tv_sec: 0, tv_nsec: 1_000_000)
                nanosleep(&ts, nil)
            }
            done.signal()
        }
        thread = t
        t.start()
    }

    func stopStreaming() async {
        streamStops.value += 1
        streaming.value = false
        joinDeliveryThread()
    }

    /// Bounded: the delivery thread exits as soon as `streaming` is false. Kept synchronous so the
    /// semaphore wait is not issued from an async context.
    private func joinDeliveryThread() {
        if thread != nil { done.wait(); thread = nil }
    }
}

final class DeviceLossDaemonTests: XCTestCase {
    /// Polls `cond` every 20 ms until it holds or `timeoutMs` elapses.
    private func eventually(timeoutMs: Int = 3000, _ cond: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0..<(timeoutMs / 20) {
            if try await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await cond()
    }

    func testDeviceLossDetachesCaptureAndReArrivalRebinds() async throws {
        try await withDaemon { c in
            let first = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(first).descriptor
            let mirrored = try await self.eventually {
                let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                return s.devices.contains(where: { $0.deviceID == d.id.string })
            }
            XCTAssertTrue(mirrored, "session store mirrors the attached device")
            let events = await EventCollector.start(c.control, daemon: c.daemon)

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.state, .captureActive)
            let capID = try XCTUnwrap(CaptureID(string: capture.captureID))
            let maybeEngine = await c.daemon.store.captureEngine(capID)
            let engine = try XCTUnwrap(maybeEngine)
            let flowing = await self.eventually { engine.stats.blocksProcessed > 0 }
            XCTAssertTrue(flowing, "samples flow before the loss")
            XCTAssertEqual(engine.core.threadStartCount, 1)

            // Link loss: the device hook reports .disconnected, the registry publishes `changed`,
            // the store detaches the capture and clients see CAPTURE_DETACHED with full state.
            first.dropLink()
            let detachedEvent = await events.waitFor { ev in
                if case .capture(let cap)? = ev.body { return cap.captureID == capture.captureID && cap.state == .captureDetached }
                return false
            }
            let detached = try XCTUnwrap(detachedEvent, "expected a CAPTURE_DETACHED event")
            guard case .capture(let detachedCap)? = detached.body else { return XCTFail("capture body") }
            XCTAssertEqual(detachedCap.deviceID, d.id.string)
            XCTAssertEqual(detachedCap.centerHz, 146_520_000)
            XCTAssertEqual(first.streamStops.value, 1, "the dead stream was stopped")
            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.state, .captureDetached)
            XCTAssertEqual(testDevices(state.devices).first?.state, .disconnected)
            let deviceGone = await events.waitFor { ev in
                if case .device(let dev)? = ev.body { return dev.deviceID == d.id.string && dev.state == .disconnected }
                return false
            }
            XCTAssertNotNil(deviceGone, "device event announces the loss")
            let processedAtLoss = engine.stats.blocksProcessed

            // The device goes away entirely (unplug), then comes back with the same identity and so
            // the same stable id: the store rebinds the detached capture and streaming resumes.
            try await c.daemon.registry.detachVirtualDevice(id: d.id)
            XCTAssertEqual(first.closes.value, 1)
            let second = RebindableDevice()
            let again = try await c.daemon.registry.attachVirtualDevice(second).descriptor
            XCTAssertEqual(again.id, d.id, "same identity key mints the same stable id")
            let rebound = await events.waitFor { ev in
                if case .capture(let cap)? = ev.body, cap.captureID == capture.captureID, cap.state == .captureActive {
                    return ev.seq > detached.seq
                }
                return false
            }
            XCTAssertNotNil(rebound, "expected CAPTURE_ACTIVE after the rebind")
            XCTAssertEqual(second.opens.value, 1)
            XCTAssertEqual(second.streamStarts.value, 1, "stream restarted on the new device")
            XCTAssertEqual(first.streamStarts.value, 1, "the lost device is never restarted")
            let resumed = await self.eventually { engine.stats.blocksProcessed > processedAtLoss + 2 }
            XCTAssertTrue(resumed, "samples flow again after rebind")
            XCTAssertEqual(engine.core.threadStartCount, 1, "rebind reused the DSP thread")
            XCTAssertEqual(engine.deviceID, d.id)
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.state, .captureActive)
            XCTAssertEqual(state.captures.first?.captureID, capture.captureID)
            XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.id.string])
            XCTAssertEqual(testDevices(state.devices).first?.state, .inUse)
            let registryState = testDevices(await c.daemon.registry.devices).first?.state
            XCTAssertEqual(registryState, .inUse)

            var dcap = Leyline_V1_DestroyCaptureRequest()
            dcap.captureID = capture.captureID
            _ = try await c.control.destroyCapture(dcap, metadata: testMetadata)
            XCTAssertEqual(second.streamStops.value, 1)
            XCTAssertEqual(second.closes.value, 1, "destroy closes the rebound device")
            await events.stop()
        }
    }
}
