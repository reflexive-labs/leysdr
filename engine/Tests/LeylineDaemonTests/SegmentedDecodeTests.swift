// SPDX-License-Identifier: GPL-3.0-or-later

// SEGMENTED decode jobs end to end against the fake decoder: one record per over, dated where the
// over's audio starts, and nothing sent while the squelch is shut (docs/dev/engine-internals.md,
// "Decoders"). `FAKE_DECODER_SEGMENTS=1` makes the fake answer each segment with its frame and
// sample counts.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

final class SegmentedDecodeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("FAKE_DECODER_SEGMENTS", "1", 1)
    }

    override func tearDown() {
        unsetenv("FAKE_DECODER_SEGMENTS")
        super.tearDown()
    }

    /// A fake whose manifest asks for SEGMENTED audio, on nfm_keyed's carrier.
    func writeSegmentedPlugin(in dir: String, name: String = "fake", executable: String? = nil,
                              credentialProvider: String = "", args: [String] = []) throws {
        try writeFakePlugin(in: dir, name: name, json: """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "counts segments, for tests",
          "recipe": {"frequenciesHz": ["\(recordFrequencyHz)"], "bandwidthHz": 12500, "mode": "NFM", "gain": "GAIN_LEAVE"},
          "input": {"mode": "SEGMENTED", "tap": "TAP_AUDIO", "signal": "SIGNAL_AUDIO"},
          "outputs": ["SHAPE_RECORDS"],
          "credentialProvider": "\(credentialProvider)",
          "executable": "\(executable ?? fakeDecoderPath())",
          "args": [\(args.map { "\"\($0)\"" }.joined(separator: ", "))]
        }
        """)
    }

    func attach(_ c: DaemonClients, fixture: String, loop: Bool) async throws {
        let path = fixturePath(fixture)
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("fixture missing: \(path)") }
        var request = Leyline_V1_AttachFileDeviceRequest()
        request.path = path
        request.loop = loop
        _ = try await c.control.attachFileDevice(request, metadata: testMetadata)
    }

    func startDecode(_ c: DaemonClients, _ config: Leyline_V1_DecodeConfig) async throws -> Leyline_V1_Job {
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        return try await c.jobs.getJob(ref, metadata: testMetadata)
    }

    func cancel(_ c: DaemonClients, _ id: String) async throws {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
    }

    /// Records from the start of the job's window until `count` arrive or the time runs out.
    func records(_ c: DaemonClients, job: String, count: Int, timeoutMs: Int = 30000) async throws -> [Leyline_V1_DecodeRecord] {
        var subscription = Leyline_V1_RecordSubscription()
        subscription.jobID = job
        subscription.sinceSeq = 0
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
                XCTFail("\(count) records did not arrive within \(timeoutMs) ms")
                return []
            }
            return first
        }
    }

    func integer(_ rec: Leyline_V1_DecodeRecord, _ name: String) -> Int64 {
        rec.fields[name]?.integer ?? -1
    }

    // MARK: Live

    func testALiveJobSendsOneSegmentPerOverAndNothingBetween() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeSegmentedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            // Looped, so the last over, which runs to the end of the file, has floor after it.
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: true)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "fake"
            let started = try await self.startDecode(c, config)
            let got = try await self.records(c, job: started.jobID, count: 3, timeoutMs: 30000)
            try await self.cancel(c, started.jobID)
            XCTAssertEqual(got.count, 3, "one record per over: \(got.map { $0.fields["text"]?.text ?? "" })")
            guard got.count == 3 else { return }

            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let rate = Double(state.captures.first?.sampleRate ?? 2_400_000)
            // nfm_keyed keys at 1.0, 5.0 and 8.5 s for 1.0, 0.5 and 2.0 s; a segment reaches 0.5 s
            // before each and 0.5 s after. The squelch decides once per capture block, and the
            // follower's pre-roll is whole audio samples, so the edges are good to 150 ms.
            let keyed: [(start: Double, seconds: Double)] = [(1.0, 1.0), (5.0, 0.5), (8.5, 2.0)]
            for (i, rec) in got.enumerated() {
                let audioRate = Double(self.integer(rec, "rate"))
                XCTAssertEqual(rec.over, UInt32(i + 1), "over counts the segments since the job began")
                XCTAssertTrue(rec.clipUri.isEmpty, "no recording holds a live job's audio")
                XCTAssertEqual(rec.fields["text"]?.text, "segment \(i + 1)")
                XCTAssertEqual(self.integer(rec, "outside"), 0, "no frame arrives while the squelch is shut")
                let startS = Double(rec.time.sampleIndex) / rate
                XCTAssertEqual(startS, keyed[i].start - 0.5, accuracy: 0.15, "over \(i + 1) starts a pre-roll before its key-up")
                let seconds = Double(self.integer(rec, "samples")) / audioRate
                XCTAssertEqual(seconds, keyed[i].seconds + 1.0, accuracy: 0.3,
                               "over \(i + 1) holds its keying plus the pre-roll and the hang")
            }
        }
    }

    // MARK: A stored recording

    /// The synthetic recording's capture rate and audio rate: ten capture samples per audio sample,
    /// so every cut in it lands on a whole audio sample and the expected counts are exact.
    static let captureRate: UInt64 = 480_000
    static let audioRate: UInt64 = 48_000

    func capture(_ seconds: Double) -> UInt64 { UInt64((seconds * Double(Self.captureRate)).rounded()) }

    /// Writes a 60 s gated recording of two contiguous 30 s parts through `PartWriter`, the way the
    /// daemon writes one, with squelch intervals at `opens` (seconds, per part). Returns its id.
    func writeRecording(in dir: String, kind: String = "audio",
                        opens: [[(Double, Double)]] = SegmentedDecodeTests.syntheticOpens,
                        finished: Bool = true) async throws -> String
    {
        let id = JobID().string
        let manifest = RecordingManifest(
            jobID: id, kind: kind, frequencyHz: recordFrequencyHz, mode: "NFM", bandwidthHz: 12_500,
            sampleRate: kind == "iq" ? Self.captureRate : Self.audioRate, format: kind == "iq" ? "cf32" : "wav-s16",
            device: nil, gains: [], squelchDbfs: -40,
            gate: RecordingGateInfo(kind: "squelch", preRollMs: 500, hangMs: 5000), partMs: 30_000,
            startedAtNs: WallClock.nowNs(), createdBy: RecordingClient(clientID: "", kind: "cli", label: "test"),
            anchors: [])
        let captureID = CaptureID().string
        let writer = try PartWriter(directory: dir + "/" + id, manifest: manifest, captureID: captureID, centerHz: recordFrequencyHz)
        await writer.noteAnchor(CaptureAnchor(hostTimeNsAtSampleZero: WallClock.nowNs(), sampleRate: Self.captureRate),
                                captureID: captureID, fromSample: 0)
        for (i, partOpens) in opens.enumerated() {
            let start = capture(Double(i) * 30)
            await writer.openPart(at: start)
            let audio = (0..<Int(30 * Self.audioRate)).map { Float(sin(Double($0) * 0.13)) * 0.5 }
            if kind == "iq" {
                await writer.append(iq: Data(count: 8 * 1000))
            } else {
                await writer.append(audio: audio)
            }
            for (open, close) in partOpens {
                await writer.noteSquelch(open: true, at: capture(open))
                await writer.noteSquelch(open: false, at: capture(close))
            }
            await writer.closePart(endSample: capture(Double(i + 1) * 30))
        }
        // An unfinished recording is one whose job is still running: no `ended_by` yet.
        if finished { await writer.finish(endedBy: "duration", endSample: capture(60)) }
        return id
    }

    static let syntheticOpens: [[(Double, Double)]] = [
        [(2.0, 4.0), (4.3, 5.0), (10.0, 12.0), (29.8, 30.0)],
        [(31.0, 33.0), (45.0, 45.2)],
    ]

    /// What the synthetic recording's segments are, worked out by hand from the rule: 0.5 s back
    /// from each first opening, 0.5 s on from each last close, an opening inside the hang
    /// continuing the segment, and neither end past its part.
    static let syntheticSegments: [(part: Int, over: UInt32, start: Double, end: Double)] = [
        (1, 1, 1.5, 5.5),   // 4.3 opens 0.3 s after 4.0 closed: the same over
        (1, 3, 9.5, 12.5),
        (1, 4, 29.3, 30.0), // the hang would run past the part's end
        (2, 1, 30.5, 33.5),
        (2, 2, 44.5, 45.7),
    ]

    func sourceConfig(_ id: String, keep: Bool = false) -> Leyline_V1_DecodeConfig {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = "fake"
        config.sourceUri = "ley://recordings/\(id)"
        config.keep = keep
        return config
    }

    func waitForEnd(_ c: DaemonClients, _ id: String, timeoutMs: Int = 20000) async throws -> Leyline_V1_Job {
        for _ in 0..<(timeoutMs / 20) {
            let j = try await job(c, id)
            if j.state != .running, j.state != .degraded { return j }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await job(c, id)
    }

    func testARecordingIsReadAsFastAsThePluginTakesItAndCutTheLiveWay() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        let store = try makeTempDir("store")
        defer {
            for d in [plugins, recordings, store] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins)
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], storePath: store, recordingsPath: recordings) { c in
            let began = ContinuousClock.now
            let started = try await self.startDecode(c, self.sourceConfig(id, keep: true))
            let done = try await self.waitForEnd(c, started.jobID)
            let took = ContinuousClock.now - began
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            XCTAssertLessThan(took, .seconds(5), "a 60 s recording is read in under 5 s")

            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.captures.isEmpty, "a recording needs no radio")
            XCTAssertTrue(state.channels.isEmpty)

            let got = try await self.records(c, job: started.jobID, count: Self.syntheticSegments.count, timeoutMs: 5000)
            XCTAssertEqual(got.count, Self.syntheticSegments.count, "one record per over")
            for (rec, want) in zip(got, Self.syntheticSegments) {
                XCTAssertEqual(rec.time.sampleIndex, self.capture(want.start),
                               "the record is dated at its segment's first sample, to the sample")
                XCTAssertEqual(rec.clipUri, "ley://recordings/\(id)/\(want.part)")
                XCTAssertEqual(rec.over, want.over, "over is the index of the segment's first opening in its part")
                XCTAssertTrue(rec.channelID.isEmpty)
                XCTAssertTrue(rec.rssiDbfs.isNaN)
                XCTAssertTrue(rec.snrDb.isNaN)
                let samples = (self.capture(want.end) - self.capture(want.start)) / (Self.captureRate / Self.audioRate)
                XCTAssertEqual(self.integer(rec, "samples"), Int64(samples),
                               "the segment holds exactly its span, pre-roll and hang included")
                XCTAssertEqual(self.integer(rec, "frames"), Int64((samples + 4095) / 4096))
                XCTAssertEqual(self.integer(rec, "outside"), 0, "nothing is sent between segments")
                XCTAssertEqual(self.integer(rec, "rate"), Int64(Self.audioRate))
            }

            // Kept, so the records are a resource dated by the recording's own anchor.
            var query = Leyline_V1_RecordQuery()
            query.jobID = started.jobID
            let page = try await c.decoders.queryRecords(query, metadata: testMetadata)
            XCTAssertEqual(page.records.count, Self.syntheticSegments.count)
            XCTAssertEqual(page.anchors.first?.anchor.sampleRate, Self.captureRate)
        }
    }

    func testAGatedRecordingOfTheKeyedFixtureDecodesOverForOver() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: false)
            var record = Leyline_V1_RecordConfig()
            record.frequencyHz = recordFrequencyHz
            record.mode = .nfm
            record.gate = .squelch
            record.squelchDbfs = -40
            record.preRollMs = 500
            record.hangMs = 5000
            record.durationMs = 11_500
            var request = Leyline_V1_StartJobRequest()
            request.record = record
            let recording = try await c.jobs.startJob(request, metadata: testMetadata)
            let recorded = try await self.waitForEnd(c, recording.jobID, timeoutMs: 30000)
            XCTAssertNotEqual(recorded.state, .failed, recorded.statusDetail)

            let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: URL(
                fileURLWithPath: recordings + "/" + recording.jobID + "/recording.json")))
            var want: [(part: Int, start: UInt64, end: UInt64, over: UInt32)] = []
            var rates: (capture: Double, audio: Double) = (Double(manifest.anchors[0].sampleRate), Double(manifest.sampleRate))
            for part in manifest.parts {
                let base = (part.file as NSString).deletingPathExtension
                let sidecar = try JSONDecoder().decode(PartSidecar.self, from: Data(contentsOf: URL(
                    fileURLWithPath: recordings + "/" + recording.jobID + "/" + base + ".json")))
                rates.capture = Double(sidecar.anchor.sampleRate)
                // The manifest leaves the decoder's pre-roll and hang at 0: 500 ms each.
                let preRoll = UInt64(0.5 * rates.capture)
                let hang = preRoll
                var lastEnd = part.startSample
                var current: (start: UInt64, end: UInt64, over: UInt32)?
                for (i, o) in sidecar.recording.squelchOpens.enumerated() {
                    if let cur = current, o.openSample < cur.end {
                        current!.end = o.closeSample + hang
                        continue
                    }
                    if let cur = current {
                        want.append((part.part, cur.start, min(cur.end, part.endSample), cur.over))
                        lastEnd = min(cur.end, part.endSample)
                    }
                    let start = max(o.openSample >= preRoll ? o.openSample - preRoll : 0, part.startSample, lastEnd)
                    current = (start, o.closeSample + hang, UInt32(i + 1))
                }
                if let cur = current { want.append((part.part, cur.start, min(cur.end, part.endSample), cur.over)) }
            }
            XCTAssertEqual(want.count, 3, "nfm_keyed keys three times")

            let started = try await self.startDecode(c, self.sourceConfig(recording.jobID))
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            let got = try await self.records(c, job: started.jobID, count: want.count, timeoutMs: 5000)
            XCTAssertEqual(got.count, want.count)
            for (rec, w) in zip(got, want) {
                XCTAssertEqual(rec.time.sampleIndex, w.start, "the over's opening less the pre-roll, to the sample")
                XCTAssertEqual(rec.over, w.over)
                XCTAssertEqual(rec.clipUri, "ley://recordings/\(recording.jobID)/\(w.part)")
                XCTAssertEqual(self.integer(rec, "outside"), 0)
                // The WAV places a capture sample by the two rates, rounded to an audio sample.
                let part = manifest.parts.first { $0.part == w.part }!
                func frame(_ x: UInt64) -> Int64 {
                    min(Int64(part.samples), Int64((Double(x - part.startSample) * rates.audio / rates.capture).rounded()))
                }
                XCTAssertEqual(self.integer(rec, "samples"), frame(w.end) - frame(w.start),
                               "the frames between START and END hold the interval plus pre-roll and tail")
            }
        }
    }

    func testAContinuousDecoderReadsEveryPartWhole() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        // The plain fake: one record per frame, CONTINUOUS input.
        try writeFakePlugin(in: plugins)
        unsetenv("FAKE_DECODER_SEGMENTS")
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            // Kept, because there are more records than the live window replays.
            let started = try await self.startDecode(c, self.sourceConfig(id, keep: true))
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            // 30 s at 48 kHz is 1,440,000 samples a part, in frames of 4096.
            let perPart = (Int(30 * Self.audioRate) + 4095) / 4096
            var query = Leyline_V1_RecordQuery()
            query.jobID = started.jobID
            let got = try await c.decoders.queryRecords(query, metadata: testMetadata).records.sorted { $0.seq < $1.seq }
            XCTAssertEqual(got.count, 2 * perPart, "every sample of both parts, and nothing twice")
            guard got.count == 2 * perPart else { return }
            XCTAssertEqual(got.first?.time.sampleIndex, 0)
            XCTAssertEqual(got[perPart].time.sampleIndex, self.capture(30), "the second part starts where it was cut")
            XCTAssertEqual(Set(got.prefix(perPart).map(\.clipUri)), ["ley://recordings/\(id)/1"])
            XCTAssertEqual(Set(got.suffix(perPart).map(\.clipUri)), ["ley://recordings/\(id)/2"])
            XCTAssertEqual(Set(got.map(\.over)), [0], "an over is a SEGMENTED notion")
        }
    }

    // MARK: A plugin that misbehaves on a recording

    func testAPluginThatStopsReadingDoesNotHoldUpACancel() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        // The plain fake reads one frame and then never reads again, so the pipe fills and the
        // source's write waits on it.
        try writeFakePlugin(in: plugins, args: ["--deaf-after=1"])
        unsetenv("FAKE_DECODER_SEGMENTS")
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let started = try await self.startDecode(c, self.sourceConfig(id))
            _ = try await self.records(c, job: started.jobID, count: 1, timeoutMs: 5000)
            try await Task.sleep(nanoseconds: 300_000_000)
            let began = ContinuousClock.now
            try await self.cancel(c, started.jobID)
            let took = ContinuousClock.now - began
            XCTAssertLessThan(took, .milliseconds(1200), "a cancel waits on no plugin that has stopped reading: \(took)")
            let j = try await self.job(c, started.jobID)
            XCTAssertEqual(j.state, .cancelled)
        }
    }

    func testAPluginThatNeverExitsFailsTheJobRatherThanHangingIt() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins)
        setenv("FAKE_DECODER_IGNORE_EOF", "1", 1)
        defer { unsetenv("FAKE_DECODER_IGNORE_EOF") }
        DecodeRunner.sourceExitAllowance.withLock { $0 = (0.5, 0.1) }
        defer { DecodeRunner.sourceExitAllowance.withLock { $0 = (30, 2) } }
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let started = try await self.startDecode(c, self.sourceConfig(id))
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 15000)
            XCTAssertEqual(done.state, .failed)
            XCTAssertEqual(done.error.code, EngineError.Code.decoderFailed)
            XCTAssertTrue(done.statusDetail.hasPrefix("fake did not exit within"), done.statusDetail)
            let got = try await self.records(c, job: started.jobID, count: Self.syntheticSegments.count, timeoutMs: 2000)
            XCTAssertEqual(got.count, Self.syntheticSegments.count, "what it answered before it hung is kept")
        }
    }

    func testAPluginThatDiesBeforeAnsweringASegmentIsGivenItAgain() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        // It answers two segments, then dies on the third's END without answering it, once.
        try writeSegmentedPlugin(in: plugins, args: ["--die-after=2"])
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let started = try await self.startDecode(c, self.sourceConfig(id))
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 15000)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            XCTAssertTrue(FileManager.default.fileExists(atPath: plugins + "/fake/.died-once"), "the first plugin was the one set to die")
            let got = try await self.records(c, job: started.jobID, count: Self.syntheticSegments.count, timeoutMs: 3000)
            // Exactly once: the restart starts at the first segment with no record, and every one
            // before it had its record.
            XCTAssertEqual(got.map { "\($0.clipUri) \($0.over)" },
                           Self.syntheticSegments.map { "ley://recordings/\(id)/\($0.part) \($0.over)" },
                           "every over answered once, the one in flight when the plugin died included")
        }
    }

    /// A plugin that dies before answering anything is given three restarts, and the fourth exit
    /// with the cursor where it was ends the job, rather than a restart every 30 s for ever.
    func testAPluginThatNeverAnswersFailsTheJobAfterFourExits() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins, args: ["--exit-at-start=1000"])
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let began = ContinuousClock.now
            let started = try await self.startDecode(c, self.sourceConfig(id))
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 20000)
            let took = ContinuousClock.now - began
            XCTAssertEqual(done.state, .failed, done.statusDetail)
            XCTAssertEqual(done.error.code, EngineError.Code.decoderFailed)
            XCTAssertEqual(done.statusDetail,
                           "fake exited 4 times without decoding ley://recordings/\(id); "
                               + "last status 3: fake decoder giving up at start 4")
            // 1 + 2 + 4 s of backoff between the four starts.
            XCTAssertLessThan(took, .seconds(12), "the job gave up after its fourth exit: \(took)")
        }
    }

    /// Three exits with nothing answered are allowed: the fourth start that works completes the job.
    func testAPluginThatDiesThreeTimesBeforeAnsweringStillCompletes() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins, args: ["--exit-at-start=3"])
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let started = try await self.startDecode(c, self.sourceConfig(id))
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 20000)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            let got = try await self.records(c, job: started.jobID, count: Self.syntheticSegments.count, timeoutMs: 3000)
            XCTAssertEqual(got.count, Self.syntheticSegments.count, "every over answered once")
        }
    }

    // MARK: The key

    func testADecoderNamingAProviderWithNoKeyIsRefusedWithTheCommandThatAddsOne() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins, credentialProvider: "anthropic")
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            do {
                _ = try await self.startDecode(c, self.sourceConfig(id))
                XCTFail("a decoder whose provider has no key started")
            } catch {
                let (code, detail) = errorCode(error)
                XCTAssertEqual(code, EngineError.Code.credentialMissing)
                XCTAssertTrue(detail?.message.contains("ley ai add anthropic") == true, detail?.message ?? "\(error)")
            }
            let jobs = try await c.jobs.listJobs(Leyline_V1_ListJobsRequest(), metadata: testMetadata)
            XCTAssertTrue(jobs.jobs.isEmpty, "a refused job is not a job")
        }
    }

    func testThePluginReadsTheKeyBeforeItsDescriptorOnEveryStart() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        let secret = "sk-ant-test-0123456789-Zq7w"
        try writeSegmentedPlugin(in: plugins, credentialProvider: "anthropic")
        // A second plugin on the live path that dies once, so the key is seen to go to the restart.
        try writeFakePlugin(in: plugins, name: "dies", recipe: (decodeFrequencyHz, 15_000), args: ["--die-after=2"],
                            credentialProvider: "anthropic")
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            var key = Leyline_V1_SetCredentialRequest()
            key.provider = "anthropic"
            key.secret = secret
            _ = try await c.credentials.setCredential(key, metadata: testMetadata)
            // The speech model chosen on this provider reaches the plugin as --model.
            var model = Leyline_V1_FeatureModel()
            model.feature = "speech"
            model.provider = "anthropic"
            model.model = "test-model-1"
            _ = try await c.credentials.setFeatureModel(model, metadata: testMetadata)

            let started = try await self.startDecode(c, self.sourceConfig(id))
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            let got = try await self.records(c, job: started.jobID, count: Self.syntheticSegments.count, timeoutMs: 5000)
            XCTAssertEqual(got.count, Self.syntheticSegments.count)
            for rec in got {
                XCTAssertEqual(rec.fields["key_last_four"]?.text, "Zq7w", "the plugin had the key")
                XCTAssertEqual(rec.fields["model"]?.text, "test-model-1", "the plugin was told the model")
                XCTAssertFalse(try rec.jsonString().contains(secret), "the key reached a record")
            }

            unsetenv("FAKE_DECODER_SEGMENTS")
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "dies"
            config.frequencyHz = decodeFrequencyHz
            let live = try await self.startDecode(c, config)
            // Two records from the first plugin, then the restart's.
            let records = try await self.records(c, job: live.jobID, count: 4, timeoutMs: 15000)
            try await self.cancel(c, live.jobID)
            XCTAssertEqual(records.count, 4)
            XCTAssertEqual(Set(records.map { $0.fields["key_last_four"]?.text ?? "" }), ["Zq7w"],
                           "a restarted plugin reads the key again")
            XCTAssertEqual(Set(records.map { $0.fields["model"]?.text ?? "" }), ["test-model-1"],
                           "and is told the model again")
        }
    }

    /// The key's presence is told to the plugin in its environment, by the installed manifest: a
    /// binary built without a provider of its own cannot tell from its built-in manifest. A daemon
    /// that has the variable in its own environment does not pass it to a plugin it sends no key.
    func testThePluginIsToldInItsEnvironmentWhenAKeyComesFirst() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        // Dumps its environment into its own directory, then reads its input to the end.
        let script = plugins + "/dump-env"
        try "#!/bin/sh\nenv > plugin.env\ncat > /dev/null\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        try writeSegmentedPlugin(in: plugins, name: "free", executable: script)
        try writeSegmentedPlugin(in: plugins, name: "paid", executable: script, credentialProvider: "anthropic")
        setenv("LEYLINE_KEY_ON_STDIN", "1", 1)
        defer { unsetenv("LEYLINE_KEY_ON_STDIN") }
        let id = try await writeRecording(in: recordings)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            var key = Leyline_V1_SetCredentialRequest()
            key.provider = "anthropic"
            key.secret = "sk-ant-test-env-0000"
            _ = try await c.credentials.setCredential(key, metadata: testMetadata)
            for name in ["free", "paid"] {
                var config = self.sourceConfig(id)
                config.decoder = name
                let started = try await self.startDecode(c, config)
                let done = try await self.waitForEnd(c, started.jobID)
                XCTAssertEqual(done.state, .completed, "\(name): \(done.statusDetail)")
            }
        }
        func environment(_ name: String) throws -> [String] {
            try String(contentsOfFile: "\(plugins)/\(name)/plugin.env", encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        XCTAssertTrue(try environment("paid").contains("LEYLINE_KEY_ON_STDIN=1"), "a plugin sent the key is told so")
        XCTAssertFalse(try environment("free").contains { $0.hasPrefix("LEYLINE_KEY_ON_STDIN=") },
                       "a plugin sent no key is not told one is coming, whatever the daemon's own environment says")
        XCTAssertTrue(try environment("free").contains { $0.hasPrefix("PATH=") }, "the rest is the daemon's environment")
    }

    func testARecordingSourceIsRefusedWhenItCannotBeRead() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins)
        let iq = try await writeRecording(in: recordings, kind: "iq")
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            func refusal(_ uri: String) async -> String {
                var config = self.sourceConfig("")
                config.sourceUri = uri
                do {
                    _ = try await self.startDecode(c, config)
                    return "started"
                } catch {
                    return errorCode(error).code
                }
            }
            let missing = await refusal("ley://recordings/job_01JAAAAAAAAAAAAAAAAAAAAAAA")
            XCTAssertEqual(missing, EngineError.Code.jobNotFound, "as ResolveLocalPath says it")
            let iqCode = await refusal("ley://recordings/\(iq)")
            XCTAssertEqual(iqCode, EngineError.Code.unimplemented, "an IQ recording needs an offline demodulator first")
            let part = await refusal("ley://recordings/\(iq)/1")
            XCTAssertEqual(part, EngineError.Code.invalidArgument)
            let notRecording = await refusal("ley://records/\(iq)")
            XCTAssertEqual(notRecording, EngineError.Code.invalidArgument)
            let running = try await self.writeRecording(in: recordings, finished: false)
            let stillRecording = await refusal("ley://recordings/\(running)")
            XCTAssertEqual(stillRecording, EngineError.Code.failedPrecondition, "a recording still being made")
        }
    }

    func testARecordingWithNoOpeningsEndsWithNothingDecoded() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins)
        let quiet = try await writeRecording(in: recordings, opens: [[], []])
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            let started = try await self.startDecode(c, self.sourceConfig(quiet))
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, "nothing to send is not an error: \(done.statusDetail)")
            XCTAssertFalse(done.hasError)
            XCTAssertTrue(done.statusDetail.contains("0 records"), done.statusDetail)
        }
    }

    func testSegmentedIQInputIsNotImplemented() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, json: """
        {
          "name": "fake",
          "version": "0.1.0",
          "recipe": {"frequenciesHz": ["\(recordFrequencyHz)"]},
          "input": {"mode": "SEGMENTED", "signal": "SIGNAL_IQ"},
          "executable": "\(fakeDecoderPath())"
        }
        """)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "fake"
            do {
                _ = try await self.startDecode(c, config)
                XCTFail("a segmented IQ decoder started")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.unimplemented)
            }
        }
    }
}
