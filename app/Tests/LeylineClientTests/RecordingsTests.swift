// SPDX-License-Identifier: Apache-2.0

// Recordings without a daemon: a hand-written `recording.json` in the shape
// docs/design/recording.md, "The manifest" gives, parsed; the containment rule that makes a live
// transmission a kept row; a listing's summary from a resource's metadata; the record job the
// switch starts and the job that is its state; the status line under the switch; and the
// question asked before the window moves the radio off a recording
// (docs/design/app-design-handoff-m3.md, 8a and 8b).

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

    /// The switch turned off and on: the first recording kept two transmissions, the second
    /// one started empty and then kept a third. Every row keeps its ▶, whichever recording
    /// holds it.
    func testAKeptRowMatchesAcrossEveryRecordingOfTheChannel() throws {
        let older = try manifest()
        var newer = try manifest()
        newer.jobID = "job_b"
        newer.uri = "ley://recordings/job_b"
        newer.parts = []
        let first = heard(3_600_000, 6_000_000)
        let second = heard(12_100_000, 14_000_000)
        let third = heard(20_000_000, 21_000_000)
        XCTAssertEqual(
            RecordingParts.keptPartURI(of: first, in: [newer, older]), "ley://recordings/job_a/1",
            "the new recording's empty manifest does not hide the old one's parts")
        XCTAssertEqual(
            RecordingParts.keptPartURI(of: second, in: [newer, older]), "ley://recordings/job_a/2")
        XCTAssertNil(RecordingParts.keptPartURI(of: third, in: [newer, older]))
        newer.parts = [
            RecordingPart(
                part: 1, file: "p1.wav", startSample: 19_000_000, endSample: 22_000_000,
                samples: 60_000, bytes: 120_044, captureID: "cap_a")
        ]
        XCTAssertEqual(
            RecordingParts.keptPartURI(of: third, in: [newer, older]), "ley://recordings/job_b/1")
        XCTAssertEqual(
            RecordingParts.keptPartURI(of: first, in: [newer, older]), "ley://recordings/job_a/1")
        XCTAssertNil(RecordingParts.keptPartURI(of: first, in: []))
    }

    func testTheTunedChannelsRecordingsAreEveryOneOnItsFrequencyAndModeNewestFirst() {
        func listed(_ id: String, hz: UInt64, mode: String, startedNs: Int64) -> RecordingSummary {
            RecordingSummary(
                Leyline_V1_Resource.with {
                    $0.uri = "ley://recordings/\(id)"
                    $0.originatingJobID = id
                    $0.metadata = [
                        "frequency_hz": "\(hz)", "mode": mode, "started_at_ns": "\(startedNs)",
                    ]
                })
        }
        let listing = [
            listed("job_old", hz: 462_562_500, mode: "NFM", startedNs: 1_000_000_000),
            listed("job_new", hz: 462_562_500, mode: "NFM", startedNs: 3_000_000_000),
            listed("job_am", hz: 462_562_500, mode: "AM", startedNs: 4_000_000_000),
            listed("job_else", hz: 146_520_000, mode: "NFM", startedNs: 5_000_000_000),
            listed("job_any", hz: 462_562_500, mode: "", startedNs: 2_000_000_000),
        ]
        XCTAssertEqual(
            Recordings.recordingIDs(onFrequencyHz: 462_562_500, mode: .nfm, in: listing),
            ["job_new", "job_any", "job_old"], "another mode and another frequency are not these")
        XCTAssertEqual(
            Recordings.recordingIDs(
                onFrequencyHz: 462_562_500, mode: .nfm, in: listing, running: "job_live"),
            ["job_live", "job_new", "job_any", "job_old"],
            "the running job first, before the listing carries it")
        XCTAssertEqual(
            Recordings.recordingIDs(
                onFrequencyHz: 462_562_500, mode: .nfm, in: listing, running: "job_old"),
            ["job_old", "job_new", "job_any"], "listed once")
    }

    func testSummaryFromTheResourceMetadata() {
        let r = Leyline_V1_Resource.with {
            $0.uri = "ley://recordings/job_a"
            $0.kind = .recording
            $0.sizeBytes = 6_900_000
            $0.originatingJobID = "job_a"
            $0.metadata = [
                "kind": "audio", "frequency_hz": "462562500", "mode": "NFM",
                "bandwidth_hz": "12500", "sample_rate": "48000", "format": "wav-s16",
                "duration_ms": "720000", "parts": "4",
                "started_at_ns": "1789653802000000000", "ended_at_ns": "0", "ended_by": "",
                "device": "Nooelec NESDR SMArt",
            ]
        }
        let s = RecordingSummary(r)
        XCTAssertEqual(s.jobID, "job_a")
        XCTAssertEqual(s.frequencyHz, 462_562_500)
        XCTAssertEqual(s.mode, .nfm)
        XCTAssertEqual(s.bandwidthHz, 12_500, "the width recorded, which a sidebar click tunes")
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
        XCTAssertEqual(RecordingSummary(bare).bandwidthHz, 0, "no key: the mode's default is tuned")
    }

    func testTheWindowsRecordJobCopiesTheChannel() {
        let gated = Recordings.config(
            frequencyHz: 462_562_500, mode: .nfm, bandwidthHz: 12_500, squelchDBFS: -80)
        XCTAssertEqual(gated.frequencyHz, 462_562_500)
        XCTAssertEqual(gated.mode, .nfm)
        XCTAssertEqual(gated.bandwidthHz, 12_500)
        XCTAssertEqual(gated.squelchDbfs, -80)
        XCTAssertEqual(gated.gate, .squelch, "cut at dead air; there is no continuous option")
        XCTAssertEqual(gated.durationMs, 0)
        XCTAssertEqual(gated.stopAfterQuietMs, 0)
        XCTAssertEqual(gated.preRollMs, 500, "the daemon's default, stated")
        XCTAssertEqual(
            gated.hangMs, 500,
            "each transmission its own part: the daemon's 5 s hang folds a whole exchange into one")
        XCTAssertEqual(gated.hangMs, gated.preRollMs, "a gap shorter than the pre-roll is one part")
        XCTAssertTrue(gated.channelID.isEmpty, "the frequency form: the job owns its channel")
        let off = Recordings.config(frequencyHz: 1, mode: .am, bandwidthHz: 0, squelchDBFS: .nan)
        XCTAssertEqual(off.gate, .squelch)
        XCTAssertTrue(off.squelchDbfs.isNaN, "an off squelch is the channel default")
    }

    private func job(
        _ id: String, _ state: Leyline_V1_JobState, hz: UInt64, mode: Leyline_V1_DemodMode = .nfm,
        channel: String = "", bandwidthHz: UInt32 = 12_500
    ) -> Leyline_V1_Job {
        .with {
            $0.jobID = id
            $0.state = state
            $0.record = .with {
                $0.frequencyHz = hz
                $0.mode = mode
                $0.bandwidthHz = bandwidthHz
                $0.channelID = channel
            }
        }
    }

    func testFindsTheActiveRecordJobOnAFrequencyAndMode() {
        let scan = Leyline_V1_Job.with {
            $0.jobID = "job_s"
            $0.state = .running
            $0.scan = .init()
        }
        let jobs = [
            job("job_1", .completed, hz: 100), job("job_2", .degraded, hz: 100),
            job("job_3", .running, hz: 200), job("job_4", .running, hz: 100, channel: "chan_x"),
            job("job_5", .running, hz: 300, mode: .am),
            job("job_6", .running, hz: 400, mode: .unspecified), scan,
        ]
        XCTAssertEqual(
            Recordings.activeJob(in: jobs, frequencyHz: 100, mode: .nfm)?.jobID, "job_2",
            "a degraded job is still the switch's state")
        XCTAssertEqual(Recordings.activeJob(in: jobs, frequencyHz: 200, mode: .nfm)?.jobID, "job_3")
        XCTAssertNil(Recordings.activeJob(in: jobs, frequencyHz: 300, mode: .nfm), "another mode")
        XCTAssertEqual(Recordings.activeJob(in: jobs, frequencyHz: 300, mode: .am)?.jobID, "job_5")
        XCTAssertEqual(
            Recordings.activeJob(in: jobs, frequencyHz: 400, mode: .usb)?.jobID, "job_6",
            "a job that named no mode matches any")
        XCTAssertEqual(
            Recordings.activeJob(in: jobs, frequencyHz: 300, mode: .unspecified)?.jobID, "job_5",
            "a bookmark saved without a mode matches any")
        XCTAssertNil(Recordings.activeJob(in: jobs, frequencyHz: 500, mode: .nfm))
        XCTAssertNil(scan.recordConfig)
    }

    func testTheSwitchMatchesAJobWithinOneHertz() {
        let jobs = [
            job("job_1", .running, hz: 462_612_501),
            job("job_2", .running, hz: 462_587_500, mode: .unspecified),
        ]
        XCTAssertEqual(
            Recordings.activeJob(in: jobs, frequencyHz: 462_612_500, mode: .nfm)?.jobID, "job_1",
            "1 Hz above is the same channel")
        XCTAssertEqual(
            Recordings.activeJob(in: jobs, frequencyHz: 462_612_502, mode: .nfm)?.jobID, "job_1",
            "1 Hz below is the same channel")
        XCTAssertNil(
            Recordings.activeJob(in: jobs, frequencyHz: 462_612_503, mode: .nfm),
            "2 Hz apart is another channel")
        XCTAssertNil(
            Recordings.activeJob(in: jobs, frequencyHz: 462_612_500, mode: .am),
            "a job that names a mode matches that mode only")
        XCTAssertEqual(
            Recordings.activeJob(in: jobs, frequencyHz: 462_587_499, mode: .wfm)?.jobID, "job_2",
            "a job that names no mode matches any, within the tolerance")
        XCTAssertTrue(Recordings.sameChannel(0, .nfm, 1, .nfm), "no underflow at 0 Hz")
        XCTAssertTrue(Recordings.sameChannel(.max, .nfm, .max - 1, .nfm), "no overflow at the top")
    }

    func testAClickIsShownForAtMostThreeSecondsThenTheJob() {
        let t0 = Date(timeIntervalSince1970: 1_789_636_360)
        let click = RecordSwitchClick(frequencyHz: 462_612_500, mode: .nfm, on: true, at: t0)
        func shown(
            _ hz: UInt64?, _ mode: Leyline_V1_DemodMode = .nfm, after s: TimeInterval,
            running: Bool = false
        ) -> Bool {
            RecordSwitchClick.shown(
                pending: click, frequencyHz: hz, mode: mode, running: running,
                now: t0.addingTimeInterval(s))
        }
        XCTAssertTrue(shown(462_612_500, after: 0), "the click, at once")
        XCTAssertTrue(shown(462_612_500, after: 2.9), "the click, inside the hold")
        XCTAssertTrue(shown(462_612_501, after: 1), "the click, on the same channel within 1 Hz")
        XCTAssertFalse(shown(462_612_500, after: 3), "the job, once the hold is over")
        XCTAssertTrue(shown(462_612_500, after: 3, running: true), "the job, once the hold is over")
        XCTAssertFalse(shown(462_612_500, after: -1), "a clock set back does not extend the hold")
        XCTAssertFalse(shown(462_637_500, after: 1), "another channel shows its own job")
        XCTAssertFalse(shown(462_612_500, .am, after: 1), "another mode shows its own job")
        XCTAssertFalse(shown(nil, after: 1), "nothing tuned shows the job alone")
        XCTAssertTrue(
            RecordSwitchClick.shown(
                pending: nil, frequencyHz: 462_612_500, mode: .nfm, running: true, now: t0),
            "no click shows the job")
        XCTAssertEqual(RecordSwitchClick.holdSeconds, 3)
    }

    func testTheStatusLine() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var running = job("job_a", .running, hz: 462_562_500)
        // 2026-09-17 09:12:40 UTC.
        running.createdAtNs = 1_789_636_360_000_000_000
        var m = try manifest()
        m.bytes = 1_153_434
        XCTAssertEqual(
            Recordings.statusLine(job: running, manifest: m, timeZone: utc),
            "Since 09:12 · 2 parts · 1.1 MB. Keeps going if you tune away.")
        XCTAssertEqual(
            Recordings.statusLine(job: running, manifest: nil, timeZone: utc),
            "Since 09:12. Keeps going if you tune away.", "before the manifest is read")
        m.jobID = "job_other"
        XCTAssertEqual(
            Recordings.statusLine(job: running, manifest: m, timeZone: utc),
            "Since 09:12. Keeps going if you tune away.", "another recording's counts are not shown"
        )
        var degraded = running
        degraded.state = .degraded
        degraded.statusDetail =
            "out of capture since 09:40:02, will resume when 462.562 MHz is back"
        XCTAssertEqual(
            Recordings.statusLine(job: degraded, manifest: m, timeZone: utc),
            degraded.statusDetail)
        XCTAssertEqual(Recordings.sinceWords(createdAtNs: 0, timeZone: utc), "Since now")
        XCTAssertEqual(Recordings.sizeWords(512), "512 B")
        XCTAssertEqual(Recordings.sizeWords(96_044), "94 KB")
        XCTAssertEqual(Recordings.sizeWords(7_235_174), "6.9 MB")
        XCTAssertEqual(Recordings.sizeWords(3 << 30), "3.0 GB")
    }

    /// A capture at 462.6 MHz, 2.4 MSPS wide, with the window's channel and the frequency-form
    /// job's own channel on it, and one job borrowing the window's channel.
    private func radio() -> MirrorState {
        var s = MirrorState()
        s.captures = [
            .with {
                $0.captureID = "cap_a"
                $0.centerHz = 462_600_000
                $0.sampleRate = 2_400_000
            }
        ]
        s.channels = [
            .with {
                $0.channelID = "chan_app"
                $0.captureID = "cap_a"
                $0.offsetHz = -37_500
                $0.owner = .with { $0.kind = "app" }
            },
            .with {
                $0.channelID = "chan_job"
                $0.captureID = "cap_a"
                $0.offsetHz = -37_500
                $0.requiredHz = 462_562_500
                $0.owner = .with { $0.kind = "job" }
            },
        ]
        s.jobs = [
            job("job_own", .running, hz: 462_562_500),
            job("job_done", .completed, hz: 462_562_500),
            job("job_elsewhere", .running, hz: 146_520_000),
        ]
        return s
    }

    func testTheJobsRidingACapture() {
        var s = radio()
        XCTAssertEqual(Recordings.jobs(riding: "cap_a", in: s).map(\.jobID), ["job_own"])
        s.jobs.append(job("job_borrow", .degraded, hz: 0, channel: "chan_app"))
        XCTAssertEqual(
            Recordings.jobs(riding: "cap_a", in: s).map(\.jobID), ["job_own", "job_borrow"])
        XCTAssertEqual(Recordings.jobs(riding: "cap_b", in: s).map(\.jobID), [])
    }

    func testAMoveThatLeavesARecordingOutAsksFirst() {
        let s = radio()
        // Inside: the span slides 1 MHz up and 462.5625 is still 162 kHz inside its low edge.
        XCTAssertEqual(
            Recordings.leftOut(capture: "cap_a", movingTo: 462_400_000...464_800_000, in: s), [])
        // Outside: another band.
        let left = Recordings.leftOut(capture: "cap_a", movingTo: 144_800_000...147_200_000, in: s)
        XCTAssertEqual(left.map(\.jobID), ["job_own"])
        // A narrower span that no longer holds the channel's width: 462.5625 ± 6.25 kHz.
        XCTAssertEqual(
            Recordings.leftOut(capture: "cap_a", movingTo: 462_560_000...463_800_000, in: s)
                .map(\.jobID), ["job_own"])
        XCTAssertEqual(
            Recordings.retuneWords(jobs: left),
            "job_own is recording on this radio; moving the radio would leave a gap in it.")
        XCTAssertNil(Recordings.retuneWords(jobs: []), "nothing recording, nothing asked")
        XCTAssertEqual(
            Recordings.retuneWords(jobs: [
                job("job_a", .running, hz: 1), job("job_b", .running, hz: 2),
            ]),
            "job_a and job_b are recording on this radio; moving the radio would leave a gap in them."
        )
        // A job already outside the span (degraded) is not asked about again.
        var away = s
        away.captures[0].centerHz = 150_000_000
        XCTAssertEqual(
            Recordings.leftOut(capture: "cap_a", movingTo: 144_800_000...147_200_000, in: away), [])
    }

    // MARK: The sidebar's Recordings source and the store footer

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Thursday 2026-09-24 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_251_200)

    private func listed(
        _ id: String, hz: UInt64, mode: String = "NFM", startedHoursAgo: Double,
        endedHoursAgo: Double? = nil, size: UInt64 = 1 << 20
    ) -> RecordingSummary {
        let ns = { (h: Double) in String(Int64((self.now.timeIntervalSince1970 - h * 3600) * 1e9)) }
        return RecordingSummary(
            .with {
                $0.uri = "ley://recordings/\(id)"
                $0.originatingJobID = id
                $0.sizeBytes = size
                $0.metadata = [
                    "frequency_hz": String(hz), "mode": mode, "started_at_ns": ns(startedHoursAgo),
                    "ended_at_ns": endedHoursAgo.map(ns) ?? "0",
                ]
            })
    }

    func testChannelsGroupByFrequencyAndModeNewestActivityFirst() {
        let recordings = [
            listed("job_a", hz: 462_612_500, startedHoursAgo: 1, endedHoursAgo: 0.5),
            listed("job_b", hz: 462_612_500, startedHoursAgo: 30, endedHoursAgo: 29),
            listed("job_c", hz: 146_520_000, startedHoursAgo: 3, endedHoursAgo: 2),
            listed("job_d", hz: 146_520_000, mode: "AM", startedHoursAgo: 72, endedHoursAgo: 71),
            listed("job_e", hz: 462_562_500, startedHoursAgo: 80),
        ]
        let bookmarks = [
            Bookmark(id: "bm_1", name: "GMRS CH3", hz: 462_612_500, mode: .nfm),
            Bookmark(id: "bm_2", name: "2 m calling", hz: 146_520_000, mode: .nfm),
        ]
        let jobs = [job("job_e", .running, hz: 462_562_500), job("job_a", .completed, hz: 1)]
        let rows = Recordings.channels(recordings, bookmarks: bookmarks, jobs: jobs)
        XCTAssertEqual(
            rows.map(\.title), ["462.5625", "GMRS CH3", "2 m calling", "146.5200"],
            "running first, then newest end; AM on 146.52 is not the NFM bookmark")
        XCTAssertEqual(rows.map(\.running), [true, false, false, false])
        XCTAssertEqual(rows[1].recordings.map(\.jobID), ["job_a", "job_b"], "newest first")
        XCTAssertEqual(rows[0].subtitle(now: now, calendar: utc), "1 recording · latest now")
        XCTAssertEqual(rows[1].subtitle(now: now, calendar: utc), "2 recordings · latest today")
        XCTAssertEqual(
            rows[3].subtitle(now: now, calendar: utc), "1 recording · latest Mon",
            "71 hours before Thursday noon is Monday")
        XCTAssertEqual(Recordings.channels([], bookmarks: bookmarks, jobs: jobs), [])
    }

    func testSearchFindsNameFrequencyAndDay() {
        let rows = Recordings.channels(
            [
                listed("job_a", hz: 462_612_500, startedHoursAgo: 1, endedHoursAgo: 0.5),
                listed("job_d", hz: 146_520_000, startedHoursAgo: 72, endedHoursAgo: 71),
            ],
            bookmarks: [Bookmark(id: "bm_1", name: "GMRS CH3", hz: 462_612_500, mode: .nfm)],
            jobs: [])
        let found = { (q: String) in
            rows.filter { $0.matches(q, now: self.now, calendar: self.utc) }.map(\.title)
        }
        XCTAssertEqual(found(""), ["GMRS CH3", "146.5200"])
        XCTAssertEqual(found("  gmrs "), ["GMRS CH3"])
        XCTAssertEqual(found("462.61"), ["GMRS CH3"], "a bookmarked row keeps its frequency")
        XCTAssertEqual(found("146.52"), ["146.5200"])
        XCTAssertEqual(found("mon"), ["146.5200"], "the weekday it started")
        XCTAssertEqual(found("thursday"), ["GMRS CH3"])
        XCTAssertEqual(found("today"), ["GMRS CH3"])
        XCTAssertEqual(found("NOAA"), [])
    }

    func testTheStoreFooter() {
        let used = Recordings.storeUsedBytes([
            listed("job_a", hz: 1, startedHoursAgo: 1, size: 900 << 20),
            listed("job_b", hz: 1, startedHoursAgo: 1, size: 44 << 20),
        ])
        XCTAssertEqual(used, 944 << 20)
        XCTAssertEqual(
            Recordings.storeWords(usedBytes: used, capBytes: 20 << 30),
            "944 MB of 20 GB · oldest go first")
        XCTAssertEqual(
            Recordings.storeWords(usedBytes: used, capBytes: 0), "944 MB · oldest go first",
            "a daemon that reports no cap")
        XCTAssertEqual(
            Recordings.storeFraction(usedBytes: used, capBytes: 20 << 30)!, 0.0461, accuracy: 1e-4)
        XCTAssertNil(Recordings.storeFraction(usedBytes: used, capBytes: 0))
        XCTAssertEqual(Recordings.storeFraction(usedBytes: 30 << 30, capBytes: 20 << 30), 1)
        XCTAssertEqual(Recordings.storeSizeWords(0), "0 B")
        XCTAssertEqual(Recordings.storeSizeWords(1_153_434), "1.1 MB")
        XCTAssertEqual(Recordings.storeSizeWords(3 << 29), "1.5 GB")
    }

    func testDayWords() {
        let hours = { (h: Double) in self.now.addingTimeInterval(-h * 3600) }
        XCTAssertEqual(Recordings.dayWords(hours(11), now: now, calendar: utc), "today")
        XCTAssertEqual(Recordings.dayWords(hours(13), now: now, calendar: utc), "yesterday")
        XCTAssertEqual(Recordings.dayWords(hours(72), now: now, calendar: utc), "Monday")
        XCTAssertEqual(Recordings.dayWords(hours(24 * 9), now: now, calendar: utc), "15 Sep")
        XCTAssertEqual(
            Recordings.dayWords(hours(-30), now: now, calendar: utc), "today", "a clock step")
        XCTAssertEqual(Recordings.shortDayWords(hours(13), now: now, calendar: utc), "Wed")
        XCTAssertEqual(Recordings.shortDayWords(hours(1), now: now, calendar: utc), "today")
    }

    // MARK: The channel page's switch

    func testThePagesRequestComesFromTheListingAndAsksForTheAutoSquelch() {
        let c = RecordingChannel(
            frequencyHz: 462_612_500, mode: .nfm, bookmarkName: nil, recordings: [], running: false,
            latest: nil)
        let r = Recordings.pageConfig(c, groups: [])
        XCTAssertEqual(r.frequencyHz, 462_612_500)
        XCTAssertEqual(r.mode, .nfm)
        XCTAssertEqual(r.bandwidthHz, 0, "no recording states a width: the mode's default")
        XCTAssertTrue(r.squelchDbfs.isNaN, "NaN asks a gated recording for the auto squelch")
        XCTAssertEqual(r.gate, .squelch)
        XCTAssertEqual(r.preRollMs, 500)
        XCTAssertEqual(r.hangMs, 500, "the page's switch cuts parts as the log's does")
        XCTAssertTrue(r.channelID.isEmpty, "the frequency form, which the switch finds its job by")
    }

    func testAJobTheDaemonDeclinedIsANoticeThatSaysWhatToDo() {
        var job = Leyline_V1_Job()
        job.jobID = "job_a"
        job.state = .running
        job.record = Recordings.config(
            frequencyHz: 462_612_500, mode: .nfm, bandwidthHz: 0, squelchDBFS: .nan)
        XCTAssertNil(Recordings.failureNotice(job), "a running job is no notice")
        job.state = .failed
        job.statusDetail = "the app is listening on 146.520 MHz"
        job.error = .with {
            $0.code = "DEVICE_BUSY"
            $0.message = "the app is listening on 146.520 MHz"
        }
        XCTAssertEqual(
            Recordings.failureNotice(job),
            "Could not record: the app is listening on 146.520 MHz. Tune to 462.6125 MHz first, and the recording shares the radio."
        )
        job.error = .with { $0.code = "NO_DEVICE" }
        job.statusDetail = "no radio here can hear 462.612 MHz"
        XCTAssertEqual(
            Recordings.failureNotice(job), "Could not record: no radio here can hear 462.612 MHz")
        job.state = .cancelled
        XCTAssertNil(Recordings.failureNotice(job), "switched off is not a failure")
    }
}
