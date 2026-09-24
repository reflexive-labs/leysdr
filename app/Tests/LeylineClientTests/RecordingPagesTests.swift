// SPDX-License-Identifier: Apache-2.0

// The channel page and the inspector on a part without a daemon (docs/design/
// app-design-handoff-m3.md, 8c): cards built from a listing and a hand-written manifest, the day
// groups and the rule that folds the older cards, a chip's words, the inspector's lines and
// table, the ended and delete words, Play all's order, and the rule the chips wrap by.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class RecordingPagesTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Thursday 2026-09-24 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_251_200)
    /// Midnight UTC `days` before `now`'s day.
    private func midnight(_ days: Int) -> Date {
        utc.startOfDay(for: now).addingTimeInterval(-Double(days) * 86_400)
    }

    private func seconds(_ h: Int, _ m: Int, _ s: Int = 0) -> Int { h * 3600 + m * 60 + s }

    /// A gated audio manifest on `cap_<id>`, whose anchor dates sample 0 at midnight `days` ago
    /// and runs at 1000 S/s, so a part's samples are milliseconds since that midnight. Each part
    /// is (start seconds after midnight, length in seconds, squelch opens).
    private func manifest(
        _ id: String, days: Int, parts: [(start: Int, length: Double, opens: Int)],
        endedBy: String = "cancelled", format: String = "wav-s16"
    ) throws -> RecordingManifest {
        let dayNs = Int64(midnight(days).timeIntervalSince1970) * 1_000_000_000
        let partJSON = parts.enumerated().map { i, p in
            let start = p.start * 1000
            let end = start + Int(p.length * 1000)
            return """
                { "part": \(i + 1), "file": "p\(i + 1).wav", "start_sample": \(start),
                  "end_sample": \(end), "samples": \(Int(p.length * 48_000)), "bytes": 1000000,
                  "peak_dbfs": -6.2, "mean_dbfs": -18.4, "squelch_opens": \(p.opens) }
                """
        }
        let json = """
            {
              "job_id": "\(id)", "uri": "ley://recordings/\(id)", "kind": "audio",
              "frequency_hz": 462612500, "mode": "NFM", "bandwidth_hz": 12500,
              "sample_rate": 48000, "format": "\(format)",
              "device": { "driver": "hackrf", "model": "HackRF Pro", "serial": "1" },
              "gains": [ { "element": "LNA", "value_db": 16 }, { "element": "VGA", "value_db": 20 },
                         { "element": "AMP", "value_db": 0 } ],
              "squelch_dbfs": -80,
              "gate": { "kind": "squelch", "pre_roll_ms": 500, "hang_ms": 5000 },
              "started_at_ns": \(dayNs + Int64((parts.first?.start ?? 0) - 40) * 1_000_000_000),
              "ended_at_ns": \(endedBy.isEmpty ? 0 : dayNs + 86_000 * 1_000_000_000),
              "ended_by": "\(endedBy)",
              "anchors": [ { "capture_id": "cap_\(id)", "host_time_ns": \(dayNs),
                             "sample_rate": 1000, "drift_ppm": 0, "from_sample": 0 } ],
              "parts": [ \(partJSON.joined(separator: ",")) ],
              "bytes": \(parts.count * 1_000_000)
            }
            """
        return try RecordingManifest.decode(Data(json.utf8))
    }

    private func listed(_ m: RecordingManifest) -> RecordingSummary {
        RecordingSummary(
            .with {
                $0.uri = m.uri
                $0.originatingJobID = m.jobID
                $0.sizeBytes = m.bytes + 4096
                $0.metadata = [
                    "frequency_hz": String(m.frequencyHz), "mode": m.mode,
                    "bandwidth_hz": String(m.bandwidthHz), "started_at_ns": String(m.startedAtNs),
                    "ended_at_ns": String(m.endedAtNs), "parts": String(m.parts.count),
                    "duration_ms": "4000", "ended_by": m.endedBy,
                ]
            })
    }

    private func running(_ id: String) -> Leyline_V1_Job {
        .with {
            $0.jobID = id
            $0.state = .running
            $0.record = .with { $0.frequencyHz = 462_612_500 }
        }
    }

    // MARK: Cards

    func testACardFromTheManifestDatesItsPartsThroughTheAnchor() throws {
        let m = try manifest(
            "job_tue", days: 2,
            parts: [
                (seconds(14, 2, 18), 9, 1), (seconds(16, 11, 4), 10, 2),
                (seconds(17, 9, 58), 9, 1),
            ])
        let g = RecordingGroup(summary: listed(m), manifest: m, running: false)
        XCTAssertEqual(g.parts, 3)
        XCTAssertEqual(g.seconds, 28, accuracy: 1e-9)
        XCTAssertEqual(g.bytes, 3_000_000, "the manifest's bytes, not the listing's size on disk")
        XCTAssertEqual(g.endedBy, "cancelled")
        XCTAssertEqual(g.chips.map(\.uri), (1...3).map { "ley://recordings/job_tue/\($0)" })
        XCTAssertEqual(
            g.chips.map { $0.words(timeZone: utc.timeZone) },
            ["14:02:18 · 9 s", "16:11:04 · 10 s", "17:09:58 · 9 s"])
        XCTAssertEqual(
            g.rangeWords(collapsed: false, now: now, calendar: utc), "14:02 — 17:10",
            "the parts' span: the switch went off after the last one")
        XCTAssertEqual(g.countWords(collapsed: false), "3 parts · 28 s · 2.9 MB")
        XCTAssertEqual(
            g.rangeWords(collapsed: true, now: now, calendar: utc), "Tue 14:02 — 17:10",
            "a folded card names its day")
        XCTAssertEqual(g.countWords(collapsed: true), "3 parts · 28 s", "and leaves the size out")
    }

    func testARunningCardReadsNowAndBeforeItsManifestTheListingsCounts() throws {
        let m = try manifest(
            "job_run", days: 0, parts: [(seconds(9, 12, 40), 8, 1), (seconds(10, 3, 11), 6, 1)],
            endedBy: "")
        let g = RecordingGroup(summary: listed(m), manifest: m, running: true)
        XCTAssertEqual(g.rangeWords(collapsed: false, now: now, calendar: utc), "09:12 — now")
        XCTAssertNil(g.endedAt)
        XCTAssertEqual(g.chips.first?.words(timeZone: utc.timeZone), "09:12:40 · 8 s")

        let early = RecordingGroup(summary: listed(m), manifest: nil, running: true)
        XCTAssertEqual(early.parts, 2)
        XCTAssertEqual(early.seconds, 4, "the listing's duration_ms")
        XCTAssertEqual(early.bytes, m.bytes + 4096, "the listing's size")
        XCTAssertEqual(early.chips, [], "no chips before the manifest is read")
        XCTAssertEqual(
            early.rangeWords(collapsed: false, now: now, calendar: utc), "09:12 — now",
            "the job's start, from the listing")
    }

    func testAChipWithoutAnAnchorIsNamedByItsPart() {
        let chip = RecordingChip(
            uri: "ley://recordings/job_a/3", part: 3, startedAt: nil, seconds: 0.3)
        XCTAssertEqual(chip.words(), "part 3 · 1 s", "a part that holds anything is at least 1 s")
    }

    // MARK: Days

    func testDaysGroupNewestFirstAndFoldWhatIsOlderThanTwoDays() throws {
        let run = try manifest("job_run", days: 3, parts: [(seconds(9, 12, 40), 8, 1)], endedBy: "")
        let today = try manifest("job_today", days: 0, parts: [(seconds(8, 0), 5, 1)])
        let wed = try manifest("job_wed", days: 1, parts: [(seconds(10, 0), 5, 1)])
        let tue = try manifest("job_tue", days: 2, parts: [(seconds(14, 2, 18), 9, 1)])
        let tueLate = try manifest("job_tue2", days: 2, parts: [(seconds(18, 0), 9, 1)])
        let mon = try manifest("job_mon", days: 3, parts: [(seconds(20, 39), 10, 1)])
        let sun = try manifest("job_sun", days: 4, parts: [(seconds(11, 20), 7, 1)])
        let all = [sun, tue, run, mon, today, tueLate, wed]
        let groups = Recordings.groups(
            all.map(listed),
            manifests: Dictionary(uniqueKeysWithValues: all.map { ($0.jobID, $0) }),
            jobs: [running("job_run")])
        let days = Recordings.days(groups, now: now, calendar: utc)
        XCTAssertEqual(days.map(\.title), ["today", "yesterday", "Tuesday", "earlier"])
        XCTAssertEqual(days.map(\.collapsed), [false, false, false, true])
        XCTAssertEqual(
            days.map { $0.recordings.map(\.jobID) },
            [
                ["job_run", "job_today"], ["job_wed"], ["job_tue2", "job_tue"],
                ["job_mon", "job_sun"],
            ],
            "a running recording is today's top card whenever it began; newest first within a day")
        XCTAssertEqual(Recordings.days([], now: now, calendar: utc), [])
    }

    func testTheCollapseRuleIsTheHandoffsTwoDays() {
        XCTAssertEqual(Recordings.collapseAfterDays, 2)
    }

    func testThePageHeaderAndWidth() throws {
        let a = try manifest("job_a", days: 0, parts: [(seconds(9, 0), 5, 1)])
        let b = try manifest(
            "job_b", days: 1, parts: [(seconds(9, 0), 5, 1), (seconds(9, 5), 5, 1)])
        let groups = Recordings.groups(
            [listed(a), listed(b)], manifests: ["job_a": a], jobs: [])
        XCTAssertEqual(
            Recordings.pageWords(groups), "2 recordings · 2.9 MB",
            "the manifest's bytes where read, the listing's size where not")
        let channel = Recordings.channels([listed(a), listed(b)], bookmarks: [], jobs: [])[0]
        XCTAssertEqual(Recordings.channelWidth(groups, channel: channel), 12_500)
        XCTAssertEqual(Recordings.pageWords([groups[0]]), "1 recording · 977 KB")
    }

    // MARK: The inspector on a part

    func testThePartsWords() throws {
        let m = try manifest(
            "job_tue", days: 2,
            parts: [(seconds(14, 2, 18), 9, 1), (seconds(16, 11, 4), 10, 2)])
        let part = m.parts[1]
        let idle = Recordings.partWords(
            part: part, of: m, positionFrames: nil, positionRate: 0, now: now, calendar: utc)
        XCTAssertEqual(idle.title, "Part 2 of Tuesday 14:02")
        XCTAssertEqual(idle.time, "16:11:04 · 10.0 s")
        XCTAssertEqual(idle.progress, "0:00.0 of 0:10.0 · 2 overs")
        XCTAssertEqual(idle.fraction, 0)
        let playing = Recordings.partWords(
            part: part, of: m, positionFrames: 182_400, positionRate: 48_000, now: now,
            calendar: utc)
        XCTAssertEqual(playing.progress, "0:03.8 of 0:10.0 · 2 overs")
        XCTAssertEqual(playing.fraction, 0.38, accuracy: 1e-9)
        let first = Recordings.partWords(
            part: m.parts[0], of: m, positionFrames: 0, positionRate: 0, now: now, calendar: utc)
        XCTAssertEqual(first.progress, "0:00.0 of 0:09.0 · 1 over")

        let today = try manifest("job_t", days: 0, parts: [(seconds(9, 12, 40), 75.5, 0)])
        let words = Recordings.partWords(
            part: today.parts[0], of: today, positionFrames: nil, positionRate: 0, now: now,
            calendar: utc)
        XCTAssertEqual(words.title, "Part 1 of Today 09:12")
        XCTAssertEqual(words.progress, "0:00.0 of 1:15.5", "no overs clause without an open")
    }

    func testThePartsTable() throws {
        let m = try manifest("job_a", days: 0, parts: [(seconds(9, 0), 10, 2)])
        let rows = Recordings.partTable(part: m.parts[0], of: m, running: false)
        XCTAssertEqual(
            rows.map(\.label), ["Peak", "Mean", "Radio", "Gain", "Squelch", "Ended", "Files"])
        XCTAssertEqual(
            rows.map(\.value),
            [
                "−6.2 dBFS", "−18.4 dBFS", "HackRF Pro", "LNA 16 · VGA 20 · AMP 0", "−80 dBFS",
                "Switched off", "1 WAV · 977 KB",
            ])
        XCTAssertEqual(
            Recordings.partTable(part: m.parts[0], of: m, running: true)[5].value, "Recording")
        XCTAssertEqual(
            Recordings.gainWords([.init(element: "tuner", valueDB: 29.7)]), "30 dB",
            "one stage is its dB alone")
        XCTAssertEqual(Recordings.gainWords([]), "—")
        var unmeasured = m.parts[0]
        unmeasured.peakDBFS = nil
        XCTAssertEqual(Recordings.partTable(part: unmeasured, of: m, running: false)[0].value, "—")
    }

    func testEndedWords() {
        let cases = [
            ("cancelled", "Switched off"), ("duration", "Duration reached"),
            ("quiet", "Went quiet"), ("channel ended", "Channel ended"),
            ("restart", "Daemon restarted"), ("store full", "Store full"), ("error", "Error"),
            ("", "—"), ("something new", "Something new"),
        ]
        for (word, words) in cases {
            XCTAssertEqual(Recordings.endedWords(word, running: false), words, word)
        }
        XCTAssertEqual(Recordings.endedWords("", running: true), "Recording")
    }

    func testDeleteWords() throws {
        XCTAssertEqual(
            Recordings.deleteWords(parts: 11),
            "Deletes all 11 parts. A recording is kept or deleted whole.")
        XCTAssertEqual(
            Recordings.deleteWords(parts: 1),
            "Deletes its one part. A recording is kept or deleted whole.")
        XCTAssertEqual(
            Recordings.deleteRefusalWords(jobID: "job_a"),
            "job_a is still recording; cancel the job first, then delete it")
        let m = try manifest("job_tue", days: 2, parts: [(seconds(14, 2, 18), 9, 1)])
        let g = RecordingGroup(summary: listed(m), manifest: m, running: false)
        XCTAssertEqual(
            Recordings.deleteQuestion(channelTitle: "GMRS CH3", group: g, now: now, calendar: utc),
            "Delete GMRS CH3, Tuesday 14:02?")
    }

    func testLengthWords() {
        XCTAssertEqual(Recordings.lengthWords(24), "24 s")
        XCTAssertEqual(Recordings.lengthWords(108), "1 m 48 s")
        XCTAssertEqual(Recordings.lengthWords(3840), "1 h 04 m")
        XCTAssertEqual(Recordings.lengthWords(.nan), "0 s")
        XCTAssertEqual(Recordings.elapsedWords(3.8), "0:03.8")
        XCTAssertEqual(Recordings.elapsedWords(59.96), "1:00.0")
    }

    // MARK: Playing

    func testPlayAllPlaysThePartsInOrderAndStops() throws {
        let m = try manifest(
            "job_a", days: 0,
            parts: [(seconds(9, 0), 5, 1), (seconds(9, 5), 5, 1), (seconds(9, 10), 5, 1)])
        var shuffled = m
        shuffled.parts = [m.parts[2], m.parts[0], m.parts[1]]
        let g = RecordingGroup(summary: listed(m), manifest: shuffled, running: false)
        var q = PlayQueue()
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.start(g), "ley://recordings/job_a/1", "part order, not file order")
        XCTAssertEqual(q.recordingURI, "ley://recordings/job_a")
        XCTAssertEqual(q.next(), "ley://recordings/job_a/2")
        XCTAssertEqual(q.next(), "ley://recordings/job_a/3")
        XCTAssertNil(q.next(), "done after the last part")
        XCTAssertTrue(q.isEmpty)

        _ = q.start(g)
        q.clear()
        XCTAssertNil(q.next(), "a stop clears what was left")
        let none = RecordingGroup(summary: listed(m), manifest: nil, running: false)
        XCTAssertNil(q.start(none), "nothing to play before the manifest")
        XCTAssertTrue(q.isEmpty)
    }

    func testPlayAllFromAPartQueuesTheRestOfTheRecording() throws {
        let m = try manifest(
            "job_a", days: 0,
            parts: [(seconds(9, 0), 5, 1), (seconds(9, 5), 5, 1), (seconds(9, 10), 5, 1)])
        let g = RecordingGroup(summary: listed(m), manifest: m, running: false)
        var q = PlayQueue()
        XCTAssertEqual(q.start(g, at: "ley://recordings/job_a/2"), "ley://recordings/job_a/2")
        XCTAssertEqual(q.pending, ["ley://recordings/job_a/3"], "the parts after it, in order")
        XCTAssertEqual(q.start(g, at: "ley://recordings/job_a/1"), "ley://recordings/job_a/1")
        XCTAssertEqual(q.pending.count, 2, "a step back queues the later parts again")
        XCTAssertNil(q.start(g, at: "ley://recordings/job_b/1"), "another recording's part")
        XCTAssertTrue(q.isEmpty)
    }

    // MARK: The player

    func testThePlayersWords() throws {
        let m = try manifest(
            "job_tue", days: 2,
            parts: [(seconds(14, 2, 18), 9, 1), (seconds(16, 11, 4), 10, 2)])
        let idle = Recordings.playerWords(
            channelTitle: "GMRS CH3", part: m.parts[1], of: m, positionFrames: nil,
            positionRate: 0, now: now, calendar: utc)
        XCTAssertEqual(idle.title, "GMRS CH3 · Tuesday 14:02 · part 2 of 2")
        XCTAssertEqual(idle.time, "16:11:04 · 10.0 s")
        XCTAssertEqual(idle.played, "0:00.0")
        XCTAssertEqual(idle.length, "0:10.0")
        XCTAssertEqual(idle.fraction, 0)
        let playing = Recordings.playerWords(
            channelTitle: "GMRS CH3", part: m.parts[1], of: m, positionFrames: 182_400,
            positionRate: 48_000, now: now, calendar: utc)
        XCTAssertEqual(playing.played, "0:03.8")
        XCTAssertEqual(playing.fraction, 0.38, accuracy: 1e-9)
        let over = Recordings.playerWords(
            channelTitle: "GMRS CH3", part: m.parts[1], of: m, positionFrames: 600_000,
            positionRate: 48_000, now: now, calendar: utc)
        XCTAssertEqual(over.played, "0:10.0", "the position never reads past the part's length")

        var undated = m
        undated.anchors = []
        undated.startedAtNs = 0
        let bare = Recordings.playerWords(
            channelTitle: "462.6125", part: undated.parts[0], of: undated, positionFrames: nil,
            positionRate: 0, now: now, calendar: utc)
        XCTAssertEqual(bare.title, "462.6125 · part 1 of 2", "no day clause without a date")
        XCTAssertEqual(bare.time, "part 1 · 9.0 s")
    }

    func testThePlayerStepsWithinTheRecording() throws {
        let m = try manifest(
            "job_a", days: 0,
            parts: [(seconds(9, 0), 5, 1), (seconds(9, 5), 5, 1), (seconds(9, 10), 5, 1)])
        var shuffled = m
        shuffled.parts = [m.parts[2], m.parts[0], m.parts[1]]
        let two = "ley://recordings/job_a/2"
        XCTAssertEqual(
            Recordings.neighbourPart(of: two, in: shuffled, step: -1), "ley://recordings/job_a/1",
            "part order, not file order")
        XCTAssertEqual(
            Recordings.neighbourPart(of: two, in: shuffled, step: 1), "ley://recordings/job_a/3")
        XCTAssertNil(
            Recordings.neighbourPart(of: "ley://recordings/job_a/1", in: m, step: -1),
            "nothing before the first part")
        XCTAssertNil(
            Recordings.neighbourPart(of: "ley://recordings/job_a/3", in: m, step: 1),
            "nothing after the last")
        XCTAssertNil(
            Recordings.neighbourPart(of: "ley://recordings/job_b/2", in: m, step: 1),
            "another recording's part")
        XCTAssertNil(Recordings.neighbourPart(of: "ley://recordings/job_a/9", in: m, step: -1))
    }

    func testAPartURIComesApart() {
        let ref = RecordingPartRef(uri: "ley://recordings/job_a/5")
        XCTAssertEqual(ref?.jobID, "job_a")
        XCTAssertEqual(ref?.part, 5)
        XCTAssertEqual(ref?.recordingURI, "ley://recordings/job_a")
        XCTAssertNil(RecordingPartRef(uri: "ley://recordings/job_a"))
        XCTAssertNil(RecordingPartRef(uri: "ley://records/job_a/5"))
        XCTAssertNil(RecordingPartRef(uri: "ley://recordings/job_a/x"))
    }

    // MARK: Wrapping

    func testChipsWrapWhenTheyWouldCrossTheLine() {
        XCTAssertEqual(
            FlowRows.lines(widths: [40, 40, 40, 40], spacing: 10, width: 100), [[0, 1], [2, 3]])
        XCTAssertEqual(
            FlowRows.lines(widths: [40, 40], spacing: 10, width: 90), [[0, 1]], "exactly full")
        XCTAssertEqual(
            FlowRows.lines(widths: [150, 20], spacing: 10, width: 100), [[0], [1]],
            "a chip wider than the line sits alone")
        XCTAssertEqual(FlowRows.lines(widths: [], spacing: 10, width: 100), [])
    }
}
