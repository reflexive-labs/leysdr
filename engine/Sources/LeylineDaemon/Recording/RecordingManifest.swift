// SPDX-License-Identifier: GPL-3.0-or-later

// What a recording is on disk (docs/design/recording.md, "Files"): one directory per recording,
// named by the job id, holding `recording.json` and one samples file plus sidecar per part. The
// shapes here are the file format, so their JSON keys are the contract a client reads; nothing
// derives them from a proto.

import EngineCore
import Foundation

/// One part of a recording as `recording.json` lists it. The samples live in `file`, beside the
/// manifest; `start_sample` and `end_sample` are on the capture's timeline at the capture rate, so
/// a client places a part on the same timeline as the telemetry and the decode records.
struct RecordingPart: Codable, Sendable {
    var part: Int
    var file: String
    var startSample: UInt64
    var endSample: UInt64
    /// Frames in the file: audio frames for a WAV part, complex samples for a cf32 one.
    var samples: UInt64
    var bytes: UInt64
    /// Measured from the samples as they passed. Absent on a part whose measurement never finished
    /// (one a daemon restart repaired, for example), because a level invented here would be
    /// indistinguishable from one that was measured.
    var peakDbfs: Double?
    var meanDbfs: Double?
    /// How many times the squelch opened inside this part. A continuous recording has none.
    var squelchOpens: Int

    enum CodingKeys: String, CodingKey {
        case part, file, samples, bytes
        case startSample = "start_sample"
        case endSample = "end_sample"
        case peakDbfs = "peak_dbfs"
        case meanDbfs = "mean_dbfs"
        case squelchOpens = "squelch_opens"
    }
}

/// One open-and-close of the squelch inside a part, on the capture's timeline. The part sidecar
/// lists them so the overs of an exchange are countable; the manifest carries only the count.
struct RecordingSquelchOpen: Codable, Sendable {
    var openSample: UInt64
    var closeSample: UInt64

    enum CodingKeys: String, CodingKey {
        case openSample = "open_sample"
        case closeSample = "close_sample"
    }
}

/// Time the recording did not cover, and why. The gaps between a gated recording's parts and the
/// stretches its capture was tuned away are listed rather than hidden inside one file
/// (invariant 5).
struct RecordingGap: Codable, Sendable {
    var fromSample: UInt64
    var toSample: UInt64
    var reason: String

    enum CodingKeys: String, CodingKey {
        case reason
        case fromSample = "from_sample"
        case toSample = "to_sample"
    }
}

/// The radio the recording was made on, identified the way `ley devices` lists it.
struct RecordingDevice: Codable, Sendable {
    var driver: String
    var model: String
    var serial: String
}

struct RecordingGain: Codable, Sendable {
    var element: String
    var valueDb: Double

    enum CodingKeys: String, CodingKey {
        case element
        case valueDb = "value_db"
    }
}

/// What opened and closed the parts, and with what timings. Absent on a continuous recording.
struct RecordingGateInfo: Codable, Sendable {
    var kind: String
    var preRollMs: UInt32
    var hangMs: UInt32

    enum CodingKeys: String, CodingKey {
        case kind
        case preRollMs = "pre_roll_ms"
        case hangMs = "hang_ms"
    }
}

/// Who asked for the recording.
struct RecordingClient: Codable, Sendable {
    var clientID: String
    var kind: String
    var label: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case kind, label
    }
}

/// `recording.json`: the resource. `GetResource` returns it as `Resource.metadata`, and
/// `ley recordings show` prints it whole.
struct RecordingManifest: Codable, Sendable {
    var jobID: String
    var uri: String
    /// `audio` or `iq`.
    var kind: String
    var frequencyHz: UInt64
    var mode: String
    var bandwidthHz: UInt32
    /// The rate of the part files: the audio rate for a WAV recording, the capture rate for IQ.
    var sampleRate: UInt64
    /// `wav-s16` or `cf32`.
    var format: String
    var device: RecordingDevice?
    var gains: [RecordingGain]
    /// The threshold the gate watched, or NaN when the recording was not gated.
    var squelchDbfs: Double
    var gate: RecordingGateInfo?
    var partMs: Int64
    var startedAtNs: Int64
    var endedAtNs: Int64
    /// One of duration, quiet, cancelled, channel ended, restart, store full, error. Empty while
    /// the job is still running.
    var endedBy: String
    var createdBy: RecordingClient
    /// One per capture the recording spanned, each dating its own capture's samples: a recording
    /// that outlives a detach and reattach spans two timelines, and each starts at sample zero.
    var anchors: [StoredAnchor]
    var parts: [RecordingPart]
    var coverageGaps: [RecordingGap]
    var bytes: UInt64

    enum CodingKeys: String, CodingKey {
        case uri, kind, mode, format, device, gains, gate, parts, bytes
        case jobID = "job_id"
        case frequencyHz = "frequency_hz"
        case bandwidthHz = "bandwidth_hz"
        case sampleRate = "sample_rate"
        case squelchDbfs = "squelch_dbfs"
        case partMs = "part_ms"
        case startedAtNs = "started_at_ns"
        case endedAtNs = "ended_at_ns"
        case endedBy = "ended_by"
        case createdBy = "created_by"
        case anchors
        case coverageGaps = "coverage_gaps"
    }

    /// NaN does not survive a JSON round trip, and a squelch that is off is exactly what NaN means
    /// on the wire (control.proto, `Channel.squelch_db`). Absent in the file is off here too.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(String.self, forKey: .jobID)
        uri = try c.decodeIfPresent(String.self, forKey: .uri) ?? "ley://recordings/\(jobID)"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "audio"
        frequencyHz = try c.decodeIfPresent(UInt64.self, forKey: .frequencyHz) ?? 0
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        bandwidthHz = try c.decodeIfPresent(UInt32.self, forKey: .bandwidthHz) ?? 0
        sampleRate = try c.decodeIfPresent(UInt64.self, forKey: .sampleRate) ?? 0
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        device = try c.decodeIfPresent(RecordingDevice.self, forKey: .device)
        gains = try c.decodeIfPresent([RecordingGain].self, forKey: .gains) ?? []
        squelchDbfs = try c.decodeIfPresent(Double.self, forKey: .squelchDbfs) ?? Double.nan
        gate = try c.decodeIfPresent(RecordingGateInfo.self, forKey: .gate)
        partMs = try c.decodeIfPresent(Int64.self, forKey: .partMs) ?? 0
        startedAtNs = try c.decodeIfPresent(Int64.self, forKey: .startedAtNs) ?? 0
        endedAtNs = try c.decodeIfPresent(Int64.self, forKey: .endedAtNs) ?? 0
        endedBy = try c.decodeIfPresent(String.self, forKey: .endedBy) ?? ""
        createdBy = try c.decodeIfPresent(RecordingClient.self, forKey: .createdBy)
            ?? RecordingClient(clientID: "", kind: "", label: "")
        anchors = try c.decodeIfPresent([StoredAnchor].self, forKey: .anchors) ?? []
        parts = try c.decodeIfPresent([RecordingPart].self, forKey: .parts) ?? []
        coverageGaps = try c.decodeIfPresent([RecordingGap].self, forKey: .coverageGaps) ?? []
        bytes = try c.decodeIfPresent(UInt64.self, forKey: .bytes) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
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
        if squelchDbfs.isFinite { try c.encode(squelchDbfs, forKey: .squelchDbfs) }
        try c.encodeIfPresent(gate, forKey: .gate)
        try c.encode(partMs, forKey: .partMs)
        try c.encode(startedAtNs, forKey: .startedAtNs)
        try c.encode(endedAtNs, forKey: .endedAtNs)
        try c.encode(endedBy, forKey: .endedBy)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encode(anchors, forKey: .anchors)
        try c.encode(parts, forKey: .parts)
        try c.encode(coverageGaps, forKey: .coverageGaps)
        try c.encode(bytes, forKey: .bytes)
    }

    init(jobID: String, kind: String, frequencyHz: UInt64, mode: String, bandwidthHz: UInt32,
         sampleRate: UInt64, format: String, device: RecordingDevice?, gains: [RecordingGain],
         squelchDbfs: Double, gate: RecordingGateInfo?, partMs: Int64, startedAtNs: Int64,
         createdBy: RecordingClient, anchors: [StoredAnchor])
    {
        self.jobID = jobID
        uri = "ley://recordings/\(jobID)"
        self.kind = kind
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.sampleRate = sampleRate
        self.format = format
        self.device = device
        self.gains = gains
        self.squelchDbfs = squelchDbfs
        self.gate = gate
        self.partMs = partMs
        self.startedAtNs = startedAtNs
        endedAtNs = 0
        endedBy = ""
        self.createdBy = createdBy
        self.anchors = anchors
        parts = []
        coverageGaps = []
        bytes = 0
    }

    /// How long the recording holds, in milliseconds of samples actually written. Not wall clock:
    /// a gated recording's gaps are not part of what it holds.
    var durationMs: Int64 {
        guard sampleRate > 0 else { return 0 }
        let samples = parts.reduce(UInt64(0)) { $0 + $1.samples }
        return Int64((Double(samples) / Double(sampleRate)) * 1000)
    }

    /// The frozen metadata keys `ListResources` filters on (docs/design/recording.md, "The wire").
    /// Frozen because `metadata_filter` matches them by exact string.
    var resourceMetadata: [String: String] {
        var out: [String: String] = [
            "kind": kind,
            "frequency_hz": String(frequencyHz),
            "mode": mode,
            "bandwidth_hz": String(bandwidthHz),
            "sample_rate": String(sampleRate),
            "format": format,
            "duration_ms": String(durationMs),
            "parts": String(parts.count),
            "started_at_ns": String(startedAtNs),
            "ended_at_ns": String(endedAtNs),
            "ended_by": endedBy,
        ]
        out["device"] = device.map { $0.model.isEmpty ? $0.driver : $0.model } ?? ""
        return out
    }
}
