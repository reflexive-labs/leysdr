// SPDX-License-Identifier: GPL-3.0-or-later

import EngineCore
import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// `CaptureLevel` on the telemetry plane: the capture's rail count and peak, four times a second,
/// on the sample timebase, from the daemon playing a fixture.
final class CaptureLevelTests: XCTestCase {
    func testAFixtureWithNoRailsReportsNoClipping() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture missing: \(fixture) (run leyfix generate)")
        }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)

            var sub = Leyline_V1_TelemetrySubscription()
            sub.captureID = capture.captureID
            sub.types = [.captureLevel]
            let levels: [Leyline_V1_TelemetryMsg] = try await c.telemetry.subscribe(sub, metadata: testMetadata) { response in
                var out: [Leyline_V1_TelemetryMsg] = []
                for try await m in response.messages {
                    out.append(m)
                    if out.count >= 3 { break }
                }
                return out
            }
            XCTAssertEqual(levels.count, 3)
            for (i, m) in levels.enumerated() {
                XCTAssertEqual(m.seq, UInt64(i + 1), "one reading per generation, no gaps and no repeats")
                XCTAssertEqual(m.time.captureID, capture.captureID, "invariant 5: the reading is on the capture's timebase")
                guard case .captureLevel(let level)? = m.body else { XCTFail("not a CaptureLevel: \(m)"); continue }
                XCTAssertEqual(level.captureID, capture.captureID)
                // The fixture is a -20 dBFS tone over a -60 dBFS floor: nothing near a rail.
                XCTAssertEqual(level.clippedSamples, 0)
                // A quarter of a second at 2.4 MSPS, plus the block that closed the interval.
                XCTAssertGreaterThanOrEqual(level.totalSamples, 600_000)
                XCTAssertLessThan(level.totalSamples, 600_000 + UInt64(CaptureDSPCore.blockSize) * 2)
                XCTAssertGreaterThan(level.peakDbfs, -30, "a -20 dBFS tone peaks near -20 dBFS, got \(level.peakDbfs)")
                XCTAssertLessThan(level.peakDbfs, -10)
            }
            XCTAssertGreaterThan(levels[2].time.sampleIndex, levels[0].time.sampleIndex)
            XCTAssertEqual(levels[1].time.sampleIndex - levels[0].time.sampleIndex,
                           levels[1].captureLevel.totalSamples, "the interval ends where its sample count says")
        }
    }

    /// A channel-scoped subscription carries channel telemetry only; the capture's level is sent
    /// with the capture's other telemetry, on a capture or daemon scope.
    func testAChannelScopeCarriesNoCaptureLevel() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture missing: \(fixture) (run leyfix generate)")
        }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)

            var sub = Leyline_V1_TelemetrySubscription()
            sub.channelID = channel.channelID
            sub.types = [.captureLevel, .meter]
            let msgs: [Leyline_V1_TelemetryMsg] = try await c.telemetry.subscribe(sub, metadata: testMetadata) { response in
                var out: [Leyline_V1_TelemetryMsg] = []
                for try await m in response.messages {
                    out.append(m)
                    if out.count >= 6 { break }
                }
                return out
            }
            XCTAssertEqual(msgs.count, 6)
            XCTAssertTrue(msgs.allSatisfy { if case .meter? = $0.body { return true } else { return false } },
                          "a channel scope sent something other than meters: \(msgs.map(\.body))")
        }
    }
}
