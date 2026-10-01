// SPDX-License-Identifier: GPL-3.0-or-later

// Channels and sinks over the daemon: presence reaping, the system-audio volume, and writes on a
// channel outside its capture.

@testable import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineServer
import LeylineProto
import XCTest

extension DaemonTests {
    func testPresenceReapsNonPersistentChannels() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing") }
        try await withDaemon(presenceGraceNs: 300_000_000) { c in
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
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let ephemeral = try await c.control.createChannel(cch, metadata: testMetadata)
            cch.persistent = true
            let persistent = try await c.control.createChannel(cch, metadata: testMetadata)
            // A second client's channel must not be touched.
            let other: Metadata = ["leyline-client-id": .string("cli_OTHER"), "leyline-client-kind": .string("app")]
            let otherEvents = Task {
                var scope = Leyline_V1_EventScope()
                scope.daemon = true
                try? await c.control.watchEvents(scope, metadata: other) { r in for try await _ in r.messages {} }
            }
            cch.persistent = false
            let held = try await c.control.createChannel(cch, metadata: other)

            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: other)
            XCTAssertEqual(state.channels.count, 3)
            // Only unary calls from our client: present for 300 ms, then reaped.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: other)
            let ids = Set(state.channels.map(\.channelID))
            XCTAssertFalse(ids.contains(ephemeral.channelID), "ephemeral channel of the absent client is reaped")
            XCTAssertTrue(ids.contains(persistent.channelID), "persistent channel survives")
            XCTAssertTrue(ids.contains(held.channelID), "channel held open by WatchEvents survives")
            otherEvents.cancel()
        }
    }

    /// `SystemAudioSink.volume` is proto3-optional: absent means 1.0, an explicit 0 means muted, and
    /// anything outside 0..1 is INVALID_ARGUMENT. The range check runs before the platform sink is
    /// built, so on hosts without AVFoundation the two valid shapes reach PLATFORM_UNSUPPORTED (proof
    /// they passed validation) while 1.5 is refused everywhere.
    func testAttachSinkVolumePresence() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture missing: \(fixture) (run leyfix generate)")
        }
        try await withDaemon { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
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
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)

            func attachSink(_ sa: Leyline_V1_SystemAudioSink) async throws -> Leyline_V1_Sink {
                var req = Leyline_V1_AttachSinkRequest()
                req.channelID = channel.channelID
                req.sink.systemAudio = sa
                return try await c.control.attachSink(req, metadata: testMetadata)
            }
            /// Attaches and, where the host can build a system-audio sink, asserts the volume the
            /// daemon settled on in both the reply and the Sink event.
            func expectVolume(_ sa: Leyline_V1_SystemAudioSink, _ expected: Double, _ label: String) async throws {
                do {
                    let sink = try await attachSink(sa)
                    XCTAssertTrue(sink.systemAudio.hasVolume, "\(label): reply must carry volume presence")
                    XCTAssertEqual(sink.systemAudio.volume, expected, "\(label): reply volume")
                    let ev = await events.waitFor { ev in
                        if case .sink(let s)? = ev.body { return s.sinkID == sink.sinkID }
                        return false
                    }
                    XCTAssertNotNil(ev, "\(label): Sink event")
                    XCTAssertEqual(ev?.sink.systemAudio.hasVolume, true, "\(label): event presence")
                    XCTAssertEqual(ev?.sink.systemAudio.volume, expected, "\(label): event volume")
                } catch {
                    let code = errorCode(error).code
                    #if canImport(AVFoundation)
                    XCTAssertEqual(code, "DEVICE_IO", "\(label): headless runner may fail AVAudioEngine.start; got \(code)")
                    #else
                    XCTAssertEqual(code, "PLATFORM_UNSUPPORTED", "\(label): got \(code)")
                    #endif
                }
            }

            // Absent -> 1.0.
            try await expectVolume(Leyline_V1_SystemAudioSink(), 1.0, "absent volume")
            // Explicit 0 -> muted, not "unset".
            var muted = Leyline_V1_SystemAudioSink()
            muted.volume = 0
            try await expectVolume(muted, 0, "explicit zero")
            // Out of range -> INVALID_ARGUMENT before any platform sink is built.
            var loud = Leyline_V1_SystemAudioSink()
            loud.volume = 1.5
            do {
                _ = try await attachSink(loud)
                XCTFail("expected INVALID_ARGUMENT for volume 1.5")
            } catch {
                XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
                XCTAssertEqual(errorCode(error).trailer?.code, "INVALID_ARGUMENT")
            }
            await events.stop()
        }
    }

    /// FU-2: WriteParams on an OUT_OF_CAPTURE channel. `bandwidth_hz` and `mode` are stored (the
    /// Channel event carries the new values with state OUT_OF_CAPTURE, no WriteRejected), and the
    /// channel comes back ACTIVE with them once `center_hz` moves the capture back over it.
    func testStructuralWritesOnOutOfCaptureChannelAreStored() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            for _ in 0..<150 {
                let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                if s.devices.contains(where: { $0.deviceID == d.id.string }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let events = await EventCollector.start(c.control, daemon: c.daemon)

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 100_000_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.sampleRate, 2_400_000)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            XCTAssertEqual(channel.state, .channelActive)
            XCTAssertEqual(channel.bandwidthHz, 12_500)

            func write(tag: UInt64, target: String, _ fill: (inout Leyline_V1_ParamWrite) -> Void) async throws {
                var w = Leyline_V1_ParamWrite()
                w.tag = tag
                w.targetID = target
                fill(&w)
                let message = w
                let summary = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
                XCTAssertEqual(summary.writesApplied, 1, "write tag \(tag) applied")
            }

            // Retune 1.5 MHz away: the channel (100.1 MHz) no longer fits ±1.2 MHz.
            try await write(tag: 1, target: capture.captureID) { $0.centerHz = 101_500_000 }
            let out = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.state == .outOfCapture }
                return false
            }
            XCTAssertNotNil(out, "channel event OUT_OF_CAPTURE after the retune")
            XCTAssertEqual(out?.channel.offsetHz, -1_400_000, "offset follows the absolute frequency")

            // Bandwidth then mode while out: both stored, no WriteRejected, state stays OUT_OF_CAPTURE.
            try await write(tag: 2, target: channel.channelID) { $0.bandwidthHz = 8_000 }
            let bw = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.bandwidthHz == 8_000 }
                return false
            }
            XCTAssertNotNil(bw, "channel event with the stored bandwidth")
            XCTAssertEqual(bw?.channel.state, .outOfCapture)
            XCTAssertEqual(bw?.channel.offsetHz, -1_400_000)
            try await write(tag: 3, target: channel.channelID) { $0.mode = .am }
            let mode = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.mode == .am }
                return false
            }
            XCTAssertNotNil(mode, "channel event with the stored mode")
            XCTAssertEqual(mode?.channel.state, .outOfCapture)
            XCTAssertEqual(mode?.channel.bandwidthHz, 8_000)
            let rejected = await events.events.contains { ev in
                if case .writeRejected? = ev.body { return true }
                return false
            }
            XCTAssertFalse(rejected, "no write was rejected")

            // An offset write while out is still checked against the capture.
            var bad = Leyline_V1_ParamWrite()
            bad.tag = 4
            bad.targetID = channel.channelID
            bad.offsetHz = -2_000_000
            let badMessage = bad
            _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(badMessage) }
            let wr = await events.waitFor { ev in
                if case .writeRejected(let r)? = ev.body { return r.tag == 4 }
                return false
            }
            XCTAssertEqual(wr?.writeRejected.error.code, "OFFSET_OUT_OF_CAPTURE")

            // Move the capture back: ACTIVE with the stored bandwidth and mode at 100.1 MHz.
            try await write(tag: 5, target: capture.captureID) { $0.centerHz = 100_000_000 }
            let back = await events.waitFor { ev in
                // The create event was also CHANNEL_ACTIVE at +100 kHz; the one after the retune carries the stored bandwidth.
                if case .channel(let ch)? = ev.body {
                    return ch.channelID == channel.channelID && ch.state == .channelActive && ch.offsetHz == 100_000 && ch.bandwidthHz == 8_000
                }
                return false
            }
            XCTAssertNotNil(back, "channel event CHANNEL_ACTIVE after the capture moves back")
            XCTAssertEqual(back?.channel.bandwidthHz, 8_000)
            XCTAssertEqual(back?.channel.mode, .am)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let ch = try XCTUnwrap(state.channels.first(where: { $0.channelID == channel.channelID }))
            XCTAssertEqual(ch.state, .channelActive)
            XCTAssertEqual(ch.bandwidthHz, 8_000)
            XCTAssertEqual(ch.mode, .am)
            await events.stop()
        }
    }
}
