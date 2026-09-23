// SPDX-License-Identifier: GPL-3.0-or-later

// The demod tap on the bulk plane: a channel's detector output, negotiated like any audio stream,
// echoed in the descriptor, and refused where there is no detector to read.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// Thrown when a bounded stream read runs past its deadline.
private struct StreamDeadlineExceeded: Error {}

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

    /// Polls `cond` every 20 ms until it holds or `timeoutMs` elapses.
    private func eventually(timeoutMs: Int = 5000, _ cond: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0 ..< (timeoutMs / 20) {
            if try await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await cond()
    }

    /// Bounds a read on a stream: a tap that stalls fails this test rather than hanging the suite
    /// until the runner gives up on it.
    private func withDeadline<T: Sendable>(seconds: Double, _ body: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                throw StreamDeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw StreamDeadlineExceeded() }
            return first
        }
    }

    /// One applied parameter write.
    private func write(_ c: DaemonClients, target: String, _ fill: (inout Leyline_V1_ParamWrite) -> Void) async throws {
        var w = Leyline_V1_ParamWrite()
        w.tag = 1
        w.targetID = target
        fill(&w)
        let message = w
        let summary = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
        XCTAssertEqual(summary.writesApplied, 1, "the write applied")
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
            XCTAssertEqual(desc.audio.fullScaleDeviationHz, 2_500,
                           "a 12.5 kHz NFM channel carries ±2.5 kHz, and the descriptor says so")
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let frames = try await self.withDeadline(seconds: 20) {
                try await c.bulk.stream(ref, metadata: testMetadata) { response in
                    var out: [Leyline_V1_Frame] = []
                    for try await f in response.messages {
                        out.append(f)
                        if out.count == 3 { break }
                    }
                    return out
                }
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

    /// A subscription that does not specify a tap gets the audio tap (what the speaker plays).
    func testDefaultTapIsAudio() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let (capture, channel) = try await self.fixtureChannel(c, mode: .nfm)
            // No tap specified: proto3 default, which is the speaker's audio.
            let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapAudio)
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc.audio.tap, .tapAudio)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        }
    }

    /// Full scale is the channel's own limit, so the descriptor answers a wide NFM channel with the
    /// ±5 kHz it can carry, both taps of one channel with the same number, and an amplitude mode
    /// with none: a client reads hertz off a tap without a full scale of its own.
    func testDescriptorCarriesTheChannelsFullScaleDeviation() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let (capture, narrow) = try await self.fixtureChannel(c, mode: .nfm)
            for tap in [Leyline_V1_AudioTap.tapDemod, .tapAudio] {
                let req = self.audioRequest(capture: capture.captureID, channel: narrow.channelID, tap: tap)
                let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
                XCTAssertEqual(desc.audio.fullScaleDeviationHz, 2_500, "\(tap) on a 12.5 kHz channel")
                var ref = Leyline_V1_StreamRef()
                ref.streamID = desc.streamID
                _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
            }
            for (mode, bandwidth, want) in [(Leyline_V1_DemodMode.nfm, UInt32(25_000), UInt32(5_000)),
                                            (.am, 12_500, 0)]
            {
                var cch = Leyline_V1_CreateChannelRequest()
                cch.captureID = capture.captureID
                cch.offsetHz = 100_000
                cch.mode = mode
                cch.bandwidthHz = bandwidth
                let channel = try await c.control.createChannel(cch, metadata: testMetadata)
                let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapAudio)
                let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
                XCTAssertEqual(desc.audio.fullScaleDeviationHz, want, "\(mode) at \(bandwidth) Hz")
                var ref = Leyline_V1_StreamRef()
                ref.streamID = desc.streamID
                _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
            }
        }
    }

    /// Destroying the channel ends its demod tap: the stream's sample source is gone.
    func testDestroyingTheChannelEndsTheDemodTapStream() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let (capture, channel) = try await self.fixtureChannel(c, mode: .nfm)
            let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapDemod)
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let ended = LockedValue(false)
            let reader = Task {
                do {
                    try await c.bulk.stream(ref, metadata: testMetadata) { response in
                        for try await _ in response.messages {}
                    }
                } catch {}
                ended.value = true
            }
            var dc = Leyline_V1_DestroyChannelRequest()
            dc.channelID = channel.channelID
            _ = try await c.control.destroyChannel(dc, metadata: testMetadata)
            let closed = await self.eventually { ended.value }
            XCTAssertTrue(closed, "destroying the channel ends the demod tap stream")
            reader.cancel()
            _ = await reader.value
        }
    }

    /// A capture-rate change re-plans the channel at a new audio rate, so the descriptor this
    /// stream was handed is no longer valid and the stream ends for a fresh subscription.
    func testCaptureRateChangeEndsTheDemodTapStream() async throws {
        try await withDaemon { c in
            // A virtual device rather than the fixture: the rate has to be writable for the
            // re-plan this is about, and a file plays at the one rate its sidecar specifies.
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapDemod)
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc.audio.sampleRate, 48_000)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let ended = LockedValue(false)
            let reader = Task {
                do {
                    try await c.bulk.stream(ref, metadata: testMetadata) { response in
                        for try await _ in response.messages {}
                    }
                } catch {}
                ended.value = true
            }
            try await self.write(c, target: capture.captureID) { $0.captureSampleRate = 1_024_000 }
            let closed = await self.eventually { ended.value }
            XCTAssertTrue(closed, "the tap negotiated at 48 kHz ends when the capture rate moves")
            reader.cancel()
            _ = await reader.value
            let again = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(again.audio.sampleRate, 51_200, "a fresh subscription carries the new audio rate")
            XCTAssertEqual(again.audio.tap, .tapDemod)
            var ref2 = Leyline_V1_StreamRef()
            ref2.streamID = again.streamID
            _ = try await c.bulk.unsubscribe(ref2, metadata: testMetadata)
        }
    }

    /// Two capture rates can plan to the same audio rate, and audio frames scale their spans by the
    /// capture rate, so the stream has to end on the capture rate moving rather than on the audio
    /// rate holding still.
    func testCaptureRateChangeEndsTheAudioStreamWhenTheAudioRateHolds() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            try await self.write(c, target: capture.captureID) { $0.captureSampleRate = 1_024_000 }
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let req = self.audioRequest(capture: capture.captureID, channel: channel.channelID, tap: .tapAudio)
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let ended = LockedValue(false)
            let reader = Task {
                do {
                    try await c.bulk.stream(ref, metadata: testMetadata) { response in
                        for try await _ in response.messages {}
                    }
                } catch {}
                ended.value = true
            }
            try await self.write(c, target: capture.captureID) { $0.captureSampleRate = 2_048_000 }
            let closed = await self.eventually { ended.value }
            XCTAssertTrue(closed, "the stream ends when the capture rate doubles under it")
            reader.cancel()
            _ = await reader.value
            let again = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(again.audio.sampleRate, desc.audio.sampleRate, "the audio rate never moved")
            var ref2 = Leyline_V1_StreamRef()
            ref2.streamID = again.streamID
            _ = try await c.bulk.unsubscribe(ref2, metadata: testMetadata)
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
