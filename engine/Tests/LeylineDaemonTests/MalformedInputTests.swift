// Malformed-input hardening across the gRPC surface (engine-review WI-4): extreme offsets, denormal
// spectrum rates, non-finite gains and non-regular files must be rejected cleanly, never crash or hang.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import XCTest

final class MalformedInputDaemonTests: XCTestCase {
    private func attachFixtureCapture(_ c: DaemonClients) async throws -> Leyline_V1_Capture {
        var attach = Leyline_V1_AttachFileDeviceRequest()
        attach.path = fixturePath("nfm_tone.cf32")
        attach.loop = true
        let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
        var cc = Leyline_V1_CreateCaptureRequest()
        cc.deviceID = device.deviceID
        cc.centerHz = 146_520_000
        return try await c.control.createCapture(cc, metadata: testMetadata)
    }

    func testExtremeOffsetsAreRejectedWithoutCrash() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_tone.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let capture = try await self.attachFixtureCapture(c)
            for offset in [Int64.min, Int64.max, Int64.min + 1] {
                var cch = Leyline_V1_CreateChannelRequest()
                cch.captureID = capture.captureID
                cch.offsetHz = offset
                cch.mode = .nfm
                do {
                    _ = try await c.control.createChannel(cch, metadata: testMetadata)
                    XCTFail("expected rejection for offset \(offset)")
                } catch {
                    XCTAssertEqual(errorCode(error).code, "OFFSET_OUT_OF_CAPTURE", "offset \(offset)")
                }
            }
            // The same extremes through WriteParams: rejected with the tag, channel untouched.
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            _ = try await c.control.writeParams(metadata: testMetadata) { writer in
                var w = Leyline_V1_ParamWrite()
                w.tag = 41
                w.targetID = channel.channelID
                w.offsetHz = Int64.min
                try await writer.write(w)
            }
            let rejected = await events.waitFor { ev in
                if case .writeRejected(let wr)? = ev.body { return wr.tag == 41 }
                return false
            }
            XCTAssertEqual(rejected?.writeRejected.error.code, "OFFSET_OUT_OF_CAPTURE")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.channels.first?.offsetHz, 100_000)
            await events.stop()
        }
    }

    func testDenormalRowsPerSecondClampsAndDeliversRows() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_tone.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let capture = try await self.attachFixtureCapture(c)
            var req = Leyline_V1_SubscribeRequest()
            req.captureID = capture.captureID
            req.kind = .fft
            req.policy = .latestWins
            req.transport = .grpc
            req.fft.bins = 256
            req.fft.rowsPerSecond = 1e-300
            req.fft.binFormat = .dbF32
            let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTAssertEqual(desc.fft.rowsPerSecond, DefaultSpectrumLadder.minRowsPerSecond)
            var ref = Leyline_V1_StreamRef()
            ref.streamID = desc.streamID
            let frames: [Leyline_V1_Frame] = try await c.bulk.stream(ref, metadata: testMetadata) { response in
                var out: [Leyline_V1_Frame] = []
                for try await f in response.messages {
                    out.append(f)
                    break
                }
                return out
            }
            XCTAssertEqual(frames.count, 1, "the first row is due immediately even at the floor rate")
            XCTAssertEqual(frames.first?.payload.count, 256 * 4)
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        }
    }

    func testNonFiniteGainIsInvalidArgument() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_tone.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            let capture = try await self.attachFixtureCapture(c)
            // One stream per value: same-target gain writes coalesce within a stream (last wins).
            for (tag, db) in [(UInt64(51), Double.nan), (52, .infinity), (53, -.infinity)] {
                let summary = try await c.control.writeParams(metadata: testMetadata) { writer in
                    var w = Leyline_V1_ParamWrite()
                    w.tag = tag
                    w.targetID = capture.captureID
                    w.gain.element = "TUNER"
                    w.gain.db = db
                    try await writer.write(w)
                }
                XCTAssertEqual(summary.writesReceived, 1)
                XCTAssertEqual(summary.writesApplied, 0)
            }
            for tag: UInt64 in [51, 52, 53] {
                let rejected = await events.waitFor { ev in
                    if case .writeRejected(let wr)? = ev.body { return wr.tag == tag }
                    return false
                }
                XCTAssertEqual(rejected?.writeRejected.error.code, "INVALID_ARGUMENT", "tag \(tag)")
                XCTAssertEqual(rejected?.writeRejected.error.target, capture.captureID)
            }
            await events.stop()
        }
    }

    func testAttachFileDeviceRejectsFIFOAndDirectoryPromptly() async throws {
        try await withDaemon { c in
            let dir = NSTemporaryDirectory() + "leyline-malformed-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            // A FIFO with a valid sidecar beside it: a plain open() would block forever on it.
            try IQSidecar(format: "cf32", sampleRate: 48_000, centerHz: 1).save(path: dir + "/fifo.json")
            guard mkfifo(dir + "/fifo.cf32", 0o600) == 0 else { throw XCTSkip("mkfifo unavailable: \(errno)") }
            try FileManager.default.createDirectory(atPath: dir + "/sub.cf32", withIntermediateDirectories: true)
            for path in [dir + "/fifo.cf32", dir + "/fifo.json", dir, dir + "/sub.cf32"] {
                let started = Date()
                var attach = Leyline_V1_AttachFileDeviceRequest()
                attach.path = path
                do {
                    _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
                    XCTFail("expected INVALID_ARGUMENT for \(path)")
                } catch {
                    XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT", path)
                }
                XCTAssertLessThan(Date().timeIntervalSince(started), 2, "\(path) must be rejected without blocking")
            }
            let listed = try await c.control.listDevices(Leyline_V1_ListDevicesRequest(), metadata: testMetadata)
            XCTAssertTrue(testDevices(listed.devices).isEmpty, "nothing was attached")
        }
    }
}
