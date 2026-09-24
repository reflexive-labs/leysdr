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
    }

    public init(
        part: Int, file: String, startSample: UInt64, endSample: UInt64, samples: UInt64,
        bytes: UInt64, peakDBFS: Double? = nil, meanDBFS: Double? = nil, squelchOpens: Int = 0,
        captureID: String? = nil
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
    }
}

public enum RecordingParts {
    /// The part a transmission lies inside, or nil: the same capture, the part's start at or
    /// before the transmission's start, and the transmission's end at or before the part's end.
    /// A part whose capture is unknown matches nothing. A transmission with a part is a kept row
    /// of the log, one without is a heard row (docs/design/app-design-handoff-m3.md, "The rule").
    public static func match(transmission t: Transmission, in parts: [RecordingPart])
        -> RecordingPart?
    {
        parts.first { p in
            guard let capture = p.captureID, !capture.isEmpty else { return false }
            return capture == t.start.captureID && capture == t.end.captureID
                && p.startSample <= t.start.sampleIndex && t.end.sampleIndex <= p.endSample
        }
    }
}

/// A recording as `Resources.ListResources(RECORDING)` lists it, read from the resource's frozen
/// metadata keys (`proto/leyline/v1/jobs.proto`, `Resource.metadata`). The window lists no
/// recordings until M3's Recordings source (docs/design/app-design-handoff-m3.md, 8c), whose rows
/// these are; File ▸ Show Recordings in Finder reads the list for a recording's path.
public struct RecordingSummary: Sendable, Equatable, Identifiable {
    public var uri: String
    public var jobID: String
    public var frequencyHz: UInt64
    public var mode: Leyline_V1_DemodMode
    /// The channel width recorded, from `bandwidth_hz`; 0 for an IQ recording and for a listing
    /// from a daemon older than the key (2026-09-24).
    public var bandwidthHz: UInt32
    public var startedAt: Date?
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

public enum Recordings {
    /// The newest active record job on `frequencyHz` and `mode`, in the frequency form, whoever
    /// started it: the Record transmissions switch's state, and a bookmark's dot. A job that
    /// borrows a channel records whatever that channel is tuned to, so its `frequency_hz` says
    /// nothing. A job whose config names no mode (`ley record` leaves it to the daemon) matches
    /// any mode on its frequency, and so does `mode` unspecified (a bookmark saved without one).
    public static func activeJob(
        in jobs: [Leyline_V1_Job], frequencyHz: UInt64, mode: Leyline_V1_DemodMode
    ) -> Leyline_V1_Job? {
        jobs.last { j in
            guard j.isActive, let r = j.recordConfig else { return false }
            return r.channelID.isEmpty && r.frequencyHz == frequencyHz
                && (r.mode == mode || r.mode == .unspecified || mode == .unspecified)
        }
    }

    /// The window's recording: the frequency form of `RecordConfig` with the channel's settings
    /// copied at the start, so the job owns its channel and outlives the window, a retune and a
    /// quit (docs/plans/app.md, APP-5). Gated by squelch, because the daemon's gate cuts a part
    /// at dead air and a channel that never goes quiet is one long part; an ungated recording is
    /// `ley record` without `--gate` (docs/design/app-design-handoff-m3.md, 8a). Pre-roll, hang
    /// and part length are left at the daemon's defaults, with no duration and no stop after
    /// quiet. A squelch that is off (NaN) is sent as NaN, which the daemon reads as the channel
    /// default.
    public static func config(
        frequencyHz: UInt64, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32, squelchDBFS: Double
    ) -> Leyline_V1_RecordConfig {
        .with {
            $0.frequencyHz = frequencyHz
            $0.mode = mode
            $0.bandwidthHz = bandwidthHz
            $0.squelchDbfs = squelchDBFS
            $0.gate = .squelch
        }
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
