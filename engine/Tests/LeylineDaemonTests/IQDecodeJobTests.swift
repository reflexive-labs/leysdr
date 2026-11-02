// SPDX-License-Identifier: GPL-3.0-or-later

// An IQ decode job end to end against a file device and the fake decoder: a plugin whose manifest
// declares SIGNAL_IQ receives the capture's raw cf32 band rather than a channel's audio, and the
// records it emits are stamped by the daemon with no channel behind them
// (docs/design/decoders.md, "Multiplexing"; DecoderSignal SIGNAL_IQ).

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

final class IQDecodeJobTests: XCTestCase {
    /// The fixture's carrier: 146.520 MHz centre. The IQ decoder takes the whole span, so the
    /// requested frequency need only fall inside it; 146.620 MHz sits +100 kHz up, as the audio
    /// tests use.
    private let iqFrequencyHz: UInt64 = 146_620_000

    /// Attaches nfm_tone on a loop, so the job has something to stream for as long as it runs.
    private func attachFixture(_ c: DaemonClients) async throws {
        var attach = Leyline_V1_AttachFileDeviceRequest()
        attach.path = fixturePath("nfm_tone.cf32")
        attach.loop = true
        _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
    }

    /// Starts an IQ decode job (the manifest's signal is SIGNAL_IQ, so the daemon allocates a
    /// capture-IQ lease and an IQDecodeRunner).
    private func startIQDecode(_ c: DaemonClients, keep: Bool = false, decoder: String = "fakeiq") async throws -> Leyline_V1_Job {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = iqFrequencyHz
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

    func testAnIQDecoderReceivesCaptureIQ() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startIQDecode(c)
            XCTAssertEqual(started.state, .running)

            let got = try await self.records(c, job: started.jobID, count: 4)
            XCTAssertEqual(got.count, 4)
            XCTAssertEqual(got.map(\.seq), [1, 2, 3, 4], "seq is 1-based and contiguous per job")
            for rec in got {
                XCTAssertTrue(rec.recordID.hasPrefix("rec_"), "record id \(rec.recordID)")
                XCTAssertEqual(rec.jobID, started.jobID)
                XCTAssertEqual(rec.protocol, "fake", "the plugin's own protocol name survives")
                XCTAssertTrue(rec.channelID.isEmpty, "an IQ job has no channel to stamp")
                XCTAssertTrue(rec.rssiDbfs.isNaN, "no channel meter, so rssi is NaN not invented")
                XCTAssertTrue(rec.snrDb.isNaN, "no channel meter, so snr is NaN not invented")
                XCTAssertFalse(rec.time.captureID.isEmpty, "every record is on the capture's timeline")
            }
            XCTAssertEqual(got.map(\.deviceID), ["FAKE-1", "FAKE-2", "FAKE-3", "FAKE-4"],
                           "the plugin's own fields survive the stamping")
            _ = try await c.jobs.cancelJob({ var r = Leyline_V1_JobRef(); r.jobID = started.jobID; return r }(), metadata: testMetadata)
        }
    }

    func testIQJobCancelReleasesTheCapture() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startIQDecode(c)
            _ = try await self.records(c, job: started.jobID, count: 1)

            let during = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(during.captures.count, 1, "the allocator built one capture")
            XCTAssertEqual(during.channels.count, 0, "an IQ decoder taps the capture, it has no channel")

            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            let cancelled = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            XCTAssertEqual(cancelled.state, .cancelled)
            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(after.captures.count, 0, "the capture the lease created goes with the job")
        }
    }

    // MARK: Following the capture (DA-4)

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

    private func cancel(_ c: DaemonClients, _ id: String) async throws {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
    }

    /// A radio that can be pointed anywhere from 0 to 1 GHz, so a capture can be walked away from
    /// the job and back. A file device's range is the single point its recording was made at.
    private func attachRetunable(_ c: DaemonClients) async throws -> String {
        let device = RebindableDevice()
        let id = try await c.daemon.registry.attachVirtualDevice(device).descriptor.id.string
        for _ in 0..<150 {
            let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if s.devices.contains(where: { $0.deviceID == id }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return id
    }

    private func onlyCapture(_ c: DaemonClients) async throws -> Leyline_V1_Capture {
        var made: Leyline_V1_Capture?
        for _ in 0..<200 where made == nil {
            made = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata).captures.first
            if made == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        return try XCTUnwrap(made, "a capture appears within 10 s")
    }

    private func retune(_ c: DaemonClients, _ captureID: String, tag: UInt64, to hz: UInt64) async throws {
        var w = Leyline_V1_ParamWrite()
        w.tag = tag
        w.targetID = captureID
        w.centerHz = hz
        let message = w
        _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
    }

    private func startIQ(_ c: DaemonClients, decoder: String, frequencyHz: UInt64,
                         takeOver: Bool = false) async throws -> Leyline_V1_Job
    {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = frequencyHz
        config.takeOver = takeOver
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    /// The first record the live stream delivers from now on.
    private func nextRecord(_ c: DaemonClients, job: String) -> Task<Leyline_V1_DecodeRecord?, Error> {
        var subscription = Leyline_V1_RecordSubscription()
        subscription.jobID = job
        let s = subscription
        return Task {
            try await c.decoders.subscribeRecords(s, metadata: testMetadata) { response in
                for try await rec in response.messages { return rec }
                return nil
            }
        }
    }

    private func integer(_ rec: Leyline_V1_DecodeRecord?, _ name: String) -> Int64? {
        rec?.fields[name]?.integer
    }

    func testAnIQJobFollowsItsCaptureAwayAndBack() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            _ = try await self.attachRetunable(c)
            let started = try await self.startIQ(c, decoder: "fakeiq", frequencyHz: 100_100_000)
            let first = try await self.records(c, job: started.jobID, count: 1)
            XCTAssertEqual(self.integer(first.first, "center_hz"), 100_100_000, "a created capture is centred on the frequency")
            XCTAssertEqual(self.integer(first.first, "iq"), 1)
            let capture = try await self.onlyCapture(c)
            XCTAssertEqual(capture.centerHz, 100_100_000)

            // Off the frequency altogether.
            try await self.retune(c, capture.captureID, tag: 1, to: 103_000_000)
            let away = try await self.waitForJob(c, started.jobID) { $0.state == .degraded }
            XCTAssertEqual(away?.statusDetail, "the capture moved away from 100.100 MHz; waiting for it to come back")
            // No records arrive while it is away, so the count's republish cannot be the capture
            // coming back: past one interval the job is still DEGRADED.
            try await Task.sleep(for: DecodeLiveness.interval + .milliseconds(500))
            let later = try await self.job(c, started.jobID)
            XCTAssertEqual(later.state, .degraded, later.statusDetail)

            // Recentred somewhere that still covers it: the plugin was told 100.1 MHz, so this is
            // still away.
            try await self.retune(c, capture.captureID, tag: 2, to: 100_500_000)
            let recentred = try await self.waitForJob(c, started.jobID) { $0.statusDetail.contains("moved from") }
            XCTAssertEqual(recentred?.state, .degraded)
            XCTAssertEqual(recentred?.statusDetail,
                           "the capture moved from 100.100 MHz to 100.500 MHz; waiting for it to come back")

            // Back where the plugin was told: RUNNING, and the first frame it gets says what it missed.
            let next = self.nextRecord(c, job: started.jobID)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await self.retune(c, capture.captureID, tag: 3, to: 100_100_000)
            let back = try await self.waitForJob(c, started.jobID) { $0.state == .running }
            XCTAssertNotNil(back, "the capture coming back puts the job back to RUNNING")
            let resumed = try await next.value
            let from = try XCTUnwrap(self.integer(resumed, "gap_from"), "the first frame after the return carries the gap")
            let to = try XCTUnwrap(self.integer(resumed, "gap_to"))
            XCTAssertEqual(UInt64(to), resumed?.time.sampleIndex, "the gap runs up to the frame that carries it")
            XCTAssertGreaterThan(to - from, 400_000, "the gap covers the time away, not a frame or two")
            XCTAssertEqual(self.integer(resumed, "center_hz"), 100_100_000)
            try await self.cancel(c, started.jobID)
        }
    }

    /// A fake whose manifest sets `needs_dedicated_capture`.
    private func writeDedicatedPlugin(in dir: String) throws {
        try writeFakePlugin(in: dir, name: "fakewide", json: """
        {
          "name": "fakewide",
          "version": "0.1.0",
          "recipe": {"frequenciesHz": ["100100000"]},
          "input": {"mode": "CONTINUOUS", "signal": "SIGNAL_IQ"},
          "needsDedicatedCapture": true,
          "outputs": ["SHAPE_RECORDS"],
          "executable": "\(fakeDecoderPath())"
        }
        """)
    }

    func testADedicatedDecoderSharesOnlyACentredCapture() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try writeDedicatedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let device = try await self.attachRetunable(c)
            var create = Leyline_V1_CreateCaptureRequest()
            create.deviceID = device
            create.centerHz = 100_500_000
            let capture = try await c.control.createCapture(create, metadata: testMetadata)

            // An ordinary IQ decoder reads the capture where it is: 100.1 MHz is inside its span.
            let shared = try await self.startIQ(c, decoder: "fakeiq", frequencyHz: 100_100_000)
            let sharedRec = try await self.records(c, job: shared.jobID, count: 1)
            XCTAssertEqual(self.integer(sharedRec.first, "center_hz"), 100_500_000, "a covering capture is shared as it is")
            try await self.cancel(c, shared.jobID)

            // Somebody tunes it, so it is in use for the next minute.
            try await self.retune(c, capture.captureID, tag: 1, to: 100_600_000)
            let refused = try await self.startIQ(c, decoder: "fakewide", frequencyHz: 100_100_000)
            let failed = try await self.waitForJob(c, refused.jobID) { $0.state == .failed }
            XCTAssertEqual(failed?.error.code, EngineError.Code.deviceBusy,
                           "an off-centre capture somebody is using is not the dedicated decoder's")
            XCTAssertTrue(failed?.statusDetail.contains("tuning this radio") == true, failed?.statusDetail ?? "")
            let untouched = try await self.onlyCapture(c)
            XCTAssertEqual(untouched.centerHz, 100_600_000, "a refusal leaves the radio where it was")

            // take_over retunes it onto the frequency.
            let taken = try await self.startIQ(c, decoder: "fakewide", frequencyHz: 100_100_000, takeOver: true)
            let takenRec = try await self.records(c, job: taken.jobID, count: 1)
            XCTAssertEqual(self.integer(takenRec.first, "center_hz"), 100_100_000)
            let retuned = try await self.onlyCapture(c)
            XCTAssertEqual(retuned.centerHz, 100_100_000)
            try await self.cancel(c, taken.jobID)

            // Now centred, it is shared without take_over, though it was tuned within the minute.
            let centred = try await self.startIQ(c, decoder: "fakewide", frequencyHz: 100_100_000)
            let centredRec = try await self.records(c, job: centred.jobID, count: 1)
            XCTAssertEqual(self.integer(centredRec.first, "center_hz"), 100_100_000)
            try await self.cancel(c, centred.jobID)
        }
    }
}
