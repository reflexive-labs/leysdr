// SPDX-License-Identifier: Apache-2.0

// Recordings without a daemon: a hand-written `recording.json` in the shape
// docs/design/recording.md, "The manifest" gives, parsed; the containment rule that puts a live
// transmission inside a part; the log's rows merged from live transmissions and parts; the
// sidebar's summary from a resource's metadata; the record job the window starts; and the
// header's status words.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class RecordingsTests: XCTestCase {
    /// Two closed parts of a gated audio recording on `cap_a`, dated by one anchor; the second
    /// part's levels were never measured, so its peak and mean are absent. No squelch key: the
    /// recording's squelch is off.
    private let manifestJSON = """
        {
          "job_id": "job_a",
          "uri": "ley://recordings/job_a",
          "kind": "audio",
          "frequency_hz": 462562500,
          "mode": "NFM",
          "bandwidth_hz": 12500,
          "sample_rate": 48000,
          "format": "wav-s16",
          "device": { "driver": "rtlsdr", "model": "Nooelec NESDR SMArt", "serial": "00000001" },
          "gains": [ { "element": "tuner", "value_db": 29.7 } ],
          "gate": { "kind": "squelch", "pre_roll_ms": 500, "hang_ms": 5000 },
          "part_ms": 0,
          "started_at_ns": 1789653802000000000,
          "ended_at_ns": 0,
          "ended_by": "",
          "created_by": { "client_id": "app_01", "kind": "app", "label": "Leyline" },
          "anchors": [ { "capture_id": "cap_a", "host_time_ns": 1789653700000000000,
                         "sample_rate": 2400000, "drift_ppm": 0, "from_sample": 0 } ],
          "parts": [
            { "part": 1, "file": "p1.wav", "start_sample": 2400000, "end_sample": 7200000,
              "samples": 96000, "bytes": 192044, "peak_dbfs": -6.2, "mean_dbfs": -18.4,
              "squelch_opens": 2 },
            { "part": 2, "file": "p2.wav", "start_sample": 12000000, "end_sample": 14400000,
              "samples": 48000, "bytes": 96044, "squelch_opens": 1 }
          ],
          "coverage_gaps": [ { "from_sample": 7200000, "to_sample": 12000000,
                               "reason": "squelch closed" } ],
          "bytes": 288088
        }
        """

    private func manifest() throws -> RecordingManifest {
        try RecordingManifest.decode(Data(manifestJSON.utf8))
    }

    private func at(_ index: UInt64, capture: String = "cap_a") -> Leyline_V1_SampleTime {
        .with {
            $0.captureID = capture
            $0.sampleIndex = index
        }
    }

    private func heard(_ from: UInt64, _ to: UInt64, capture: String = "cap_a") -> Transmission {
        Transmission(
            start: at(from, capture: capture), end: at(to, capture: capture),
            seconds: Double(to - from) / 2_400_000, peakSNRDB: 20, peakAudioDBFS: -8, tone: nil)
    }

    func testParsesTheManifest() throws {
        let m = try manifest()
        XCTAssertEqual(m.jobID, "job_a")
        XCTAssertEqual(m.frequencyHz, 462_562_500)
        XCTAssertEqual(m.demodMode, .nfm)
        XCTAssertEqual(m.bandwidthHz, 12_500)
        XCTAssertEqual(m.sampleRate, 48_000)
        XCTAssertEqual(m.device?.model, "Nooelec NESDR SMArt")
        XCTAssertEqual(m.gains, [RecordingManifest.Gain(element: "tuner", valueDB: 29.7)])
        XCTAssertTrue(m.squelchDBFS.isNaN, "an absent squelch is off")
        XCTAssertEqual(m.gate?.hangMs, 5000)
        XCTAssertEqual(m.createdBy?.kind, "app")
        XCTAssertEqual(m.anchors.first?.sampleRate, 2_400_000)
        XCTAssertEqual(m.parts.map(\.part), [1, 2])
        XCTAssertEqual(m.parts[0].peakDBFS, -6.2)
        XCTAssertNil(m.parts[1].peakDBFS, "a level nobody measured stays absent")
        XCTAssertEqual(m.parts.map(\.captureID), ["cap_a", "cap_a"], "the anchors' one capture")
        XCTAssertEqual(m.coverageGaps.first?.reason, "squelch closed")
        XCTAssertEqual(m.bytes, 288_088)
        XCTAssertEqual(m.uri(of: m.parts[1]), "ley://recordings/job_a/2")
        XCTAssertEqual(m.startedAt, Date(timeIntervalSince1970: 1_789_653_802))
    }

    func testReadsFromTheRecordingsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(manifestJSON.utf8).write(to: dir.appendingPathComponent("recording.json"))
        let fromDirectory = try RecordingManifest.read(at: dir)
        let fromFile = try RecordingManifest.read(at: dir.appendingPathComponent("recording.json"))
        XCTAssertEqual(fromDirectory, try manifest())
        XCTAssertEqual(fromFile, fromDirectory)
    }

    func testTwoCapturesTakeEachPartsCaptureFromItsSidecar() throws {
        var json = manifestJSON.replacingOccurrences(
            of: #""from_sample": 0 } ],"#,
            with:
                #""from_sample": 0 }, { "capture_id": "cap_b", "host_time_ns": 1789653900000000000, "sample_rate": 2400000, "drift_ppm": 0, "from_sample": 0 } ],"#
        )
        json = json.replacingOccurrences(
            of: "\"ended_by\": \"\"", with: "\"ended_by\": \"restart\"")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(json.utf8).write(to: dir.appendingPathComponent("recording.json"))
        try Data(#"{"anchor": {"capture_id": "cap_b"}}"#.utf8)
            .write(to: dir.appendingPathComponent("p2.json"))
        let m = try RecordingManifest.read(at: dir)
        XCTAssertEqual(m.anchors.count, 2)
        XCTAssertEqual(m.parts.map(\.captureID), [nil, "cap_b"], "part 1 has no sidecar here")
        XCTAssertEqual(
            try RecordingManifest.decode(Data(json.utf8)).parts.map(\.captureID), [nil, nil],
            "without the files, two captures cannot be told apart")
    }

    func testMatchesATransmissionInsideAPart() throws {
        let parts = try manifest().parts
        // Inside part 1, and exactly on its edges.
        XCTAssertEqual(
            RecordingParts.match(transmission: heard(3_600_000, 6_000_000), in: parts)?.part, 1)
        XCTAssertEqual(
            RecordingParts.match(transmission: heard(2_400_000, 7_200_000), in: parts)?.part, 1)
        // Starts before part 1, runs past its end, lies in the gap: none.
        XCTAssertNil(RecordingParts.match(transmission: heard(2_000_000, 6_000_000), in: parts))
        XCTAssertNil(RecordingParts.match(transmission: heard(6_000_000, 8_000_000), in: parts))
        XCTAssertNil(RecordingParts.match(transmission: heard(8_000_000, 9_000_000), in: parts))
        // The same samples on another capture's timeline are another time.
        XCTAssertNil(
            RecordingParts.match(
                transmission: heard(3_600_000, 6_000_000, capture: "cap_b"), in: parts))
        // A part whose capture could not be told matches nothing.
        var unknown = parts
        unknown[0].captureID = nil
        XCTAssertNil(RecordingParts.match(transmission: heard(3_600_000, 6_000_000), in: unknown))
    }

    func testSeedsTheLogFromPartsNewestFirst() throws {
        let m = try manifest()
        let rows = RecordingParts.merge(closed: [], manifest: m)
        XCTAssertEqual(
            rows.map(\.partURI), ["ley://recordings/job_a/2", "ley://recordings/job_a/1"])
        XCTAssertTrue(rows.allSatisfy(\.fromPart))
        let first = rows[1].transmission
        XCTAssertEqual(first.start, at(2_400_000))
        XCTAssertEqual(first.end, at(7_200_000))
        XCTAssertEqual(first.seconds, 2, accuracy: 1e-9, "96000 frames at 48 kHz")
        XCTAssertEqual(first.peakAudioDBFS, -6.2)
        XCTAssertTrue(first.peakSNRDB.isNaN, "a part has no floor, so no signal word")
        XCTAssertTrue(rows[0].transmission.peakAudioDBFS.isNaN)
        // One second in at 2.4 MSPS, through the anchor.
        XCTAssertEqual(
            rows[1].startDate?.timeIntervalSince1970 ?? 0, 1_789_653_701, accuracy: 1e-6)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    func testMergesLiveRowsAndPartsBySampleTime() throws {
        let m = try manifest()
        // Newest first, as the log keeps them: one after part 2, one inside part 1.
        let live = [heard(20_000_000, 21_000_000), heard(3_600_000, 6_000_000)]
        let rows = RecordingParts.merge(closed: live, manifest: m)
        XCTAssertEqual(rows.map(\.fromPart), [false, true, false])
        XCTAssertEqual(
            rows.map(\.transmission.start.sampleIndex), [20_000_000, 12_000_000, 3_600_000])
        XCTAssertNil(rows[0].partURI, "no part holds it")
        XCTAssertEqual(rows[1].partURI, "ley://recordings/job_a/2", "no live row lies in part 2")
        XCTAssertEqual(rows[2].partURI, "ley://recordings/job_a/1", "the live row plays its part")
    }

    func testPartsOnAnotherCaptureFollowTheLiveRows() throws {
        let m = try manifest()
        let rows = RecordingParts.merge(
            closed: [heard(100, 2_400_100, capture: "cap_z")], manifest: m)
        XCTAssertEqual(rows.map(\.fromPart), [false, true, true])
        XCTAssertEqual(
            rows.map(\.partURI).dropFirst(),
            ["ley://recordings/job_a/2", "ley://recordings/job_a/1"])
        XCTAssertEqual(RecordingParts.merge(closed: [heard(1, 2)], manifest: nil).count, 1)
    }

    func testSummaryFromTheResourceMetadata() {
        let r = Leyline_V1_Resource.with {
            $0.uri = "ley://recordings/job_a"
            $0.kind = .recording
            $0.sizeBytes = 6_900_000
            $0.originatingJobID = "job_a"
            $0.metadata = [
                "kind": "audio", "frequency_hz": "462562500", "mode": "NFM",
                "sample_rate": "48000", "format": "wav-s16", "duration_ms": "720000", "parts": "4",
                "started_at_ns": "1789653802000000000", "ended_at_ns": "0", "ended_by": "",
                "device": "Nooelec NESDR SMArt",
            ]
        }
        let s = RecordingSummary(r)
        XCTAssertEqual(s.jobID, "job_a")
        XCTAssertEqual(s.frequencyHz, 462_562_500)
        XCTAssertEqual(s.mode, .nfm)
        XCTAssertEqual(s.durationMs, 720_000)
        XCTAssertEqual(s.parts, 4)
        XCTAssertEqual(s.startedAt, Date(timeIntervalSince1970: 1_789_653_802))
        XCTAssertEqual(RecordingSummary.durationWords(ms: s.durationMs), "12 min")
        XCTAssertEqual(RecordingSummary.durationWords(ms: 42_900), "42 s")
        XCTAssertEqual(RecordingSummary.durationWords(ms: 3_840_000), "1 h 04 min")
        XCTAssertEqual(RecordingSummary.partsWords(1), "1 part")
        XCTAssertEqual(RecordingSummary.partsWords(4), "4 parts")
        var bare = r
        bare.originatingJobID = ""
        bare.metadata = [:]
        XCTAssertEqual(RecordingSummary(bare).jobID, "job_a", "the id is the URI's last segment")
        XCTAssertNil(RecordingSummary(bare).startedAt)
    }

    func testTheWindowsRecordJobCopiesTheChannel() {
        let gated = Recordings.config(
            frequencyHz: 462_562_500, mode: .nfm, bandwidthHz: 12_500, squelchDBFS: -80,
            continuous: false)
        XCTAssertEqual(gated.frequencyHz, 462_562_500)
        XCTAssertEqual(gated.mode, .nfm)
        XCTAssertEqual(gated.bandwidthHz, 12_500)
        XCTAssertEqual(gated.squelchDbfs, -80)
        XCTAssertEqual(gated.gate, .squelch)
        XCTAssertEqual(gated.durationMs, 0)
        XCTAssertEqual(gated.stopAfterQuietMs, 0)
        XCTAssertEqual(gated.preRollMs, 0, "the daemon's default")
        XCTAssertTrue(gated.channelID.isEmpty, "the frequency form: the job owns its channel")
        let continuous = Recordings.config(
            frequencyHz: 1, mode: .am, bandwidthHz: 0, squelchDBFS: .nan, continuous: true)
        XCTAssertEqual(continuous.gate, .none)
        XCTAssertTrue(continuous.squelchDbfs.isNaN)
    }

    func testFindsTheActiveRecordJobOnAFrequency() {
        func job(_ id: String, _ state: Leyline_V1_JobState, hz: UInt64, channel: String = "")
            -> Leyline_V1_Job
        {
            .with {
                $0.jobID = id
                $0.state = state
                $0.record = .with {
                    $0.frequencyHz = hz
                    $0.channelID = channel
                }
            }
        }
        let scan = Leyline_V1_Job.with {
            $0.jobID = "job_s"
            $0.state = .running
            $0.scan = .init()
        }
        let jobs = [
            job("job_1", .completed, hz: 100), job("job_2", .degraded, hz: 100),
            job("job_3", .running, hz: 200), job("job_4", .running, hz: 100, channel: "chan_x"),
            scan,
        ]
        XCTAssertEqual(Recordings.activeJob(in: jobs, frequencyHz: 100)?.jobID, "job_2")
        XCTAssertEqual(Recordings.activeJob(in: jobs, frequencyHz: 200)?.jobID, "job_3")
        XCTAssertNil(Recordings.activeJob(in: jobs, frequencyHz: 300))
        XCTAssertNil(scan.recordConfig)
    }

    func testStatusWords() {
        XCTAssertEqual(
            Recordings.statusWords("recording audio: 1 m 12 s, 3 parts, 6.9 MB"),
            "1 m 12 s · 3 parts · 6.9 MB")
        XCTAssertEqual(
            Recordings.statusWords("recording audio: 4 m 02 s, 3 parts, squelch closed 38 s"),
            "4 m 02 s · 3 parts · squelch closed 38 s")
        let degraded = "out of capture since 14:05:10, will resume when 146.520 MHz is back"
        XCTAssertEqual(Recordings.statusWords(degraded), degraded)
        XCTAssertEqual(Recordings.statusWords(""), "recording")
    }
}
