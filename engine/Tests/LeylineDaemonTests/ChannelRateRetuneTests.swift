// A capture_sample_rate write that pushes a channel OUT_OF_CAPTURE re-plans nothing until a retune
// brings the channel back; at that point its audio rate follows the new capture rate and the
// daemon reconciles sinks/bulk audio streams exactly as it does for an in-capture rate change.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import XCTest

final class ChannelRateRetuneDaemonTests: XCTestCase {
    /// Polls `cond` every 20 ms until it holds or `timeoutMs` elapses.
    private func eventually(timeoutMs: Int = 3000, _ cond: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0 ..< (timeoutMs / 20) {
            if try await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await cond()
    }

    private func write(_ c: DaemonClients, tag: UInt64, target: String, _ fill: (inout Leyline_V1_ParamWrite) -> Void) async throws {
        var w = Leyline_V1_ParamWrite()
        w.tag = tag
        w.targetID = target
        fill(&w)
        let summary = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(w) }
        XCTAssertEqual(summary.writesApplied, 1, "write tag \(tag) applied")
    }

    func testRateChangeOutOfCaptureThenRetuneBackFollowsNewAudioRate() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device)
            let mirrored = try await self.eventually {
                let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                return s.devices.contains(where: { $0.deviceID == d.id.string })
            }
            XCTAssertTrue(mirrored, "session store mirrors the attached device")
            let events = await EventCollector.start(c.control, daemon: c.daemon)

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.sampleRate, 2_400_000)
            // +600 kHz fits a 2.4 MSPS capture (±1.2 MHz) but not a 1.024 MSPS one (±512 kHz).
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 600_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            XCTAssertEqual(channel.state, .channelActive)
            let chanID = try XCTUnwrap(ChannelID(string: channel.channelID))
            let maybeEngine = await c.daemon.store.channelEngine(chanID)
            let engine = try XCTUnwrap(maybeEngine)
            XCTAssertEqual(engine.audioRate, 48_000, "2.4 MSPS: r1 = 240 kHz, d2 = 5")

            // Bulk audio at the original rate; its CallbackSink is attached to the channel.
            var req = Leyline_V1_SubscribeRequest()
            req.captureID = capture.captureID
            req.channelID = channel.channelID
            req.kind = .audio
            req.policy = .latestWins
            req.transport = .grpc
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc.audio.sampleRate, 48_000)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            var sinks = await engine.sinks
            XCTAssertEqual(sinks.count, 1, "bulk audio attaches one CallbackSink")
            let streamEnded = LockedValue(false)
            let reader = Task {
                do {
                    try await c.bulk.stream(ref, metadata: testMetadata) { response in
                        for try await _ in response.messages {}
                    }
                } catch {}
                streamEnded.value = true
            }

            // Rate change: the channel no longer fits and goes OUT_OF_CAPTURE at its absolute frequency.
            try await self.write(c, tag: 1, target: capture.captureID) { $0.captureSampleRate = 1_024_000 }
            let out = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.state == .outOfCapture }
                return false
            }
            XCTAssertNotNil(out, "channel event OUT_OF_CAPTURE after the rate change")
            XCTAssertEqual(out?.channel.offsetHz, 600_000, "offset follows the absolute frequency")
            XCTAssertFalse(streamEnded.value, "no chain was re-planned yet: the audio stream is still open")
            XCTAssertEqual(engine.audioRate, 48_000, "audio rate is unchanged while out of capture")

            // Retune so the channel (147.12 MHz) sits at the capture center: active again at the new rate.
            try await self.write(c, tag: 2, target: capture.captureID) { $0.centerHz = 147_120_000 }
            let back = await events.waitFor { ev in
                // The create event was also CHANNEL_ACTIVE; the one after the retune carries the new offset.
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.state == .channelActive && ch.offsetHz == 0 }
                return false
            }
            XCTAssertNotNil(back, "channel event CHANNEL_ACTIVE with the new offset (same absolute frequency) after the retune")
            XCTAssertEqual(engine.audioRate, 51_200, "1.024 MSPS: r1 = 256 kHz, d2 = 5")
            let ended = await self.eventually { streamEnded.value }
            XCTAssertTrue(ended, "the audio stream negotiated at 48 kHz ends when the rate moves")
            _ = await reader.value
            let detached = await self.eventually { await engine.sinks.isEmpty }
            XCTAssertTrue(detached, "the 48 kHz CallbackSink is detached from the channel")

            // A fresh subscription negotiates the new rate and re-attaches a sink.
            let desc2 = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc2.audio.sampleRate, 51_200, "bulk audio descriptor follows the new audio rate")
            sinks = await engine.sinks
            XCTAssertEqual(sinks.count, 1, "new CallbackSink attached")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.sampleRate, 1_024_000)
            XCTAssertEqual(state.captures.first?.centerHz, 147_120_000)
            XCTAssertEqual(state.channels.first?.state, .channelActive)
            XCTAssertEqual(state.channels.first?.offsetHz, 0)
            var ref2 = Leyline_V1_StreamRef()
            ref2.streamID = desc2.streamID
            _ = try await c.bulk.unsubscribe(ref2, metadata: testMetadata)
            await events.stop()
        }
    }
}
