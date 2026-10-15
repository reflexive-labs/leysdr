// SPDX-License-Identifier: Apache-2.0

// Speech in the Library without a daemon: hand-made speech records folded onto a hand-made gated
// recording, the newest transcription shown by default, one over's sample range from the part's
// openings, the search, the text and SRT exports byte for byte, the sidecar read, the question
// `ley transcribe` asks, and the transcription's status line.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class SpeechRecordsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-13 14:03:00 UTC, the capture's sample 0.
    private let hostNs: Int64 = 1_791_900_180_000_000_000
    private let rate: UInt64 = 2_400_000

    private func ms(_ v: UInt64) -> UInt64 { v * rate / 1000 }

    /// Two parts on `cap_a`, recorded with a 1 s gate pre-roll that an over's audio must not use:
    /// part 1 from 0 to 6 s with three openings, the first two inside the
    /// half-second hang of each other, so the decoder heard them as one segment; part 2 from 16 s
    /// to 18 s with one.
    private func manifest() -> RecordingManifest {
        let json = """
            {"job_id": "job_rec", "kind": "audio", "frequency_hz": 146520000, "mode": "NFM",
             "sample_rate": 48000, "gate": {"kind": "squelch", "pre_roll_ms": 1000, "hang_ms": 5000},
             "anchors": [{"capture_id": "cap_a", "host_time_ns": \(hostNs), "sample_rate": 2400000,
                          "drift_ppm": 0, "from_sample": 0}],
             "parts": [
               {"part": 1, "file": "p1.wav", "start_sample": 0, "end_sample": 14400000,
                "samples": 288000, "bytes": 576044, "squelch_opens": 3, "squelch_open_ms": 2600},
               {"part": 2, "file": "p2.wav", "start_sample": 38400000, "end_sample": 43200000,
                "samples": 96000, "bytes": 192044, "squelch_opens": 1}]}
            """
        var m = try! RecordingManifest.decode(Data(json.utf8))
        m.parts[0].squelchIntervals = [
            .init(openSample: ms(600), closeSample: ms(1600)),
            .init(openSample: ms(1900), closeSample: ms(2500)),
            .init(openSample: ms(4000), closeSample: ms(5000)),
        ]
        m.parts[1].squelchIntervals = [.init(openSample: ms(16_600), closeSample: ms(17_200))]
        return m
    }

    private func record(
        job: String, id: String, part: Int, over: UInt32, at sample: UInt64, text: String,
        model: String = "scripted", confidence: Double? = nil, callsigns: String = "",
        seq: UInt64 = 1, recording: String = "job_rec", protocol p: String = "speech"
    ) -> Leyline_V1_DecodeRecord {
        .with {
            $0.recordID = id
            $0.jobID = job
            $0.protocol = p
            $0.seq = seq
            $0.clipUri = "ley://recordings/\(recording)/\(part)"
            $0.over = over
            $0.time = .with {
                $0.captureID = "cap_a"
                $0.sampleIndex = sample
            }
            $0.fields["text"] = .with { $0.text = text }
            $0.fields["model"] = .with { $0.text = model }
            if let c = confidence { $0.fields["confidence"] = .with { $0.number = c } }
            if !callsigns.isEmpty { $0.fields["callsigns"] = .with { $0.text = callsigns } }
        }
    }

    /// The first transcription, job_01: one line per segment, the two-opening segment as one
    /// line at its first opening.
    private func firstJob() -> [Leyline_V1_DecodeRecord] {
        [
            record(
                job: "job_01", id: "rec_1", part: 1, over: 1, at: ms(100),
                text: "This is whiskey six alpha bravo charlie", confidence: 0.92,
                callsigns: "W6ABC", seq: 1),
            record(
                job: "job_01", id: "rec_2", part: 1, over: 3, at: ms(3500),
                text: "Road closed at the bridge", seq: 2),
            record(
                job: "job_01", id: "rec_3", part: 2, over: 1, at: ms(16_100),
                text: "Roger, K6XYZ and W6ABC", callsigns: "K6XYZ, W6ABC", seq: 3),
        ]
    }

    private func speech(_ records: [Leyline_V1_DecodeRecord]) -> RecordingSpeech {
        RecordingSpeech(
            lines: SpeechRecords.byRecording(records)["job_rec"] ?? [], manifest: manifest())
    }

    func testRecordsFoldOntoPartsAndOvers() {
        let other = record(
            job: "job_01", id: "rec_x", part: 1, over: 1, at: 0, text: "elsewhere",
            recording: "job_other")
        let aprs = record(
            job: "job_02", id: "rec_y", part: 1, over: 1, at: 0, text: "", protocol: "aprs")
        let by = SpeechRecords.byRecording(firstJob() + [other, aprs])
        XCTAssertEqual(by.keys.sorted(), ["job_other", "job_rec"], "speech only, by clip_uri")
        let s = speech(firstJob())
        let shown = s.shown()
        XCTAssertEqual(shown.map(\.recordID), ["rec_1", "rec_2", "rec_3"], "part, then over")
        XCTAssertEqual(shown.map(\.over), [1, 3, 1])
        XCTAssertEqual(s.shown(part: 1).count, 2, "two openings heard as one segment are one line")
        let first = shown[0]
        XCTAssertEqual(first.partURI, "ley://recordings/job_rec/1")
        XCTAssertEqual(first.model, "scripted")
        XCTAssertEqual(first.confidence, 0.92)
        XCTAssertEqual(first.sourceWords, "scripted · 92%")
        XCTAssertEqual(shown[2].callsigns, ["K6XYZ", "W6ABC"])
        XCTAssertEqual(shown[1].sourceWords, "scripted", "no confidence reported, none shown")
        XCTAssertEqual(
            first.wallTime, Date(timeIntervalSince1970: 1_791_900_180.1),
            "dated through the manifest's anchor")
    }

    /// Transcribing again adds records; the newest job's line is shown for each over it covers,
    /// the earlier one stays available, and an over only the earlier job covered still shows.
    func testTheNewestTranscriptionIsShownByDefault() {
        let again = [
            record(
                job: "job_02", id: "rec_9", part: 1, over: 1, at: ms(100),
                text: "This is Whiskey 6 Alpha Bravo Charlie", model: "better", seq: 1)
        ]
        let s = speech(firstJob() + again)
        XCTAssertEqual(s.jobs, ["job_02", "job_01"])
        XCTAssertEqual(s.shown().map(\.recordID), ["rec_9", "rec_2", "rec_3"])
        XCTAssertEqual(s.versions(part: 1, over: 1).map(\.recordID), ["rec_9", "rec_1"])
        XCTAssertEqual(s.shown(job: "job_01").map(\.recordID), ["rec_1", "rec_2", "rec_3"])
        XCTAssertEqual(s.shown(job: "job_02").map(\.recordID), ["rec_9"])
        // A segment sent twice within one job (a restart) shows its later record.
        let resent = record(
            job: "job_01", id: "rec_4", part: 1, over: 3, at: ms(3500), text: "Road closed", seq: 4)
        XCTAssertEqual(speech(firstJob() + [resent]).shown(part: 1).last?.recordID, "rec_4")
    }

    /// An over plays its segment as the speech decoder cut it: half a second before its first
    /// opening, not the recording's 1 s gate pre-roll, to half a second after its last close.
    /// Over 2 lies inside over 1's segment and plays the same.
    func testAnOverPlaysItsSegment() throws {
        let m = manifest()
        let one = try XCTUnwrap(SpeechRecords.range(over: 1, of: m.parts[0], in: m))
        XCTAssertEqual(one.start, ms(100))
        XCTAssertEqual(one.end, ms(3000))
        let two = try XCTUnwrap(SpeechRecords.range(over: 2, of: m.parts[0], in: m))
        XCTAssertEqual(two.start, one.start)
        XCTAssertEqual(two.end, one.end)
        let three = try XCTUnwrap(SpeechRecords.range(over: 3, of: m.parts[0], in: m))
        XCTAssertEqual(three.start, ms(3500))
        XCTAssertEqual(three.end, ms(5500))
        XCTAssertNil(SpeechRecords.range(over: 4, of: m.parts[0], in: m))
        XCTAssertNil(SpeechRecords.range(over: 0, of: m.parts[0], in: m), "0 plays the whole part")
        var unread = m.parts[0]
        unread.squelchIntervals = nil
        XCTAssertNil(SpeechRecords.range(over: 1, of: unread, in: m))
    }

    /// The Go rule's own example (`leyline.TestSegments`), so both clients cut alike.
    func testSegmentsMatchTheDaemonsRule() {
        let opens: [SquelchInterval] = [
            .init(openSample: 1000, closeSample: 2000), .init(openSample: 2300, closeSample: 2500),
            .init(openSample: 2600, closeSample: 3000), .init(openSample: 9000, closeSample: 9900),
        ]
        let got = SpeechRecords.segments(
            opens, partStart: 500, partEnd: 10_000, preRoll: 600, hang: 400)
        XCTAssertEqual(got.map(\.start), [500, 8400])
        XCTAssertEqual(got.map(\.end), [3400, 10_000])
        XCTAssertEqual(got.map(\.first), [1, 4])
        XCTAssertEqual(got.map(\.last), [3, 4])
    }

    func testSearchFindsTheOverByItsWords() throws {
        let s = speech(firstJob())
        XCTAssertEqual(SpeechRecords.search("ROAD closed", in: s.shown())?.recordID, "rec_2")
        XCTAssertNil(SpeechRecords.search("  ", in: s.shown()), "an empty query selects nothing")
        XCTAssertNil(SpeechRecords.search("net control", in: s.shown()))
        let summary = RecordingSummary(
            .with {
                $0.uri = "ley://recordings/job_rec"
                $0.originatingJobID = "job_rec"
                $0.metadata = ["frequency_hz": "146520000", "mode": "NFM"]
            })
        let channel = RecordingChannel(
            frequencyHz: 146_520_000, mode: .nfm, bookmarkName: nil, recordings: [summary],
            running: false, latest: nil)
        let hit = try XCTUnwrap(SpeechRecords.hit("k6xyz", in: channel, speech: ["job_rec": s]))
        XCTAssertEqual(hit.partURI, "ley://recordings/job_rec/2")
        XCTAssertEqual(hit.over, 1)
        XCTAssertNil(SpeechRecords.hit("k6xyz", in: channel, speech: [:]), "nothing loaded, no hit")
    }

    func testTheTextExportIsOneLinePerOver() {
        let text = SpeechRecords.export(
            speech(firstJob()), manifest: manifest(), format: .text, timeZone: utc
        ).text
        XCTAssertEqual(
            text,
            """
            [14:03:00] This is whiskey six alpha bravo charlie (W6ABC)
            [14:03:03] Road closed at the bridge
            [14:03:16] Roger, K6XYZ and W6ABC (K6XYZ, W6ABC)

            """)
    }

    /// SRT times run from the recording's first sample through the anchor, so the ten seconds
    /// between the parts are kept; each cue lasts as long as its over plays.
    func testTheSRTExportIsTimedFromTheAnchor() {
        let srt = SpeechRecords.export(
            speech(firstJob()), manifest: manifest(), format: .srt, timeZone: utc
        ).text
        XCTAssertEqual(
            srt,
            """
            1
            00:00:00,100 --> 00:00:03,000
            This is whiskey six alpha bravo charlie

            2
            00:00:03,500 --> 00:00:05,500
            Road closed at the bridge

            3
            00:00:16,100 --> 00:00:17,700
            Roger, K6XYZ and W6ABC


            """)
        XCTAssertEqual(SpeechRecords.srtTime(3_723.45), "01:02:03,450")
    }

    /// `read(at:)` reads the openings and the capture rate from the sidecar of a part whose
    /// squelch opened, and leaves a part with none alone.
    func testTheManifestReaderTakesTheSidecarsOpenings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifestJSON = """
            {"job_id": "job_r", "kind": "audio", "sample_rate": 48000,
             "anchors": [{"capture_id": "cap_a", "host_time_ns": 1, "sample_rate": 2400000}],
             "parts": [
               {"part": 1, "file": "a.wav", "start_sample": 0, "end_sample": 4800000, "samples": 96000,
                "squelch_opens": 2},
               {"part": 2, "file": "b.wav", "start_sample": 9600000, "end_sample": 12000000,
                "samples": 48000, "squelch_opens": 0}]}
            """
        let sidecar = """
            {"format": "wav-s16", "sample_rate": 48000,
             "anchor": {"capture_id": "cap_a", "host_time_ns": 1, "sample_rate": 2400000, "drift_ppm": 0},
             "recording": {"part": 1, "squelch_opens": [
               {"open_sample": 1200000, "close_sample": 2400000},
               {"open_sample": 3000000, "close_sample": 3600000}]}}
            """
        try Data(manifestJSON.utf8).write(to: dir.appendingPathComponent("recording.json"))
        try Data(sidecar.utf8).write(to: dir.appendingPathComponent("a.json"))
        let m = try RecordingManifest.read(at: dir)
        XCTAssertEqual(
            m.parts[0].squelchIntervals,
            [
                .init(openSample: 1_200_000, closeSample: 2_400_000),
                .init(openSample: 3_000_000, closeSample: 3_600_000),
            ])
        XCTAssertEqual(m.parts[0].captureRate, 2_400_000)
        XCTAssertNil(m.parts[1].squelchIntervals, "a part whose squelch never opened is not read")
        XCTAssertEqual(
            SpeechRecords.squelchOpenMs(m), 750, "no squelch_open_ms: the openings summed")
    }

    /// The question is `ley transcribe`'s statement, word for word, with a question mark.
    func testTheQuestionIsLeyTranscribes() {
        var d = Leyline_V1_DecoderManifest()
        d.name = "speech"
        d.input.mode = .segmented
        XCTAssertEqual(
            SpeechRecords.question(manifest: manifest(), decoder: d),
            "Transcribe 2 parts, 0.1 min of squelch-open audio from 146.520 MHz NFM, with speech (on this Mac; no audio leaves it)?"
        )
        d.contactsHosts = ["api.example.com"]
        XCTAssertTrue(
            SpeechRecords.question(manifest: manifest(), decoder: d, model: "m2")
                .hasSuffix(
                    "with speech, model m2 (sends the audio to api.example.com); the speech model is set to m2 for this and later jobs?"
                ))
        XCTAssertEqual(
            SpeechRecords.squelchOpenMs(manifest()), 3200, "2600 from the key, 600 summed")
        XCTAssertTrue(SpeechRecords.canTranscribe(decoder: d, ai: .init()), "no key needed")
        d.credentialProvider = "openai"
        XCTAssertFalse(
            SpeechRecords.canTranscribe(decoder: d, ai: .init()), "a key needed and none set")
        XCTAssertFalse(SpeechRecords.canTranscribe(decoder: nil, ai: .init()))
    }

    func testTheTranscriptionJobAndItsLine() {
        let cfg = SpeechRecords.transcribeConfig(recordingURI: "ley://recordings/job_rec")
        XCTAssertEqual(cfg.decoder, "speech")
        XCTAssertEqual(cfg.sourceUri, "ley://recordings/job_rec")
        XCTAssertTrue(cfg.keep)
        func job(_ id: String, _ state: Leyline_V1_JobState) -> Leyline_V1_Job {
            .with {
                $0.jobID = id
                $0.state = state
                $0.decode = cfg
            }
        }
        var running = job("job_02", .running)
        let jobs = [job("job_01", .completed), running, .with { $0.jobID = "job_09" }]
        XCTAssertEqual(
            SpeechRecords.transcription(of: "ley://recordings/job_rec", in: jobs)?.jobID, "job_02")
        XCTAssertEqual(SpeechRecords.statusLine(job: running, speech: nil), "Transcribing")
        let lines = speech([
            record(job: "job_02", id: "r", part: 1, over: 1, at: ms(100), text: "hi")
        ])
        XCTAssertEqual(
            SpeechRecords.statusLine(job: running, speech: lines), "Transcribing · 1 over so far")
        running.state = .degraded
        running.statusDetail = "the provider's rate limit; retrying in 30 s"
        XCTAssertEqual(SpeechRecords.statusLine(job: running, speech: lines), running.statusDetail)
        running.state = .failed
        running.error = .with {
            $0.code = "CREDENTIAL_MISSING"
            $0.message = "no key for openai"
        }
        XCTAssertEqual(
            SpeechRecords.statusLine(job: running, speech: lines),
            "Could not transcribe: no key for openai")
        XCTAssertNil(SpeechRecords.statusLine(job: job("job_01", .completed), speech: lines))
    }

    /// Transcribe again offers the model in use first, then the catalogue's speech models.
    func testTranscribeAgainOffersTheModelInUseFirst() {
        let speechy = AIProvider(
            id: "acme", name: "Acme", features: ["speech"], models: ["s1", "s2"],
            reach: .cloud(host: "api.acme.test"), takesEndpoint: false)
        var ai = Leyline_V1_AIState()
        XCTAssertEqual(SpeechRecords.models(ai, providers: [speechy]).offered, ["s1", "s2"])
        ai.features = [
            .with {
                $0.feature = "speech"
                $0.provider = "acme"
                $0.model = "s2"
            }
        ]
        let got = SpeechRecords.models(ai, providers: [speechy])
        XCTAssertEqual(got.current, "s2")
        XCTAssertEqual(got.offered, ["s2", "s1"])
    }

    func testARecordingURIGivesItsID() {
        XCTAssertEqual(RecordingPartRef.recordingID(of: "ley://recordings/job_rec"), "job_rec")
        XCTAssertNil(RecordingPartRef.recordingID(of: "ley://recordings/job_rec/2"))
        XCTAssertNil(RecordingPartRef.recordingID(of: "ley://records/job_rec"))
        XCTAssertNil(RecordingPartRef.recordingID(of: "ley://recordings/"))
    }

    /// A recording across two captures: each part's cues are timed through its own capture's
    /// anchor, the second one's drift included, from the first part's first sample; a line
    /// nothing dates is left out of the SRT and counted, not given a cue at 0.
    func testSRTFollowsEachCapturesAnchorAndSkipsUndatedLines() throws {
        let json = """
            {"job_id": "job_two", "kind": "audio", "frequency_hz": 146520000, "mode": "NFM",
             "sample_rate": 48000,
             "anchors": [
               {"capture_id": "cap_a", "host_time_ns": \(hostNs), "sample_rate": 2400000, "from_sample": 0},
               {"capture_id": "cap_b", "host_time_ns": \(hostNs + 100_000_000_000), "sample_rate": 2400000,
                "drift_ppm": 100, "from_sample": 0}],
             "parts": [
               {"part": 1, "file": "p1.wav", "start_sample": 0, "end_sample": 2400000,
                "samples": 48000, "squelch_opens": 1},
               {"part": 2, "file": "p2.wav", "start_sample": 0, "end_sample": 720000000,
                "samples": 14400000, "squelch_opens": 1}]}
            """
        var m = try RecordingManifest.decode(Data(json.utf8))
        m.parts[0].captureID = "cap_a"
        m.parts[0].squelchIntervals = [.init(openSample: ms(200), closeSample: ms(800))]
        m.parts[1].captureID = "cap_b"
        m.parts[1].squelchIntervals = [.init(openSample: ms(100_000), closeSample: ms(101_000))]
        func line(_ id: String, part: Int, over: UInt32, capture: String, at sample: UInt64)
            -> Leyline_V1_DecodeRecord
        {
            var r = record(
                job: "job_t", id: id, part: part, over: over, at: sample, text: id,
                recording: "job_two")
            r.time.captureID = capture
            return r
        }
        let records = [
            line("first", part: 1, over: 1, capture: "cap_a", at: 0),
            line("undated", part: 1, over: 2, capture: "cap_z", at: 0),
            line("second", part: 2, over: 1, capture: "cap_b", at: ms(99_500)),
        ]
        let speech = RecordingSpeech(
            lines: SpeechRecords.byRecording(records)["job_two"] ?? [], manifest: m)
        let srt = SpeechRecords.export(speech, manifest: m, format: .srt, timeZone: utc)
        XCTAssertEqual(srt.skipped, 1)
        // Part 1 ends at 1 s, which ends its cue short of the hang. Part 2's over starts 99.5 s into capture b, which runs 100 ppm slow against the clock:
        // 99.50995 s after its anchor, which is 100 s after the first part's first sample.
        XCTAssertEqual(
            srt.text,
            """
            1
            00:00:00,000 --> 00:00:01,000
            first

            2
            00:03:19,510 --> 00:03:21,510
            second


            """)
    }

    /// One query covers a channel's recordings: from a minute before the first began to a minute
    /// after the last ended; a recording nothing dates leaves the start open.
    func testOneQueryCoversSeveralRecordings() {
        func summary(_ id: String, _ from: Int64, _ to: Int64) -> RecordingSummary {
            RecordingSummary(
                .with {
                    $0.uri = "ley://recordings/\(id)"
                    $0.originatingJobID = id
                    $0.metadata = [
                        "started_at_ns": "\(from * 1_000_000_000)",
                        "ended_at_ns": "\(to * 1_000_000_000)",
                    ]
                })
        }
        let now = Date(timeIntervalSince1970: 5_000)
        let q = SpeechRecords.query(
            for: [summary("job_b", 2_000, 2_100), summary("job_a", 1_000, 1_100)], now: now)
        XCTAssertEqual(q.protocol, "speech")
        XCTAssertEqual(q.sinceNs, 940_000_000_000)
        XCTAssertEqual(q.untilNs, 2_160_000_000_000)
        let open = SpeechRecords.query(for: [summary("job_c", 0, 0)], now: now)
        XCTAssertEqual(open.sinceNs, 0, "undated: no lower bound")
        XCTAssertEqual(open.untilNs, 5_060_000_000_000, "still running as far as anyone knows")
    }

    /// Re-reading a recording keeps what an earlier read took from the sidecars of parts that have
    /// not changed, and reads only the new part's.
    func testAReReadOpensOnlyTheNewPartsSidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func part(_ n: Int, _ from: Int) -> String {
            """
            {"part": \(n), "file": "p\(n).wav", "start_sample": \(from), "end_sample": \(from + 2_400_000),
             "samples": 48000, "squelch_opens": 1}
            """
        }
        func sidecar(_ open: Int) -> String {
            """
            {"anchor": {"capture_id": "cap_a", "sample_rate": 2400000},
             "recording": {"squelch_opens": [{"open_sample": \(open), "close_sample": \(open + 1000)}]}}
            """
        }
        func manifest(_ parts: [String]) -> String {
            """
            {"job_id": "job_r", "sample_rate": 48000,
             "anchors": [{"capture_id": "cap_a", "host_time_ns": 1, "sample_rate": 2400000}],
             "parts": [\(parts.joined(separator: ","))]}
            """
        }
        let file = dir.appendingPathComponent("recording.json")
        try Data(manifest([part(1, 0)]).utf8).write(to: file)
        try Data(sidecar(100).utf8).write(to: dir.appendingPathComponent("p1.json"))
        let first = try RecordingManifest.read(at: dir)
        XCTAssertEqual(first.parts[0].squelchIntervals?.first?.openSample, 100)

        // Part 2 closes. Part 1's sidecar is gone, so a value for it can only be the earlier one.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("p1.json"))
        try Data(manifest([part(1, 0), part(2, 4_800_000)]).utf8).write(to: file)
        try Data(sidecar(4_800_500).utf8).write(to: dir.appendingPathComponent("p2.json"))
        let again = try RecordingManifest.read(at: dir, reusing: first)
        XCTAssertEqual(again.parts[0].squelchIntervals?.first?.openSample, 100)
        XCTAssertEqual(again.parts[1].squelchIntervals?.first?.openSample, 4_800_500)
        XCTAssertNil(
            try RecordingManifest.read(at: dir).parts[0].squelchIntervals,
            "without the earlier read, part 1's sidecar is looked for")
    }

    /// The decoder's own pre-roll and hang, 0 read as the half-second defaults.
    func testTheDecodersTimingsCutTheOvers() throws {
        XCTAssertEqual(SpeechRecords.timings(nil).preRollMs, 500)
        var d = Leyline_V1_DecoderManifest()
        d.input.preRollMs = 250
        XCTAssertEqual(SpeechRecords.timings(d).preRollMs, 250)
        XCTAssertEqual(SpeechRecords.timings(d).hangMs, 500)
        let m = manifest()
        let r = try XCTUnwrap(SpeechRecords.range(over: 3, of: m.parts[0], in: m, preRollMs: 250))
        XCTAssertEqual(r.start, ms(3750))
    }
}
