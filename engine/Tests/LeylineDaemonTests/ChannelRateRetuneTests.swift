// SPDX-License-Identifier: GPL-3.0-or-later

// A capture_sample_rate write that pushes a channel OUT_OF_CAPTURE re-plans nothing until a retune
// brings the channel back; at that point its audio rate follows the new capture rate and the
// daemon reconciles sinks/bulk audio streams exactly as it does for an in-capture rate change.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
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
        let message = w
        let summary = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
        XCTAssertEqual(summary.writesApplied, 1, "write tag \(tag) applied")
    }

    func testRateChangeOutOfCaptureThenRetuneBackFollowsNewAudioRate() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
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
            XCTAssertEqual(engine.audioRate, 48_000, "audio rate is unchanged while out of capture")
            // The stream's frame spans are scaled by the capture rate, so it ends on the rate write
            // itself, before any chain is re-planned.
            let endedOnRate = await self.eventually { streamEnded.value }
            XCTAssertTrue(endedOnRate, "the audio stream ends when the capture rate moves under it")
            _ = await reader.value
            let detached = await self.eventually { await engine.sinks.isEmpty }
            XCTAssertTrue(detached, "the 48 kHz CallbackSink is detached from the channel")

            // Retune so the channel (147.12 MHz) sits at the capture center: active again at the new rate.
            try await self.write(c, tag: 2, target: capture.captureID) { $0.centerHz = 147_120_000 }
            let back = await events.waitFor { ev in
                // The create event was also CHANNEL_ACTIVE; the one after the retune carries the new offset.
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.state == .channelActive && ch.offsetHz == 0 }
                return false
            }
            XCTAssertNotNil(back, "channel event CHANNEL_ACTIVE with the new offset (same absolute frequency) after the retune")
            XCTAssertEqual(engine.audioRate, 51_200, "1.024 MSPS: r1 = 256 kHz, d2 = 5")

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

    /// The same re-plan reached through a channel write rather than a retune: an out-of-capture
    /// channel brought back by an offset write gets its chain planned at the current capture rate,
    /// so streams negotiated at the old audio rate -- the listener's and the scope's alike -- end.
    func testOffsetWriteThatRePlansTheChainEndsAudioStreams() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 600_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let chanID = try XCTUnwrap(ChannelID(string: channel.channelID))
            let maybeEngine = await c.daemon.store.channelEngine(chanID)
            let engine = try XCTUnwrap(maybeEngine)
            XCTAssertEqual(engine.audioRate, 48_000)

            // What `ley listen` opens, and what `ley scope` opens beside it.
            func subscribe(_ tap: Leyline_V1_AudioTap) async throws -> (Leyline_V1_StreamRef, LockedValue<Bool>, Task<Void, Never>) {
                var req = Leyline_V1_SubscribeRequest()
                req.captureID = capture.captureID
                req.channelID = channel.channelID
                req.kind = .audio
                req.policy = .latestWins
                req.transport = .grpc
                req.audio.tap = tap
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
                return (ref, ended, reader)
            }
            // The rate change pushes the channel out of capture and re-plans nothing yet, so the
            // streams opened after it still negotiate 48 kHz and only the offset write can move them.
            try await self.write(c, tag: 1, target: capture.captureID) { $0.captureSampleRate = 1_024_000 }
            let out = await self.eventually { await engine.state == .outOfCapture }
            XCTAssertTrue(out, "600 kHz does not fit a 1.024 MSPS capture")
            XCTAssertEqual(engine.audioRate, 48_000, "audio rate is unchanged while out of capture")

            let (_, heardEnded, heardReader) = try await subscribe(.tapAudio)
            let (_, scopeEnded, scopeReader) = try await subscribe(.tapDemod)
            XCTAssertFalse(heardEnded.value, "nothing was re-planned yet: the streams are still open")

            // An offset that fits brings it back, and the chain is planned at the new capture rate.
            try await self.write(c, tag: 2, target: channel.channelID) { $0.offsetHz = 0 }
            XCTAssertEqual(engine.audioRate, 51_200, "1.024 MSPS: r1 = 256 kHz, d2 = 5")
            let heardClosed = await self.eventually { heardEnded.value }
            XCTAssertTrue(heardClosed, "the 48 kHz audio stream ends")
            let scopeClosed = await self.eventually { scopeEnded.value }
            XCTAssertTrue(scopeClosed, "the 48 kHz demod tap ends with it")
            heardReader.cancel()
            scopeReader.cancel()
            _ = await heardReader.value
            _ = await scopeReader.value

            var again = Leyline_V1_SubscribeRequest()
            again.captureID = capture.captureID
            again.channelID = channel.channelID
            again.kind = .audio
            again.policy = .latestWins
            again.transport = .grpc
            again.audio.tap = .tapDemod
            let desc = try await c.bulk.subscribe(again, metadata: testMetadata)
            XCTAssertEqual(desc.audio.sampleRate, 51_200, "a fresh subscription carries the new audio rate")
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        }
    }

    /// The descriptor stays valid for the life of the stream, not just its rate. A squelch write
    /// changes nothing a client holds, so `ley listen` and `ley scope` stay open through it; a
    /// bandwidth write rescales the NFM detector without moving the audio rate, and every stream
    /// that reported the old `full_scale_deviation_hz` ends so a client reads hertz off the new
    /// one.
    func testBandwidthWriteThatMovesFullScaleEndsAudioStreams() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 0
            cch.mode = .nfm
            cch.bandwidthHz = 12_500
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let chanID = try XCTUnwrap(ChannelID(string: channel.channelID))
            let maybeEngine = await c.daemon.store.channelEngine(chanID)
            let engine = try XCTUnwrap(maybeEngine)
            let rateBefore = engine.audioRate

            func subscribe(_ tap: Leyline_V1_AudioTap) async throws -> (Leyline_V1_StreamDescriptor, LockedValue<Bool>, Task<Void, Never>) {
                var req = Leyline_V1_SubscribeRequest()
                req.captureID = capture.captureID
                req.channelID = channel.channelID
                req.kind = .audio
                req.policy = .latestWins
                req.transport = .grpc
                req.audio.tap = tap
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
                return (desc, ended, reader)
            }
            let (heardDesc, heardEnded, heardReader) = try await subscribe(.tapAudio)
            let (scopeDesc, scopeEnded, scopeReader) = try await subscribe(.tapDemod)
            XCTAssertEqual(heardDesc.audio.fullScaleDeviationHz, 2_500, "a 12.5 kHz channel answers +/-2.5 kHz")
            XCTAssertEqual(scopeDesc.audio.fullScaleDeviationHz, 2_500)

            // A squelch write leaves the descriptor valid, so nothing ends.
            try await self.write(c, tag: 1, target: channel.channelID) { $0.squelchDb = -40 }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertFalse(heardEnded.value, "a squelch write does not end the audio stream")
            XCTAssertFalse(scopeEnded.value, "a squelch write does not end the demod tap")

            // A bandwidth write keeps the audio rate and moves the full scale: both taps end.
            try await self.write(c, tag: 2, target: channel.channelID) { $0.bandwidthHz = 25_000 }
            XCTAssertEqual(engine.audioRate, rateBefore, "the audio rate is the capture's business, not the bandwidth's")
            let heardClosed = await self.eventually { heardEnded.value }
            XCTAssertTrue(heardClosed, "the audio stream negotiated at 2.5 kHz full scale ends")
            let scopeClosed = await self.eventually { scopeEnded.value }
            XCTAssertTrue(scopeClosed, "the demod tap ends with it")
            heardReader.cancel()
            scopeReader.cancel()
            _ = await heardReader.value
            _ = await scopeReader.value

            let (fresh, _, freshReader) = try await subscribe(.tapDemod)
            XCTAssertEqual(fresh.audio.fullScaleDeviationHz, 5_000, "a fresh subscription answers the 25 kHz channel's full scale")
            XCTAssertEqual(fresh.audio.sampleRate, rateBefore)
            freshReader.cancel()
            _ = await freshReader.value
            var ref = Leyline_V1_StreamRef()
            ref.streamID = fresh.streamID
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        }
    }
}
