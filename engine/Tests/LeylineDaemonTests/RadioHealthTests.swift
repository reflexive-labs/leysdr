// SPDX-License-Identifier: GPL-3.0-or-later

// A radio that stops answering (2026-11-09): a capture whose stream stops goes CAPTURE_STALLED and
// back to active when samples return; a stall that outlasts the reopen window gets one reopen,
// and a reopen that fails or a stream still silent after it leaves the radio NOT_ANSWERING with
// its capture detached; three failed opens do the same, and nothing opens it again until it comes
// back as a new arrival. The probe-level half (descriptor reads, busy dongles, revives) is
// `RegistryProbeTests`.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class RadioHealthTests: XCTestCase {
    static let notAnswering =
        "Scripted RTL is not answering: unplug it and plug it back in, ideally into a port on the back of the Mac"

    func testAStalledCaptureSaysSoAndComesBack() async throws {
        try await withDaemon(captureStallAfter: .seconds(1), captureReopenAfter: .seconds(60)) { c in
            let (radio, capture) = try await self.streaming(c)

            radio.stalled.value = true
            var cap = try await self.waitCapture(c, capture) { $0.state == .captureStalled }
            XCTAssertEqual(cap.stateDetail, "no samples from Scripted RTL for 1 s")

            radio.stalled.value = false
            cap = try await self.waitCapture(c, capture) { $0.state == .captureActive }
            XCTAssertEqual(cap.stateDetail, "")
            XCTAssertEqual(radio.opens.value, 1, "a stall shorter than the reopen window reopens nothing")
        }
    }

    func testAStallThatOutlastsTheReopenGivesUpOnTheRadio() async throws {
        try await withDaemon(captureStallAfter: .seconds(1), captureReopenAfter: .seconds(2)) { c in
            let (radio, capture) = try await self.streaming(c)
            radio.stalled.value = true

            // One reopen, which opens the radio and leaves it as silent as before.
            let reopened = await self.eventually(timeoutMs: 8000) { radio.opens.value == 2 }
            XCTAssertTrue(reopened, "the stalled radio is closed and opened again once")

            let device = try await self.waitDevice(c, capture.deviceID) { $0.state == .notAnswering }
            XCTAssertEqual(device.stateDetail, Self.notAnswering)
            let cap = try await self.waitCapture(c, capture) { $0.state == .captureDetached }
            XCTAssertEqual(cap.stateDetail, "")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            XCTAssertEqual(radio.opens.value, 2, "a radio that is not answering is not opened again")
        }
    }

    func testAReopenThatFailsLeavesTheRadioNotAnswering() async throws {
        try await withDaemon(captureStallAfter: .seconds(1), captureReopenAfter: .seconds(2)) { c in
            let (radio, capture) = try await self.streaming(c)
            radio.stalled.value = true
            radio.failsOpen.value = true

            let device = try await self.waitDevice(c, capture.deviceID) { $0.state == .notAnswering }
            XCTAssertEqual(device.stateDetail, Self.notAnswering)
            XCTAssertEqual(radio.opens.value, 2, "the first open, then the one reopen")
            _ = try await self.waitCapture(c, capture) { $0.state == .captureDetached }
        }
    }

    /// Three opens that get past the claim and fail: NOT_ANSWERING, and a fourth create is refused
    /// with the sentence without opening the radio. The radio coming back as a new arrival (a
    /// replug) starts from a clean count, and opens.
    func testThreeFailedOpensLeaveTheRadioAloneUntilItComesBack() async throws {
        try await withDaemon { c in
            let radio = ScriptedRadio()
            radio.failsOpen.value = true
            let d = try await c.daemon.registry.attachVirtualDevice(radio).descriptor
            _ = try await self.waitDevice(c, d.id.string) { $0.state == .available }

            var request = Leyline_V1_CreateCaptureRequest()
            request.deviceID = d.id.string
            request.centerHz = 146_000_000
            for attempt in 1...3 {
                do {
                    _ = try await c.control.createCapture(request, metadata: testMetadata)
                    XCTFail("open \(attempt) should fail")
                } catch {}
            }
            let device = try await self.waitDevice(c, d.id.string) { $0.state == .notAnswering }
            XCTAssertEqual(device.stateDetail, Self.notAnswering)
            XCTAssertEqual(radio.opens.value, 3)

            do {
                _ = try await c.control.createCapture(request, metadata: testMetadata)
                XCTFail("a radio that is not answering is not opened")
            } catch {
                XCTAssertTrue("\(error)".contains("is not answering"), "\(error)")
            }
            XCTAssertEqual(radio.opens.value, 3, "refused before anything opened it")

            // Replugged: the registry lets the old one go and a new one arrives under the same id.
            try await c.daemon.registry.detachVirtualDevice(id: d.id)
            let again = ScriptedRadio()
            let back = try await c.daemon.registry.attachVirtualDevice(again).descriptor
            XCTAssertEqual(back.id, d.id)
            _ = try await self.waitDevice(c, d.id.string) { $0.state == .available && $0.stateDetail.isEmpty }
            let capture = try await c.control.createCapture(request, metadata: testMetadata)
            XCTAssertEqual(capture.state, .captureActive)
            XCTAssertEqual(again.opens.value, 1)
        }
    }

    // MARK: Helpers

    /// A ScriptedRadio with a capture streaming from it.
    private func streaming(_ c: DaemonClients) async throws -> (ScriptedRadio, Leyline_V1_Capture) {
        let radio = ScriptedRadio()
        let d = try await c.daemon.registry.attachVirtualDevice(radio).descriptor
        _ = try await waitDevice(c, d.id.string) { $0.state == .available }
        var request = Leyline_V1_CreateCaptureRequest()
        request.deviceID = d.id.string
        request.centerHz = 146_000_000
        let capture = try await c.control.createCapture(request, metadata: testMetadata)
        XCTAssertEqual(capture.state, .captureActive)
        let id = try XCTUnwrap(CaptureID(string: capture.captureID))
        let engine = await c.daemon.store.captureEngine(id)
        let flowing = await eventually { (engine?.stats.blocksReceived ?? 0) > 2 }
        XCTAssertTrue(flowing, "samples flow before the stall")
        return (radio, capture)
    }

    private func waitCapture(_ c: DaemonClients, _ capture: Leyline_V1_Capture,
                             until done: (Leyline_V1_Capture) -> Bool) async throws -> Leyline_V1_Capture
    {
        var last = Leyline_V1_Capture()
        for _ in 0..<250 {
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if let cap = state.captures.first(where: { $0.captureID == capture.captureID }) {
                last = cap
                if done(cap) { return cap }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("the capture never got there: \(last.state) \(last.stateDetail)")
        return last
    }

    private func waitDevice(_ c: DaemonClients, _ id: String,
                            until done: (Leyline_V1_DeviceDescriptor) -> Bool) async throws -> Leyline_V1_DeviceDescriptor
    {
        var last = Leyline_V1_DeviceDescriptor()
        for _ in 0..<250 {
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if let d = state.devices.first(where: { $0.deviceID == id }) {
                last = d
                if done(d) { return d }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("the device never got there: \(last.state) \(last.stateDetail)")
        return last
    }

    private func eventually(timeoutMs: Int = 5000, _ cond: () async -> Bool) async -> Bool {
        for _ in 0..<(timeoutMs / 20) {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await cond()
    }
}
