// SPDX-License-Identifier: GPL-3.0-or-later

// The kept-records store: files, not a database (docs/design/decoders.md, "Decisions": "The store
// is files"). A kept job's records go to `<store>/records/<job_id>.records` as varint-delimited
// DecodeRecords, beside `<job_id>.json` holding the job's config, the decoder's name and version,
// and every CaptureAnchor that was in force while it ran. A query scans the sidecars, skips the
// files that cannot match, and filters the rest in memory. There is no index; a SQLite one is
// worth adding only once a query is measured to be slow.

import EngineCore
import Foundation
import LeylineProto
import Logging
import SwiftProtobuf

/// One anchor as the sidecar holds it: the anchor itself and the sample it starts applying at.
struct StoredAnchor: Codable, Sendable {
    var hostTimeNs: Int64
    var sampleRate: UInt64
    var driftPpm: Double
    var fromSample: UInt64
    /// The capture this anchor dates, once a job has outlived one: a kept job resumed after a
    /// daemon restart writes into the same file from a new capture whose sample index starts over,
    /// and an anchor that did not say which capture it belonged to would date the old records by
    /// the new clock. Absent in a sidecar whose job never outlived a capture.
    var captureID: String?

    enum CodingKeys: String, CodingKey {
        case hostTimeNs = "host_time_ns"
        case sampleRate = "sample_rate"
        case driftPpm = "drift_ppm"
        case fromSample = "from_sample"
        case captureID = "capture_id"
    }

    /// Wall clock for a sample index on the capture this anchor belongs to.
    func hostTime(at sampleIndex: UInt64) -> Int64 {
        guard sampleRate > 0 else { return hostTimeNs }
        let ns = (Double(sampleIndex) / Double(sampleRate)) * 1e9 * (1 + driftPpm * 1e-6)
        return hostTimeNs + Int64(ns)
    }
}

/// `<job_id>.json`: everything a query needs before it opens the records file.
struct RecordSidecar: Codable, Sendable {
    var jobID: String
    var decoder: String
    var version: String
    /// The DecodeConfig in proto3 JSON, so the sidecar carries no shape of our own.
    var config: String
    var createdAtNs: Int64
    var captureID: String
    var anchors: [StoredAnchor]
    var count: UInt64

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case decoder
        case version
        case config
        case createdAtNs = "created_at_ns"
        case captureID = "capture_id"
        case anchors
        case count
    }
}

actor RecordStore {
    struct Stats: Sendable {
        var path: String
        var capBytes: UInt64
        var ageDays: UInt32
    }

    static let defaultLimit = 1000

    let directory: String
    let capBytes: UInt64
    let ageDays: UInt32
    private let log = Logger(label: "leyline.decoders.store")

    init(directory: String, capBytes: UInt64, ageDays: UInt32) {
        self.directory = directory
        self.capBytes = capBytes
        self.ageDays = ageDays
    }

    var stats: Stats { Stats(path: directory, capBytes: capBytes, ageDays: ageDays) }

    var recordsDir: String { directory + "/records" }

    /// Opens a writer for a kept job. Throws if the store directory cannot be made: a `keep` job
    /// that silently kept nothing would be worse than one that refused to start.
    ///
    /// A job the store already has files for -- a kept job resumed after a daemon restart --
    /// appends to them: the records and the count carry on, the old anchors stay (each naming the
    /// capture it dated), and the new capture's anchor joins them.
    func open(job: JobID, config: Leyline_V1_DecodeConfig, manifest: Leyline_V1_DecoderManifest,
              capture: CaptureID, anchor: CaptureAnchor?) throws -> RecordWriter
    {
        try FileManager.default.createDirectory(atPath: recordsDir, withIntermediateDirectories: true)
        let base = recordsDir + "/" + job.string
        let fresh = anchor.map { [StoredAnchor(hostTimeNs: $0.hostTimeNsAtSampleZero, sampleRate: $0.sampleRate,
                                               driftPpm: $0.driftPPM, fromSample: 0, captureID: capture.string)] } ?? []
        if let data = FileManager.default.contents(atPath: base + ".json"),
           var existing = try? JSONDecoder().decode(RecordSidecar.self, from: data)
        {
            // Anchors written before captures were named belong to the capture the sidecar named.
            for i in existing.anchors.indices where existing.anchors[i].captureID == nil {
                existing.anchors[i].captureID = existing.captureID
            }
            existing.captureID = capture.string
            existing.anchors.append(contentsOf: fresh)
            return try RecordWriter(base: base, sidecar: existing)
        }
        let sidecar = RecordSidecar(
            jobID: job.string, decoder: manifest.name, version: manifest.version,
            config: (try? config.jsonString()) ?? "{}", createdAtNs: WallClock.nowNs(),
            captureID: capture.string, anchors: fresh, count: 0)
        return try RecordWriter(base: base, sidecar: sidecar)
    }
}

extension RecordStore {
    /// Reads the store. Newest first, cut at `limit`, with the anchors the answer needs so a client
    /// derives wall time from sample time exactly as it does for a live capture.
    func query(_ q: Leyline_V1_RecordQuery) -> Leyline_V1_RecordPage {
        var page = Leyline_V1_RecordPage()
        let limit = q.limit == 0 ? Self.defaultLimit : Int(q.limit)
        var hits: [(record: Leyline_V1_DecodeRecord, wallNs: Int64, job: String)] = []
        var anchors: [String: (captureID: String, list: [StoredAnchor])] = [:]
        for sidecar in sidecars() {
            if !q.protocol.isEmpty, sidecar.decoder != q.protocol { continue }
            if !q.jobID.isEmpty, sidecar.jobID != q.jobID { continue }
            guard spanCanMatch(sidecar, q) else { continue }
            for rec in records(jobID: sidecar.jobID) {
                let wall = wallTime(rec, sidecar)
                if q.sinceNs != 0, wall < q.sinceNs { continue }
                if q.untilNs != 0, wall > q.untilNs { continue }
                guard matches(rec, q) else { continue }
                hits.append((rec, wall, sidecar.jobID))
                anchors[sidecar.jobID] = (sidecar.captureID, sidecar.anchors)
            }
        }
        hits.sort { $0.wallNs > $1.wallNs }
        if hits.count > limit {
            hits = Array(hits.prefix(limit))
            page.truncated = true
        }
        page.records = hits.map(\.record)
        // Only the jobs still on the page: a cut answer carries the anchors its records need and
        // no others.
        let wanted = Set(hits.map(\.job))
        for (job, entry) in anchors.sorted(by: { $0.key < $1.key }) where wanted.contains(job) {
            for a in entry.list {
                var ra = Leyline_V1_RecordAnchor()
                ra.anchor.captureID = a.captureID ?? entry.captureID
                ra.anchor.hostTimeNs = a.hostTimeNs
                ra.anchor.sampleRate = a.sampleRate
                ra.anchor.driftPpm = a.driftPpm
                ra.fromSample = a.fromSample
                page.anchors.append(ra)
            }
        }
        return page
    }

    /// Age first, then size: a store over its cap loses its oldest jobs, and a job past the age
    /// goes whether the store is full or not.
    func retain() {
        let fm = FileManager.default
        var files = sidecarPaths().compactMap { path -> (base: String, modified: Date, bytes: UInt64)? in
            let base = String(path.dropLast(".json".count))
            let attrs = try? fm.attributesOfItem(atPath: base + ".records")
            let modified = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let bytes = UInt64((attrs?[.size] as? NSNumber)?.uint64Value ?? 0)
            return (base, modified, bytes)
        }
        if ageDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(ageDays) * 86400)
            for f in files where f.modified < cutoff {
                remove(base: f.base)
            }
            files.removeAll { $0.modified < cutoff }
        }
        files.sort { $0.modified < $1.modified }
        var total = files.reduce(UInt64(0)) { $0 + $1.bytes }
        var index = 0
        while total > capBytes, index < files.count {
            remove(base: files[index].base)
            total -= min(total, files[index].bytes)
            index += 1
        }
    }

    private func remove(base: String) {
        try? FileManager.default.removeItem(atPath: base + ".records")
        try? FileManager.default.removeItem(atPath: base + ".json")
    }

    private func sidecarPaths() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: recordsDir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().map { recordsDir + "/" + $0 }
    }

    func sidecars() -> [RecordSidecar] {
        sidecarPaths().compactMap { path in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            do {
                return try JSONDecoder().decode(RecordSidecar.self, from: data)
            } catch {
                log.warning("\(path): sidecar does not parse (\(error)); skipping")
                return nil
            }
        }
    }

    /// The file's wall-clock span against the query's bounds. The lower bound is when the job
    /// started; the upper is when its records file was last written.
    private func spanCanMatch(_ s: RecordSidecar, _ q: Leyline_V1_RecordQuery) -> Bool {
        // The bounds are wide: this only decides which files to open, and the exact
        // test is per record. The lower bound is the earliest clock the job knew -- which is an
        // anchor's, not the job's creation time, because a fixture's timeline can be anywhere.
        if q.untilNs != 0 {
            let earliest = ([s.createdAtNs] + s.anchors.map { $0.hostTime(at: $0.fromSample) }).min() ?? s.createdAtNs
            if q.untilNs < earliest { return false }
        }
        if q.sinceNs != 0 {
            let attrs = try? FileManager.default.attributesOfItem(atPath: recordsDir + "/" + s.jobID + ".records")
            let modified = (attrs?[.modificationDate] as? Date) ?? Date()
            let latest = ([Int64(modified.timeIntervalSince1970 * 1e9)] + s.anchors.map { $0.hostTime(at: $0.fromSample) }).max() ?? 0
            if latest < q.sinceNs { return false }
        }
        return true
    }

    private func records(jobID: String) -> [Leyline_V1_DecodeRecord] {
        guard let data = FileManager.default.contents(atPath: recordsDir + "/" + jobID + ".records") else { return [] }
        var out: [Leyline_V1_DecodeRecord] = []
        var i = data.startIndex
        while i < data.endIndex {
            var length: UInt64 = 0
            var shift: UInt64 = 0
            var ok = false
            while i < data.endIndex {
                let b = data[i]
                i = data.index(after: i)
                length |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { ok = true; break }
                shift += 7
                if shift > 63 { break }
            }
            guard ok, length <= UInt64(data.distance(from: i, to: data.endIndex)) else { break }
            let end = data.index(i, offsetBy: Int(length))
            if let rec = try? Leyline_V1_DecodeRecord(serializedBytes: Array(data[i..<end])) { out.append(rec) }
            i = end
        }
        return out
    }

    /// The newest anchor whose `from_sample` is not past the record's, as the contract says.
    private func wallTime(_ rec: Leyline_V1_DecodeRecord, _ s: RecordSidecar) -> Int64 {
        let sample = rec.time.sampleIndex
        // Only the anchors of the capture the record was decoded on: a resumed job's file holds
        // two captures' timelines, and each starts at sample zero.
        let mine = s.anchors.filter { ($0.captureID ?? s.captureID) == rec.time.captureID }
        let candidates = mine.isEmpty ? s.anchors : mine
        var chosen: StoredAnchor?
        for a in candidates where a.fromSample <= sample {
            if chosen == nil || a.fromSample >= chosen!.fromSample { chosen = a }
        }
        guard let anchor = chosen ?? candidates.first else { return s.createdAtNs }
        return anchor.hostTime(at: sample)
    }

    private func matches(_ rec: Leyline_V1_DecodeRecord, _ q: Leyline_V1_RecordQuery) -> Bool {
        if !q.deviceID.isEmpty, rec.deviceID != q.deviceID { return false }
        if !q.kind.isEmpty, rec.kind != q.kind { return false }
        if q.hasNear, q.radiusM > 0 {
            guard rec.hasPosition else { return false }
            if haversineMetres(q.near, rec.position) > q.radiusM { return false }
        }
        if q.inEffect {
            guard rec.hasValidity else { return false }
            let now = WallClock.realNowNs()
            if rec.validity.startNs != 0, now < rec.validity.startNs { return false }
            if rec.validity.endNs != 0, now > rec.validity.endNs { return false }
        }
        for match in q.fields {
            guard let have = rec.fields[match.name], have == match.equals else { return false }
        }
        return true
    }
}

/// Great-circle distance in metres, which is what "within 10 km of here" means on a sphere.
func haversineMetres(_ a: Leyline_V1_Position, _ b: Leyline_V1_Position) -> Double {
    let radius = 6_371_000.0
    let p1 = a.latitude * .pi / 180
    let p2 = b.latitude * .pi / 180
    let dp = (b.latitude - a.latitude) * .pi / 180
    let dl = (b.longitude - a.longitude) * .pi / 180
    let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
    return 2 * radius * atan2(sqrt(h), sqrt(1 - h))
}

// MARK: As resources

// A kept decode job's records are a resource like a recording is (jobs.proto, ResourceKind.RECORDS):
// the same service answers both, from the same shape of on-disk store, so a client that can list
// one can list the other (docs/design/recording.md, "The wire").
extension RecordStore {
    func resources() -> [Leyline_V1_Resource] {
        sidecars().map { resource($0) }
    }

    func resource(jobID: String) -> Leyline_V1_Resource? {
        sidecars().first { $0.jobID == jobID }.map { resource($0) }
    }

    /// The records file itself, for `ResolveLocalPath`. A client on this machine reads the
    /// varint-delimited records rather than paging them over the socket.
    func localPath(jobID: String) -> String? {
        let path = recordsDir + "/" + jobID + ".records"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func resource(_ sidecar: RecordSidecar) -> Leyline_V1_Resource {
        var r = Leyline_V1_Resource()
        r.uri = "ley://records/\(sidecar.jobID)"
        r.kind = .records
        r.createdAtNs = sidecar.createdAtNs
        r.originatingJobID = sidecar.jobID
        let attrs = try? FileManager.default.attributesOfItem(atPath: recordsDir + "/" + sidecar.jobID + ".records")
        r.sizeBytes = ((attrs?[.size] as? NSNumber)?.uint64Value) ?? 0
        r.metadata = [
            "protocol": sidecar.decoder,
            "version": sidecar.version,
            "records": String(sidecar.count),
            "created_at_ns": String(sidecar.createdAtNs),
        ]
        return r
    }
}
