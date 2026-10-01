// SPDX-License-Identifier: Apache-2.0

// The Library's channel page and the inspector on a part as the design draws them, as data: rows
// are parts, grouped by the day each part started, a recording of several parts bracketed in the
// gutter and separated from the next by a gap, each day with its head words, its 24-hour strip and
// its play order; days older than two are EARLIER, one line each. Built from the recordings'
// manifests (`RecordingGroup`), with wall clock only through the manifests' anchors (invariant 5).
// No Observation here, so the Linux tests cover every rule the page draws.

import Foundation
import LeylineProto

/// One part as a row of the page: what the columns print and where it sits in its recording.
public struct PartRow: Sendable, Equatable, Identifiable {
    /// Where the row sits in the gutter's bracket: a recording of one part on this day has none.
    public enum Bracket: Sendable, Equatable {
        case none, first, middle, last
    }

    /// `ley://recordings/<id>/<part>`, what `StartPlayback` and `ResolveLocalPath` take.
    public var uri: String
    public var recordingURI: String
    public var jobID: String
    public var part: Int
    /// The part's first sample through its capture's anchor; nil when no anchor dates it.
    public var startedAt: Date?
    public var seconds: Double
    public var peakDBFS: Double?
    public var clippedMs: Int64?
    public var bytes: UInt64
    public var bracket: Bracket
    /// The row opens a recording that follows another on the same day: the page leaves a gap
    /// above it.
    public var gapBefore: Bool

    public var id: String { uri }

    /// The capture clipped during the part (`clipped_ms` > 0), which the row prints as a
    /// `0.0 dBFS` peak in `accentRec`.
    public var clipped: Bool { (clippedMs ?? 0) > 0 }

    public func words(timeZone: TimeZone = .current) -> PartRowWords {
        PartRowWords(
            starts: startedAt.map { Recordings.clock($0, "HH:mm:ss", timeZone) } ?? "part \(part)",
            length: Recordings.wholeSeconds(seconds),
            peak: clipped ? "0.0 dBFS" : Recordings.dbfsWords(peakDBFS, places: 1),
            size: Recordings.sizeWords(bytes))
    }
}

/// A row's four printed columns: `14:03:03`, `4 s`, `−3.1 dBFS`, `372 KB`. The level column is a
/// graph (`LevelGraph`), not words.
public struct PartRowWords: Sendable, Equatable {
    public var starts: String
    public var length: String
    /// `0.0 dBFS` when the part clipped, whatever the audio's peak; `—` when nobody measured it.
    public var peak: String
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
    /// `7 parts · 1 m 17 s`: the day's parts and their lengths summed.
    public var headWords: String
    /// `5 parts · 3 recordings`: the EARLIER line's words.
    public var earlierWords: String
    /// Recordings newest first; within a recording its parts in part order.
    public var rows: [PartRow]
    /// Every dated part's start on the strip.
    public var marks: [DayMark]

    /// Play day's queue: the day's parts oldest first, in the order they were heard.
    public var playOrder: [String] {
        rows.sorted { a, b in
            let sa = a.startedAt ?? .distantPast
            let sb = b.startedAt ?? .distantPast
            if sa != sb { return sa < sb }
            if a.jobID != b.jobID { return a.jobID < b.jobID }
            return a.part < b.part
        }
        .map(\.uri)
    }
}

/// The inspector on a part: the part's own lines, then its recording's.
public struct PartInspectorWords: Sendable, Equatable {
    /// `PART 4 OF 4`.
    public var heading: String
    /// `14:03:20 · 5.8 s`.
    public var time: String
    /// Peak, Mean and Overs; Overs is left out when the squelch never opened (a continuous
    /// recording), as the first build did.
    public var levels: [PartTableRow]
    /// The Peak row reads `0.0 dBFS · clipped` and is drawn in `accentRec`.
    public var clipped: Bool
    /// `Clipped for 0.4 s. Lower gain or pull back from the transmitter for the next one.`, or
    /// nil when the part did not clip.
    public var clippedSentence: String?
    /// Span, Ended, Radio, Gain, Squelch, Files.
    public var recording: [PartTableRow]
    /// `Play all 4`; `Play` for a recording of one part.
    public var playAll: String
    /// `Deletes all 4 parts.`
    public var deleteLine: String
}

/// One row of the inspector's tables: `Peak` and `−6.2 dBFS`.
public struct PartTableRow: Sendable, Equatable, Identifiable {
    public var label: String
    public var value: String

    public var id: String { label }
}

extension Recordings {
    /// The page's days, newest first: every part of every recording in `groups` whose manifest has
    /// been read, as a row under the day its part started. A recording with no part never shows
    /// (the daemon discards one at job end, but a listing can lag), and neither does one whose
    /// manifest is not read yet. `today`, `yesterday` and the day before by name are open; older
    /// days are EARLIER, one line each; parts no anchor dates, nor the job's start, go last under
    /// EARLIER as `undated`. Within a day, recordings newest first by their first part there, and a
    /// recording's parts in part order, so its bracket reads down the way it was heard; a recording
    /// that ran past midnight is on both days.
    public static func dayRows(
        _ groups: [RecordingGroup], now: Date, calendar: Calendar = .current
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
            for p in m.parts.sorted(by: { $0.part < $1.part }) {
                let date = m.startTime(of: p)
                let key: String
                if let d = date ?? g.startedAt {
                    let start = calendar.startOfDay(for: d)
                    key = format(start, "yyyy-MM-dd", calendar)
                    dayStart[key] = start
                } else {
                    key = undatedID
                }
                let row = PartRow(
                    uri: m.uri(of: p), recordingURI: m.uri, jobID: m.jobID, part: p.part,
                    startedAt: date, seconds: m.seconds(of: p), peakDBFS: p.peakDBFS,
                    clippedMs: p.clippedMs, bytes: p.bytes, bracket: .none, gapBefore: false)
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
                headWords: "\(RecordingSummary.partsWords(rows.count)) · \(lengthWords(seconds))",
                earlierWords:
                    "\(RecordingSummary.partsWords(rows.count)) · "
                    + (count == 1 ? "1 recording" : "\(count) recordings"),
                rows: rows, marks: marks)
        }
    }

    /// The id and title of the day that holds parts nothing dates.
    static let undatedID = "undated"

    /// The inspector's words on `part` of `manifest`: the part's place, time and length, its levels
    /// and overs, the clipped sentence from `clipped_ms`, then the recording's table, Play all's
    /// label and the line under Delete. `running` is the recording's job still writing: Ended reads
    /// `Recording` and the span runs to `now`.
    public static func partInspectorWords(
        part: RecordingPart, of manifest: RecordingManifest, running: Bool,
        timeZone: TimeZone = .current
    ) -> PartInspectorWords {
        let ordered = manifest.parts.sorted { $0.part < $1.part }
        let place = (ordered.firstIndex { $0.part == part.part } ?? 0) + 1
        let start = manifest.startTime(of: part).map { clock($0, "HH:mm:ss", timeZone) }
        let time =
            (start ?? "part \(part.part)") + " · "
            + String(format: "%.1f s", manifest.seconds(of: part))
        let clipped = (part.clippedMs ?? 0) > 0
        var levels = [
            PartTableRow(
                label: "Peak",
                value: clipped ? "0.0 dBFS · clipped" : dbfsWords(part.peakDBFS, places: 1)),
            PartTableRow(label: "Mean", value: dbfsWords(part.meanDBFS, places: 1)),
        ]
        if part.squelchOpens > 0 {
            levels.append(PartTableRow(label: "Overs", value: "\(part.squelchOpens)"))
        }
        let sentence = part.clippedMs.flatMap { ms -> String? in
            guard ms > 0 else { return nil }
            return String(format: "Clipped for %.1f s.", Double(ms) / 1000)
                + " Lower gain or pull back from the transmitter for the next one."
        }
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
        let n = manifest.parts.count
        return PartInspectorWords(
            heading: "PART \(place) OF \(n)", time: time, levels: levels, clipped: clipped,
            clippedSentence: sentence, recording: recording,
            playAll: n == 1 ? "Play" : "Play all \(n)", deleteLine: deleteWords(parts: n))
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
