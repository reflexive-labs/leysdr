import Foundation
import XCTest
@testable import EngineCore

final class ChannelTests: XCTestCase {
    private func nfmTonePath() throws -> String {
        let p = Fixtures.dir + "/nfm_tone.cf32"
        guard FileManager.default.fileExists(atPath: p) else { throw XCTSkip("nfm_tone fixture missing") }
        return p
    }

    /// Narrow modes cannot ask for more than 0.9·r2: the channel would be filtered narrower than it reports.
    func testNarrowBandwidthAboveAudioRateIsRejected() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        do {
            _ = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 50_000, mode: .nfm))
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .am)) as! DefaultChannelEngine
        let core = try XCTUnwrap(channel.slot.load())
        do {
            try await channel.update(ChannelConfig(offsetHz: 100_000, bandwidthHz: 50_000, mode: .am))
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let kept = await channel.config
        XCTAssertEqual(kept.bandwidthHz, 12_500)
        XCTAssertTrue(channel.slot.load() === core)
        // WFM is the wide path.
        _ = try await capture.addChannel(ChannelConfig(offsetHz: 300_000, bandwidthHz: 200_000, mode: .wfm))
    }

    func testOffsetOutsideCaptureIsRejected() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        do {
            _ = try await capture.addChannel(ChannelConfig(offsetHz: 1_300_000, bandwidthHz: 12_500, mode: .nfm))
            XCTFail("expected OFFSET_OUT_OF_CAPTURE")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "OFFSET_OUT_OF_CAPTURE")
        }
        let channels = await capture.channels
        XCTAssertTrue(channels.isEmpty)
    }

    func testRetuneMovesChannelOutOfCaptureAndBack() async throws {
        let device = BurstDevice(blocks: 0)
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        XCTAssertEqual(channel.audioRate, 48_000)
        var state = await channel.state
        XCTAssertEqual(state, .active)
        XCTAssertNotNil(channel.slot.load())

        try await capture.retune(centerHz: 101_500_000)
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        XCTAssertNil(channel.slot.load(), "out-of-capture channel must be skipped by the DSP thread")
        var config = await channel.config
        XCTAssertEqual(config.offsetHz, 100_000, "offset unchanged while out of capture")

        try await capture.retune(centerHz: 100_500_000)
        state = await channel.state
        XCTAssertEqual(state, .active)
        config = await channel.config
        XCTAssertEqual(config.offsetHz, -400_000, "channel keeps its absolute frequency (100.1 MHz)")
        XCTAssertNotNil(channel.slot.load())
        let snap = await capture.snapshot
        XCTAssertEqual(snap.centerHz, 100_500_000)
        await capture.stop()
    }

    func testUpdateInPlaceVersusStructural() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        let sink = NullSink()
        try await channel.attach(sink)
        let core1 = try XCTUnwrap(channel.slot.load())
        // Squelch/AGC-only change: same core.
        try await channel.update(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: -50, agc: .manual))
        XCTAssertTrue(channel.slot.load() === core1)
        // Structural change: new core, sinks carried over, audio rate re-derived.
        try await channel.update(ChannelConfig(offsetHz: 200_000, bandwidthHz: 10_000, mode: .am, squelchDB: -50))
        let core2 = try XCTUnwrap(channel.slot.load())
        XCTAssertFalse(core2 === core1)
        XCTAssertEqual(core2.config.mode, .am)
        XCTAssertEqual(core2.currentSinks.count, 1)
        XCTAssertEqual(channel.audioRate, 48_000)
        let sinks = await channel.sinks
        XCTAssertEqual(sinks.count, 1)
        await channel.detach(sink.id)
        let after = await channel.sinks
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(core2.currentSinks.count, 0)
        await capture.stop()
    }

    /// A PCM-only sink (system audio) must never receive a raw-IQ channel's cf32 blocks: attach to a
    /// raw-IQ channel is refused, and so is switching a channel to raw IQ while one is attached.
    func testPCMOnlySinkRejectedOnRawIQChannel() async throws {
        final class PCMOnlyNull: PCMOnlyAudioSink, @unchecked Sendable {
            let id = SinkID()
            func write(_ audio: SampleBuffer, at time: SampleTime) {}
            func flush() async {}
            func closeSink() async {}
        }
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        let raw = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .rawIQ)) as! DefaultChannelEngine
        do {
            try await raw.attach(PCMOnlyNull())
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let rawSinks = await raw.sinks
        XCTAssertTrue(rawSinks.isEmpty)
        // A plain sink is still fine on raw IQ.
        try await raw.attach(NullSink())

        let nfm = try await capture.addChannel(ChannelConfig(offsetHz: 200_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        try await nfm.attach(PCMOnlyNull())
        do {
            try await nfm.update(ChannelConfig(offsetHz: 200_000, bandwidthHz: 12_500, mode: .rawIQ))
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let cfg = await nfm.config
        XCTAssertEqual(cfg.mode, .nfm)
        await capture.stop()
    }

    func testSquelchTelemetryTransitionsAndZeros() async throws {
        let path = try nfmTonePath()
        let device = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let capture = DefaultCaptureEngine(device: device, centerHz: UInt64(device.sidecar.centerHz), sampleRate: UInt64(device.sidecar.sampleRate))
        // Threshold far above the −20 dBFS tone: squelch stays closed, audio must be all zeros.
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: 0)) as! DefaultChannelEngine
        let collector = AudioCollector()
        try await channel.attach(collector.sink)
        let events = Task<[ChannelTelemetry], Never> {
            var out: [ChannelTelemetry] = []
            for await t in channel.telemetry() { out.append(t) }
            return out
        }
        try await capture.start()
        let deadline = Date().addingTimeInterval(5)
        while collector.count < 9600, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(collector.all.allSatisfy { $0 == 0 }, "closed squelch must write zeros")
        // Open it: threshold below the signal → a .squelch(open: true) transition and non-zero audio.
        try await channel.update(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40))
        let before = collector.count
        while collector.count < before + 9600, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await capture.stop()
        let all = await events.value
        let opens = all.compactMap { if case let .squelch(_, open) = $0 { return open } else { return nil } }
        XCTAssertEqual(opens.last, true, "expected a squelch-open transition after lowering the threshold: \(opens)")
        let meters = all.filter { if case .meter = $0 { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(meters.count, 3, "meter cadence is 100 ms of samples")
        XCTAssertTrue(collector.all.suffix(4800).contains { $0 != 0 }, "audio flows once open")
        let state = await channel.state
        XCTAssertEqual(state, .active)
    }

    func testStopLeavesNoEngineThreads() async throws {
        let path = try nfmTonePath()
        let device = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let capture = DefaultCaptureEngine(device: device, centerHz: UInt64(device.sidecar.centerHz), sampleRate: UInt64(device.sidecar.sampleRate))
        _ = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm))
        try await capture.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(capture.core.isRunning)
        XCTAssertTrue(Self.engineThreadNames().contains { $0.hasPrefix("leyline.dsp") }, "DSP thread should be named leyline.dsp.<id>: \(Self.engineThreadNames())")
        await capture.stop()
        XCTAssertFalse(capture.core.isRunning)
        XCTAssertTrue(Self.engineThreadNames().isEmpty, "engine threads still alive: \(Self.engineThreadNames())")
        let channels = await capture.channels
        XCTAssertTrue(channels.isEmpty)
    }

    /// Names of live threads in this process that belong to the engine (Linux: /proc/self/task/*/comm).
    static func engineThreadNames() -> [String] {
        #if os(Linux)
        let tasks = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/task")) ?? []
        return tasks.compactMap { t in
            (try? String(contentsOfFile: "/proc/self/task/\(t)/comm", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.hasPrefix("leyline") }
        #else
        return []
        #endif
    }
}
