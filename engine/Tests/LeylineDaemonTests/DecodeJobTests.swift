// SPDX-License-Identifier: GPL-3.0-or-later

// A decode job end to end against a file device and the fake decoder: what the daemon stamps on a
// record, what `keep` writes, what cancel hands back, and what a plugin that dies costs
// (docs/design/decoders.md, "Decisions": "A decode job is a job").

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// The fixture's carrier: 146.520 MHz centre, the NFM tone 100 kHz up.
let decodeFrequencyHz: UInt64 = 146_620_000

final class DecodeJobTests: XCTestCase {
    /// Attaches nfm_tone on a loop, so the job has something to hear for as long as it runs.
    private func attachFixture(_ c: DaemonClients) async throws {
        var attach = Leyline_V1_AttachFileDeviceRequest()
        attach.path = fixturePath("nfm_tone.cf32")
        attach.loop = true
        _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
    }

    private func startDecode(_ c: DaemonClients, keep: Bool = false, decoder: String = "fake",
                             frequencyHz: UInt64 = decodeFrequencyHz) async throws -> Leyline_V1_Job
    {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = frequencyHz
        config.keep = keep
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    /// Reads `count` records off the live stream, replayed from the start of the job's window.
    private func records(_ c: DaemonClients, job: String, count: Int, since: UInt64? = 0,
                         timeoutMs: Int = 15000) async throws -> [Leyline_V1_DecodeRecord]
    {
        var subscription = Leyline_V1_RecordSubscription()
        subscription.jobID = job
        if let since { subscription.sinceSeq = since }
        return try await withThrowingTaskGroup(of: [Leyline_V1_DecodeRecord]?.self) { group in
            group.addTask {
                try await c.decoders.subscribeRecords(subscription, metadata: testMetadata) { response in
                    var out: [Leyline_V1_DecodeRecord] = []
                    for try await rec in response.messages {
                        out.append(rec)
                        if out.count >= count { return out }
                    }
                    return out
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let first else {
                XCTFail("no records within \(timeoutMs) ms")
                return []
            }
            return first
        }
    }

    private func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        return try await c.jobs.getJob(ref, metadata: testMetadata)
    }

    private func waitForJob(_ c: DaemonClients, _ id: String, timeoutMs: Int = 10000,
                            _ pred: @Sendable (Leyline_V1_Job) -> Bool) async throws -> Leyline_V1_Job?
    {
        for _ in 0..<(timeoutMs / 50) {
            let j = try await job(c, id)
            if pred(j) { return j }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func testRecordsCarryTheDaemonsStamps() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c)
            XCTAssertEqual(started.state, .running)
            XCTAssertTrue(started.resultUris.isEmpty, "an ephemeral job is not a resource")

            let got = try await self.records(c, job: started.jobID, count: 4)
            XCTAssertEqual(got.count, 4)
            XCTAssertEqual(got.map(\.seq), [1, 2, 3, 4], "seq is 1-based and contiguous per job")
            for rec in got {
                XCTAssertTrue(rec.recordID.hasPrefix("rec_"), "record id \(rec.recordID)")
                XCTAssertEqual(rec.jobID, started.jobID)
                XCTAssertEqual(rec.protocol, "fake")
                XCTAssertEqual(rec.kind, "position")
                XCTAssertTrue(rec.channelID.hasPrefix("chan_"), "channel id \(rec.channelID)")
                XCTAssertFalse(rec.time.captureID.isEmpty, "every record is on the capture's timeline")
            }
            XCTAssertEqual(got.map(\.deviceID), ["FAKE-1", "FAKE-2", "FAKE-3", "FAKE-4"],
                           "the plugin's own fields survive the stamping")
            // The meter arrives at its own cadence, so the levels are read off a record taken
            // after one has had time to land rather than off the first frames of the job.
            try await Task.sleep(nanoseconds: 400_000_000)
            let later = try await self.records(c, job: started.jobID, count: 1, since: nil)
            XCTAssertFalse(later[0].rssiDbfs.isNaN, "rssi_dbfs is stamped from the channel meter")
            XCTAssertGreaterThan(later[0].seq, got[3].seq)
            _ = try await c.jobs.cancelJob({ var r = Leyline_V1_JobRef(); r.jobID = started.jobID; return r }(), metadata: testMetadata)
        }
    }

    func testCancelHandsBackTheChannelAndTheCapture() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c)
            _ = try await self.records(c, job: started.jobID, count: 1)

            let during = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(during.channels.count, 1, "the job owns one channel")
            XCTAssertEqual(during.channels.first?.owner.kind, "job")
            XCTAssertTrue(during.channels.first?.persistent == true)
            XCTAssertEqual(during.channels.first?.requiredHz, decodeFrequencyHz)
            XCTAssertEqual(during.captures.count, 1, "the allocator built one capture")

            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            let cancelled = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            XCTAssertEqual(cancelled.state, .cancelled)
            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(after.channels.count, 0, "the channel goes with the job")
            XCTAssertEqual(after.captures.count, 0, "so does the capture the lease created")
        }
    }

    func testKeepWritesTheStoreAndQueryReadsItBack() async throws {
        let plugins = try makeTempDir("decoders")
        let storeDir = try makeTempDir("store")
        defer {
            try? FileManager.default.removeItem(atPath: plugins)
            try? FileManager.default.removeItem(atPath: storeDir)
        }
        try writeFakePlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins], storePath: storeDir) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c, keep: true)
            XCTAssertEqual(started.resultUris, ["ley://records/\(started.jobID)"], "a kept job is a resource")
            let live = try await self.records(c, job: started.jobID, count: 40)
            XCTAssertEqual(live.count, 40)
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)

            var query = Leyline_V1_RecordQuery()
            query.jobID = started.jobID
            let page = try await c.decoders.queryRecords(query, metadata: testMetadata)
            XCTAssertGreaterThanOrEqual(page.records.count, 32, "the writer flushes every 32 records")
            XCTAssertEqual(page.records.first?.jobID, started.jobID)
            XCTAssertEqual(page.anchors.count, 1, "the capture's anchor comes with the page")
            XCTAssertGreaterThan(page.anchors.first?.anchor.sampleRate ?? 0, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: storeDir + "/records/\(started.jobID).json"))

            query = Leyline_V1_RecordQuery()
            query.deviceID = "FAKE-1"
            let one = try await c.decoders.queryRecords(query, metadata: testMetadata)
            XCTAssertEqual(one.records.count, 1)
        }
    }

    func testAPluginThatExitsIsRestartedAndTheJobSaysSo() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, args: ["--die-after=2"])
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c)
            let degraded = try await self.waitForJob(c, started.jobID) { $0.statusDetail.contains("restarting") }
            XCTAssertNotNil(degraded, "the job says the decoder exited and is being restarted")
            XCTAssertEqual(degraded?.state, .degraded)
            XCTAssertTrue(degraded?.statusDetail.contains("status 3") == true, degraded?.statusDetail ?? "")

            let running = try await self.waitForJob(c, started.jobID, timeoutMs: 15000) { $0.state == .running }
            XCTAssertNotNil(running, "the plugin is spawned again")
            // Seq is the job's, not the plugin's: a restart does not rewind it.
            let got = try await self.records(c, job: started.jobID, count: 3)
            XCTAssertEqual(got.map(\.seq), [1, 2, 3])
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
        }
    }

    func testAPluginThatStopsReadingDoesNotWedgeTheDrain() async throws {
        // A decoder that reads three frames then stops reading is the DEC-16 hang: the daemon's
        // write is non-blocking, so the drain drops and gaps rather than parking on a full pipe,
        // the job stays RUNNING (silence is not failure -- the plugin never exited), and cancel
        // still hands the radio back promptly rather than blocking on a wedged writer.
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, args: ["--deaf-after=3"])
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c)
            let got = try await self.records(c, job: started.jobID, count: 3)
            XCTAssertEqual(got.count, 3, "the frames before the plugin went deaf still decoded")
            // Give the looping fixture time to overrun the wedged plugin's pipe several times over.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let still = try await self.job(c, started.jobID)
            XCTAssertEqual(still.state, .running, "a plugin that reads nothing is not a failed job")
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            XCTAssertLessThan(ContinuousClock.now, deadline, "cancel returned rather than blocking on the wedged pipe")
        }
    }

    func testAChannelOutOfCaptureDegradesTheJobAndComingBackRestoresIt() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            // A radio that can be pointed anywhere, so the capture can be walked away from the
            // channel and back. A file device's range is the single point its recording was made at.
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device).descriptor
            for _ in 0..<150 {
                let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                if s.devices.contains(where: { $0.deviceID == d.id.string }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let started = try await self.startDecode(c, frequencyHz: 100_100_000)
            let running = try await self.waitForJob(c, started.jobID) { $0.state == .running }
            XCTAssertNotNil(running)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let capture = try XCTUnwrap(state.captures.first)
            // A quarter span below the channel: clear of the tuner's own DC spike.
            XCTAssertEqual(capture.centerHz, 100_100_000 - 2_400_000 / 8)

            func retune(tag: UInt64, to hz: UInt64) async throws {
                var w = Leyline_V1_ParamWrite()
                w.tag = tag
                w.targetID = capture.captureID
                w.centerHz = hz
                let message = w
                _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
            }
            try await retune(tag: 1, to: 103_000_000)
            let degraded = try await self.waitForJob(c, started.jobID) { $0.state == .degraded }
            XCTAssertNotNil(degraded, "a channel out of its capture degrades the job")
            XCTAssertTrue(degraded?.statusDetail.contains("moved away") == true, degraded?.statusDetail ?? "")

            try await retune(tag: 2, to: 100_100_000 - 2_400_000 / 8)
            let back = try await self.waitForJob(c, started.jobID) { $0.state == .running }
            XCTAssertNotNil(back, "the capture coming back puts the job back to RUNNING")
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
        }
    }

    func testAnUnknownDecoderIsNotFound() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            do {
                _ = try await self.startDecode(c, decoder: "nobody")
                XCTFail("a decoder that is not installed should not start a job")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.decoderNotFound)
                XCTAssertEqual((error as? RPCError)?.code, .notFound)
            }
        }
    }
}
