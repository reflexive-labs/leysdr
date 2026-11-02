// SPDX-License-Identifier: Apache-2.0

// The Library's channel page and its inspector as the design draws them, as data: rows are
// transmissions, grouped by the day each started, a recording of several transmissions bracketed
// in the gutter and separated from the next by a gap, each day with its head words, its 24-hour
// strip and its play order; days older than two are EARLIER, one line each. A transmission is a
// part (one file) or, in a part that holds several overs (a recording made with a long hang), one
// over of it, cut as the speech decoder cuts it (`SpeechRecords.segments`), so a row, its
// transcript line and what its click plays are the same audio. Built from the recordings'
// manifests (`RecordingGroup`), with wall clock only through the manifests' anchors (invariant 5).
// No Observation here, so the Linux tests cover every rule the page draws.

import Foundation
import LeylineProto

/// One transmission as a row of the page: what the columns print, where it sits in its recording,
/// and which part and overs hold it. The type keeps the file's name because a row is played,
/// revealed and deleted through its part.
public struct PartRow: Sendable, Equatable, Identifiable {
    /// Where the row sits in the gutter's bracket: a recording of one transmission on this day has
    /// none.
    public enum Bracket: Sendable, Equatable {
        case none, first, middle, last
    }

    /// `ley://recordings/<id>/<part>`, what `StartPlayback` and `ResolveLocalPath` take.
    public var uri: String
    public var recordingURI: String
    public var jobID: String
    public var part: Int
    /// When the transmission began, through its capture's anchor: the part's first sample, or the
    /// over's opening on a split row; nil when no anchor dates it.
    public var startedAt: Date?
    /// The audio the row plays: the part's length, or the over's segment on a split row.
    public var seconds: Double
    public var peakDBFS: Double?
    public var clippedMs: Int64?
    public var bytes: UInt64
    public var bracket: Bracket
    /// The row opens a recording that follows another on the same day: the page leaves a gap
    /// above it.
    public var gapBefore: Bool
    /// Where the daemon dropped samples inside the part, as fractions of its level graph
    /// (`RecordingPart.gapFractions`): the row's faint mark, and a tick on the graph at each.
    public var gapFractions: [Double] = []
    /// The overs of the part's `squelch_opens` the row holds, counted from 1: `over` is the one
    /// a speech line names. Both 0 for a part with no openings read (continuous, WFM, IQ).
    public var over: Int = 0
    public var lastOver: Int = 0
    /// The part holds more than one transmission and this row is one of them: it plays a sample
    /// range of the part, and its peak and level graph are the part's (the graph cut to the row's
    /// place in it).
    public var split: Bool = false
    /// The row's place in its part's level graph, as fractions of the part.
    public var startFraction: Double = 0
    public var endFraction: Double = 1
    /// The whole part's length, which its level graph is read at.
    public var partSeconds: Double = 0

    public var id: String { split ? "\(uri)#\(over)" : uri }

    /// The over `AppSession.play(part:over:)` plays for this row; nil plays the whole part.
    public var playOver: Int? { split ? over : nil }

    /// Whether over `n` of this row's part is in the row: every over of an unsplit part is.
    public func holds(over n: Int) -> Bool { !split || (over...max(over, lastOver)).contains(n) }

    /// The row's columns of its part's level graph: all of them, or a split row's share.
    public func levels(_ graph: [Float]) -> [Float] {
        guard split, !graph.isEmpty else { return graph }
        let n = Double(graph.count)
        let lo = min(graph.count - 1, max(0, Int((startFraction * n).rounded(.down))))
        let hi = min(graph.count, max(lo + 1, Int((endFraction * n).rounded(.up))))
        return Array(graph[lo..<hi])
    }

    /// The daemon fell behind the radio inside this part and its file holds less than its span
    /// (docs/design/recording.md, "Gaps").
    public var hasGaps: Bool { !gapFractions.isEmpty }

    /// The capture clipped during the part (`clipped_ms` > 0), which the row prints as a
    /// `0.0 dBFS` peak in `accentRec`.
    public var clipped: Bool { (clippedMs ?? 0) > 0 }

    public func words(timeZone: TimeZone = .current) -> PartRowWords {
        PartRowWords(
            starts: startedAt.map { Recordings.clock($0, "HH:mm:ss", timeZone) } ?? "—",
            length: Recordings.wholeSeconds(seconds),
            peak: clipped ? "0.0 dBFS" : Recordings.dbfsWords(peakDBFS, places: 1),
            size: split ? "—" : Recordings.sizeWords(bytes))
    }
}

/// A row's four printed columns: `14:03:03`, `4 s`, `−3.1 dBFS`, `372 KB`. The level column is a
/// graph (`LevelGraph`), not words.
public struct PartRowWords: Sendable, Equatable {
    public var starts: String
    public var length: String
    /// The part's peak, a split row's too, since levels are measured per file: `0.0 dBFS` when
    /// it clipped, whatever the audio's peak; `—` when nobody measured it.
    public var peak: String
    /// The part's file size; `—` on a split row, whose share of a file is not a file.
    public var size: String
}

/// A mark on a day's 24-hour strip: a part's start as a fraction of its day.
public struct DayMark: Sendable, Equatable {
    public var uri: String
    /// 0 at the day's midnight, 1 at the next.
    public var fraction: Double
}

/// One day of the page: `TODAY  7 parts · 1 m 17 s`, its strip and its rows; or, older than
/// `Recordings.collapseAfterDays`, one EARLIER line, `Monday  5 parts · 3 recordings`, that opens
/// in place to the same rows.
public struct DayRows: Sendable, Equatable, Identifiable {
    /// `yyyy-MM-dd` in the calendar's zone, or `undated` for parts no anchor dates.
    public var id: String
    /// `today`, `yesterday`, `Tuesday`; under EARLIER `Monday`, `12 Sep` or `undated`. The day's
    /// head uppercases the first three.
    public var title: String
    /// Older than `Recordings.collapseAfterDays`: listed under EARLIER, one line until opened.
    public var earlier: Bool
    /// `7 transmissions · 1 m 17 s`: the day's transmissions and their lengths summed.
    public var headWords: String
    /// `5 transmissions · 3 recordings`: the EARLIER line's words.
    public var earlierWords: String
    /// Recordings newest first; within a recording its transmissions in the order heard.
    public var rows: [PartRow]
    /// Every dated transmission's start on the strip.
    public var marks: [DayMark]

    /// Play day's queue: the day's parts oldest first, in the order they were heard, each once
    /// however many transmissions it holds.
    public var playOrder: [String] {
        var seen = Set<String>()
        return rows.sorted { a, b in
            let sa = a.startedAt ?? .distantPast
            let sb = b.startedAt ?? .distantPast
            if sa != sb { return sa < sb }
            if a.jobID != b.jobID { return a.jobID < b.jobID }
            if a.part != b.part { return a.part < b.part }
            return a.over < b.over
        }
        .map(\.uri)
        .filter { seen.insert($0).inserted }
    }
}

/// The inspector on a transmission: its own lines, then its recording's.
public struct PartInspectorWords: Sendable, Equatable {
    /// `TRANSMISSION 4 OF 20`.
    public var heading: String
    /// `14:03:20 · 5.8 s`.
    public var time: String
    /// Peak and Mean; `File peak` and `File mean` on a transmission that shares its file with
    /// others, because levels are measured per file.
    public var levels: [PartTableRow]
    /// The Peak row reads `0.0 dBFS · clipped` and is drawn in `accentRec`.
    public var clipped: Bool
    /// `Clipped for 0.4 s. Lower gain or pull back from the transmitter for the next one.`, or
    /// nil when the part did not clip.
    public var clippedSentence: String?
    /// `0.6 s dropped in 2 gaps: the daemon fell behind the radio, and the file holds the audio
    /// either side.`, or nil when the part dropped nothing.
    public var droppedSentence: String? = nil
    /// Span, Ended, Radio, Gain, Squelch, Files.
    public var recording: [PartTableRow]
    /// `Play all 4`; `Play` for a recording of one transmission.
    public var playAll: String
    /// `Deletes all 4 transmissions.`
    public var deleteLine: String
}

/// One row of the inspector's tables: `Peak` and `−6.2 dBFS`.
public struct PartTableRow: Sendable, Equatable, Identifiable {
    public var label: String
    public var value: String

    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

extension Recordings {
    /// A recording's transmissions in the order heard: each part's, part by part
    /// (`transmissions(of:in:preRollMs:hangMs:)`).
    public static func transmissions(
        of m: RecordingManifest, preRollMs: UInt64 = SpeechRecords.defaultPreRollMs,
        hangMs: UInt64 = SpeechRecords.defaultHangMs
    ) -> [PartRow] {
        m.parts.sorted { $0.part < $1.part }.flatMap {
            transmissions(of: $0, in: m, preRollMs: preRollMs, hangMs: hangMs)
        }
    }

    /// A part's transmissions: the part itself when it has no openings read, or they make one
    /// segment; else one row per segment as the speech decoder cuts it with `preRollMs` and
    /// `hangMs` (`SpeechRecords.segments`), so one row is one transcript line and plays what was
    /// transcribed. A part from before the 500 ms hang holds an exchange of several overs; one
    /// written since holds one.
    public static func transmissions(
        of p: RecordingPart, in m: RecordingManifest,
        preRollMs: UInt64 = SpeechRecords.defaultPreRollMs,
        hangMs: UInt64 = SpeechRecords.defaultHangMs
    ) -> [PartRow] {
        var whole = PartRow(
            uri: m.uri(of: p), recordingURI: m.uri, jobID: m.jobID, part: p.part,
            startedAt: m.startTime(of: p), seconds: m.seconds(of: p), peakDBFS: p.peakDBFS,
            clippedMs: p.clippedMs, bytes: p.bytes, bracket: .none, gapBefore: false,
            gapFractions: p.gapFractions)
        whole.partSeconds = whole.seconds
        guard let opens = p.squelchIntervals, !opens.isEmpty else { return [whole] }
        whole.over = 1
        whole.lastOver = opens.count
        let rate = SpeechRecords.captureRate(of: p, in: m)
        guard rate > 0, p.endSample > p.startSample else { return [whole] }
        let perMs = rate / 1000
        let spans = SpeechRecords.segments(
            opens, partStart: p.startSample, partEnd: p.endSample,
            preRoll: UInt64(Double(preRollMs) * perMs), hang: UInt64(Double(hangMs) * perMs))
        guard spans.count > 1 else { return [whole] }
        let length = Double(p.endSample - p.startSample)
        return spans.map { s in
            var row = whole
            row.over = s.first
            row.lastOver = s.last
            row.split = true
            row.seconds = Double(s.end - s.start) / rate
            row.startFraction = Double(s.start - p.startSample) / length
            row.endFraction = Double(s.end - p.startSample) / length
            let opened = opens[s.first - 1].openSample
            row.startedAt =
                p.captureID.flatMap { m.wallTime(ofSample: opened, capture: $0) }
                ?? whole.startedAt
            let (a, b) = (row.startFraction, row.endFraction)
            row.gapFractions = whole.gapFractions.compactMap { f in
                f >= a && f < b && b > a ? (f - a) / (b - a) : nil
            }
            return row
        }
    }

    /// The page's days, newest first: every transmission of every recording in `groups` whose
    /// manifest has been read (`transmissions(of:preRollMs:hangMs:)`), as a row under the day it
    /// started. A recording with no part never shows (the daemon discards one at job end, but a
    /// listing can lag), and neither does one whose manifest is not read yet. `today`,
    /// `yesterday` and the day before by name are open; older days are EARLIER, one line each;
    /// transmissions no anchor dates, nor the job's start, go last under EARLIER as `undated`.
    /// Within a day, recordings newest first by their first transmission there, and a recording's
    /// transmissions in the order heard, so its bracket reads down the way it was heard; a
    /// recording that ran past midnight is on both days.
    public static func dayRows(
        _ groups: [RecordingGroup], now: Date, calendar: Calendar = .current,
        preRollMs: UInt64 = SpeechRecords.defaultPreRollMs,
        hangMs: UInt64 = SpeechRecords.defaultHangMs
    ) -> [DayRows] {
        struct Segment {
            var group: RecordingGroup
            var rows: [PartRow]
            var first: Date?
        }
        var segments: [String: [Segment]] = [:]
        var dayStart: [String: Date] = [:]
        for g in groups {
            guard let m = g.manifest, !m.parts.isEmpty else { continue }
            var byDay: [(key: String, rows: [PartRow])] = []
            for row in transmissions(of: m, preRollMs: preRollMs, hangMs: hangMs) {
                let key: String
                if let d = row.startedAt ?? g.startedAt {
                    let start = calendar.startOfDay(for: d)
                    key = format(start, "yyyy-MM-dd", calendar)
                    dayStart[key] = start
                } else {
                    key = undatedID
                }
                if let i = byDay.firstIndex(where: { $0.key == key }) {
                    byDay[i].rows.append(row)
                } else {
                    byDay.append((key, [row]))
                }
            }
            for (key, rows) in byDay {
                segments[key, default: []].append(
                    Segment(group: g, rows: rows, first: rows.first?.startedAt ?? g.startedAt))
            }
        }
        let keys = segments.keys.sorted { a, b in
            if a == undatedID { return false }
            if b == undatedID { return true }
            return a > b
        }
        return keys.map { key in
            let ordered = (segments[key] ?? []).sorted { a, b in
                let fa = a.first ?? .distantPast
                let fb = b.first ?? .distantPast
                if fa != fb { return fa > fb }
                return a.group.uri > b.group.uri
            }
            var rows: [PartRow] = []
            for (s, seg) in ordered.enumerated() {
                for (i, var row) in seg.rows.enumerated() {
                    if seg.rows.count > 1 {
                        row.bracket =
                            i == 0 ? .first : i == seg.rows.count - 1 ? .last : .middle
                    }
                    row.gapBefore = s > 0 && i == 0
                    rows.append(row)
                }
            }
            let title: String
            let earlier: Bool
            var marks: [DayMark] = []
            if key == undatedID {
                title = "undated"
                earlier = true
            } else {
                let start = dayStart[key] ?? now
                let n = daysBefore(start, now: now, calendar: calendar)
                earlier = n > collapseAfterDays
                title =
                    earlier
                    ? dayWords(start, now: now, calendar: calendar)
                    : n == 0 ? "today" : n == 1 ? "yesterday" : format(start, "EEEE", calendar)
                let end =
                    calendar.date(byAdding: .day, value: 1, to: start)
                    ?? start.addingTimeInterval(86_400)
                let length = end.timeIntervalSince(start)
                marks = rows.compactMap { r in
                    guard let d = r.startedAt, length > 0 else { return nil }
                    let f = d.timeIntervalSince(start) / length
                    return DayMark(uri: r.uri, fraction: min(1, max(0, f)))
                }
            }
            let seconds = rows.reduce(0) { $0 + $1.seconds }
            let count = ordered.count
            return DayRows(
                id: key, title: title, earlier: earlier,
                headWords: "\(transmissionsWords(rows.count)) · \(lengthWords(seconds))",
                earlierWords:
                    "\(transmissionsWords(rows.count)) · "
                    + (count == 1 ? "1 recording" : "\(count) recordings"),
                rows: rows, marks: marks)
        }
    }

    /// The id and title of the day that holds parts nothing dates.
    static let undatedID = "undated"

    /// `1 transmission`, `20 transmissions`.
    public static func transmissionsWords(_ n: Int) -> String {
        n == 1 ? "1 transmission" : "\(n) transmissions"
    }

    /// The inspector's words on a transmission of `part` of `manifest`: the one holding `over`, or
    /// the part's first. Its place among the recording's transmissions, time and length, its
    /// levels, the clipped sentence from `clipped_ms`, then the recording's table, Play all's
    /// label and the line under Delete. `running` is the recording's job still writing: Ended reads
    /// `Recording` and the span runs to `now`.
    public static func partInspectorWords(
        part: RecordingPart, over: Int? = nil, of manifest: RecordingManifest, running: Bool,
        preRollMs: UInt64 = SpeechRecords.defaultPreRollMs,
        hangMs: UInt64 = SpeechRecords.defaultHangMs, timeZone: TimeZone = .current
    ) -> PartInspectorWords {
        let all = transmissions(of: manifest, preRollMs: preRollMs, hangMs: hangMs)
        let index =
            all.firstIndex { $0.part == part.part && over.map($0.holds(over:)) ?? true }
            ?? all.firstIndex { $0.part == part.part } ?? 0
        let row = all.indices.contains(index) ? all[index] : nil
        let start = row?.startedAt.map { clock($0, "HH:mm:ss", timeZone) }
        let time =
            (start ?? "—") + " · "
            + String(format: "%.1f s", row?.seconds ?? manifest.seconds(of: part))
        let clipped = (part.clippedMs ?? 0) > 0
        let shared = row?.split ?? false
        let levels = [
            PartTableRow(
                label: shared ? "File peak" : "Peak",
                value: clipped ? "0.0 dBFS · clipped" : dbfsWords(part.peakDBFS, places: 1)),
            PartTableRow(
                label: shared ? "File mean" : "Mean", value: dbfsWords(part.meanDBFS, places: 1)),
        ]
        let sentence = part.clippedMs.flatMap { ms -> String? in
            guard ms > 0 else { return nil }
            return String(format: "Clipped for %.1f s.", Double(ms) / 1000)
                + " Lower gain or pull back from the transmitter for the next one."
        }
        let dropped = droppedSentence(part, of: manifest)
        let recording = [
            PartTableRow(
                label: "Span", value: spanWords(manifest, running: running, timeZone: timeZone)),
            PartTableRow(label: "Ended", value: endedWords(manifest.endedBy, running: running)),
            PartTableRow(label: "Radio", value: radioWords(manifest.device)),
            PartTableRow(label: "Gain", value: gainWords(manifest.gains)),
            PartTableRow(
                label: "Squelch",
                value: manifest.squelchDBFS.isFinite ? dbfsWords(manifest.squelchDBFS) : "off"),
            PartTableRow(label: "Files", value: filesWords(manifest)),
        ]
        let n = max(1, all.count)
        return PartInspectorWords(
            heading: "TRANSMISSION \(index + 1) OF \(n)", time: time, levels: levels,
            clipped: clipped, clippedSentence: sentence, droppedSentence: dropped,
            recording: recording, playAll: n == 1 ? "Play" : "Play all \(n)",
            deleteLine: deleteWords(transmissions: n))
    }

    /// The inspector's line on a part the daemon dropped samples inside, at the capture rate of the
    /// part's anchor; nil when it dropped nothing or no rate is known.
    static func droppedSentence(_ part: RecordingPart, of m: RecordingManifest) -> String? {
        guard !part.gaps.isEmpty else { return nil }
        let anchor =
            m.anchors.last { $0.captureID == (part.captureID ?? "") }
            ?? m.anchors.last { $0.sampleRate > 0 }
        let rate = part.captureRate ?? anchor?.sampleRate ?? 0
        guard rate > 0 else { return nil }
        let seconds = Double(part.droppedSamples) / Double(rate)
        let amount =
            seconds < 0.1
            ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.1f s", seconds)
        let n = part.gaps.count
        return "\(amount) dropped in \(n) gap\(n == 1 ? "" : "s"): the daemon fell behind the"
            + " radio, and the file holds the audio either side."
    }

    /// `14:03:03 – 14:03:26`: the first part's start to the last part's end, through the anchors;
    /// `14:03:03 – now` while the job writes; `—` when no anchor dates either end.
    static func spanWords(_ m: RecordingManifest, running: Bool, timeZone: TimeZone) -> String {
        let ordered = m.parts.sorted { $0.part < $1.part }
        guard let from = ordered.first.flatMap({ m.startTime(of: $0) }) else { return "—" }
        let to =
            running
            ? "now"
            : ordered.last.flatMap { m.endTime(of: $0) }.map {
                clock($0, "HH:mm:ss", timeZone)
            }
        guard let to else { return "—" }
        return "\(clock(from, "HH:mm:ss", timeZone)) – \(to)"
    }
}
