// SPDX-License-Identifier: GPL-3.0-or-later

// The claims ledger (docs/design/claims.md, CL-1): every consumer of a capture shows as a claim on
// it in GetState while it runs, and its claim goes when it ends, however it ends.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
import LeylineProto
import XCTest

final class ClaimsLedgerTests: XCTestCase {
    // MARK: Harness

    private func state(_ c: DaemonClients) async throws -> Leyline_V1_GetStateResponse {
        try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
    }

    private func claims(_ c: DaemonClients) async throws -> [Leyline_V1_Claim] {
        try await state(c).captures.flatMap(\.claims)
    }

    /// Polls GetState until the claims satisfy `pred`, and returns them; fails with what it last saw.
    @discardableResult
    private func waitForClaims(_ c: DaemonClients, timeoutMs: Int = 10000, _ why: String,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ pred: ([Leyline_V1_Claim]) -> Bool) async throws -> [Leyline_V1_Claim]
    {
        var last: [Leyline_V1_Claim] = []
        for _ in 0..<(timeoutMs / 50) {
            last = try await claims(c)
            if pred(last) { return last }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("\(why); claims were \(last.map { "\($0.kind) \($0.holder.clientID)" })", file: file, line: line)
        return last
    }

    private func attach(_ c: DaemonClients, _ fixture: String) async throws -> String {
        var attach = Leyline_V1_AttachFileDeviceRequest()
        attach.path = fixturePath(fixture)
        attach.loop = true
        return try await c.control.attachFileDevice(attach, metadata: testMetadata).deviceID
    }

    private func capture(_ c: DaemonClients, on device: String, at hz: UInt64 = 146_520_000) async throws -> String {
        var create = Leyline_V1_CreateCaptureRequest()
        create.deviceID = device
        create.centerHz = hz
        return try await c.control.createCapture(create, metadata: testMetadata).captureID
    }

    private func write(_ c: DaemonClients, _ w: Leyline_V1_ParamWrite) async throws {
        _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(w) }
    }

    private func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        try await c.jobs.getJob(.with { $0.jobID = id }, metadata: testMetadata)
    }

    private func waitForJob(_ c: DaemonClients, _ id: String, _ pred: (Leyline_V1_Job) -> Bool) async throws -> Leyline_V1_Job {
        var j = try await job(c, id)
        for _ in 0..<400 where !pred(j) {
            try await Task.sleep(nanoseconds: 50_000_000)
            j = try await job(c, id)
        }
        return j
    }

    private func cancel(_ c: DaemonClients, _ id: String) async throws {
        _ = try await c.jobs.cancelJob(.with { $0.jobID = id }, metadata: testMetadata)
    }

    private func startDecode(_ c: DaemonClients, decoder: String, frequencyHz: UInt64) async throws -> Leyline_V1_Job {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = frequencyHz
        return try await c.jobs.startJob(.with { $0.decode = config }, metadata: testMetadata)
    }

    private func requireFixture(_ name: String) throws {
        guard FileManager.default.fileExists(atPath: fixturePath(name)) else { throw XCTSkip("fixture missing: \(name)") }
    }

    // MARK: A person

    /// A person's channel is a PERSON channel claim, and their writes, channel and live audio sink
    /// hold one PERSON presence on the capture, which lapses a window after the last write once
    /// nothing else holds it.
    func testAPersonsChannelAndPresence() async throws {
        try requireFixture("nfm_tone.cf32")
        try await withDaemon { c in
            await c.daemon.store.setPresenceWindow(400_000_000)
            let device = try await self.attach(c, "nfm_tone.cf32")
            let captureID = try await self.capture(c, on: device)
            let none = try await self.claims(c)
            XCTAssertTrue(none.isEmpty, "a capture nobody uses carries no claims: \(none)")

            var create = Leyline_V1_CreateChannelRequest()
            create.captureID = captureID
            create.offsetHz = 100_000
            create.mode = .nfm
            let channel = try await c.control.createChannel(create, metadata: testMetadata)
            var held = try await self.claims(c)
            XCTAssertEqual(held.map(\.kind), [.claimChannel, .claimListen])
            let ch = try XCTUnwrap(held.first)
            XCTAssertEqual(ch.priority, .priorityPerson)
            XCTAssertEqual(ch.holder.clientID, testClientID)
            XCTAssertEqual(ch.covers.frequencyHz, 146_620_000, "the channel's absolute frequency")
            XCTAssertEqual(ch.covers.bandwidthHz, channel.bandwidthHz)
            XCTAssertEqual(ch.state, .claimSatisfied)
            XCTAssertTrue(ch.claimID.hasPrefix("clm_"), ch.claimID)
            XCTAssertEqual(held.last?.priority, .priorityPerson)
            XCTAssertEqual(held.last?.holder.clientID, testClientID)

            // A live audio sink is the same person's presence, not a second claim. A host that
            // cannot build one skips this part.
            var sinkReq = Leyline_V1_AttachSinkRequest()
            sinkReq.channelID = channel.channelID
            sinkReq.sink.systemAudio = .with { $0.volume = 0 }
            let sink = try? await c.control.attachSink(sinkReq, metadata: testMetadata)
            // The channel holds the presence past the window.
            try await Task.sleep(nanoseconds: 700_000_000)
            held = try await self.claims(c)
            XCTAssertEqual(held.map(\.kind), [.claimChannel, .claimListen], "a channel holds its person's presence")
            if let sink {
                _ = try await c.control.detachSink(.with { $0.sinkID = sink.sinkID }, metadata: testMetadata)
            }

            // The channel goes, and the window ran out long ago: both claims go with it.
            _ = try await c.control.destroyChannel(.with { $0.channelID = channel.channelID }, metadata: testMetadata)
            held = try await self.claims(c)
            XCTAssertTrue(held.isEmpty, "\(held)")

            // A write alone is a presence for the window, then lapses on its own.
            var w = Leyline_V1_ParamWrite()
            w.tag = 1
            w.targetID = captureID
            w.centerHz = 146_520_000
            try await self.write(c, w)
            let present = try await self.waitForClaims(c, "a write makes a presence") { $0.map(\.kind) == [.claimListen] }
            XCTAssertNil(present.first?.need)
            try await self.waitForClaims(c, timeoutMs: 3000, "the presence lapses after the window") { $0.isEmpty }
        }
    }

    // MARK: Jobs

    /// A decode job's channel is a JOB channel claim held by the job, released on cancel and when
    /// the plugin's failure ends the job.
    func testAJobsChannelIsAJobClaim() async throws {
        try requireFixture("nfm_tone.cf32")
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fake", recipe: (146_520_000, 15_000))
        try writeFakePlugin(in: plugins, name: "refuser", recipe: (146_520_000, 15_000), args: ["--refuse-input"])
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            _ = try await self.attach(c, "nfm_tone.cf32")
            let started = try await self.startDecode(c, decoder: "fake", frequencyHz: 146_520_000)
            let held = try await self.waitForClaims(c, "the job's channel claim") { $0.contains { $0.kind == .claimChannel } }
            let claim = try XCTUnwrap(held.first { $0.kind == .claimChannel })
            XCTAssertEqual(claim.priority, .priorityJob)
            XCTAssertEqual(claim.holder.kind, "job")
            XCTAssertEqual(claim.holder.clientID, started.jobID)
            XCTAssertFalse(held.contains { $0.kind == .claimListen }, "a job is not a person")
            try await self.cancel(c, started.jobID)
            try await self.waitForClaims(c, "cancel releases it") { !$0.contains { $0.holder.clientID == started.jobID } }

            let refused = try await self.startDecode(c, decoder: "refuser", frequencyHz: 146_520_000)
            let failed = try await self.waitForJob(c, refused.jobID) { $0.state == .failed }
            XCTAssertEqual(failed.state, .failed, failed.statusDetail)
            try await self.waitForClaims(c, "a failed job releases it") { !$0.contains { $0.holder.clientID == refused.jobID } }
        }
    }

    /// A record job that ends at its duration releases its channel claim.
    func testARecordingThatEndsReleasesItsClaim() async throws {
        try requireFixture("nfm_tone.cf32")
        let recordings = try makeTempDir("recordings")
        defer { try? FileManager.default.removeItem(atPath: recordings) }
        try await withDaemon(recordingsPath: recordings) { c in
            let device = try await self.attach(c, "nfm_tone.cf32")
            // A capture of the person's own, so the claim is seen to go while the capture stays.
            _ = try await self.capture(c, on: device)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_520_000
            config.mode = .nfm
            config.durationMs = 1500
            let started = try await c.jobs.startJob(.with { $0.record = config }, metadata: testMetadata)
            let held = try await self.waitForClaims(c, "the recording's channel claim") {
                $0.contains { $0.holder.clientID == started.jobID }
            }
            XCTAssertEqual(held.first { $0.holder.clientID == started.jobID }?.kind, .claimChannel)
            let ended = try await self.waitForJob(c, started.jobID) { $0.state != .running }
            XCTAssertEqual(ended.state, .completed, ended.statusDetail)
            try await self.waitForClaims(c, "the end releases it") { !$0.contains { $0.holder.clientID == started.jobID } }
            let captures = try await self.state(c).captures
            XCTAssertEqual(captures.count, 1, "the person's capture stays")
        }
    }

    /// IQ readers: an IQ decode job and an IQ recording each hold a JOB IQ claim, a dedicated
    /// decoder's needing the centre and its rate, and each goes on cancel or failure.
    func testIQReadersAreIQClaims() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer { for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) } }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try writeFakePlugin(in: plugins, name: "refuseiq", signal: .signalIq, args: ["--refuse-input"])
        try FileManager.default.createDirectory(atPath: plugins + "/fakewide", withIntermediateDirectories: true)
        try """
        {
          "name": "fakewide",
          "version": "0.1.0",
          "description": "a wide IQ decoder that needs its capture centred, for tests",
          "recipe": {"frequenciesHz": ["100100000"]},
          "input": {"mode": "CONTINUOUS", "signal": "SIGNAL_IQ"},
          "needsDedicatedCapture": true,
          "outputs": ["SHAPE_RECORDS"],
          "executable": "\(fakeDecoderPath())"
        }
        """.write(toFile: plugins + "/fakewide/manifest.json", atomically: true, encoding: .utf8)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let device = try await c.daemon.registry.attachVirtualDevice(RebindableDevice()).descriptor.id.string
            for _ in 0..<150 {
                if try await self.state(c).devices.contains(where: { $0.deviceID == device }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            _ = try await self.capture(c, on: device, at: 100_500_000)

            let reader = try await self.startDecode(c, decoder: "fakeiq", frequencyHz: 100_100_000)
            var held = try await self.waitForClaims(c, "the IQ decoder's claim") { $0.contains { $0.holder.clientID == reader.jobID } }
            let iq = try XCTUnwrap(held.first { $0.holder.clientID == reader.jobID })
            XCTAssertEqual(iq.kind, .claimIq)
            XCTAssertEqual(iq.priority, .priorityJob)
            XCTAssertEqual(iq.covers.frequencyHz, 100_100_000)
            XCTAssertEqual(iq.sampleRateHz, 0, "an ordinary IQ decoder takes any rate")
            XCTAssertEqual(iq.state, .claimSatisfied)
            try await self.cancel(c, reader.jobID)
            try await self.waitForClaims(c, "cancel releases it") { !$0.contains { $0.holder.clientID == reader.jobID } }

            // A dedicated decoder takes the capture over and needs it centred, at its rate.
            var wide = Leyline_V1_DecodeConfig()
            wide.decoder = "fakewide"
            wide.frequencyHz = 100_100_000
            wide.takeOver = true
            let dedicated = try await c.jobs.startJob(.with { $0.decode = wide }, metadata: testMetadata)
            held = try await self.waitForClaims(c, "the dedicated decoder's claim") { $0.contains { $0.holder.clientID == dedicated.jobID } }
            let centred = try XCTUnwrap(held.first { $0.holder.clientID == dedicated.jobID })
            XCTAssertEqual(centred.centred.frequencyHz, 100_100_000)
            XCTAssertEqual(centred.centred.toleranceHz, SessionCaptureAllocator.centredToleranceHz)
            XCTAssertNotEqual(centred.sampleRateHz, 0)
            XCTAssertEqual(centred.state, .claimSatisfied)
            try await self.cancel(c, dedicated.jobID)
            try await self.waitForClaims(c, "cancel releases it") { !$0.contains { $0.holder.clientID == dedicated.jobID } }

            // An IQ recording.
            var record = Leyline_V1_RecordConfig()
            record.frequencyHz = 100_100_000
            record.mode = .rawIq
            let recording = try await c.jobs.startJob(.with { $0.record = record }, metadata: testMetadata)
            held = try await self.waitForClaims(c, "the IQ recording's claim") { $0.contains { $0.holder.clientID == recording.jobID } }
            XCTAssertEqual(held.first { $0.holder.clientID == recording.jobID }?.kind, .claimIq)
            try await self.cancel(c, recording.jobID)
            try await self.waitForClaims(c, "cancel releases it") { !$0.contains { $0.holder.clientID == recording.jobID } }

            // A plugin that refuses its input fails the job, and the claim goes with it.
            let refused = try await self.startDecode(c, decoder: "refuseiq", frequencyHz: 100_100_000)
            let failed = try await self.waitForJob(c, refused.jobID) { $0.state == .failed }
            XCTAssertEqual(failed.state, .failed, failed.statusDetail)
            try await self.waitForClaims(c, "a failed job releases it") { !$0.contains { $0.holder.clientID == refused.jobID } }
            let left = try await self.state(c).captures
            XCTAssertEqual(left.count, 1, "the person's capture stays")
        }
    }

    /// A monitor holds an exclusive SWEEP claim for as long as it runs, and a write to its capture
    /// is refused with DEVICE_SWEEPING meanwhile.
    func testAMonitorHoldsASweepClaim() async throws {
        try requireFixture("scan_band.cf32")
        try await withDaemon { c in
            _ = try await self.attach(c, "scan_band.cf32")
            try await Task.sleep(nanoseconds: 200_000_000)
            var config = Leyline_V1_MonitorConfig()
            config.range.minHz = 146_240_000
            config.range.maxHz = 146_900_000
            config.durationMs = 60000
            let started = try await c.jobs.startJob(.with { $0.config = .monitor(config) }, metadata: testMetadata)
            let held = try await self.waitForClaims(c, "the monitor's sweep claim") { $0.contains { $0.kind == .claimSweep } }
            let sweep = try XCTUnwrap(held.first { $0.kind == .claimSweep })
            XCTAssertEqual(sweep.holder.clientID, started.jobID)
            XCTAssertEqual(sweep.covers.frequencyHz, 146_570_000, "the middle of the range")
            XCTAssertEqual(sweep.covers.bandwidthHz, 660_000, "the width of the range")
            let capturesNow = try await self.state(c).captures
            let swept = try XCTUnwrap(capturesNow.first)
            let refusal = await c.daemon.store.applyWrite(.with { $0.targetID = swept.captureID; $0.centerHz = 146_000_000 },
                                                          by: ClientContext(id: testClientID, kind: "cli", label: "xctest"))
            XCTAssertEqual(refusal?.code, EngineError.Code.deviceSweeping)
            try await self.cancel(c, started.jobID)
            try await self.waitForClaims(c, "cancel releases it") { !$0.contains { $0.kind == .claimSweep } }
        }
    }

    // MARK: Views

    /// A capture's FFT and IQ streams are VIEW spectrum claims of the client that opened them,
    /// released by Unsubscribe; a channel's audio stream rides on the channel's claim.
    func testBulkStreamsAreViewClaims() async throws {
        try requireFixture("nfm_tone.cf32")
        try await withDaemon { c in
            let device = try await self.attach(c, "nfm_tone.cf32")
            let captureID = try await self.capture(c, on: device)
            var fft = Leyline_V1_SubscribeRequest()
            fft.captureID = captureID
            fft.kind = .fft
            let fftStream = try await c.bulk.subscribe(fft, metadata: testMetadata)
            var iq = Leyline_V1_SubscribeRequest()
            iq.captureID = captureID
            iq.kind = .iq
            let iqStream = try await c.bulk.subscribe(iq, metadata: testMetadata)
            var held = try await self.claims(c)
            XCTAssertEqual(held.map(\.kind), [.claimSpectrum, .claimSpectrum])
            XCTAssertEqual(held.map(\.priority), [.priorityView, .priorityView])
            XCTAssertEqual(held.first?.holder.clientID, testClientID)
            XCTAssertNil(held.first?.need, "a view takes the capture as it is")

            _ = try await c.bulk.unsubscribe(.with { $0.streamID = fftStream.streamID }, metadata: testMetadata)
            held = try await self.claims(c)
            XCTAssertEqual(held.map(\.kind), [.claimSpectrum])
            _ = try await c.bulk.unsubscribe(.with { $0.streamID = iqStream.streamID }, metadata: testMetadata)
            held = try await self.claims(c)
            XCTAssertTrue(held.isEmpty, "\(held)")

            // A view on a capture that is destroyed goes with it, and nothing is left behind.
            _ = try await c.bulk.subscribe(fft, metadata: testMetadata)
            let viewing = try await self.claims(c)
            XCTAssertEqual(viewing.count, 1)
            _ = try await c.control.destroyCapture(.with { $0.captureID = captureID }, metadata: testMetadata)
            let again = try await self.capture(c, on: device)
            let fresh = try await self.state(c).captures.first { $0.captureID == again }
            XCTAssertEqual(fresh?.claims.count, 0)
        }
    }
}
