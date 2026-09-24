// SPDX-License-Identifier: Apache-2.0

// The Recordings source's channel page and the inspector on a part, as data
// (docs/design/app-design-handoff-m3.md, 8c, and "The screens, read against the prose", 8c): one
// card per recording (`RecordingGroup`), the cards grouped by day with the rule that folds the
// older ones, a chip per part, the inspector's words for one part, the delete line and the order
// Play all plays the parts in. Everything is computed from a listing's `RecordingSummary` and the
// recording's `recording.json`, read through `ResolveLocalPath` as `Recordings.swift` reads it; a
// wall-clock time comes only from the manifest's anchors or its `started_at_ns`/`ended_at_ns`
// (invariant 5). No Observation here, so the Linux tests cover every rule the page draws.

import Foundation
import LeylineProto

/// One part as a chip on its recording's card: `▶ 09:12:40 · 8 s`.
public struct RecordingChip: Sendable, Equatable, Identifiable {
    /// `ley://recordings/<id>/<part>`, what `StartPlayback` and `ResolveLocalPath` take.
    public var uri: String
    public var part: Int
    /// The part's first sample as wall clock through the anchor of its capture; nil without one.
    public var startedAt: Date?
    public var seconds: Double

    public var id: String { uri }

    /// `09:12:40 · 8 s`, the seconds whole; `part 3 · 8 s` when no anchor dates the part. The
    /// view puts ▶ or ■ in front.
    public func words(timeZone: TimeZone = .current) -> String {
        let when = startedAt.map { Recordings.clock($0, "HH:mm:ss", timeZone) } ?? "part \(part)"
        return "\(when) · \(Recordings.wholeSeconds(seconds))"
    }
}

/// One recording as the channel page's card and the part inspector's table read it: the listing's
/// summary, and once its manifest has been read, the manifest's parts, device, gains and squelch.
/// Before the manifest arrives the card shows the listing's counts and no chips.
public struct RecordingGroup: Sendable, Equatable, Identifiable {
    public var jobID: String
    public var uri: String
    /// The first part's start through its anchor, else the job's `started_at_ns`.
    public var startedAt: Date?
    /// The last part's end through its anchor, else the job's `ended_at_ns`; nil while it runs,
    /// when the card reads `now`. A recording switched off after its last part ends at that part,
    /// because the card's range is what it holds.
    public var endedAt: Date?
    public var parts: Int
    /// The parts' lengths summed: what the recording holds, not the wall clock it ran.
    public var seconds: Double
    public var bytes: UInt64
    /// Its record job is running or degraded.
    public var running: Bool
    /// The manifest's `ended_by`, else the listing's; empty while it runs.
    public var endedBy: String
    public var chips: [RecordingChip]
    /// nil until `recording.json` has been read.
    public var manifest: RecordingManifest?

    public var id: String { uri }

    public init(summary: RecordingSummary, manifest: RecordingManifest?, running: Bool) {
        jobID = summary.jobID
        uri = summary.uri
        self.running = running
        self.manifest = manifest
        guard let m = manifest else {
            startedAt = summary.startedAt
            endedAt = running ? nil : summary.endedAt
            parts = summary.parts
            seconds = Double(max(0, summary.durationMs)) / 1000
            bytes = summary.sizeBytes
            endedBy = summary.endedBy
            chips = []
            return
        }
        let ordered = m.parts.sorted { $0.part < $1.part }
        chips = ordered.map {
            RecordingChip(
                uri: m.uri(of: $0), part: $0.part, startedAt: m.startTime(of: $0),
                seconds: m.seconds(of: $0))
        }
        startedAt = ordered.first.flatMap { m.startTime(of: $0) } ?? m.startedAt
        let lastEnd = ordered.last.flatMap { m.endTime(of: $0) }
        let endedNs = m.endedAtNs > 0 ? Date(timeIntervalSince1970: Double(m.endedAtNs) / 1e9) : nil
        endedAt = running ? nil : lastEnd ?? endedNs
        parts = ordered.count
        seconds = chips.reduce(0) { $0 + $1.seconds }
        bytes = m.bytes
        endedBy = m.endedBy
    }

    /// `09:12 — now`, `14:02 — 17:10`; `Mon 20:39 — 20:49` on a folded card, whose group header
    /// says only `earlier`. `—` for a time no anchor dates.
    public func rangeWords(
        collapsed: Bool, now: Date, calendar: Calendar = .current
    ) -> String {
        let tz = calendar.timeZone
        let from = startedAt.map { Recordings.clock($0, "HH:mm", tz) } ?? "—"
        let to = running ? "now" : endedAt.map { Recordings.clock($0, "HH:mm", tz) } ?? "—"
        let day =
            collapsed
            ? startedAt.map { Recordings.shortDayWords($0, now: now, calendar: calendar) }
            : nil
        return [day, "\(from) — \(to)"].compactMap { $0 }.joined(separator: " ")
    }

    /// `3 parts · 24 s · 1.1 MB`; a folded card leaves the size out, as the screens draw it.
    public func countWords(collapsed: Bool) -> String {
        var words = [RecordingSummary.partsWords(parts), Recordings.lengthWords(seconds)]
        if !collapsed { words.append(Recordings.sizeWords(bytes)) }
        return words.joined(separator: " · ")
    }
}

/// One of the page's day groups: `TODAY`, `YESTERDAY`, the day before by name, `EARLIER`.
public struct RecordingDay: Sendable, Equatable, Identifiable {
    /// `today`, `yesterday`, `Tuesday`, `earlier`; the header uppercases it.
    public var title: String
    /// The earlier group's cards fold to their header line until clicked open.
    public var collapsed: Bool
    /// Newest first, a running recording on top.
    public var recordings: [RecordingGroup]

    public var id: String { title }
}

/// A part URI taken apart: `ley://recordings/<id>/<part>`.
public struct RecordingPartRef: Sendable, Equatable {
    public var jobID: String
    public var part: Int

    public init?(uri: String) {
        let prefix = "ley://recordings/"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = uri.dropFirst(prefix.count).split(separator: "/")
        guard rest.count == 2, let n = Int(rest[1]), !rest[0].isEmpty else { return nil }
        jobID = String(rest[0])
        part = n
    }

    /// The recording the part belongs to, `ley://recordings/<id>`.
    public var recordingURI: String { "ley://recordings/\(jobID)" }
}

/// The inspector's three lines for one part (8c, "The inspector, on a part").
public struct PartWords: Sendable, Equatable {
    /// `Part 5 of Tuesday 14:02`.
    public var title: String
    /// `16:11:04 · 10.0 s`.
    public var time: String
    /// `0:03.8 of 0:10.0 · 2 overs`.
    public var progress: String
    /// The bar's fill, 0 to 1; 0 while the part is not playing.
    public var fraction: Double
}

/// One row of the inspector's table: `Peak` and `−6.2 dBFS`.
public struct PartTableRow: Sendable, Equatable, Identifiable {
    public var label: String
    public var value: String

    public var id: String { label }
}

/// Play all's queue (8c, "Playing"): the parts of one recording in order, started one at a time,
/// the next when the previous playback's tombstone arrives. Client side, because the daemon plays
/// one part per `StartPlayback`; a stop, a chip click or a failed start clears it.
public struct PlayQueue: Sendable, Equatable {
    public private(set) var recordingURI: String?
    public private(set) var pending: [String] = []

    public init() {}

    /// Queues `group`'s parts in part order and returns the first, which the caller plays now;
    /// nil for a recording with no closed part.
    public mutating func start(_ group: RecordingGroup) -> String? {
        let uris = group.chips.map(\.uri)
        guard let first = uris.first else {
            clear()
            return nil
        }
        recordingURI = group.uri
        pending = Array(uris.dropFirst())
        return first
    }

    /// The part to play after the one that just ended, removed from the queue; nil when the
    /// recording is done, which also empties the queue.
    public mutating func next() -> String? {
        guard !pending.isEmpty else {
            clear()
            return nil
        }
        return pending.removeFirst()
    }

    public mutating func clear() {
        recordingURI = nil
        pending = []
    }

    public var isEmpty: Bool { recordingURI == nil }
}

/// Where each chip goes in a card that wraps them: lines of indices, left to right, a chip moved
/// to the next line when it would cross `width`. A chip wider than the line sits alone on it.
/// The app's `FlowLayout` places its subviews by this rule.
public enum FlowRows {
    public static func lines(widths: [Double], spacing: Double, width: Double) -> [[Int]] {
        var lines: [[Int]] = []
        var line: [Int] = []
        var x = 0.0
        for (i, w) in widths.enumerated() {
            if !line.isEmpty, x + spacing + w > width {
                lines.append(line)
                line = []
                x = 0
            }
            x += (line.isEmpty ? 0 : spacing) + w
            line.append(i)
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

extension RecordingManifest {
    /// A part's length in seconds: its frames at the file's rate, else its span on the capture
    /// timeline at the anchor's rate; 0 when neither is known.
    public func seconds(of part: RecordingPart) -> Double {
        if sampleRate > 0, part.samples > 0 { return Double(part.samples) / Double(sampleRate) }
        let rate = anchors.last { $0.captureID == (part.captureID ?? "") }?.sampleRate ?? 0
        guard rate > 0, part.endSample >= part.startSample else { return 0 }
        return Double(part.endSample - part.startSample) / Double(rate)
    }

    /// A part's first and last sample as wall clock, through the anchor of its capture.
    public func startTime(of part: RecordingPart) -> Date? {
        part.captureID.flatMap { wallTime(ofSample: part.startSample, capture: $0) }
    }

    public func endTime(of part: RecordingPart) -> Date? {
        part.captureID.flatMap { wallTime(ofSample: part.endSample, capture: $0) }
    }
}

extension Recordings {
    /// The page's cards: the listing's recordings of one channel, each with its manifest when it
    /// has been read and running when its job is active in `jobs`.
    public static func groups(
        _ recordings: [RecordingSummary], manifests: [String: RecordingManifest],
        jobs: [Leyline_V1_Job]
    ) -> [RecordingGroup] {
        let active = Set(jobs.filter { $0.isActive && $0.recordConfig != nil }.map(\.jobID))
        return recordings.map {
            RecordingGroup(
                summary: $0, manifest: manifests[$0.jobID], running: active.contains($0.jobID))
        }
    }

    /// Recordings older than this many calendar days fold to their header line: the handoff's
    /// guess, "Two days before cards collapse" in its "Open" list.
    public static let collapseAfterDays = 2

    /// The page's day groups, newest first (8c): `today`, `yesterday`, the day before that by
    /// name, then `earlier`, which holds everything older than `collapseAfterDays` and is the one
    /// group that folds, so the page lists the last three days in full and the rest as one line
    /// each. The screens draw exactly that: TODAY, TUESDAY on a Thursday, then EARLIER with Monday
    /// and Sunday folded. A running recording's day is today whenever it started, so it is always
    /// the top card and never folded; an undated recording is earlier. Within a group the newest
    /// start comes first.
    public static func days(
        _ groups: [RecordingGroup], now: Date, calendar: Calendar = .current
    ) -> [RecordingDay] {
        func age(_ g: RecordingGroup) -> Int {
            if g.running { return 0 }
            guard let d = g.startedAt else { return Int.max }
            return daysBefore(d, now: now, calendar: calendar)
        }
        let sorted = groups.sorted { a, b in
            if a.running != b.running { return a.running }
            let sa = a.startedAt ?? .distantPast
            let sb = b.startedAt ?? .distantPast
            if sa != sb { return sa > sb }
            return a.uri > b.uri
        }
        var days: [RecordingDay] = []
        for g in sorted {
            let n = age(g)
            let title: String
            switch n {
            case 0: title = "today"
            case 1: title = "yesterday"
            case 2...collapseAfterDays:
                title = g.startedAt.map { format($0, "EEEE", calendar) } ?? "earlier"
            default: title = "earlier"
            }
            if let i = days.firstIndex(where: { $0.title == title }) {
                days[i].recordings.append(g)
            } else {
                days.append(
                    RecordingDay(title: title, collapsed: n > collapseAfterDays, recordings: [g]))
            }
        }
        return days
    }

    /// `4 recordings · 13.1 MB`: the page header's clause after the frequency, mode and width.
    public static func pageWords(_ groups: [RecordingGroup]) -> String {
        let count = groups.count == 1 ? "1 recording" : "\(groups.count) recordings"
        let bytes = groups.reduce(UInt64(0)) { $0 &+ $1.bytes }
        return "\(count) · \(sizeWords(bytes))"
    }

    /// The width a Record transmissions switch on the page records at, and Tune tunes: the newest
    /// manifest's, else the newest listing's, else nil for the mode's default.
    public static func channelWidth(_ groups: [RecordingGroup], channel: RecordingChannel)
        -> UInt32?
    {
        let fromManifest = groups.compactMap { $0.manifest?.bandwidthHz }.first { $0 > 0 }
        let fromListing = channel.recordings.map(\.bandwidthHz).first { $0 > 0 }
        return fromManifest ?? fromListing
    }

    /// The inspector's lines for `part` of `manifest`. The title's day and time are the
    /// recording's start (`Part 5 of Tuesday 14:02`, `Today`, `Yesterday`, a weekday for the six
    /// days before, `12 Sep`). The time line is the part's start and length to a tenth. The
    /// progress line is the playback's `position` over its rate against the part's length, and
    /// `2 overs` from the part's `squelch_opens` (one over per time the squelch opened), left out
    /// when there were none; `positionFrames` nil means the part is not playing.
    public static func partWords(
        part: RecordingPart, of manifest: RecordingManifest, positionFrames: UInt64?,
        positionRate: UInt32, now: Date, calendar: Calendar = .current
    ) -> PartWords {
        let tz = calendar.timeZone
        let recordingStart =
            manifest.parts.min { $0.part < $1.part }.flatMap { manifest.startTime(of: $0) }
            ?? manifest.startedAt
        let title: String
        if let d = recordingStart {
            let day = dayWords(d, now: now, calendar: calendar)
            title =
                "Part \(part.part) of \(day.prefix(1).uppercased() + day.dropFirst()) "
                + clock(d, "HH:mm", tz)
        } else {
            title = "Part \(part.part)"
        }
        let length = manifest.seconds(of: part)
        let start = manifest.startTime(of: part).map { clock($0, "HH:mm:ss", tz) }
        let time =
            (start ?? "part \(part.part)") + " · " + String(format: "%.1f s", length)
        let rate = positionRate > 0 ? Double(positionRate) : Double(manifest.sampleRate)
        let played = positionFrames.map { rate > 0 ? Double($0) / rate : 0 } ?? 0
        var progress = "\(elapsedWords(played)) of \(elapsedWords(length))"
        if part.squelchOpens > 0 {
            progress += part.squelchOpens == 1 ? " · 1 over" : " · \(part.squelchOpens) overs"
        }
        let fraction =
            positionFrames != nil && length > 0 ? min(1, max(0, played / length)) : 0
        return PartWords(title: title, time: time, progress: progress, fraction: fraction)
    }

    /// The inspector's table for a part: label and value, `—` for what nobody measured.
    public static func partTable(
        part: RecordingPart, of manifest: RecordingManifest, running: Bool
    ) -> [PartTableRow] {
        [
            PartTableRow(label: "Peak", value: dbfsWords(part.peakDBFS, places: 1)),
            PartTableRow(label: "Mean", value: dbfsWords(part.meanDBFS, places: 1)),
            PartTableRow(label: "Radio", value: radioWords(manifest.device)),
            PartTableRow(label: "Gain", value: gainWords(manifest.gains)),
            PartTableRow(
                label: "Squelch",
                value: manifest.squelchDBFS.isFinite ? dbfsWords(manifest.squelchDBFS) : "off"),
            PartTableRow(label: "Ended", value: endedWords(manifest.endedBy, running: running)),
            PartTableRow(label: "Files", value: filesWords(manifest)),
        ]
    }

    /// `ended_by` as a person says it (docs/design/recording.md, "The manifest", lists the
    /// daemon's words): `Recording` while the job runs.
    public static func endedWords(_ endedBy: String, running: Bool) -> String {
        if running { return "Recording" }
        switch endedBy {
        case "cancelled": return "Switched off"
        case "duration": return "Duration reached"
        case "quiet": return "Went quiet"
        case "channel ended": return "Channel ended"
        case "restart": return "Daemon restarted"
        case "store full": return "Store full"
        case "error": return "Error"
        case "": return "—"
        default: return endedBy.prefix(1).uppercased() + endedBy.dropFirst()
        }
    }

    /// `LNA 16 · VGA 20`: each stage's name and whole dB; a one-stage radio's is `30 dB`, because
    /// `tuner 30` names nothing the reader chose.
    public static func gainWords(_ gains: [RecordingManifest.Gain]) -> String {
        guard !gains.isEmpty else { return "—" }
        func db(_ v: Double) -> String { v.isFinite ? minus(String(format: "%.0f", v)) : "—" }
        if gains.count == 1 { return "\(db(gains[0].valueDB)) dB" }
        return gains.map { "\($0.element) \(db($0.valueDB))" }.joined(separator: " · ")
    }

    /// `11 WAV · 10.4 MB`: the parts, the format's first word, the manifest's bytes.
    public static func filesWords(_ m: RecordingManifest) -> String {
        let format = m.format.split(separator: "-").first.map { $0.uppercased() } ?? ""
        let kind = format.isEmpty ? (m.parts.count == 1 ? "file" : "files") : format
        return "\(m.parts.count) \(kind) · \(sizeWords(m.bytes))"
    }

    /// The line under Delete recording…: `Deletes all 11 parts. A recording is kept or deleted
    /// whole.`, because `DeleteResource` refuses one part (docs/design/recording.md, "The wire").
    public static func deleteWords(parts: Int) -> String {
        let what = parts == 1 ? "Deletes its one part." : "Deletes all \(parts) parts."
        return what + " A recording is kept or deleted whole."
    }

    /// The confirmation's question, naming the recording by its channel and start:
    /// `Delete GMRS CH3, Tuesday 14:02?`.
    public static func deleteQuestion(
        channelTitle: String, group: RecordingGroup, now: Date, calendar: Calendar = .current
    ) -> String {
        guard let d = group.startedAt else { return "Delete this recording of \(channelTitle)?" }
        let day = dayWords(d, now: now, calendar: calendar)
        let when =
            day.prefix(1).uppercased() + day.dropFirst() + " "
            + clock(d, "HH:mm", calendar.timeZone)
        return "Delete \(channelTitle), \(when)?"
    }

    /// The daemon's refusal to delete a recording whose job runs, word for word
    /// (`ResourcesService.deleteResource` in the engine), so Delete's tooltip says what `ley
    /// recordings delete` would print. The daemon-backed suite holds the two together.
    public static func deleteRefusalWords(jobID: String) -> String {
        "\(jobID) is still recording; cancel the job first, then delete it"
    }

    /// `24 s`, `1 m 48 s`, `1 h 04 m`: a recording's held length on its card.
    public static func lengthWords(_ seconds: Double) -> String {
        let s = seconds.isFinite ? Int(max(0, seconds).rounded()) : 0
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) m \(s % 60) s" }
        return "\(s / 3600) h " + String(format: "%02d m", (s % 3600) / 60)
    }

    /// `8 s`: a chip's length, whole seconds, never below 1 for a part that holds anything.
    static func wholeSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        return "\(max(1, Int(seconds.rounded()))) s"
    }

    /// `0:03.8`: minutes and seconds to a tenth, the inspector's position and length.
    static func elapsedWords(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, seconds) : 0
        let tenths = Int((s * 10).rounded())
        return String(format: "%d:%04.1f", tenths / 600, Double(tenths % 600) / 10)
    }

    private static func dbfsWords(_ v: Double?, places: Int = 0) -> String {
        guard let v, v.isFinite else { return "—" }
        return minus(String(format: "%.\(places)f", v)) + " dBFS"
    }

    private static func radioWords(_ d: RecordingManifest.Device?) -> String {
        guard let d else { return "—" }
        if !d.model.isEmpty { return d.model }
        return d.driver.isEmpty ? "—" : d.driver
    }

    /// The writing guide's minus sign.
    private static func minus(_ s: String) -> String {
        s.replacingOccurrences(of: "-", with: "−")
    }

    static func clock(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
