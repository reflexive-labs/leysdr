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
    private func attachRetunable(_ c: DaemonClients, _ device: RebindableDevice = RebindableDevice()) async throws -> String {
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

    /// A non-dedicated IQ job reads an off-centre capture; a dedicated decoder must not retune it
    /// from under that job, nor from under an IQ recording, unless it is told to take over.
    func testADedicatedDecoderLeavesACaptureAnotherJobReads() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer { for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) } }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try writeDedicatedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let device = try await self.attachRetunable(c)
            var create = Leyline_V1_CreateCaptureRequest()
            create.deviceID = device
            create.centerHz = 100_500_000
            _ = try await c.control.createCapture(create, metadata: testMetadata)

            let reader = try await self.startIQ(c, decoder: "fakeiq", frequencyHz: 100_100_000)
            _ = try await self.records(c, job: reader.jobID, count: 1)
            let refused = try await self.startIQ(c, decoder: "fakewide", frequencyHz: 100_100_000)
            let failed = try await self.waitForJob(c, refused.jobID) { $0.state == .failed }
            XCTAssertEqual(failed?.error.code, EngineError.Code.deviceBusy, failed?.statusDetail ?? "")
            XCTAssertEqual(failed?.statusDetail, "another job is reading this radio (decode fakeiq)")
            let untouched = try await self.onlyCapture(c)
            XCTAssertEqual(untouched.centerHz, 100_500_000, "the reading job's capture stays where it was")
            let still = try await self.job(c, reader.jobID)
            XCTAssertEqual(still.state, .running, still.statusDetail)
            try await self.cancel(c, reader.jobID)

            // An IQ recording is a reader too.
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 100_100_000
            config.mode = .rawIq
            var request = Leyline_V1_StartJobRequest()
            request.record = config
            let recording = try await c.jobs.startJob(request, metadata: testMetadata)
            XCTAssertEqual(recording.state, .running, recording.statusDetail)
            let refusedAgain = try await self.startIQ(c, decoder: "fakewide", frequencyHz: 100_100_000)
            let failedAgain = try await self.waitForJob(c, refusedAgain.jobID) { $0.state == .failed }
            XCTAssertEqual(failedAgain?.statusDetail, "another job is reading this radio (record)")
            let stillThere = try await self.onlyCapture(c)
            XCTAssertEqual(stillThere.centerHz, 100_500_000)
            try await self.cancel(c, recording.jobID)
        }
    }

    /// A file radio plays what it recorded, so it cannot be centred on a frequency its recording
    /// only covers: a dedicated decoder is declined with the reason, with no capture of its own
    /// and on a capture somebody has open, take_over or not, and the capture stays where it was.
    func testADedicatedDecoderIsDeclinedAFileRadioRecordedOffItsFrequency() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeDedicatedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            // nfm_tone is centred on 146.520 MHz; 146.620 MHz is inside its span, not on it.
            try await self.attachFixture(c)
            let reason = "cannot tune to 146.620 MHz (a file radio plays what it recorded)"
            let alone = try await self.startIQ(c, decoder: "fakewide", frequencyHz: self.iqFrequencyHz)
            let declined = try await self.waitForJob(c, alone.jobID) { $0.state == .failed }
            XCTAssertEqual(declined?.error.code, EngineError.Code.noDevice, declined?.statusDetail ?? "")
            XCTAssertTrue(declined?.statusDetail.hasSuffix(reason) == true, declined?.statusDetail ?? "")
            let none = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata).captures
            XCTAssertTrue(none.isEmpty, "a declined job opens no capture")

            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            var create = Leyline_V1_CreateCaptureRequest()
            create.deviceID = try XCTUnwrap(state.devices.first?.deviceID)
            create.centerHz = 146_520_000
            _ = try await c.control.createCapture(create, metadata: testMetadata)
            let taking = try await self.startIQ(c, decoder: "fakewide", frequencyHz: self.iqFrequencyHz, takeOver: true)
            let refused = try await self.waitForJob(c, taking.jobID) { $0.state == .failed }
            XCTAssertEqual(refused?.error.code, EngineError.Code.noDevice, refused?.statusDetail ?? "")
            XCTAssertTrue(refused?.statusDetail.hasSuffix(reason) == true, refused?.statusDetail ?? "")
            let untouched = try await self.onlyCapture(c)
            XCTAssertEqual(untouched.centerHz, 146_520_000, "the file radio's capture stays where it was")

            // On its recording's own centre it is the dedicated decoder's.
            let centred = try await self.startIQ(c, decoder: "fakewide", frequencyHz: 146_520_000)
            let rec = try await self.records(c, job: centred.jobID, count: 1)
            XCTAssertEqual(self.integer(rec.first, "center_hz"), 146_520_000)
            try await self.cancel(c, centred.jobID)
        }
    }

    /// An IQ plugin that exits 3 ends its job FAILED_PRECONDITION with its words, as an audio one does.
    func testAnIQPluginThatRefusesItsInputFailsTheJob() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq, args: ["--refuse-input"])
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startIQDecode(c)
            let failed = try await self.waitForJob(c, started.jobID) { $0.state == .failed }
            XCTAssertEqual(failed?.error.code, EngineError.Code.failedPrecondition, failed?.statusDetail ?? "")
            XCTAssertEqual(failed?.statusDetail, "the capture is centred on 146520000 Hz, which this fake cannot decode")
            try await Task.sleep(for: .seconds(DecodeRunner.firstRestartSeconds + 1))
            let starts = try String(contentsOfFile: plugins + "/fakeiq/.refused-input", encoding: .utf8)
            XCTAssertEqual(starts, "start\n", "the plugin is not started again")
            let none = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata).captures
            XCTAssertTrue(none.isEmpty, "the job's own capture goes with it")
        }
    }

    /// A rate change that lands and a retune that does not leave the capture as it was found.
    func testAFailedRetuneLeavesTheCaptureAtItsOldRate() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeDedicatedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let radio = RebindableDevice()
            radio.refusedTuneHz.value = 100_100_000
            let device = try await self.attachRetunable(c, radio)
            var create = Leyline_V1_CreateCaptureRequest()
            create.deviceID = device
            create.centerHz = 100_500_000
            create.sampleRate = 1_024_000
            _ = try await c.control.createCapture(create, metadata: testMetadata)

            let taking = try await self.startIQ(c, decoder: "fakewide", frequencyHz: 100_100_000, takeOver: true)
            let failed = try await self.waitForJob(c, taking.jobID) { $0.state == .failed }
            XCTAssertNotNil(failed, "a radio that will not tune there is no capture for the job")
            let after = try await self.onlyCapture(c)
            XCTAssertEqual(after.sampleRate, 1_024_000, "the rate is put back")
            XCTAssertEqual(after.centerHz, 100_500_000, "and so is the centre")
        }
    }

    /// The first record from now on whose frame carried a gap, or nil after `timeoutMs`.
    private func nextGap(_ c: DaemonClients, job: String, timeoutMs: Int) async throws -> Leyline_V1_DecodeRecord? {
        var subscription = Leyline_V1_RecordSubscription()
        subscription.jobID = job
        let s = subscription
        return try await withThrowingTaskGroup(of: Leyline_V1_DecodeRecord?.self) { group in
            group.addTask {
                try await c.decoders.subscribeRecords(s, metadata: testMetadata) { response in
                    for try await rec in response.messages where rec.fields["gap_from"] != nil { return rec }
                    return nil
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A retune away and back between two looks at the capture still breaks the plugin's stream:
    /// the samples from the other tuning reached it, so the next frame says there was a gap.
    func testARoundTripRetuneInsideOnePollIsStillAGap() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            _ = try await self.attachRetunable(c)
            let started = try await self.startIQ(c, decoder: "fakeiq", frequencyHz: 100_100_000)
            _ = try await self.records(c, job: started.jobID, count: 1)
            let capture = try await self.onlyCapture(c)
            let quiet = try await self.nextGap(c, job: started.jobID, timeoutMs: 700)
            XCTAssertNil(quiet, "an undisturbed capture marks no gap")
            let captureID = try XCTUnwrap(CaptureID(string: capture.captureID))
            let maybeEngine = await c.daemon.store.captureEngine(captureID)
            let engine = try XCTUnwrap(maybeEngine)
            let gap = Task { try await self.nextGap(c, job: started.jobID, timeoutMs: 3000) }
            try await Task.sleep(nanoseconds: 200_000_000)
            try await engine.retune(centerHz: 103_000_000)
            try await engine.retune(centerHz: 100_100_000)
            let marked = try await gap.value
            XCTAssertNotNil(marked, "the round trip is marked as a gap")
            let now = try await self.job(c, started.jobID)
            XCTAssertEqual(now.state, .running, now.statusDetail)
            try await self.cancel(c, started.jobID)
        }
    }

    // MARK: A stored IQ recording (DA-6)

    /// Writes a finished IQ recording through `PartWriter`, the way the daemon writes one: a part
    /// of `samples` cf32 samples (each `level` + 0j) at each of `starts` (capture samples), so a
    /// start past the previous part's end is a hole the recording does not hold. Returns its id.
    private func writeIQRecording(in dir: String, rate: UInt64, starts: [UInt64], samples: Int,
                                  level: Float = 0.1) async throws -> String
    {
        let id = JobID().string
        let manifest = RecordingManifest(
            jobID: id, kind: "iq", frequencyHz: iqFrequencyHz, mode: "", bandwidthHz: 0,
            sampleRate: rate, format: "cf32", device: nil, gains: [], squelchDbfs: .nan, gate: nil,
            partMs: 0, startedAtNs: WallClock.nowNs(),
            createdBy: RecordingClient(clientID: "", kind: "cli", label: "test"), anchors: [])
        let captureID = CaptureID().string
        let writer = try PartWriter(directory: dir + "/" + id, manifest: manifest, captureID: captureID,
                                    centerHz: iqFrequencyHz)
        await writer.noteAnchor(CaptureAnchor(hostTimeNsAtSampleZero: WallClock.nowNs(), sampleRate: rate),
                                captureID: captureID, fromSample: 0)
        let payload = [Float](repeating: 0, count: samples * 2).enumerated().map { $0.offset % 2 == 0 ? level : 0 }
        for start in starts {
            await writer.openPart(at: start)
            await writer.append(iq: payload.withUnsafeBytes { Data($0) })
            await writer.closePart(endSample: start + UInt64(samples))
        }
        await writer.finish(endedBy: "duration", endSample: (starts.last ?? 0) + UInt64(samples))
        return id
    }

    private func startSource(_ c: DaemonClients, decoder: String, recording: String,
                             keep: Bool = false) async throws -> Leyline_V1_Job
    {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.sourceUri = "ley://recordings/\(recording)"
        config.keep = keep
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    private func waitForEnd(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job? {
        try await waitForJob(c, id, timeoutMs: 20000) { $0.state != .running && $0.state != .degraded }
    }

    private func query(_ c: DaemonClients, job: String) async throws -> [Leyline_V1_DecodeRecord] {
        var query = Leyline_V1_RecordQuery()
        query.jobID = job
        return try await c.decoders.queryRecords(query, metadata: testMetadata).records.sorted { $0.seq < $1.seq }
    }

    func testAnIQDecoderReadsAStoredIQRecordingFrameByFrameWithItsGaps() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        let store = try makeTempDir("store")
        defer { for d in [plugins, recordings, store] { try? FileManager.default.removeItem(atPath: d) } }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        // Two parts of 40,000 samples with 60,000 samples between them that nobody recorded.
        let block = CaptureDSPCore.blockSize
        let id = try await writeIQRecording(in: recordings, rate: 2_400_000, starts: [0, 100_000], samples: 40000)
        try await withDaemon(decoderSearchPath: [plugins], storePath: store, recordingsPath: recordings) { c in
            let started = try await self.startSource(c, decoder: "fakeiq", recording: id, keep: true)
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done?.state, .completed, done?.statusDetail ?? "")
            let got = try await self.query(c, job: started.jobID)
            // A capture block a frame, as the live IQ path frames it: 16384 + 16384 + 7232 a part.
            let perPart = (40000 + block - 1) / block
            XCTAssertEqual(got.count, 2 * perPart, "every frame of both parts, once")
            guard got.count == 2 * perPart else { return }
            XCTAssertEqual(got.map { self.integer($0, "bytes") ?? 0 }.prefix(perPart),
                           [Int64(block * 8), Int64(block * 8), Int64((40000 - 2 * block) * 8)])
            XCTAssertEqual(got.map(\.time.sampleIndex),
                           [0, UInt64(block), UInt64(2 * block), 100_000, 100_000 + UInt64(block), 100_000 + UInt64(2 * block)])
            for rec in got {
                XCTAssertEqual(self.integer(rec, "iq"), 1, "the plugin is told IQ")
                XCTAssertEqual(self.integer(rec, "stored"), 1, "and that it reads a stored recording")
                XCTAssertEqual(self.integer(rec, "center_hz"), Int64(self.iqFrequencyHz))
            }
            let gapped = got.filter { self.integer($0, "gap_from") != nil }
            XCTAssertEqual(gapped.count, 1, "one hole, marked once")
            XCTAssertEqual(self.integer(gapped.first, "gap_from"), 40000)
            XCTAssertEqual(self.integer(gapped.first, "gap_to"), 100_000)
            XCTAssertEqual(Set(got.prefix(perPart).map(\.clipUri)), ["ley://recordings/\(id)/1"])
            XCTAssertEqual(Set(got.suffix(perPart).map(\.clipUri)), ["ley://recordings/\(id)/2"])
        }
    }

    /// iqstat, the repository's IQ test decoder, over a recording of known power: `make go` puts it
    /// in go/bin, and the test skips without it.
    func testIQStatReadsTheLevelOfAStoredIQRecording() async throws {
        let binary = URL(fileURLWithPath: fixturePath("")).deletingLastPathComponent()
            .appendingPathComponent("go/bin/leydec-iqstat").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("\(binary) is not built; run make go")
        }
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer { for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) } }
        try writeFakePlugin(in: plugins, name: "iqstat", json: """
        {
          "name": "iqstat",
          "version": "0.1.0",
          "recipe": {"frequenciesHz": ["100000000"]},
          "input": {"mode": "CONTINUOUS", "signal": "SIGNAL_IQ"},
          "outputs": ["SHAPE_RECORDS"],
          "executable": "\(binary)"
        }
        """)
        // At 48 kHz iqstat reports every 24,000 samples: two records a part, each 0.1 + 0j, -20 dBFS.
        let id = try await writeIQRecording(in: recordings, rate: 48000, starts: [0, 96000], samples: 48000)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let started = try await self.startSource(c, decoder: "iqstat", recording: id)
            let got = try await self.records(c, job: started.jobID, count: 4)
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done?.state, .completed, done?.statusDetail ?? "")
            XCTAssertEqual(got.count, 4)
            for rec in got {
                XCTAssertEqual(rec.protocol, "iqstat")
                XCTAssertEqual(rec.fields["power_dbfs"]?.number ?? 0, -20, accuracy: 0.01)
                XCTAssertEqual(rec.fields["sample_rate"]?.integer, 48000)
                XCTAssertEqual(rec.fields["center_hz"]?.integer, Int64(self.iqFrequencyHz))
            }
            XCTAssertEqual(got.map(\.time.sampleIndex), [24000, 48000, 96000 + 24000, 96000 + 48000])
        }
    }

    /// Four parts on one capture: the first and last at the recording's own tuning, the second at
    /// another rate and the third at another centre, as a capture retuned under the recorder or a
    /// recording carried on after a restart leaves them. 40,000 samples each, 10,000 apart.
    private func writeMixedIQRecording(in dir: String) async throws -> String {
        let id = JobID().string
        let rate: UInt64 = 2_400_000
        let manifest = RecordingManifest(
            jobID: id, kind: "iq", frequencyHz: iqFrequencyHz, mode: "", bandwidthHz: 0,
            sampleRate: rate, format: "cf32", device: nil, gains: [], squelchDbfs: .nan, gate: nil,
            partMs: 0, startedAtNs: WallClock.nowNs(),
            createdBy: RecordingClient(clientID: "", kind: "cli", label: "test"), anchors: [])
        let captureID = CaptureID().string
        let writer = try PartWriter(directory: dir + "/" + id, manifest: manifest, captureID: captureID,
                                    centerHz: iqFrequencyHz)
        let host = WallClock.nowNs()
        let payload = [Float](repeating: 0, count: 80000).enumerated().map { $0.offset % 2 == 0 ? Float(0.1) : 0 }
        func part(at start: UInt64, rate partRate: UInt64, centre: UInt64) async {
            await writer.noteAnchor(CaptureAnchor(hostTimeNsAtSampleZero: host, sampleRate: partRate),
                                    captureID: captureID, fromSample: start)
            await writer.retarget(captureID: captureID, centerHz: centre)
            await writer.openPart(at: start)
            await writer.append(iq: payload.withUnsafeBytes { Data($0) })
            await writer.closePart(endSample: start + 40000)
        }
        await part(at: 0, rate: rate, centre: iqFrequencyHz)
        await part(at: 50000, rate: 1_024_000, centre: iqFrequencyHz)
        await part(at: 100_000, rate: rate, centre: iqFrequencyHz + 500_000)
        await part(at: 150_000, rate: rate, centre: iqFrequencyHz)
        await writer.finish(endedBy: "duration", endSample: 190_000)
        return id
    }

    func testPartsAtAnotherTuningAreSkippedAndCounted() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        let store = try makeTempDir("store")
        defer { for d in [plugins, recordings, store] { try? FileManager.default.removeItem(atPath: d) } }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        let id = try await writeMixedIQRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], storePath: store, recordingsPath: recordings) { c in
            let started = try await self.startSource(c, decoder: "fakeiq", recording: id, keep: true)
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done?.state, .completed, done?.statusDetail ?? "")
            XCTAssertTrue(done?.statusDetail.hasSuffix("; 2 parts at another tuning skipped") == true, done?.statusDetail ?? "")
            let got = try await self.query(c, job: started.jobID)
            XCTAssertEqual(Set(got.map(\.clipUri)), ["ley://recordings/\(id)/1", "ley://recordings/\(id)/4"],
                           "only the parts at the recording's own tuning reach the plugin")
            let block = UInt64(CaptureDSPCore.blockSize)
            XCTAssertEqual(got.map(\.time.sampleIndex), [0, block, 2 * block, 150_000, 150_000 + block, 150_000 + 2 * block],
                           "a file sample is a capture sample")
            let gapped = got.filter { self.integer($0, "gap_from") != nil }
            XCTAssertEqual(gapped.count, 1)
            XCTAssertEqual(self.integer(gapped.first, "gap_from"), 40000)
            XCTAssertEqual(self.integer(gapped.first, "gap_to"), 150_000)
        }
    }

    /// A part whose file holds less than the manifest says: the gap before the next part starts
    /// where the samples ran out, not where the manifest said they would.
    func testTheGapAfterAShortPartStartsWhereItsSamplesEnd() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        let store = try makeTempDir("store")
        defer { for d in [plugins, recordings, store] { try? FileManager.default.removeItem(atPath: d) } }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        let id = try await writeIQRecording(in: recordings, rate: 2_400_000, starts: [0, 100_000], samples: 40000)
        let dir = recordings + "/" + id
        let first = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".cf32") }.sorted().first)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: dir + "/" + first))
        try handle.truncate(atOffset: 20000 * 8)
        try handle.close()
        try await withDaemon(decoderSearchPath: [plugins], storePath: store, recordingsPath: recordings) { c in
            let started = try await self.startSource(c, decoder: "fakeiq", recording: id, keep: true)
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done?.state, .completed, done?.statusDetail ?? "")
            let got = try await self.query(c, job: started.jobID)
            let gapped = got.filter { self.integer($0, "gap_from") != nil }
            XCTAssertEqual(gapped.count, 1)
            XCTAssertEqual(self.integer(gapped.first, "gap_from"), 20000)
            XCTAssertEqual(self.integer(gapped.first, "gap_to"), 100_000)
        }
    }

    func testAStoredRecordingOfTheWrongKindIsRefusedWithTheReason() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer { for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) } }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try writeFakePlugin(in: plugins, name: "fakeaudio")
        let iq = try await writeIQRecording(in: recordings, rate: 48000, starts: [0], samples: 1000)
        // An audio recording: the same writer with one WAV part.
        let audio = JobID().string
        let manifest = RecordingManifest(
            jobID: audio, kind: "audio", frequencyHz: iqFrequencyHz, mode: "NFM", bandwidthHz: 12500,
            sampleRate: 48000, format: "wav-s16", device: nil, gains: [], squelchDbfs: .nan, gate: nil,
            partMs: 0, startedAtNs: WallClock.nowNs(),
            createdBy: RecordingClient(clientID: "", kind: "cli", label: "test"), anchors: [])
        let writer = try PartWriter(directory: recordings + "/" + audio, manifest: manifest,
                                    captureID: CaptureID().string, centerHz: iqFrequencyHz)
        await writer.openPart(at: 0)
        await writer.append(audio: [Float](repeating: 0.1, count: 4800))
        await writer.closePart(endSample: 48000)
        await writer.finish(endedBy: "duration", endSample: 48000)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            func refusal(_ decoder: String, _ recording: String) async -> (code: String, message: String) {
                do {
                    _ = try await self.startSource(c, decoder: decoder, recording: recording)
                    return ("started", "")
                } catch {
                    let e = errorCode(error)
                    return (e.code, e.trailer?.message ?? "\(error)")
                }
            }
            let iqOnAudio = await refusal("fakeiq", audio)
            XCTAssertEqual(iqOnAudio.code, EngineError.Code.invalidArgument)
            XCTAssertTrue(iqOnAudio.message.contains("holds demodulated audio, and fakeiq reads raw IQ"), iqOnAudio.message)
            let audioOnIQ = await refusal("fakeaudio", iq)
            XCTAssertEqual(audioOnIQ.code, EngineError.Code.unimplemented)
            XCTAssertTrue(audioOnIQ.message.contains("fakeaudio reads demodulated audio"), audioOnIQ.message)
        }
    }
}
