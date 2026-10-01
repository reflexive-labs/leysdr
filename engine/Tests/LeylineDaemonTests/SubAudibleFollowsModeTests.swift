// SPDX-License-Identifier: GPL-3.0-or-later

// The tone detector is decided by the mode, at creation and again on every mode write: a channel
// that starts as AM and is written to NFM looks for a tone from then on, and one written away
// from NFM stops. The Mac app keeps one channel across bands and writes the mode, which is how
// the bug of a channel that never ran tone detection was found (2026-09-20).

import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class SubAudibleFollowsModeDaemonTests: XCTestCase {
    func testAModeWriteReDecidesTheToneDetector() async throws {
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
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = cap.captureID
            cch.offsetHz = 100_000
            cch.mode = .am
            cch.bandwidthHz = 10_000
            let ch = try await c.control.createChannel(cch, metadata: testMetadata)
            XCTAssertFalse(ch.subaudibleDetect, "AM never carries CTCSS")

            func writeMode(_ mode: Leyline_V1_DemodMode, tag: UInt64) async throws {
                _ = try await c.control.writeParams(metadata: testMetadata) { writer in
                    var w = Leyline_V1_ParamWrite()
                    w.tag = tag
                    w.targetID = ch.channelID
                    w.mode = mode
                    try await writer.write(w)
                }
            }
            try await writeMode(.nfm, tag: 71)
            let armed = await events.waitFor { ev in
                if case .channel(let x)? = ev.body { return x.channelID == ch.channelID && x.mode == .nfm && x.subaudibleDetect }
                return false
            }
            XCTAssertNotNil(armed, "written to NFM, the channel looks for a tone")
            try await writeMode(.am, tag: 72)
            let disarmed = await events.waitFor { ev in
                if case .channel(let x)? = ev.body { return x.channelID == ch.channelID && x.mode == .am && !x.subaudibleDetect }
                return false
            }
            XCTAssertNotNil(disarmed, "written back to AM, it stops")
            await events.stop()
        }
    }
}
