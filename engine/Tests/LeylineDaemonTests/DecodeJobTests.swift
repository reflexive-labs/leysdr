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
                             frequencyHz: UInt64 = decodeFrequencyHz,
                             predicate: Leyline_V1_Predicate? = nil,
                             notify: Leyline_V1_NotifyTarget? = nil) async throws -> Leyline_V1_Job
    {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = frequencyHz
        config.keep = keep
        if let predicate { config.predicate = predicate }
        if let notify { config.notify = notify }
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    /// A device_id IN [...] predicate, the shape `ley watch --where device_id=...` sends.
    private func deviceIDIn(_ ids: [String]) -> Leyline_V1_Predicate {
        var test = Leyline_V1_FieldTest()
        test.field = "device_id"
        test.op = .predIn
        test.values = ids.map { var v = Leyline_V1_FieldValue(); v.text = $0; return v }
        var clause = Leyline_V1_Clause()
        clause.field = test
        var predicate = Leyline_V1_Predicate()
        predicate.all = [clause]
        return predicate
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

    /// A running job says how much it has heard (DEC-23): the first record at once, the count
    /// afterwards on the liveness timer, so `ley jobs` tells a working decoder from a silent one
    /// without anyone subscribing to its records.
    func testARunningJobSaysHowMuchItHasHeard() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c)
            XCTAssertTrue(started.statusDetail.hasPrefix("starting") || started.statusDetail.contains("no records yet"),
                          "before any record the detail says so: \(started.statusDetail)")
            let got = try await self.records(c, job: started.jobID, count: 4)
            XCTAssertEqual(got.count, 4)
            // The fixture loops and the fake decodes every frame, so the count keeps climbing:
            // what is checked is that the published count has caught up with what was delivered.
            let counted = try await self.waitForJob(c, started.jobID, timeoutMs: 6000) { job in
                Self.recordCount(in: job.statusDetail).map { $0 >= 4 } ?? false
            }
            XCTAssertNotNil(counted, "the detail never said four or more records")
            XCTAssertTrue(counted?.statusDetail.hasPrefix("decoding with fake: ") == true, counted?.statusDetail ?? "")
            XCTAssertTrue(counted?.statusDetail.contains(", last ") == true, "the detail says how long ago: \(counted?.statusDetail ?? "")")
            XCTAssertEqual(counted?.state, .running, "counting records is not a state change")
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
        }
    }

    /// The count in a running job's detail ("decoding with fake: 12 records, last 3 s ago"), or nil.
    private static func recordCount(in detail: String) -> Int? {
        guard let colon = detail.firstIndex(of: ":") else { return nil }
        let rest = detail[detail.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return Int(rest.prefix { $0.isNumber })
    }

    /// A kept job outlives the daemon, not just its client (DEC-11): the next daemon on the same
    /// store brings it back as the same job, its records appending to the same file with the
    /// sequence carrying on, and the old records keeping the wall time of the capture that made
    /// them.
    func testAKeptJobComesBackAfterARestart() async throws {
        let dir = try makeTempDir("restart")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let plugins = dir + "/decoders"
        try writeFakePlugin(in: plugins)
        let store = dir + "/store"
        var jobID = ""
        var before = 0
        var firstCapture = ""
        try await withDaemon(dir: dir + "/run1", decoderSearchPath: [plugins], storePath: store) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c, keep: true)
            jobID = started.jobID
            let got = try await self.records(c, job: jobID, count: 3)
            firstCapture = got.first?.time.captureID ?? ""
            XCTAssertEqual(got.count, 3)
            // Let the writer flush what the query will read.
            try await Task.sleep(nanoseconds: 300_000_000)
            var q = Leyline_V1_RecordQuery()
            q.jobID = jobID
            before = try await c.decoders.queryRecords(q, metadata: testMetadata).records.count
            XCTAssertGreaterThanOrEqual(before, 3)
        }
        // The daemon is gone; the file names the job it was running.
        let kept = try XCTUnwrap(FileManager.default.contents(atPath: store + "/kept-jobs.json"))
        XCTAssertTrue(String(decoding: kept, as: UTF8.self).contains(jobID), "kept-jobs.json should name the job")

        try await withDaemon(dir: dir + "/run2", decoderSearchPath: [plugins], storePath: store) { c in
            // The resume waits for a radio; here comes one.
            try await self.attachFixture(c)
            // The job is not in the table until the resume has found a radio, so a miss is a wait.
            var back: Leyline_V1_Job?
            for _ in 0 ..< 300 {
                if let j = try? await self.job(c, jobID), j.state == .running { back = j; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let job = try XCTUnwrap(back, "the kept job did not come back")
            XCTAssertEqual(job.jobID, jobID, "the same job, not a new one")
            XCTAssertEqual(job.resultUris, ["ley://records/\(jobID)"])
            XCTAssertTrue(job.statusDetail.contains("resuming") || job.statusDetail.hasPrefix("decoding with"), job.statusDetail)
            // Records carry on: live ones continue the sequence past what the store held.
            let more = try await self.records(c, job: jobID, count: 2, since: nil)
            XCTAssertEqual(more.count, 2)
            XCTAssertGreaterThan(Int(more[0].seq), before, "seq should continue from the store's count, not restart at 1")
            XCTAssertNotEqual(more[0].time.captureID, firstCapture, "a new daemon makes a new capture")
            try await Task.sleep(nanoseconds: 300_000_000)
            var q = Leyline_V1_RecordQuery()
            q.jobID = jobID
            let page = try await c.decoders.queryRecords(q, metadata: testMetadata)
            XCTAssertGreaterThan(page.records.count, before, "the store should hold both runs' records")
            let captures = Set(page.anchors.map(\.anchor.captureID))
            XCTAssertTrue(captures.contains(firstCapture) && captures.count == 2,
                          "the page should carry an anchor for each capture the job ran on: \(captures)")
            // Newest first: a record from the new run sorts before one from the old, which is only
            // true if the old records kept the old capture's clock.
            XCTAssertNotEqual(page.records.first?.time.captureID, firstCapture)
            XCTAssertEqual(page.records.last?.time.captureID, firstCapture)
            var ref = Leyline_V1_JobRef()
            ref.jobID = jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
        }
        // Cancelled by a client, not by a shutdown: the file no longer names it.
        let after = try XCTUnwrap(FileManager.default.contents(atPath: store + "/kept-jobs.json"))
        XCTAssertFalse(String(decoding: after, as: UTF8.self).contains(jobID), "a cancelled job is not resumed")
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

    func testAPredicateFiltersRecords() async throws {
        // The fake emits FAKE-1, FAKE-2, FAKE-3, ... one per frame. A predicate that admits only
        // FAKE-2 must deliver that record and nothing else (docs/design/decoders.md, "Predicates
        // and delivery"): filtered records never reach the hub, so the seq stays contiguous.
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startDecode(c, predicate: self.deviceIDIn(["FAKE-2"]))
            let got = try await self.records(c, job: started.jobID, count: 1)
            XCTAssertEqual(got.count, 1)
            XCTAssertEqual(got[0].deviceID, "FAKE-2", "only the matching record is delivered")
            XCTAssertEqual(got[0].seq, 1, "a filtered record does not spend a seq")
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
        }
    }

    func testANotifierFiresOnAMatch() async throws {
        // A shell notify target appends each matching record's LEYLINE_DEVICE_ID to a file. With a
        // predicate admitting FAKE-2 and FAKE-4, the file gets exactly those and never a filtered id.
        let plugins = try makeTempDir("decoders")
        let work = try makeTempDir("notify")
        defer {
            try? FileManager.default.removeItem(atPath: plugins)
            try? FileManager.default.removeItem(atPath: work)
        }
        try writeFakePlugin(in: plugins)
        let hits = work + "/hits.txt"
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            var notify = Leyline_V1_NotifyTarget()
            notify.shell = "printf '%s\\n' \"$LEYLINE_DEVICE_ID\" >> '\(hits)'"
            let started = try await self.startDecode(
                c, predicate: self.deviceIDIn(["FAKE-2", "FAKE-4"]), notify: notify)
            // Both matching records delivered means both notifiers have been dispatched.
            let got = try await self.records(c, job: started.jobID, count: 2)
            XCTAssertEqual(Set(got.map(\.deviceID)), ["FAKE-2", "FAKE-4"])
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)

            // The shell hooks fire in their own tasks; give them a moment to finish writing.
            var lines: [String] = []
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 100_000_000)
                let text = (try? String(contentsOfFile: hits, encoding: .utf8)) ?? ""
                lines = text.split(separator: "\n").map(String.init)
                if Set(lines) == ["FAKE-2", "FAKE-4"] { break }
            }
            XCTAssertEqual(Set(lines), ["FAKE-2", "FAKE-4"], "the notifier fired for the matches only")
            XCTAssertFalse(lines.contains("FAKE-1"), "a filtered-out record does not notify")
            XCTAssertFalse(lines.contains("FAKE-3"), "a filtered-out record does not notify")
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
