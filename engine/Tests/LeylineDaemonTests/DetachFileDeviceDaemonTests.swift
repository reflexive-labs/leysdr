// SPDX-License-Identifier: GPL-3.0-or-later

// DetachFileDevice and DetachDevice: what may be detached, and what is left alone.

@testable import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineServer
import LeylineProto
import XCTest

final class DetachFileDeviceDaemonTests: XCTestCase {
    /// Waits until the session store mirrors `deviceID` from the registry (arrivals are asynchronous).
    private func waitForDevice(_ c: DaemonClients, _ deviceID: String) async throws -> Leyline_V1_GetStateResponse {
        var state = Leyline_V1_GetStateResponse()
        for _ in 0..<150 {
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if state.devices.contains(where: { $0.deviceID == deviceID }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return state
    }

    /// DetachFileDevice is rejected before mutating anything: it names a file, so a virtual device
    /// that is not one is INVALID_ARGUMENT and an unknown id is DEVICE_NOT_FOUND, and a capture on
    /// the device survives both. (DetachDevice is the RPC that takes any device a client attached.)
    func testDetachRejectsNonFileAndUnknownDevicesWithoutTouchingCaptures() async throws {
        try await withDaemon { c in
            let dev = FaultyStreamDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(dev).descriptor
            var state = try await self.waitForDevice(c, d.id.string)
            XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.id.string])

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.state, .captureActive)

            // Hosted virtual device that is not file playback (driver "test"): DetachFileDevice
            // accepts only file devices and refuses it, even though DetachDevice would take this.
            var detach = Leyline_V1_DetachFileDeviceRequest()
            detach.deviceID = d.id.string
            do {
                _ = try await c.control.detachFileDevice(detach, metadata: testMetadata)
                XCTFail("expected INVALID_ARGUMENT")
            } catch {
                XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
            }
            let detachable = await c.daemon.registry.isDetachableVirtualDevice(id: d.id)
            XCTAssertTrue(detachable)

            // Unknown (well-formed) id: DEVICE_NOT_FOUND.
            detach.deviceID = DeviceID().string
            do {
                _ = try await c.control.detachFileDevice(detach, metadata: testMetadata)
                XCTFail("expected DEVICE_NOT_FOUND")
            } catch {
                XCTAssertEqual(errorCode(error).code, "DEVICE_NOT_FOUND")
            }

            // Nothing was mutated: the capture is still active, the device still hosted and in use.
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.map(\.captureID), [capture.captureID])
            XCTAssertEqual(state.captures.first?.state, .captureActive)
            XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.id.string])
            XCTAssertEqual(testDevices(state.devices).first?.state, .inUse)
            XCTAssertEqual(dev.closes.value, 0, "device must not be closed by a rejected detach")
            let registryIDs = testDevices(await c.daemon.registry.devices).map(\.id)
            XCTAssertEqual(registryIDs, [d.id])

            var dcap = Leyline_V1_DestroyCaptureRequest()
            dcap.captureID = capture.captureID
            _ = try await c.control.destroyCapture(dcap, metadata: testMetadata)
        }
    }

    /// A genuine file device reports as detachable and DetachFileDevice still works for it.
    func testFileDeviceIsDetachable() async throws {
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            let d = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            let id = try XCTUnwrap(DeviceID(string: d.deviceID))
            let detachable = await c.daemon.registry.isDetachableVirtualDevice(id: id)
            XCTAssertTrue(detachable)
            var detach = Leyline_V1_DetachFileDeviceRequest()
            detach.deviceID = d.deviceID
            _ = try await c.control.detachFileDevice(detach, metadata: testMetadata)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(testDevices(state.devices).isEmpty)
        }
    }
}
