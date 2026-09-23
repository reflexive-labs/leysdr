// SPDX-License-Identifier: GPL-3.0-or-later

// Gain writes through WriteParams: the element rule the contract states (`common.proto`,
// `GainWrite`: an empty element is the first the device lists), on a radio with a gain stage and
// on one without. The scan path has the same rule and its own test (ScanSweepTests).

import EngineCore
import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

final class GainWriteDaemonTests: XCTestCase {
    /// A write that names no element lands on the first the device lists, and the capture event
    /// confirms it under that name.
    func testAnEmptyElementIsTheFirstTheDeviceLists() async throws {
        try await withDaemon { c in
            let device = SyntheticBandDevice(carriers: [])
            let id = try await c.daemon.registry.attachVirtualDevice(device).descriptor.id
            try await Task.sleep(nanoseconds: 200_000_000)
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = id.string
            cc.centerHz = 146_000_000
            let cap = try await c.control.createCapture(cc, metadata: testMetadata)

            let summary = try await c.control.writeParams(metadata: testMetadata) { writer in
                var w = Leyline_V1_ParamWrite()
                w.tag = 61
                w.targetID = cap.captureID
                w.gain = .with { $0.db = 20 }
                try await writer.write(w)
            }
            XCTAssertEqual(summary.writesApplied, 1)
            let manual = await events.waitFor { ev in
                if case .capture(let c)? = ev.body {
                    return c.captureID == cap.captureID && c.gains.contains { $0.element == "TUNER" && !$0.auto && $0.db == 20 }
                }
                return false
            }
            XCTAssertNotNil(manual, "the capture event carries TUNER at 20 dB, manual")

            let auto = try await c.control.writeParams(metadata: testMetadata) { writer in
                var w = Leyline_V1_ParamWrite()
                w.tag = 62
                w.targetID = cap.captureID
                w.gain = .with { $0.auto = true }
                try await writer.write(w)
            }
            XCTAssertEqual(auto.writesApplied, 1)
            let confirmed = await events.waitFor { ev in
                if case .capture(let c)? = ev.body {
                    return c.captureID == cap.captureID && c.gains.contains { $0.element == "TUNER" && $0.auto }
                }
                return false
            }
            XCTAssertNotNil(confirmed, "the capture event carries TUNER on auto")
            await events.stop()
        }
    }

    /// A recording has no gain stage, so the empty element resolves to nothing and the refusal
    /// explains that rather than naming an element that was never given.
    func testARadioWithNoGainStageRefusesTheEmptyElement() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_tone.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let cap = try await c.control.createCapture(cc, metadata: testMetadata)
            let summary = try await c.control.writeParams(metadata: testMetadata) { writer in
                var w = Leyline_V1_ParamWrite()
                w.tag = 63
                w.targetID = cap.captureID
                w.gain = .with { $0.db = 20 }
                try await writer.write(w)
            }
            XCTAssertEqual(summary.writesApplied, 0)
            let rejected = await events.waitFor { ev in
                if case .writeRejected(let wr)? = ev.body { return wr.tag == 63 }
                return false
            }
            XCTAssertEqual(rejected?.writeRejected.error.code, "GAIN_ELEMENT_UNKNOWN")
            XCTAssertEqual(rejected?.writeRejected.error.message, "this radio reports no gain elements")
            await events.stop()
        }
    }
}
