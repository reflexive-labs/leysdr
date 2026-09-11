// An FFT stream whose source is a channel: the spectrum of what that channel produces, negotiated
// on the same params as the band's, echoed in the descriptor, and refused where there is no audio.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// Thrown when a bounded stream read runs past its deadline.
private struct StreamDeadlineExceeded: Error {}

final class AudioSpectrumStreamDaemonTests: XCTestCase {
    private func fixtureChannel(_ c: DaemonClients, mode: Leyline_V1_DemodMode)
        async throws -> Leyline_V1_Channel
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
        return try await c.control.createChannel(cch, metadata: testMetadata)
    }

    private func spectrumRequest(channel: String, tap: Leyline_V1_AudioTap,
                                 bins: UInt32 = 512, rows: Double = 10) -> Leyline_V1_SubscribeRequest
    {
        var req = Leyline_V1_SubscribeRequest()
        req.channelID = channel
        req.kind = .fft
        req.policy = .latestWins
        req.transport = .grpc
        req.fft.bins = bins
        req.fft.rowsPerSecond = rows
        req.fft.binFormat = .dbF32
        req.fft.tap = tap
        return req
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

    /// The descriptor answers the whole negotiation -- tap, bins, rate and the axis the rows are
    /// on -- and the rows themselves arrive at the negotiated width.
    func testChannelFFTEchoesTheDescriptorAndDeliversRows() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let channel = try await self.fixtureChannel(c, mode: .nfm)
            let desc = try await c.bulk.subscribe(self.spectrumRequest(channel: channel.channelID, tap: .tapDemod),
                                                  metadata: testMetadata)
            XCTAssertEqual(desc.fft.tap, .tapDemod, "the descriptor names the tap it serves")
            XCTAssertEqual(desc.fft.bins, 512)
            XCTAssertEqual(desc.fft.rowsPerSecond, 10)
            XCTAssertEqual(desc.fft.accumulation, .rowSnapshot, "a row is one transform of one window")
            XCTAssertEqual(desc.fft.looksPerRow, 1)
            // 48 kHz audio: the row runs from 0 Hz to 24 kHz, said in the terms every FFT reader
            // already understands.
            XCTAssertEqual(desc.centerHz, 12_000)
            XCTAssertEqual(desc.spanHz, 24_000)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let frames = try await self.withDeadline(seconds: 20) {
                try await c.bulk.stream(ref, metadata: testMetadata) { response in
                    var out: [Leyline_V1_Frame] = []
                    for try await f in response.messages {
                        out.append(f)
                        if out.count == 2 { break }
                    }
                    return out
                }
            }
            XCTAssertEqual(frames.count, 2)
            XCTAssertTrue(frames.allSatisfy { $0.payload.count == 512 * 4 }, "one f32 per bin")
            // The fixture's discriminator carries a 1 kHz tone: somewhere in the row is a peak well
            // above the floor an empty row reads.
            let loud = frames.contains { frame in
                frame.payload.withUnsafeBytes { raw in raw.bindMemory(to: Float.self).contains { $0 > -60 } }
            }
            XCTAssertTrue(loud, "the row is a spectrum, not a floor")
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        }
    }

    /// A raw-IQ channel produces no audio, so there is no spectrum of it to take: the band is what
    /// a capture-sourced FFT already answers.
    func testRawIQChannelRefusesAnFFT() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let channel = try await self.fixtureChannel(c, mode: .rawIq)
            for tap in [Leyline_V1_AudioTap.tapAudio, .tapDemod] {
                do {
                    _ = try await c.bulk.subscribe(self.spectrumRequest(channel: channel.channelID, tap: tap),
                                                   metadata: testMetadata)
                    XCTFail("expected a refusal for \(tap)")
                } catch {
                    XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT", "\(tap)")
                }
            }
        }
    }

    /// A row is one transform of one window, so every accumulation the daemon knows is answered
    /// with the snapshot it actually gets -- and one it does not know is refused, as on the band.
    func testChannelFFTAnswersKnownAccumulationsAndRefusesUnknownOnes() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_pl.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let channel = try await self.fixtureChannel(c, mode: .nfm)
            for acc in [Leyline_V1_FftAccumulation.unspecified, .rowSnapshot, .rowMean, .rowMax] {
                var req = self.spectrumRequest(channel: channel.channelID, tap: .tapAudio)
                req.fft.accumulation = acc
                let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
                XCTAssertEqual(desc.fft.accumulation, .rowSnapshot, "\(acc)")
                var ref = Leyline_V1_StreamRef()
                ref.streamID = desc.streamID
                _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
            }
            var bad = self.spectrumRequest(channel: channel.channelID, tap: .tapAudio)
            bad.fft.accumulation = .UNRECOGNIZED(99)
            do {
                _ = try await c.bulk.subscribe(bad, metadata: testMetadata)
                XCTFail("expected a refusal for an unknown accumulation")
            } catch {
                XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
            }
        }
    }

    /// A capture-rate change re-plans the channel at a new audio rate, so the axis this stream's
    /// descriptor named is no longer true and the stream ends for a fresh subscription.
    func testCaptureRateChangeEndsTheChannelSpectrumStream() async throws {
        try await withDaemon { c in
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
            let desc = try await c.bulk.subscribe(self.spectrumRequest(channel: channel.channelID, tap: .tapAudio),
                                                  metadata: testMetadata)
            XCTAssertEqual(desc.spanHz, 24_000)
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
            var w = Leyline_V1_ParamWrite()
            w.tag = 1
            w.targetID = capture.captureID
            w.captureSampleRate = 1_024_000
            let message = w
            _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
            let closed = await self.eventually { ended.value }
            XCTAssertTrue(closed, "a spectrum negotiated on a 48 kHz axis ends when the rate moves")
            reader.cancel()
            _ = await reader.value
        }
    }
}
