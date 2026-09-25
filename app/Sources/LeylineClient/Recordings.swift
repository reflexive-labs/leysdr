// SPDX-License-Identifier: Apache-2.0

// Recordings as the window reads them (docs/plans/app.md, APP-5; docs/design/
// app-design-handoff-m3.md, 8a and 8b): `recording.json` decoded, the rule that says which part
// holds a transmission (a kept row of the log), the frequency form of `RecordConfig` the switch
// starts, the switch's state and status line, and the question asked before the window moves the
// radio out from under a recording. The manifest is the file format the daemon writes
// (docs/design/recording.md, "The manifest"; `engine/Sources/LeylineDaemon/Recording/
// RecordingManifest.swift`), read from disk through `Resources.ResolveLocalPath` because the window
// is local, as `ley recordings show` is. Every position is a sample on a capture's timeline and
// wall clock comes only from the manifest's anchors and the job's `created_at_ns` (invariant 5).

import Foundation
import LeylineProto

/// `recording.json`, the resource a record job produces. Keys are the file's snake_case ones.
public struct RecordingManifest: Sendable, Equatable, Codable {
    public struct Device: Sendable, Equatable, Codable {
        public var driver: String
        public var model: String
        public var serial: String
    }

    public struct Gain: Sendable, Equatable, Codable {
        public var element: String
        public var valueDB: Double

        enum CodingKeys: String, CodingKey {
            case element
            case valueDB = "value_db"
        }
    }

    /// What opened and closed the parts; absent on a continuous recording.
    public struct Gate: Sendable, Equatable, Codable {
        public var kind: String
        public var preRollMs: UInt32
        public var hangMs: UInt32

        enum CodingKeys: String, CodingKey {
            case kind
            case preRollMs = "pre_roll_ms"
            case hangMs = "hang_ms"
        }
    }

    public struct Client: Sendable, Equatable, Codable {
        public var clientID: String
        public var kind: String
        public var label: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case kind, label
        }
    }

    /// One capture's anchor, dating that capture's samples from `fromSample` on. A recording that
    /// spans a detach and reattach spans two captures and lists one anchor for each.
    public struct Anchor: Sendable, Equatable, Codable {
        public var captureID: String
        public var hostTimeNs: Int64
        public var sampleRate: UInt64
        public var driftPpm: Double
        public var fromSample: UInt64

        enum CodingKeys: String, CodingKey {
            case captureID = "capture_id"
            case hostTimeNs = "host_time_ns"
            case sampleRate = "sample_rate"
            case driftPpm = "drift_ppm"
            case fromSample = "from_sample"
        }

        public init(
            captureID: String, hostTimeNs: Int64, sampleRate: UInt64, driftPpm: Double = 0,
            fromSample: UInt64 = 0
        ) {
            self.captureID = captureID
            self.hostTimeNs = hostTimeNs
            self.sampleRate = sampleRate
            self.driftPpm = driftPpm
            self.fromSample = fromSample
        }

        // Anchors written before DEC-11 carried no capture id; they date the recording's one
        // capture, which is then unknown, and nothing matches against it.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            captureID = try c.decodeIfPresent(String.self, forKey: .captureID) ?? ""
            hostTimeNs = try c.decodeIfPresent(Int64.self, forKey: .hostTimeNs) ?? 0
            sampleRate = try c.decodeIfPresent(UInt64.self, forKey: .sampleRate) ?? 0
            driftPpm = try c.decodeIfPresent(Double.self, forKey: .driftPpm) ?? 0
            fromSample = try c.decodeIfPresent(UInt64.self, forKey: .fromSample) ?? 0
        }

        /// The contract's shape, for `SampleClock`.
        public var captureAnchor: Leyline_V1_CaptureAnchor {
            .with {
                $0.captureID = captureID
                $0.hostTimeNs = hostTimeNs
                $0.sampleRate = sampleRate
                $0.driftPpm = driftPpm
            }
        }
    }

    public struct Gap: Sendable, Equatable, Codable {
        public var fromSample: UInt64
        public var toSample: UInt64
        public var reason: String

        enum CodingKeys: String, CodingKey {
            case reason
            case fromSample = "from_sample"
            case toSample = "to_sample"
        }
    }

    public var jobID: String
    public var uri: String
    /// `audio` or `iq`.
    public var kind: String
    public var frequencyHz: UInt64
    /// The mode's name as the file spells it (`NFM`); `demodMode` resolves it.
    public var mode: String
    public var bandwidthHz: UInt32
    /// The part files' rate: the audio rate for WAV, the capture rate for IQ.
    public var sampleRate: UInt64
    public var format: String
    public var device: Device?
    public var gains: [Gain]
    /// NaN when the recording was not gated: the file leaves the key out, because NaN has no JSON.
    public var squelchDBFS: Double
    public var gate: Gate?
    public var partMs: Int64
    /// Wall clock the daemon wrote when the job started and ended, nanoseconds since the epoch;
    /// `endedAtNs` is 0 and `endedBy` empty while the job runs.
    public var startedAtNs: Int64
    public var endedAtNs: Int64
    public var endedBy: String
    public var createdBy: Client?
    public var anchors: [Anchor]
    /// Closed parts in order: a part joins the manifest when it closes, so an open one is not
    /// listed.
    public var parts: [RecordingPart]
    public var coverageGaps: [Gap]
    public var bytes: UInt64

    enum CodingKeys: String, CodingKey {
        case uri, kind, mode, format, device, gains, gate, anchors, parts, bytes
        case jobID = "job_id"
        case frequencyHz = "frequency_hz"
        case bandwidthHz = "bandwidth_hz"
        case sampleRate = "sample_rate"
        case squelchDBFS = "squelch_dbfs"
        case partMs = "part_ms"
        case startedAtNs = "started_at_ns"
        case endedAtNs = "ended_at_ns"
        case endedBy = "ended_by"
        case createdBy = "created_by"
        case coverageGaps = "coverage_gaps"
    }

    /// The daemon's own defaults for a missing key (`RecordingManifest.init(from:)` in the
    /// engine), so a manifest a restart repaired reads the same on both sides.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(String.self, forKey: .jobID)
        uri = try c.decodeIfPresent(String.self, forKey: .uri) ?? "ley://recordings/\(jobID)"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "audio"
        frequencyHz = try c.decodeIfPresent(UInt64.self, forKey: .frequencyHz) ?? 0
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        bandwidthHz = try c.decodeIfPresent(UInt32.self, forKey: .bandwidthHz) ?? 0
        sampleRate = try c.decodeIfPresent(UInt64.self, forKey: .sampleRate) ?? 0
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        device = try c.decodeIfPresent(Device.self, forKey: .device)
        gains = try c.decodeIfPresent([Gain].self, forKey: .gains) ?? []
        squelchDBFS = try c.decodeIfPresent(Double.self, forKey: .squelchDBFS) ?? .nan
        gate = try c.decodeIfPresent(Gate.self, forKey: .gate)
        partMs = try c.decodeIfPresent(Int64.self, forKey: .partMs) ?? 0
        startedAtNs = try c.decodeIfPresent(Int64.self, forKey: .startedAtNs) ?? 0
        endedAtNs = try c.decodeIfPresent(Int64.self, forKey: .endedAtNs) ?? 0
        endedBy = try c.decodeIfPresent(String.self, forKey: .endedBy) ?? ""
        createdBy = try c.decodeIfPresent(Client.self, forKey: .createdBy)
        anchors = try c.decodeIfPresent([Anchor].self, forKey: .anchors) ?? []
        parts = try c.decodeIfPresent([RecordingPart].self, forKey: .parts) ?? []
        coverageGaps = try c.decodeIfPresent([Gap].self, forKey: .coverageGaps) ?? []
        bytes = try c.decodeIfPresent(UInt64.self, forKey: .bytes) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobID, forKey: .jobID)
        try c.encode(uri, forKey: .uri)
        try c.encode(kind, forKey: .kind)
        try c.encode(frequencyHz, forKey: .frequencyHz)
        try c.encode(mode, forKey: .mode)
        try c.encode(bandwidthHz, forKey: .bandwidthHz)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(device, forKey: .device)
        try c.encode(gains, forKey: .gains)
        if squelchDBFS.isFinite { try c.encode(squelchDBFS, forKey: .squelchDBFS) }
        try c.encodeIfPresent(gate, forKey: .gate)
        try c.encode(partMs, forKey: .partMs)
        try c.encode(startedAtNs, forKey: .startedAtNs)
        try c.encode(endedAtNs, forKey: .endedAtNs)
        try c.encode(endedBy, forKey: .endedBy)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(anchors, forKey: .anchors)
        try c.encode(parts, forKey: .parts)
        try c.encode(coverageGaps, forKey: .coverageGaps)
        try c.encode(bytes, forKey: .bytes)
    }

    /// NaN never equals itself, and an ungated recording's squelch is NaN; two reads of one file
    /// compare equal.
    public static func == (a: Self, b: Self) -> Bool {
        a.jobID == b.jobID && a.uri == b.uri && a.kind == b.kind && a.frequencyHz == b.frequencyHz
            && a.mode == b.mode && a.bandwidthHz == b.bandwidthHz && a.sampleRate == b.sampleRate
            && a.format == b.format && a.device == b.device && a.gains == b.gains
            && (a.squelchDBFS == b.squelchDBFS || (a.squelchDBFS.isNaN && b.squelchDBFS.isNaN))
            && a.gate == b.gate && a.partMs == b.partMs && a.startedAtNs == b.startedAtNs
            && a.endedAtNs == b.endedAtNs && a.endedBy == b.endedBy && a.createdBy == b.createdBy
            && a.anchors == b.anchors && a.parts == b.parts && a.coverageGaps == b.coverageGaps
            && a.bytes == b.bytes
    }

    public static let fileName = "recording.json"

    public var demodMode: Leyline_V1_DemodMode { Leyline_V1_DemodMode.named(mode) ?? .unspecified }

    /// Reads `recording.json` at `url`, or inside it when `url` is the recording's directory,
    /// which is what `ResolveLocalPath` returns for `ley://recordings/<id>`. Each part is given its
    /// capture (`RecordingPart.captureID`): the anchors' one capture when they name one, else the
    /// part sidecar's `anchor.capture_id`, which only a recording spanning two captures needs read.
    public static func read(at url: URL) throws -> RecordingManifest {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let file = exists && isDirectory.boolValue ? url.appendingPathComponent(fileName) : url
        var manifest = try decode(Data(contentsOf: file))
        let captures = Set(manifest.anchors.map(\.captureID).filter { !$0.isEmpty })
        if captures.count > 1 {
            let directory = file.deletingLastPathComponent()
            for i in manifest.parts.indices {
                manifest.parts[i].captureID = sidecarCapture(
                    directory.appendingPathComponent(manifest.parts[i].file))
            }
        }
        return manifest
    }

    /// Decodes the manifest's bytes; the one-capture rule of `read(at:)` applies, and a
    /// recording spanning several captures leaves its parts' captures unknown.
    public static func decode(_ data: Data) throws -> RecordingManifest {
        var manifest = try JSONDecoder().decode(RecordingManifest.self, from: data)
        let captures = Set(manifest.anchors.map(\.captureID).filter { !$0.isEmpty })
        if captures.count == 1, let only = captures.first {
            for i in manifest.parts.indices { manifest.parts[i].captureID = only }
        }
        return manifest
    }

    /// The capture a part sidecar dates its samples on (`docs/design/recording.md`, "The part
    /// sidecar"): the samples file's name with `.json` for its extension.
    private static func sidecarCapture(_ samples: URL) -> String? {
        struct Sidecar: Decodable {
            struct Anchor: Decodable {
                var captureID: String?
                enum CodingKeys: String, CodingKey { case captureID = "capture_id" }
            }
            var anchor: Anchor?
        }
        let url = samples.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url),
            let id = (try? JSONDecoder().decode(Sidecar.self, from: data))?.anchor?.captureID,
            !id.isEmpty
        else { return nil }
        return id
    }

    /// `ley://recordings/<id>/<part>`: what `Control.StartPlayback` and `ResolveLocalPath` take
    /// for one part.
    public func uri(of part: RecordingPart) -> String { "\(uri)/\(part.part)" }

    /// The wall clock of `sample` on `capture`, through the newest anchor of that capture that
    /// applies from a sample not past it; nil without one (invariant 5).
    public func wallTime(ofSample sample: UInt64, capture: String) -> Date? {
        let time = Leyline_V1_SampleTime.with {
            $0.captureID = capture
            $0.sampleIndex = sample
        }
        let anchor = anchors.last { $0.captureID == capture && $0.fromSample <= sample }
        return anchor.flatMap {
            SampleClock.wallTime(of: time, anchor: $0.captureAnchor, fromSample: $0.fromSample)
        }
    }

    /// When the job started, from the manifest's `started_at_ns`; nil when it is unset.
    public var startedAt: Date? {
        startedAtNs > 0 ? Date(timeIntervalSince1970: Double(startedAtNs) / 1e9) : nil
    }
}

/// One closed part as the manifest lists it: where it lies on its capture's timeline, its frames
/// and bytes, and the levels measured as it was written.
public struct RecordingPart: Sendable, Equatable, Codable {
    public var part: Int
    public var file: String
    /// On the capture's timeline, at the capture rate.
    public var startSample: UInt64
    public var endSample: UInt64
    /// Frames in the file, at the manifest's `sample_rate`.
    public var samples: UInt64
    public var bytes: UInt64
    /// Absent when the part's measurement never finished; a level nobody measured is not shown.
    public var peakDBFS: Double?
    public var meanDBFS: Double?
    public var squelchOpens: Int
    /// How long inside the part the capture's `CaptureLevel` reported clipping, in ms
    /// (docs/design/recording.md, "The manifest"); nil when nothing clipped, since the daemon
    /// leaves the key out at zero, and on a part a restart repaired. The Library prints
    /// `0.0 dBFS · clipped` from this, never from `peakDBFS`, which measures the audio.
    public var clippedMs: Int64?
    /// The capture the samples are on. Not in the file: `RecordingManifest.read(at:)` sets it
    /// from the anchors, and nil means it could not be told.
    public var captureID: String?

    enum CodingKeys: String, CodingKey {
        case part, file, samples, bytes
        case startSample = "start_sample"
        case endSample = "end_sample"
        case peakDBFS = "peak_dbfs"
        case meanDBFS = "mean_dbfs"
        case squelchOpens = "squelch_opens"
        case clippedMs = "clipped_ms"
    }

    public init(
        part: Int, file: String, startSample: UInt64, endSample: UInt64, samples: UInt64,
        bytes: UInt64, peakDBFS: Double? = nil, meanDBFS: Double? = nil, squelchOpens: Int = 0,
        clippedMs: Int64? = nil, captureID: String? = nil
    ) {
        self.part = part
        self.file = file
        self.startSample = startSample
        self.endSample = endSample
        self.samples = samples
        self.bytes = bytes
        self.peakDBFS = peakDBFS
        self.meanDBFS = meanDBFS
        self.squelchOpens = squelchOpens
        self.clippedMs = clippedMs
        self.captureID = captureID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        part = try c.decode(Int.self, forKey: .part)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        startSample = try c.decode(UInt64.self, forKey: .startSample)
        endSample = try c.decode(UInt64.self, forKey: .endSample)
        samples = try c.decodeIfPresent(UInt64.self, forKey: .samples) ?? 0
        bytes = try c.decodeIfPresent(UInt64.self, forKey: .bytes) ?? 0
        peakDBFS = try c.decodeIfPresent(Double.self, forKey: .peakDBFS)
        meanDBFS = try c.decodeIfPresent(Double.self, forKey: .meanDBFS)
        squelchOpens = try c.decodeIfPresent(Int.self, forKey: .squelchOpens) ?? 0
        clippedMs = try c.decodeIfPresent(Int64.self, forKey: .clippedMs)
        captureID = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(part, forKey: .part)
        try c.encode(file, forKey: .file)
        try c.encode(startSample, forKey: .startSample)
        try c.encode(endSample, forKey: .endSample)
        try c.encode(samples, forKey: .samples)
        try c.encode(bytes, forKey: .bytes)
        try c.encodeIfPresent(peakDBFS, forKey: .peakDBFS)
        try c.encodeIfPresent(meanDBFS, forKey: .meanDBFS)
        try c.encode(squelchOpens, forKey: .squelchOpens)
        try c.encodeIfPresent(clippedMs, forKey: .clippedMs)
    }
}

public enum RecordingParts {
    /// The part a transmission lies inside, or nil: the same capture, the part's start at or
    /// before the transmission's start, and the transmission's end at or before the part's end.
    /// A part whose capture is unknown matches nothing. A transmission with a part is a kept row
    /// of the log, one without is a heard row (docs/design/app-design-handoff-m3.md, "The rule").
    /// `parts` are one recording's, in order.
    ///
    /// A piece a recording's switch cut (`TransmissionLog.mark`) is timed by the newest
    /// telemetry when the job's event arrives, which is not the sample the recording's gate
    /// opened at: over a carrier, the e2e run saw the cut 20 ms before the first part began. So
    /// a piece that began at a recording-on cut may start before the recording's first part, as
    /// long as that part begins inside it, and one that ended at a recording-off cut may end
    /// after the recording's last part, as long as that part ends inside it. Any other part is
    /// held to the rule above.
    public static func match(transmission t: Transmission, in parts: [RecordingPart])
        -> RecordingPart?
    {
        let first = parts.indices.first
        let last = parts.indices.last
        return parts.indices.first { i in
            let p = parts[i]
            guard let capture = p.captureID, !capture.isEmpty else { return false }
            guard capture == t.start.captureID, capture == t.end.captureID else { return false }
            let from = t.start.sampleIndex
            let to = t.end.sampleIndex
            let startsInside =
                p.startSample <= from
                || (t.startMarker == .recordingOn && i == first && p.startSample <= to)
            let endsInside =
                to <= p.endSample
                || (t.endMarker == .recordingOff && i == last && from <= p.endSample)
            return startsInside && endsInside
        }.map { parts[$0] }
    }

    /// The URI of the part that holds `t` in any of `manifests`, searched in order (newest
    /// first, as `Recordings.recordingIDs` lists them), or nil for a heard row. A log row is
    /// matched against every recording of its channel, not only the newest: switching the
    /// switch off and on starts a new recording whose manifest is empty at first, and until
    /// 2026-09-25 that one replaced the old and the rows the old one kept lost their ▶
    /// (plans/app.md, APP-5, "Fixed 2026-09-25 (second run)").
    public static func keptPartURI(of t: Transmission, in manifests: [RecordingManifest])
        -> String?
    {
        for m in manifests {
            if let p = match(transmission: t, in: m.parts) { return m.uri(of: p) }
        }
        return nil
    }
}

/// A recording as `Resources.ListResources(RECORDING)` lists it, read from the resource's frozen
/// metadata keys (`proto/leyline/v1/jobs.proto`, `Resource.metadata`). The sidebar's Recordings
/// source groups these into channels (`Recordings.channels`) and its store footer sums their
/// sizes (docs/design/app-design-handoff-m3.md, "In every screen" and 8c).
public struct RecordingSummary: Sendable, Equatable, Identifiable {
    public var uri: String
    public var jobID: String
    public var frequencyHz: UInt64
    public var mode: Leyline_V1_DemodMode
    /// The channel width recorded, from `bandwidth_hz`; 0 for an IQ recording and for a listing
    /// from a daemon older than the key (2026-09-24).
    public var bandwidthHz: UInt32
    public var startedAt: Date?
    /// When the job ended, from `ended_at_ns`; nil while it runs.
    public var endedAt: Date?
    /// The parts' durations summed: what the recording holds, not the wall clock it ran.
    public var durationMs: Int64
    public var parts: Int
    /// Empty while the job runs.
    public var endedBy: String
    public var sizeBytes: UInt64

    public var id: String { uri }

    public init(_ r: Leyline_V1_Resource) {
        uri = r.uri
        let m = r.metadata
        jobID =
            r.originatingJobID.isEmpty
            ? String(r.uri.split(separator: "/").last ?? "") : r.originatingJobID
        frequencyHz = m["frequency_hz"].flatMap { UInt64($0) } ?? 0
        mode = m["mode"].flatMap { Leyline_V1_DemodMode.named($0) } ?? .unspecified
        bandwidthHz = m["bandwidth_hz"].flatMap { UInt32($0) } ?? 0
        startedAt = m["started_at_ns"].flatMap { Int64($0) }.flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1e9) : nil
        }
        endedAt = m["ended_at_ns"].flatMap { Int64($0) }.flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1e9) : nil
        }
        durationMs = m["duration_ms"].flatMap { Int64($0) } ?? 0
        parts = m["parts"].flatMap { Int($0) } ?? 0
        endedBy = m["ended_by"] ?? ""
        sizeBytes = r.sizeBytes
    }

    /// `42 s`, `12 min`, `1 h 04 min`: whole seconds under a minute, whole minutes under an hour.
    public static func durationWords(ms: Int64) -> String {
        let s = max(0, ms) / 1000
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h " + String(format: "%02d min", minutes % 60)
    }

    /// `1 part`, `4 parts`.
    public static func partsWords(_ n: Int) -> String { n == 1 ? "1 part" : "\(n) parts" }

    /// The last time the recording changed: when it ended, else when it started. A running one's
    /// activity is now, which `RecordingChannel` decides from the job, not from here.
    public var lastActivity: Date? { endedAt ?? startedAt }
}

/// One row of the Library's sidebar: every recording on one frequency, never one row per
/// recording (docs/design/app-design-handoff-m3.md, 8c), and since 10a never one row per mode, so
/// a width or mode change does not split a channel. Titled by the bookmark on that frequency and
/// the channel's mode when there is one, else by the frequency.
public struct RecordingChannel: Sendable, Equatable, Identifiable {
    public var frequencyHz: UInt64
    /// The newest recording's mode: what Tune and the page's switch use.
    public var mode: Leyline_V1_DemodMode
    /// The name of the bookmark whose frequency and mode are the channel's, or nil.
    public var bookmarkName: String?
    /// Newest first.
    public var recordings: [RecordingSummary]
    /// A record job of one of `recordings` is running or degraded.
    public var running: Bool
    /// The newest recording's end or start; nil when none is dated.
    public var latest: Date?

    public var id: String { "\(frequencyHz)" }

    /// `462.5625`: the frequency as the bookmark rows print it, which the title falls back to.
    public var frequencyText: String { FrequencyEntry.fieldParts(frequencyHz).major }

    public var title: String { bookmarkName ?? frequencyText }

    /// `19 recordings · today`, `· now` while one runs, else the newest one's day
    /// (`Recordings.shortDayWords`), as 10a draws it; 8c's `latest` is gone.
    public func subtitle(now: Date, calendar: Calendar = .current) -> String {
        let count = recordings.count == 1 ? "1 recording" : "\(recordings.count) recordings"
        guard let when = latestWords(now: now, calendar: calendar) else { return count }
        return "\(count) · \(when)"
    }

    private func latestWords(now: Date, calendar: Calendar) -> String? {
        if running { return "now" }
        return latest.map { Recordings.shortDayWords($0, now: now, calendar: calendar) }
    }

    /// Whether the search field's `query` finds this row: a case-blind substring of the title,
    /// the frequency as the title prints it (`462.56` finds `462.5625`), the weekday any of its recordings started on
    /// (`wed`, `Wednesday`) or the subtitle's day word (`today`, `now`). An empty query finds
    /// every row.
    public func matches(_ query: String, now: Date, calendar: Calendar = .current) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        var words = [title, frequencyText]
        if let w = latestWords(now: now, calendar: calendar) { words.append(w) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE"
        for r in recordings { if let d = r.startedAt { words.append(f.string(from: d)) } }
        return words.contains { $0.lowercased().contains(q) }
    }
}

extension Leyline_V1_Job {
    /// The record job's config, or nil for any other kind of job.
    public var recordConfig: Leyline_V1_RecordConfig? {
        if case .record(let r)? = config { return r }
        return nil
    }

    /// Running or degraded: a job that still writes, or will once its capture is back.
    public var isActive: Bool { state == .running || state == .degraded }
}

/// A Record transmissions switch's click, shown in place of the job until the job's event agrees
/// or `holdSeconds` pass, whichever is first: `StartJob` and `CancelJob` answer before the event
/// arrives, and without the hold the switch would flick back for the round trip. The hold never
/// disables the switch, and after its seconds the switch shows the job whatever the event did;
/// the session's clock clears it then, and `shown` ignores an expired one in case that clock is
/// late (plans/app.md, APP-5, "Fixed 2026-09-25 (third run)"). One click is shown by every switch
/// that names its channel (`Recordings.sameChannel`), because the channel page's switch and the
/// log's are one state in two places when they name the same channel.
public struct RecordSwitchClick: Sendable, Equatable {
    /// The longest a click is shown, the session's `neverSeenDropSeconds`: the gap between an
    /// RPC's response and its event closes in milliseconds.
    public static let holdSeconds: TimeInterval = 3

    public let frequencyHz: UInt64
    public let mode: Leyline_V1_DemodMode
    public let on: Bool
    public let at: Date

    public init(frequencyHz: UInt64, mode: Leyline_V1_DemodMode, on: Bool, at: Date = Date()) {
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.on = on
        self.at = at
    }

    /// The click was on the channel `frequencyHz` and `mode` name.
    public func names(frequencyHz: UInt64, mode: Leyline_V1_DemodMode) -> Bool {
        Recordings.sameChannel(self.frequencyHz, self.mode, frequencyHz, mode)
    }

    /// Fewer than `holdSeconds` have passed since the click. A clock set back before the click
    /// counts as expired, so a click is never held for longer than it was meant to be.
    public func isHeld(now: Date) -> Bool {
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < Self.holdSeconds
    }

    /// What a switch on `frequencyHz` and `mode` shows: a held click on its channel, else whether
    /// a record job runs there (`running`). No frequency (nothing tuned) shows the job alone.
    public static func shown(
        pending: RecordSwitchClick?, frequencyHz: UInt64?, mode: Leyline_V1_DemodMode,
        running: Bool, now: Date = Date()
    ) -> Bool {
        if let p = pending, let hz = frequencyHz, p.isHeld(now: now),
            p.names(frequencyHz: hz, mode: mode)
        {
            return p.on
        }
        return running
    }
}

public enum Recordings {
    /// The newest active record job on `frequencyHz` and `mode`, in the frequency form, whoever
    /// started it: the Record transmissions switch's state, and a bookmark's dot. A job that
    /// borrows a channel records whatever that channel is tuned to, so its `frequency_hz` says
    /// nothing. A job whose config names no mode (`ley record` leaves it to the daemon) matches
    /// any mode on its frequency, and so does `mode` unspecified (a bookmark saved without one).
    /// The frequency matches within `matchToleranceHz` (`sameChannel`).
    public static func activeJob(
        in jobs: [Leyline_V1_Job], frequencyHz: UInt64, mode: Leyline_V1_DemodMode
    ) -> Leyline_V1_Job? {
        jobs.last { j in
            guard j.isActive, let r = j.recordConfig else { return false }
            return r.channelID.isEmpty
                && sameChannel(r.frequencyHz, r.mode, frequencyHz, mode)
        }
    }

    /// How far apart two frequencies may be and still name one channel: 1 Hz. The window's
    /// frequency is the capture's centre plus the channel's offset, both whole hertz, and a job
    /// copies it at the start; the tolerance keeps a rounding of either side from turning the
    /// Record transmissions switch off under a running job (plans/app.md, APP-5, "Fixed
    /// 2026-09-25 (third run)"). No channel plan puts two channels 1 Hz apart.
    public static let matchToleranceHz: UInt64 = 1

    /// Whether a frequency and mode name the same channel as another: the frequencies within
    /// `matchToleranceHz`, and the modes equal unless either side names none.
    public static func sameChannel(
        _ aHz: UInt64, _ aMode: Leyline_V1_DemodMode, _ bHz: UInt64, _ bMode: Leyline_V1_DemodMode
    ) -> Bool {
        let apart = aHz > bHz ? aHz - bHz : bHz - aHz
        return apart <= matchToleranceHz
            && (aMode == bMode || aMode == .unspecified || bMode == .unspecified)
    }

    /// The window's hang: how long a part stays open after the squelch closes. The daemon's
    /// default of 5 s (`RecordConfig.hang_ms`) keeps an exchange of several overs in one part,
    /// and on the owner's second run (2026-09-25) one 25 s part held four 4 s log rows, so one ▶
    /// lit three rows and the Library showed one part where the log showed four. The switch's
    /// line promises `Each transmission becomes a part, cut at dead air.`, so the window asks for
    /// the pre-roll's length: a gap shorter than half a second stays one part, as the log's
    /// quarter-second rule (`TransmissionLog.shortestSeconds`) keeps a kerchunk out of the log.
    /// `ley record` keeps the daemon's default.
    public static let windowHangMs: UInt32 = 500
    /// The window's pre-roll, the daemon's default (`RecordConfig.pre_roll_ms`) sent explicitly,
    /// so the gate the window asks for is stated in one place.
    public static let windowPreRollMs: UInt32 = 500

    /// The window's recording: the frequency form of `RecordConfig` with the channel's settings
    /// copied at the start, so the job owns its channel and outlives the window, a retune and a
    /// quit (docs/plans/app.md, APP-5). Gated by squelch, because the daemon's gate cuts a part
    /// at dead air and a channel that never goes quiet is one long part; an ungated recording is
    /// `ley record` without `--gate` (docs/design/app-design-handoff-m3.md, 8a). Pre-roll and hang
    /// are the window's (`windowPreRollMs`, `windowHangMs`), so each transmission is its own
    /// part; part length is the daemon's default, with no duration and no stop after quiet. A
    /// squelch that is off (NaN) is sent as NaN, which the daemon reads as the channel default.
    public static func config(
        frequencyHz: UInt64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32, squelchDBFS: Double
    ) -> Leyline_V1_RecordConfig {
        .with {
            $0.frequencyHz = frequencyHz
            $0.mode = mode
            $0.bandwidthHz = bandwidthHz
            $0.squelchDbfs = squelchDBFS
            $0.gate = .squelch
            $0.preRollMs = windowPreRollMs
            $0.hangMs = windowHangMs
        }
    }

    /// The job ids of every recording on `frequencyHz` and `mode`, newest first: the running
    /// job's (`running`, which may not be listed yet), then the listing's by start. A recording
    /// or `mode` without a mode matches any, as `activeJob` does. The log's kept rows and the
    /// time gutter's bars come from these recordings' manifests together.
    public static func recordingIDs(
        onFrequencyHz frequencyHz: UInt64, mode: Leyline_V1_DemodMode,
        in recordings: [RecordingSummary], running: String? = nil
    ) -> [String] {
        let listed = recordings.filter { r in
            r.frequencyHz == frequencyHz
                && (r.mode == mode || r.mode == .unspecified || mode == .unspecified)
        }
        .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        .map(\.jobID)
        guard let running else { return listed }
        return [running] + listed.filter { $0 != running }
    }

    /// The channel page's switch: the frequency form on the page's channel, from the store's
    /// listing alone, since the page may have read no manifest yet. The width is the newest
    /// recording's (`channelWidth`), 0 for the mode's default when none states one, and the
    /// squelch is NaN, which asks a gated recording for the daemon's auto squelch: the page has
    /// no channel of its own to copy one from. The gate's pre-roll and hang are `config`'s, so a
    /// recording started from either switch is cut the same way.
    public static func pageConfig(_ c: RecordingChannel, groups: [RecordingGroup])
        -> Leyline_V1_RecordConfig
    {
        config(
            frequencyHz: c.frequencyHz, mode: c.mode,
            bandwidthHz: channelWidth(groups, channel: c) ?? 0, squelchDBFS: .nan)
    }

    /// The notice for a record job a switch started that the daemon then ended FAILED, or nil
    /// while it runs or once it ended any other way. `StartJob` answers before the radio is
    /// allocated, so a job the allocator declines fails after the call returned, and its reason
    /// reaches the window only on its event; until 2026-09-25 the window dropped it, and the
    /// channel page's switch went back off with nothing said (plans/app.md, APP-5). A busy radio
    /// is the page's usual case, a channel outside the band the window is listening to, and the
    /// notice says what to do about it.
    public static func failureNotice(_ job: Leyline_V1_Job) -> String? {
        guard job.state == .failed else { return nil }
        let why = job.error.message.isEmpty ? job.statusDetail : job.error.message
        var words = "Could not record: \(why.isEmpty ? job.error.code : why)"
        if job.error.code == "DEVICE_BUSY", let r = job.recordConfig, r.frequencyHz > 0 {
            let mhz = FrequencyEntry.fieldParts(r.frequencyHz).major
            words += ". Tune to \(mhz) MHz first, and the recording shares the radio."
        }
        return words
    }

    /// The line under the switch while it is on: `Since 09:12 · 3 parts · 1.1 MB. Keeps going
    /// if you tune away.` The time is the job's `created_at_ns` as wall clock in `timeZone`; the
    /// parts and bytes are the manifest's (closed parts only, since a part joins the manifest
    /// when it closes), and without a manifest yet the line is the time alone. While the job is
    /// degraded the line is the daemon's `status_detail` instead (`out of capture since …`),
    /// which the window prints in `caution`.
    public static func statusLine(
        job: Leyline_V1_Job, manifest: RecordingManifest?, timeZone: TimeZone = .current
    ) -> String {
        if job.state == .degraded, !job.statusDetail.isEmpty { return job.statusDetail }
        var words = [sinceWords(createdAtNs: job.createdAtNs, timeZone: timeZone)]
        if let m = manifest, m.jobID == job.jobID {
            words.append(RecordingSummary.partsWords(m.parts.count))
            words.append(sizeWords(m.bytes))
        }
        return words.joined(separator: " · ") + ". Keeps going if you tune away."
    }

    /// `Since 09:12`, the job's start as wall clock; `Since now` before the daemon has dated it.
    public static func sinceWords(createdAtNs: Int64, timeZone: TimeZone = .current) -> String {
        guard createdAtNs > 0 else { return "Since now" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return "Since " + f.string(from: Date(timeIntervalSince1970: Double(createdAtNs) / 1e9))
    }

    /// `1.1 MB`: the daemon's own rule for a recording's size in `status_detail`
    /// (`RecordRunner.bytesText` in the engine), binary units, so the two never disagree.
    public static func sizeWords(_ bytes: UInt64) -> String {
        if bytes >= 1 << 30 { return String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) }
        if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    /// `944 MB`, `20 GB`, `1.1 MB`: a store amount in binary units, whole from ten up and one
    /// decimal below, the store footer's rule and `ley state`'s (`storeSize` in
    /// `go/internal/cli/state.go`). `sizeWords` stays the daemon's own rule for one recording.
    public static func storeSizeWords(_ bytes: UInt64) -> String {
        func words(_ v: Double, _ unit: String) -> String {
            String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, unit)
        }
        if bytes >= 1 << 30 { return words(Double(bytes) / Double(1 << 30), "GB") }
        if bytes >= 1 << 20 { return words(Double(bytes) / Double(1 << 20), "MB") }
        if bytes >= 1 << 10 { return words(Double(bytes) / Double(1 << 10), "KB") }
        return "\(bytes) B"
    }

    /// What the store holds: the listing's `size_bytes` summed.
    public static func storeUsedBytes(_ recordings: [RecordingSummary]) -> UInt64 {
        recordings.reduce(0) { $0 &+ $1.sizeBytes }
    }

    /// The store footer's line: `944 MB of 20 GB · oldest go first`, the use against the cap
    /// the daemon reports (`DaemonInfo.recordings_cap_bytes`, `leylined --recordings-cap`), whose
    /// retention removes the oldest recordings first. Without a cap (a daemon older than the
    /// field) the `of …` clause is left out.
    public static func storeWords(usedBytes: UInt64, capBytes: UInt64) -> String {
        let used = storeSizeWords(usedBytes)
        let of = capBytes > 0 ? "\(used) of \(storeSizeWords(capBytes))" : used
        return "\(of) · oldest go first"
    }

    /// How much of the bar the use fills, 0 to 1; nil without a cap, when the bar has no fill.
    public static func storeFraction(usedBytes: UInt64, capBytes: UInt64) -> Double? {
        guard capBytes > 0 else { return nil }
        return min(1, Double(usedBytes) / Double(capBytes))
    }

    /// The Library sidebar's rows: `recordings` grouped by frequency (10a: one `GMRS CH3` row
    /// whatever the mode and width), the mode the newest recording's, each titled by the first
    /// bookmark on that frequency whose mode is the channel's (a bookmark or a recording without
    /// a mode matches any), running when one of its recordings' jobs is active in `jobs`, sorted
    /// by most recent activity: running rows first, then the newest end or start, then
    /// frequency.
    public static func channels(
        _ recordings: [RecordingSummary], bookmarks: [Bookmark], jobs: [Leyline_V1_Job]
    ) -> [RecordingChannel] {
        let active = Set(jobs.filter { $0.isActive && $0.recordConfig != nil }.map(\.jobID))
        var order: [UInt64] = []
        var groups: [UInt64: RecordingChannel] = [:]
        for r in recordings {
            let key = r.frequencyHz
            if groups[key] == nil {
                order.append(key)
                groups[key] = RecordingChannel(
                    frequencyHz: r.frequencyHz, mode: r.mode, bookmarkName: nil, recordings: [],
                    running: false, latest: nil)
            }
            groups[key]?.recordings.append(r)
            if active.contains(r.jobID) { groups[key]?.running = true }
            if let a = r.lastActivity, a > (groups[key]?.latest ?? .distantPast) {
                groups[key]?.latest = a
            }
        }
        return order.compactMap { key -> RecordingChannel? in
            guard var c = groups[key] else { return nil }
            c.recordings.sort {
                ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
            c.mode = c.recordings.first?.mode ?? .unspecified
            let mode = c.mode
            c.bookmarkName =
                bookmarks.first {
                    $0.hz == c.frequencyHz
                        && ($0.mode == mode || $0.mode == .unspecified || mode == .unspecified)
                }?.name
            return c
        }
        .sorted { a, b in
            if a.running != b.running { return a.running }
            let la = a.latest ?? .distantPast
            let lb = b.latest ?? .distantPast
            if la != lb { return la > lb }
            return a.frequencyHz < b.frequencyHz
        }
    }

    /// `today`, `yesterday`, `Wednesday` for the six days before, `12 Sep` before that: the day
    /// of `date` in `calendar`'s zone, for the Transmissions header (M3 handoff, "In every
    /// screen").
    public static func dayWords(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = daysBefore(date, now: now, calendar: calendar)
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        return format(date, days < 7 ? "EEEE" : "d MMM", calendar)
    }

    /// `today`, `Wed` for the six days before, `12 Sep` before that: the sidebar's day word
    /// (`19 recordings · today`), short because it shares a row with a count.
    public static func shortDayWords(_ date: Date, now: Date, calendar: Calendar = .current)
        -> String
    {
        let days = daysBefore(date, now: now, calendar: calendar)
        if days == 0 { return "today" }
        return format(date, days < 7 ? "EEE" : "d MMM", calendar)
    }

    /// Whole calendar days from `date` to `now`; a date after now (a clock step) is today.
    static func daysBefore(_ date: Date, now: Date, calendar: Calendar) -> Int {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
            ).day ?? 0
        return max(0, days)
    }

    static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// The running or degraded record jobs whose channel rides `captureID`: the channel form's
    /// channel on it, or the frequency form's own channel (owned by a job, `required_hz` the
    /// job's frequency) on it. The same rule as `ley`'s `recordingsOn`
    /// (`go/internal/cli/session.go`), so the window and the terminal ask about the same jobs.
    public static func jobs(riding captureID: String, in state: MirrorState) -> [Leyline_V1_Job] {
        state.jobs.filter { j in
            guard j.isActive, let r = j.recordConfig else { return false }
            if !r.channelID.isEmpty { return state.channel(r.channelID)?.captureID == captureID }
            return state.channels.contains {
                $0.captureID == captureID && $0.owner.kind == "job"
                    && $0.requiredHz == r.frequencyHz
            }
        }
    }

    /// The record jobs on `captureID` that moving the capture to `span` would leave outside it:
    /// each job's frequency with half its width either side is inside the capture's span now and
    /// is not inside `span`. Moving inside the span, or a job already outside, never asks.
    public static func leftOut(
        capture captureID: String, movingTo span: ClosedRange<UInt64>, in state: MirrorState
    ) -> [Leyline_V1_Job] {
        guard let cap = state.capture(captureID), cap.sampleRate > 0 else { return [] }
        let half = cap.sampleRate / 2
        let now = (cap.centerHz > half ? cap.centerHz - half : 0)...(cap.centerHz + half)
        return jobs(riding: captureID, in: state).filter { j in
            guard let r = j.recordConfig, let hz = frequency(of: r, in: state) else { return false }
            let bw = UInt64(r.bandwidthHz / 2)
            let lo = hz > bw ? hz - bw : 0
            let covered = { (s: ClosedRange<UInt64>) in s.contains(lo) && s.contains(hz + bw) }
            return covered(now) && !covered(span)
        }
    }

    /// Where a record job listens: its frequency, or the borrowed channel's.
    private static func frequency(of r: Leyline_V1_RecordConfig, in state: MirrorState)
        -> UInt64?
    {
        if r.channelID.isEmpty { return r.frequencyHz }
        return state.channel(r.channelID).flatMap { state.frequencyHz(of: $0) }
    }

    /// The question before a move that `leftOut` found jobs for, with `ley tune`'s content
    /// (`refuseRetuneOverRecording`): the jobs named and the gap the move would leave. nil when
    /// the list is empty, so nothing asks.
    public static func retuneWords(jobs: [Leyline_V1_Job]) -> String? {
        guard !jobs.isEmpty else { return nil }
        let ids = jobs.map(\.jobID)
        let names =
            ids.count == 1
            ? ids[0] : ids.dropLast().joined(separator: ", ") + " and " + ids[ids.count - 1]
        return ids.count == 1
            ? "\(names) is recording on this radio; moving the radio would leave a gap in it."
            : "\(names) are recording on this radio; moving the radio would leave a gap in them."
    }
}
