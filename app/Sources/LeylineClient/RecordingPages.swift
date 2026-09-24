// SPDX-License-Identifier: Apache-2.0

// The Library's recordings as data (docs/design/app-design-handoff-m3.md, 8c, revised by "10a ·
// The Library, revised"): one `RecordingGroup` per recording with its parts in order, the page's
// header words, the player's words, the recording's table words, the delete line and the order
// Play all plays the parts in; the page's rows and the inspector's words are `LibraryRows.swift`.
// Everything is computed from a listing's `RecordingSummary` and the recording's
// `recording.json`, read through `ResolveLocalPath` as `Recordings.swift` reads it; a wall-clock
// time comes only from the manifest's anchors or its `started_at_ns`/`ended_at_ns` (invariant 5).
// No Observation here, so the Linux tests cover every rule the Library draws.

import Foundation
import LeylineProto

/// One part of a recording, in part order: what Play all queues and the player steps through.
public struct RecordingChip: Sendable, Equatable, Identifiable {
    /// `ley://recordings/<id>/<part>`, what `StartPlayback` and `ResolveLocalPath` take.
    public var uri: String
    public var part: Int
    /// The part's first sample as wall clock through the anchor of its capture; nil without one.
    public var startedAt: Date?
    public var seconds: Double

    public var id: String { uri }
}

/// One recording as the page and the part inspector read it: the listing's summary, and once
/// its manifest has been read, the manifest's parts, device, gains and squelch. Before the
/// manifest arrives it has the listing's counts and no parts, and the page shows no row for it.
public struct RecordingGroup: Sendable, Equatable, Identifiable {
    public var jobID: String
    public var uri: String
    /// The first part's start through its anchor, else the job's `started_at_ns`.
    public var startedAt: Date?
    /// The last part's end through its anchor, else the job's `ended_at_ns`; nil while it runs.
    /// A recording switched off after its last part ends at that part, because its range is
    /// what it holds.
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

/// The Library's player's words for one part (docs/design/app-design-handoff-m3.md, "10a · The
/// Library, revised", "The player"): two lines beside the play button and the two ends of its
/// progress track.
public struct PlayerWords: Sendable, Equatable {
    /// `GMRS CH3 · Today`: the channel and the day the part started.
    public var title: String
    /// `14:03:20 · part 4 of 4`: the part's start and its place among the recording's parts.
    public var time: String
    /// `0:03.8`: how far the part has played, at the track's left; `0:00.0` while it is not
    /// playing.
    public var played: String
    /// `0:10.0`: the part's length, at the track's right.
    public var length: String
    /// The track's fill, 0 to 1; 0 while the part is not playing.
    public var fraction: Double
}

/// Play all's and Play day's queue (8c, "Playing"; 10a): parts in order, started one at a time,
/// the next when the previous playback's tombstone arrives. Client side, because the daemon plays
/// one part per `StartPlayback`; a stop, a row's click or a failed start clears it.
public struct PlayQueue: Sendable, Equatable {
    /// The recording a Play all walks; nil for Play day, which walks a day's parts across
    /// recordings, and for an empty queue.
    public private(set) var recordingURI: String?
    public private(set) var pending: [String] = []
    private var active = false

    public init() {}

    /// Queues `group`'s parts in part order and returns the first, which the caller plays now;
    /// nil for a recording with no closed part. With `at`, the queue starts from that part
    /// instead, which is how the player's ⏮ and ⏭ move a Play all on without ending it; nil
    /// when `at` is not one of the recording's parts.
    public mutating func start(_ group: RecordingGroup, at uri: String? = nil) -> String? {
        var uris = group.chips.map(\.uri)
        if let uri {
            guard let i = uris.firstIndex(of: uri) else {
                clear()
                return nil
            }
            uris = Array(uris[i...])
        }
        guard let first = uris.first else {
            clear()
            return nil
        }
        recordingURI = group.uri
        pending = Array(uris.dropFirst())
        active = true
        return first
    }

    /// Play day: `uris` in the order given (`DayRows.playOrder`, oldest first), the first
    /// returned for the caller to play now; nil for an empty day.
    public mutating func start(parts uris: [String]) -> String? {
        guard let first = uris.first else {
            clear()
            return nil
        }
        recordingURI = nil
        pending = Array(uris.dropFirst())
        active = true
        return first
    }

    /// Whether any part still to play belongs to the recording at `uri`, or the queue walks it:
    /// a delete of that recording clears the queue.
    public func holds(recordingURI uri: String) -> Bool {
        recordingURI == uri
            || pending.contains { RecordingPartRef(uri: $0)?.recordingURI == uri }
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
        active = false
    }

    public var isEmpty: Bool { !active }
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
    /// The page's recordings: the listing's recordings of one channel, each with its manifest when it
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

    /// Days older than this many calendar days are EARLIER, one line each until opened: the
    /// handoff's guess, "Two days before cards collapse" in its "Open" list, kept by 10a.
    public static let collapseAfterDays = 2

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

    /// The player's words for `part` of `manifest` on the channel titled `channelTitle`
    /// (`PlayerWords`): `GMRS CH3 · Today` from the part's start, else the recording's, through
    /// `dayWords` with a capital, and no day clause when nothing dates it; `14:03:20 · part 4 of
    /// 4` counting the manifest's parts in part order. The position is the playback's `position`
    /// over its rate (`positionFrames` nil while the part is not playing) and never reads past
    /// the part's length.
    public static func playerWords(
        channelTitle: String, part: RecordingPart, of manifest: RecordingManifest,
        positionFrames: UInt64?, positionRate: UInt32, now: Date, calendar: Calendar = .current
    ) -> PlayerWords {
        let start = manifest.startTime(of: part)
        let day = (start ?? manifest.startedAt).map { d -> String in
            let w = dayWords(d, now: now, calendar: calendar)
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        let title = [channelTitle, day].compactMap { $0 }.joined(separator: " · ")
        let ordered = manifest.parts.sorted { $0.part < $1.part }
        let place = (ordered.firstIndex { $0.part == part.part } ?? 0) + 1
        let time = [
            start.map { clock($0, "HH:mm:ss", calendar.timeZone) },
            "part \(place) of \(ordered.count)",
        ].compactMap { $0 }.joined(separator: " · ")
        let length = manifest.seconds(of: part)
        let rate = positionRate > 0 ? Double(positionRate) : Double(manifest.sampleRate)
        let played = positionFrames.map { rate > 0 ? Double($0) / rate : 0 } ?? 0
        let fraction = positionFrames != nil && length > 0 ? min(1, max(0, played / length)) : 0
        return PlayerWords(
            title: title, time: time, played: elapsedWords(min(played, length)),
            length: elapsedWords(length), fraction: fraction)
    }

    /// The part `step` places from the part `uri` names, in `manifest`'s part order, as the URI
    /// that plays it: the player's ⏮ (`-1`) and ⏭ (`1`). nil past either end, and for a URI that
    /// is not one of this recording's parts, which is when the buttons are disabled.
    public static func neighbourPart(
        of uri: String, in manifest: RecordingManifest, step: Int
    ) -> String? {
        guard let ref = RecordingPartRef(uri: uri), ref.jobID == manifest.jobID else { return nil }
        let ordered = manifest.parts.sorted { $0.part < $1.part }
        guard let i = ordered.firstIndex(where: { $0.part == ref.part }) else { return nil }
        let j = i + step
        guard ordered.indices.contains(j) else { return nil }
        return manifest.uri(of: ordered[j])
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

    /// The line under Delete recording…: `Deletes all 4 parts.` (10a), because
    /// `DeleteResource` refuses one part (docs/design/recording.md, "The wire").
    public static func deleteWords(parts: Int) -> String {
        parts == 1 ? "Deletes its one part." : "Deletes all \(parts) parts."
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

    /// `8 s`: a row's length, whole seconds, never below 1 for a part that holds anything.
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

    static func dbfsWords(_ v: Double?, places: Int = 0) -> String {
        guard let v, v.isFinite else { return "—" }
        return minus(String(format: "%.\(places)f", v)) + " dBFS"
    }

    static func radioWords(_ d: RecordingManifest.Device?) -> String {
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
