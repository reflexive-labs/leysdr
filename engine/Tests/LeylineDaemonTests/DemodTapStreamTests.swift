// The demod tap on the bulk plane: a channel's detector output, negotiated like any audio stream,
// echoed in the descriptor, and refused where there is no detector to read.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import XCTest

final class DemodTapStreamDaemonTests: XCTestCase {
    /// A channel on the PL fixture, with the capture it belongs to.
    private func fixtureChannel(_ c: DaemonClients, mode: Leyline_V1_DemodMode)
        async throws -> (capture: Leyline_V1_Capture, channel: Leyline_V1_Channel)
    {
        var attach = Leyline_V1_AttachFileDeviceRequest()
        attach.path = fixturePath("nfm_pl.cf32")
        attach.loop = true
        let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
        var cc = Leyline_V1_CreateCaptureRequest()
        cc.deviceID = device.deviceID
        cc.centerHz = 146_520_000
        let capture = try await c.control.createCapture(cc, metadata: testMetadata)
        var cch = Leyline_V1_CreateChannelRequest()
        cch.captureID = capture.captureID
        cch.offsetHz = 100_000
        cch.mode = mode
        return (capture, try await c.control.createChannel(cch, metadata: testMetadata))
    }

    private func audioRequest(capture: String, channel: String, tap: Leyline_V1_AudioTap) -> Leyline_V1_SubscribeRequest {
        var req = Leyline_V1_SubscribeRequest()
        req.captureID = capture
        req.channelID = channel
        req.kind = .audio
        req.policy = .latestWins
        req.transport = .grpc
        req.audio.format = .f32
        req.audio.tap = tap
        return req
    }

    /// The descriptor answers with the tap it serves, and the stream carries the detector's samples.
    func testDemodTapDeliversFramesAndEchoesTheTap() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let (capture, channel) = try await self.fixtureChannel(c, mode: .nfm)
            let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapDemod)
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc.audio.tap, .tapDemod, "the descriptor names the tap it serves")
            XCTAssertEqual(desc.audio.sampleRate, 48_000, "the demod tap runs at the channel's audio rate")
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let frames: [Leyline_V1_Frame] = try await c.bulk.stream(ref, metadata: testMetadata) { response in
                var out: [Leyline_V1_Frame] = []
                for try await f in response.messages {
                    out.append(f)
                    if out.count == 3 { break }
                }
                return out
            }
            XCTAssertEqual(frames.count, 3, "the tap flows like any audio stream")
            XCTAssertTrue(frames.allSatisfy { !$0.payload.isEmpty })
            // The fixture's discriminator carries a 1 kHz tone at 2.5 kHz deviation: nothing like silence.
            let loud = frames.contains { frame in
                frame.payload.withUnsafeBytes { raw in
                    raw.bindMemory(to: Float.self).contains { abs($0) > 0.05 }
                }
            }
            XCTAssertTrue(loud, "the detector's output is not zeros")
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        }
    }

    /// The default is unchanged: a subscription that says nothing about a tap gets the speaker's audio.
    func testDefaultTapIsAudio() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let (capture, channel) = try await self.fixtureChannel(c, mode: .nfm)
            // Nothing said about a tap: proto3 default, which is the speaker's audio.
            let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapAudio)
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc.audio.tap, .tapAudio)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        }
    }

    /// A raw-IQ channel runs no detector, so the tap is refused instead of streaming silence.
    func testDemodTapRefusedOnRawIQChannel() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let (capture, channel) = try await self.fixtureChannel(c, mode: .rawIq)
            let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapDemod)
            do {
                let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
                XCTFail("expected a refusal, got stream \(desc.streamID)")
            } catch {
                let detail = errorCode(error)
                XCTAssertEqual(detail.code, "INVALID_ARGUMENT")
                XCTAssertEqual(detail.trailer?.target, channel.channelID)
            }
        }
    }
}
