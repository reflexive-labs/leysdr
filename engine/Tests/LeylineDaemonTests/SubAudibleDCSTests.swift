// SPDX-License-Identifier: GPL-3.0-or-later

// DCS on the wire: the daemon playing a real handheld sending DCS 023 publishes a `SubAudible` with
// `kind = SUB_AUDIBLE_DCS`, the code, the polarity and the sample time the lock was first reached
// (docs/design/signal-views.md, "DCS"). The take is 230 MB and gitignored, so the test runs only
// where `LEYLINE_CAPTURES` names the directory holding it; the decoder's own tests run from the
// committed tap everywhere.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class SubAudibleDCSDaemonTests: XCTestCase {
    func testTheHandheldsDCSCodeReachesTheWire() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LEYLINE_CAPTURES"], !dir.isEmpty else {
            throw XCTSkip("set LEYLINE_CAPTURES to the directory holding the real-radio captures")
        }
        let take = dir + "/ht-dcs-023.cf32"
        guard FileManager.default.fileExists(atPath: take) else { throw XCTSkip("no capture at \(take)") }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = take
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 462_562_500
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 0
            cch.mode = .nfm
            cch.bandwidthHz = 12_500
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            XCTAssertTrue(channel.subaudibleDetect)

            var sub = Leyline_V1_TelemetrySubscription()
            sub.channelID = channel.channelID
            sub.types = [.subAudible]
            // The take keys up at 2.4 s and locks about half a second later; twenty messages at
            // one a second of heartbeat is far more than that needs.
            let msgs: [Leyline_V1_SubAudible] = try await c.telemetry.subscribe(sub, metadata: testMetadata) { response in
                var out: [Leyline_V1_SubAudible] = []
                for try await m in response.messages {
                    guard case .subAudible(let s)? = m.body else { continue }
                    XCTAssertEqual(m.time.captureID, capture.captureID, "invariant 5: on the capture's timebase")
                    XCTAssertGreaterThan(m.time.sampleIndex, 0, "the hop is stamped with its sample time")
                    out.append(s)
                    if s.kind == .subAudibleDcs || out.count >= 20 { break }
                }
                return out
            }
            let lock = try XCTUnwrap(msgs.last.flatMap { $0.kind == .subAudibleDcs ? $0 : nil },
                                     "no DCS lock in \(msgs.count) messages: \(msgs.map(\.kind))")
            XCTAssertEqual(lock.dcsCode, 23)
            XCTAssertFalse(lock.dcsInverted)
            XCTAssertTrue(lock.toneHz.isNaN, "a DCS lock claims no tone")
            XCTAssertEqual(lock.standardToneHz, 0)
            XCTAssertEqual(lock.deviationHz, 600, accuracy: 100)
            XCTAssertGreaterThan(lock.confidence, 0.5)
            XCTAssertEqual(lock.firstSeen.captureID, capture.captureID)
            XCTAssertGreaterThan(lock.firstSeen.sampleIndex, 0)
            XCTAssertFalse(msgs.contains { $0.kind == .subAudibleCtcss }, "the take carries no CTCSS")
            print("SubAudible DCS on the wire: code \(lock.dcsCode) inverted \(lock.dcsInverted), deviation "
                + String(format: "%.0f Hz, confidence %.2f, first_seen sample %llu (%.3f s)", lock.deviationHz, lock.confidence,
                         lock.firstSeen.sampleIndex, Double(lock.firstSeen.sampleIndex) / 2_400_000))
        }
    }
}
