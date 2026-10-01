// SPDX-License-Identifier: GPL-3.0-or-later

// CreateCapture unwinding when the device fails to stream.

@testable import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineServer
import LeylineProto
import XCTest

/// A registry-hosted virtual device whose `startStreaming` throws `DEVICE_IO` while `failStartStreaming`
/// is set; used to drive CreateCapture through the engine's start() unwinding.
/// Unchecked Sendable: the descriptor and hook are read and written only under `lock`; the rest are `LockedValue`s.
final class FaultyStreamDevice: VirtualDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "faulty", serial: "faulty-1",
                                               tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                               sampleRates: [2_400_000], nativeFormat: .cf32)
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    let failStartStreaming = LockedValue(false)
    let closes = LockedValue(0)
    let streamStarts = LockedValue(0)

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
    func setSampleRate(_ hz: UInt64) async throws {}
    func setGain(element: String, value: GainValue) async throws { throw EngineError.gainElementUnknown(element, target: "") }
    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        if failStartStreaming.value { throw EngineError.deviceIO("stream refused", target: descriptor.id.string) }
        streamStarts.value += 1
    }
    func stopStreaming() async {}
}

final class CaptureLifecycleDaemonTests: XCTestCase {
    /// A device that fails to stream is released by the failed CreateCapture: the error is DEVICE_IO,
    /// the device is AVAILABLE again, and a retry after the fault clears succeeds.
    func testCreateCaptureUnwindsWhenStreamingFails() async throws {
        try await withDaemon { c in
            let dev = FaultyStreamDevice()
            dev.failStartStreaming.value = true
            let d = try await c.daemon.registry.attachVirtualDevice(dev).descriptor
            // The session store mirrors the registry asynchronously; wait for the device to show up.
            var state = Leyline_V1_GetStateResponse()
            for _ in 0..<150 {
                state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                if state.devices.contains(where: { $0.deviceID == d.id.string }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.id.string])

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            do {
                _ = try await c.control.createCapture(cc, metadata: testMetadata)
                XCTFail("expected DEVICE_IO")
            } catch {
                XCTAssertEqual(errorCode(error).code, "DEVICE_IO")
            }
            XCTAssertEqual(dev.closes.value, 1, "device closed by the failed start")
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.captures.isEmpty)
            XCTAssertEqual(testDevices(state.devices).first?.state, .available)
            let registryState = testDevices(await c.daemon.registry.devices).first?.state
            XCTAssertEqual(registryState, .available)

            // Fault cleared: the retry succeeds on the same device.
            dev.failStartStreaming.value = false
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.state, .captureActive)
            XCTAssertEqual(dev.streamStarts.value, 1)
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.map(\.captureID), [capture.captureID])
            XCTAssertEqual(testDevices(state.devices).first?.state, .inUse)

            var dcap = Leyline_V1_DestroyCaptureRequest()
            dcap.captureID = capture.captureID
            _ = try await c.control.destroyCapture(dcap, metadata: testMetadata)
            XCTAssertEqual(dev.closes.value, 2)
        }
    }
}
