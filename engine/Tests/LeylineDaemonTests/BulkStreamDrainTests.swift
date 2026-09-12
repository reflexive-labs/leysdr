// SPDX-License-Identifier: GPL-3.0-or-later

import EngineCore
import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// What the bulk plane promises about the last bytes of a stream: a frame spans exactly the samples
/// it carries, and audio produced while the source is closing still reaches the reader.
final class BulkStreamDrainTests: XCTestCase {
    /// A block too big for a slot is truncated, so the frame must claim only what it carries --
    /// otherwise the client's sample-index arithmetic drifts by the samples that never arrived.
    func testIQTapReportsOnlyTheSamplesItSent() {
        let slotSamples = 64
        let ring = FrameRing(slots: 2, slotBytes: slotSamples * 8)
        let tap = IQFrameTap(id: StreamID(), ring: ring)
        let capture = CaptureID()
        let storage = SampleStorage(capacity: slotSamples * 2, format: .cf32)

        tap.write(iq: storage.view(count: slotSamples), at: SampleTime(captureID: capture, sampleIndex: 0))
        let fits = ring.pop()
        XCTAssertEqual(fits?.sampleCount, UInt64(slotSamples))
        XCTAssertEqual(fits?.payload.count, slotSamples * 8)

        tap.write(iq: storage.view(count: slotSamples * 2), at: SampleTime(captureID: capture, sampleIndex: 1000))
        let truncated = ring.pop()
        XCTAssertEqual(truncated?.payload.count, slotSamples * 8, "payload is clamped to the slot")
        XCTAssertEqual(truncated?.sampleCount, UInt64(slotSamples), "the span matches the payload, not the block")
    }

    /// The channel's audio callback runs on another thread, so a push can land as the source is
    /// finished and its wakeup is dropped. The reader must still hand those samples over instead of
    /// leaving the tail of a transmission in the ring.
    func testAudioStreamDeliversAPushThatRacesFinish() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing: \(fixture)") }
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
            cch.offsetHz = 0
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let capID = CaptureID(string: capture.captureID)!
            let chanID = ChannelID(string: channel.channelID)!
            let maybeEngine = await c.daemon.store.channelEngine(chanID)
            let engine = try XCTUnwrap(maybeEngine)

            let audio = AudioFrameSource(captureRate: capture.sampleRate, audioRate: engine.audioRate)
            var desc = Leyline_V1_StreamDescriptor()
            desc.kind = .audio
            desc.audio.sampleRate = engine.audioRate
            desc.audio.format = .s16
            let sub = BulkSubscription(id: StreamID(), descriptor: desc, captureID: capID,
                                       channelID: chanID, source: .audio(audio, engine))

            // Finish first, then push: a yield after `finish()` is a no-op, which is exactly the
            // wakeup the reader never gets when the callback races teardown.
            audio.finish()
            let samples = 128
            let storage = SampleStorage(capacity: samples, format: .f32)
            audio.sink.write(storage.view(count: samples), at: SampleTime(captureID: capID, sampleIndex: 4096))

            let frames = FrameBox()
            try await StreamRegistry.run(sub) { frames.append($0) }
            XCTAssertEqual(frames.count, 1, "the last audio push must reach the reader")
            XCTAssertEqual(frames.first?.payload.count, samples * 2, "S16 payload for every sample pushed")
        }
    }
}

/// Collects frames from the nonisolated reader loop.
private final class FrameBox: @unchecked Sendable {
    private var frames: [Leyline_V1_Frame] = []
    func append(_ f: Leyline_V1_Frame) { frames.append(f) }
    var count: Int { frames.count }
    var first: Leyline_V1_Frame? { frames.first }
}
