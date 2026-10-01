// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs on a borrowed channel: the channel going away, and the channel left alone.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
    // MARK: The channel going away under a recording

    /// The channel form borrows: when its owner closes the channel the job ends COMPLETED rather
    /// than orphaning a sink, and the recording is complete (docs/design/recording.md, "The wire":
    /// "the job borrows the channel and does not own it").
    ///
    /// The retune counterpart of this -- a capture moved out from under a recording, which degrades
    /// the job and logs the gap -- needs a radio that can be tuned somewhere else, and a file
    /// device's tuning range is the single frequency its fixture was recorded at. It is covered by
    /// the client-side guard's test in `go/internal/cli` and on a real dongle by the release
    /// checklist.
    func testTheChannelClosingEndsTheRecording() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let device = try XCTUnwrap(state.devices.first)
            var capture = Leyline_V1_CreateCaptureRequest()
            capture.deviceID = device.deviceID
            capture.centerHz = 146_520_000
            capture.sampleRate = device.sampleRates.first ?? 2_400_000
            let made = try await c.control.createCapture(capture, metadata: testMetadata)
            var channel = Leyline_V1_CreateChannelRequest()
            channel.captureID = made.captureID
            channel.offsetHz = 100_000
            channel.mode = .nfm
            let listening = try await c.control.createChannel(channel, metadata: testMetadata)

            var config = Leyline_V1_RecordConfig()
            config.channelID = listening.channelID
            let started = try await self.start(c, config)
            try await Task.sleep(nanoseconds: 600_000_000)

            // The listener stops listening.
            var destroy = Leyline_V1_DestroyChannelRequest()
            destroy.channelID = listening.channelID
            _ = try await c.control.destroyChannel(destroy, metadata: testMetadata)

            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            XCTAssertTrue(done.statusDetail.contains("channel"), done.statusDetail)
            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.endedBy, "channel ended")
            XCTAssertEqual(manifest.parts.count, 1, "what it heard before the channel closed is kept")
            XCTAssertFalse(WAVHeader.needsRepair(path: dir + "/" + started.jobID + "/" + manifest.parts[0].file))
        }
    }

    // MARK: The channel form

    func testRecordingABorrowedChannelLeavesItAlone() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let device = try XCTUnwrap(state.devices.first)
            var capture = Leyline_V1_CreateCaptureRequest()
            capture.deviceID = device.deviceID
            capture.centerHz = 146_520_000
            capture.sampleRate = device.sampleRates.first ?? 2_400_000
            let made = try await c.control.createCapture(capture, metadata: testMetadata)
            var channel = Leyline_V1_CreateChannelRequest()
            channel.captureID = made.captureID
            channel.offsetHz = 100_000
            channel.mode = .nfm
            let listening = try await c.control.createChannel(channel, metadata: testMetadata)

            var config = Leyline_V1_RecordConfig()
            config.channelID = listening.channelID
            config.durationMs = 800
            let started = try await self.start(c, config)
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.frequencyHz, recordFrequencyHz, "the channel's own frequency")
            XCTAssertEqual(manifest.mode, "NFM", "and its mode")
            XCTAssertEqual(manifest.parts.count, 1)

            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(after.channels.count, 1, "the listener still has their channel")
            XCTAssertEqual(after.channels.first?.channelID, listening.channelID)
            XCTAssertEqual(after.captures.count, 1, "and their radio")
        }
    }
}
