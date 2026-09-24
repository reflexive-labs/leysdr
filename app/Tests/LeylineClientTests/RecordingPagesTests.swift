// SPDX-License-Identifier: Apache-2.0

// The Library without a daemon (docs/design/app-design-handoff-m3.md, 8c and "10a · The Library,
// revised"): recordings built from a listing and a hand-written manifest, the page's day rows
// with their brackets, gaps, strip marks and EARLIER lines, a row's words, the level graph read
// from a written WAV, the inspector's words on a clipped part, the ended and delete words, Play
// all's and Play day's order, and the player's words.

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
        endedBy: String = "cancelled", format: String = "wav-s16", clippedMs: [Int: Int64] = [:]
    ) throws -> RecordingManifest {
        let dayNs = Int64(midnight(days).timeIntervalSince1970) * 1_000_000_000
        let partJSON = parts.enumerated().map { i, p in
            let start = p.start * 1000
            let end = start + Int((p.length * 1000).rounded())
            let clipped = clippedMs[i + 1].map { ", \"clipped_ms\": \($0)" } ?? ""
            return """
                { "part": \(i + 1), "file": "p\(i + 1).wav", "start_sample": \(start),
                  "end_sample": \(end), "samples": \(Int((p.length * 48_000).rounded())),
                  "bytes": 1000000, "peak_dbfs": -6.2, "mean_dbfs": -18.4,
                  "squelch_opens": \(p.opens)\(clipped) }
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

    // MARK: Recordings

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
        XCTAssertEqual(g.startedAt, midnight(2).addingTimeInterval(Double(seconds(14, 2, 18))))
        XCTAssertEqual(
            g.endedAt, midnight(2).addingTimeInterval(Double(seconds(17, 9, 58)) + 9),
            "the parts' span: the switch went off after the last one")
    }

    func testARunningCardReadsNowAndBeforeItsManifestTheListingsCounts() throws {
        let m = try manifest(
            "job_run", days: 0, parts: [(seconds(9, 12, 40), 8, 1), (seconds(10, 3, 11), 6, 1)],
            endedBy: "")
        let g = RecordingGroup(summary: listed(m), manifest: m, running: true)
        XCTAssertNil(g.endedAt)
        XCTAssertEqual(g.chips.count, 2)

        let early = RecordingGroup(summary: listed(m), manifest: nil, running: true)
        XCTAssertEqual(early.parts, 2)
        XCTAssertEqual(early.seconds, 4, "the listing's duration_ms")
        XCTAssertEqual(early.bytes, m.bytes + 4096, "the listing's size")
        XCTAssertEqual(early.chips, [], "no parts before the manifest is read")
        XCTAssertEqual(early.startedAt, m.startedAt, "the job's start, from the listing")
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
        XCTAssertEqual(Recordings.deleteWords(parts: 11), "Deletes all 11 parts.")
        XCTAssertEqual(Recordings.deleteWords(parts: 1), "Deletes its one part.")
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
        XCTAssertEqual(idle.title, "GMRS CH3 · Tuesday")
        XCTAssertEqual(idle.time, "16:11:04 · part 2 of 2")
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
        XCTAssertEqual(bare.title, "462.6125", "no day clause without a date")
        XCTAssertEqual(bare.time, "part 1 of 2")
        let today = try manifest("job_t", days: 0, parts: [(seconds(9, 12, 40), 5, 0)])
        XCTAssertEqual(
            Recordings.playerWords(
                channelTitle: "GMRS CH3", part: today.parts[0], of: today, positionFrames: nil,
                positionRate: 0, now: now, calendar: utc
            ).title, "GMRS CH3 · Today")
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

    // MARK: The page's rows (10a)

    /// The written store of the 10a tests: today a four-part recording whose last part clipped
    /// for 0.4 s and a one-part recording before it; yesterday a two-part recording; Monday two
    /// recordings; and today a recording that heard nothing, which the page leaves out. Each is
    /// written to disk and read back through `RecordingManifest.read(at:)`, as the window reads
    /// the daemon's.
    private func store() throws -> [RecordingGroup] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = [
            try manifest(
                "job_a", days: 0,
                parts: [
                    (seconds(9, 3, 3), 4, 1), (seconds(9, 3, 9), 5, 1), (seconds(9, 3, 16), 4, 1),
                    (seconds(9, 3, 20), 5.8, 1),
                ], clippedMs: [4: 400]),
            try manifest("job_b", days: 0, parts: [(seconds(8, 37, 32), 25, 2)]),
            try manifest(
                "job_c", days: 1,
                parts: [(seconds(16, 53, 10), 10, 1), (seconds(16, 55, 11), 10, 1)]),
            try manifest("job_d", days: 3, parts: [(seconds(10, 0), 10, 1)]),
            try manifest(
                "job_e", days: 3, parts: [(seconds(12, 0), 10, 1), (seconds(12, 5), 10, 1)]),
            try manifest("job_z", days: 0, parts: []),
        ]
        var read: [RecordingManifest] = []
        for m in made {
            let r = dir.appendingPathComponent(m.jobID)
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            try JSONEncoder().encode(m).write(to: r.appendingPathComponent("recording.json"))
            read.append(try RecordingManifest.read(at: r))
        }
        XCTAssertEqual(read, made, "clipped_ms survives the file")
        return Recordings.groups(
            read.map(listed),
            manifests: Dictionary(uniqueKeysWithValues: read.map { ($0.jobID, $0) }),
            jobs: [])
    }

    func testDaysHoldPartsNewestRecordingFirstEachBracketedInPartOrder() throws {
        let days = Recordings.dayRows(try store(), now: now, calendar: utc)
        XCTAssertEqual(days.map(\.title), ["today", "yesterday", "Monday"])
        XCTAssertEqual(days.map(\.earlier), [false, false, true])
        XCTAssertEqual(days.map(\.id), ["2026-09-24", "2026-09-23", "2026-09-21"])

        let today = days[0]
        XCTAssertEqual(
            today.rows.map(\.uri),
            (1...4).map { "ley://recordings/job_a/\($0)" } + ["ley://recordings/job_b/1"],
            "the newest recording first, its parts in part order; the empty one is left out")
        XCTAssertEqual(today.rows.map(\.bracket), [.first, .middle, .middle, .last, .none])
        XCTAssertEqual(
            today.rows.map(\.gapBefore), [false, false, false, false, true],
            "a gap between recordings, none above the day's first row")
        XCTAssertEqual(today.headWords, "5 parts · 44 s")
        XCTAssertEqual(today.rows.map(\.clipped), [false, false, false, true, false])
        XCTAssertEqual(today.marks.count, 5)
        XCTAssertEqual(today.marks[0].uri, "ley://recordings/job_a/1")
        XCTAssertEqual(today.marks[0].fraction, Double(seconds(9, 3, 3)) / 86_400, accuracy: 1e-9)
        XCTAssertEqual(today.marks[4].fraction, Double(seconds(8, 37, 32)) / 86_400, accuracy: 1e-9)
        XCTAssertEqual(
            today.playOrder,
            ["ley://recordings/job_b/1"] + (1...4).map { "ley://recordings/job_a/\($0)" },
            "Play day plays the day as it was heard, oldest first")

        XCTAssertEqual(days[1].rows.map(\.bracket), [.first, .last])
        XCTAssertEqual(days[1].headWords, "2 parts · 20 s")
        XCTAssertEqual(days[2].earlierWords, "3 parts · 2 recordings")
        XCTAssertEqual(days[2].rows.map(\.jobID), ["job_e", "job_e", "job_d"])
        XCTAssertEqual(days[2].rows.map(\.gapBefore), [false, false, true])
        XCTAssertEqual(Recordings.dayRows([], now: now, calendar: utc), [])
    }

    func testARecordingPastMidnightIsOnBothDaysAndAnUndatedOneIsLast() throws {
        // Starts at 23:59:50 two days ago, its second part after midnight.
        let late = try manifest(
            "job_late", days: 2, parts: [(seconds(23, 59, 50), 5, 1), (86_400 + 20, 5, 1)])
        var undated = try manifest("job_old", days: 5, parts: [(seconds(9, 0), 5, 1)])
        undated.anchors = []
        undated.startedAtNs = 0
        let groups = Recordings.groups(
            [listed(late), listed(undated)],
            manifests: ["job_late": late, "job_old": undated], jobs: [])
        let days = Recordings.dayRows(groups, now: now, calendar: utc)
        XCTAssertEqual(days.map(\.title), ["yesterday", "Tuesday", "undated"])
        XCTAssertEqual(days.map { $0.rows.map(\.part) }, [[2], [1], [1]])
        XCTAssertEqual(days[0].rows[0].bracket, .none, "one part of it on each day")
        XCTAssertEqual(days[2].earlier, true)
        XCTAssertEqual(days[2].marks, [], "an undated part has no place on a strip")
        XCTAssertEqual(days[2].rows[0].words(timeZone: utc.timeZone).starts, "part 1")
        XCTAssertEqual(
            Recordings.dayRows(
                Recordings.groups([listed(late)], manifests: [:], jobs: []), now: now,
                calendar: utc), [],
            "no row before the manifest is read")
    }

    func testARowsWords() throws {
        var row = PartRow(
            uri: "ley://recordings/job_a/1", recordingURI: "ley://recordings/job_a",
            jobID: "job_a", part: 1,
            startedAt: midnight(0).addingTimeInterval(Double(seconds(14, 3, 3))), seconds: 4.2,
            peakDBFS: -3.14, clippedMs: nil, bytes: 381_000, bracket: .none, gapBefore: false)
        XCTAssertEqual(
            row.words(timeZone: utc.timeZone),
            PartRowWords(starts: "14:03:03", length: "4 s", peak: "−3.1 dBFS", size: "372 KB"))
        row.clippedMs = 400
        row.peakDBFS = -2.4
        XCTAssertEqual(
            row.words(timeZone: utc.timeZone).peak, "0.0 dBFS",
            "clipped_ms is the fact, whatever the audio's peak")
        row.clippedMs = 0
        row.peakDBFS = nil
        XCTAssertFalse(row.clipped)
        XCTAssertEqual(row.words(timeZone: utc.timeZone).peak, "—", "nobody measured it")
        row.bytes = 2_411_724
        XCTAssertEqual(row.words(timeZone: utc.timeZone).size, "2.3 MB")
    }

    func testPlayDayQueuesAcrossRecordings() {
        var q = PlayQueue()
        XCTAssertEqual(
            q.start(parts: ["ley://recordings/job_b/1", "ley://recordings/job_a/1"]),
            "ley://recordings/job_b/1")
        XCTAssertFalse(q.isEmpty)
        XCTAssertNil(q.recordingURI, "a day walks no one recording")
        XCTAssertTrue(q.holds(recordingURI: "ley://recordings/job_a"))
        XCTAssertFalse(
            q.holds(recordingURI: "ley://recordings/job_b"), "already playing, not queued")
        XCTAssertEqual(q.next(), "ley://recordings/job_a/1")
        XCTAssertNil(q.next())
        XCTAssertTrue(q.isEmpty)
        XCTAssertNil(q.start(parts: []))
        XCTAssertTrue(q.isEmpty)
    }

    // MARK: The inspector on a part (10a)

    func testTheInspectorsWordsOnAClippedPart() throws {
        let a = try store().first { $0.jobID == "job_a" }
        let m = try XCTUnwrap(a?.manifest)
        let words = Recordings.partInspectorWords(
            part: m.parts[3], of: m, running: false, timeZone: utc.timeZone)
        XCTAssertEqual(words.heading, "PART 4 OF 4")
        XCTAssertEqual(words.time, "09:03:20 · 5.8 s")
        XCTAssertEqual(words.levels.map(\.label), ["Peak", "Mean", "Overs"])
        XCTAssertEqual(words.levels.map(\.value), ["0.0 dBFS · clipped", "−18.4 dBFS", "1"])
        XCTAssertTrue(words.clipped)
        XCTAssertEqual(
            words.clippedSentence,
            "Clipped for 0.4 s. Lower gain or pull back from the transmitter for the next one.")
        XCTAssertEqual(
            words.recording.map(\.label), ["Span", "Ended", "Radio", "Gain", "Squelch", "Files"])
        XCTAssertEqual(
            words.recording.map(\.value),
            [
                "09:03:03 – 09:03:25", "Switched off", "HackRF Pro", "LNA 16 · VGA 20 · AMP 0",
                "−80 dBFS", "4 WAV · 3.8 MB",
            ])
        XCTAssertEqual(words.playAll, "Play all 4")
        XCTAssertEqual(words.deleteLine, "Deletes all 4 parts.")

        let clean = Recordings.partInspectorWords(
            part: m.parts[0], of: m, running: true, timeZone: utc.timeZone)
        XCTAssertEqual(clean.heading, "PART 1 OF 4")
        XCTAssertEqual(clean.levels[0].value, "−6.2 dBFS")
        XCTAssertFalse(clean.clipped)
        XCTAssertNil(clean.clippedSentence)
        XCTAssertEqual(clean.recording[0].value, "09:03:03 – now", "while the job writes")
        XCTAssertEqual(clean.recording[1].value, "Recording")

        let one = try manifest("job_one", days: 0, parts: [(seconds(9, 0), 5, 0)], endedBy: "")
        let single = Recordings.partInspectorWords(
            part: one.parts[0], of: one, running: false, timeZone: utc.timeZone)
        XCTAssertEqual(single.levels.map(\.label), ["Peak", "Mean"], "no overs clause at zero")
        XCTAssertEqual(single.playAll, "Play")
        XCTAssertEqual(single.deleteLine, "Deletes its one part.")
        var undated = one
        undated.anchors = []
        XCTAssertEqual(
            Recordings.partInspectorWords(
                part: undated.parts[0], of: undated, running: false, timeZone: utc.timeZone
            ).recording[0].value, "—")
    }

    func testThePlayersWordsOnTheClippedPart() throws {
        let m = try XCTUnwrap(try store().first { $0.jobID == "job_a" }?.manifest)
        let words = Recordings.playerWords(
            channelTitle: "GMRS CH3", part: m.parts[3], of: m, positionFrames: 100_800,
            positionRate: 48_000, now: now, calendar: utc)
        XCTAssertEqual(words.title, "GMRS CH3 · Today")
        XCTAssertEqual(words.time, "09:03:20 · part 4 of 4")
        XCTAssertEqual(words.played, "0:02.1")
        XCTAssertEqual(words.length, "0:05.8")
    }

    // MARK: The level graph

    /// A PCM WAV of `samples` with `channels` and `bits`, as `PartWriter` writes one (and, with
    /// other shapes, as it never does).
    private func wav(
        _ samples: [Int16], channels: UInt16 = 1, bits: UInt16 = 16, list: Bool = false
    ) throws -> URL {
        func le<T: FixedWidthInteger>(_ v: T) -> Data {
            withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }
        var body = Data()
        for s in samples { body.append(le(s)) }
        var fmt = Data()
        fmt.append(le(UInt16(1)))
        fmt.append(le(channels))
        fmt.append(le(UInt32(48_000)))
        fmt.append(le(UInt32(48_000) * UInt32(channels) * 2))
        fmt.append(le(channels * 2))
        fmt.append(le(bits))
        var file = Data("RIFF".utf8)
        var chunks = Data("WAVE".utf8)
        chunks.append(Data("fmt ".utf8))
        chunks.append(le(UInt32(fmt.count)))
        chunks.append(fmt)
        if list {
            // A chunk another tool might put before the data, odd-sized to test the pad byte.
            chunks.append(Data("LIST".utf8))
            chunks.append(le(UInt32(3)))
            chunks.append(Data([1, 2, 3, 0]))
        }
        chunks.append(Data("data".utf8))
        chunks.append(le(UInt32(body.count)))
        chunks.append(body)
        file.append(le(UInt32(chunks.count)))
        file.append(chunks)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvl-\(UUID().uuidString).wav")
        try file.write(to: url)
        return url
    }

    func testTheLevelGraphIsRMSPerColumnAgainstSixtyDB() throws {
        // Four quarters: full-scale square, a tenth of full scale (−20 dBFS), −70 dBFS (under
        // the floor), silence.
        let quarter = 1200
        var samples: [Int16] = []
        for i in 0..<quarter { samples.append(i % 2 == 0 ? 32767 : -32767) }
        samples += Array(repeating: 3277, count: quarter)
        samples += Array(repeating: 10, count: quarter)
        samples += Array(repeating: 0, count: quarter)
        let url = try wav(samples, list: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let columns = try LevelGraph.columns(wav: url, columns: 4)
        XCTAssertEqual(columns.count, 4)
        XCTAssertEqual(columns[0], 1, accuracy: 1e-3)
        XCTAssertEqual(columns[1], 40.0 / 60, accuracy: 1e-3)
        XCTAssertEqual(columns[2], 0, "below −60 dBFS is the floor")
        XCTAssertEqual(columns[3], 0)
        XCTAssertEqual(try LevelGraph.columns(wav: url, columns: 40).count, 40)
        XCTAssertEqual(try LevelGraph.columns(wav: url, columns: 0), [])

        let short = try wav([16384, 16384])
        defer { try? FileManager.default.removeItem(at: short) }
        XCTAssertEqual(
            try LevelGraph.columns(wav: short, columns: 40).count, 2, "one column a frame")
    }

    func testTheLevelGraphRefusesWhatARecordingNeverWrites() throws {
        let stereo = try wav([1, 2, 3, 4], channels: 2)
        let eight = try wav([1, 2], bits: 8)
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvl-\(UUID().uuidString).wav")
        try Data("not a wav at all".utf8).write(to: text)
        defer { for u in [stereo, eight, text] { try? FileManager.default.removeItem(at: u) } }
        for url in [stereo, eight, text] {
            XCTAssertThrowsError(
                try LevelGraph.columns(wav: url, columns: 40), url.lastPathComponent)
        }
        XCTAssertThrowsError(
            try LevelGraph.columns(
                wav: URL(fileURLWithPath: "/nonexistent/part.wav"), columns: 40))
    }

    func testTheLevelGraphsColumnsFollowTheLength() {
        XCTAssertEqual(LevelGraph.columnCount(seconds: 4), 6)
        XCTAssertEqual(LevelGraph.columnCount(seconds: 25), 40)
        XCTAssertEqual(LevelGraph.columnCount(seconds: 600), LevelGraph.maxColumns)
        XCTAssertEqual(LevelGraph.columnCount(seconds: 0.5), 4)
        XCTAssertEqual(LevelGraph.columnCount(seconds: .nan), 4)
    }
}
