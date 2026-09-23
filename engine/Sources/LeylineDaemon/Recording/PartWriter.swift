// SPDX-License-Identifier: GPL-3.0-or-later

// One recording's files: the manifest, and one open part at a time (docs/design/recording.md,
// "The daemon"). Nothing here runs on the DSP thread -- the drain task hands it blocks that the
// sink already copied out of the hot path.
//
// A part is the unit `ley play` understands: samples plus a JSON sidecar giving format, rate,
// centre and the anchor. The manifest is rewritten atomically whenever a part is added or closed,
// so a client reading a running recording sees a manifest that matches the parts on disk.

import EngineCore
import Foundation
import Logging

/// The sidecar written beside each part: the `iqfile` document with one added `recording` block,
/// so `ley play` reads the keys it needs and ignores the rest.
struct PartSidecar: Codable, Sendable {
    struct Anchor: Codable, Sendable {
        var captureID: String
        var hostTimeNs: Int64
        var sampleRate: UInt64
        var driftPpm: Double

        enum CodingKeys: String, CodingKey {
            case captureID = "capture_id"
            case hostTimeNs = "host_time_ns"
            case sampleRate = "sample_rate"
            case driftPpm = "drift_ppm"
        }
    }

    struct Recording: Codable, Sendable {
        var jobID: String
        var part: Int
        var kind: String
        var startSample: UInt64
        var endSample: UInt64
        var bandwidthHz: UInt32
        var squelchDbfs: Double?
        var peakDbfs: Double?
        var meanDbfs: Double?
        var squelchOpens: [RecordingSquelchOpen]

        enum CodingKeys: String, CodingKey {
            case part, kind
            case jobID = "job_id"
            case startSample = "start_sample"
            case endSample = "end_sample"
            case bandwidthHz = "bandwidth_hz"
            case squelchDbfs = "squelch_dbfs"
            case peakDbfs = "peak_dbfs"
            case meanDbfs = "mean_dbfs"
            case squelchOpens = "squelch_opens"
        }
    }

    var format: String
    var sampleRate: UInt64
    var centerHz: UInt64
    var samples: UInt64
    var createdAtNs: Int64
    var anchor: Anchor
    var metadata: [String: String]
    var recording: Recording

    enum CodingKeys: String, CodingKey {
        case format, samples, anchor, metadata, recording
        case sampleRate = "sample_rate"
        case centerHz = "center_hz"
        case createdAtNs = "created_at_ns"
    }
}

/// The 44-byte canonical PCM header a WAV part opens with, and the two lengths that are patched
/// into it on close. A header left with its placeholders -- a daemon that went away mid-part --
/// is repaired from the file's own length at the next boot.
enum WAVHeader {
    static let bytes = 44
    /// What an unfinished part carries where its lengths belong. Zero rather than 0xFFFFFFFF: a
    /// player that ignores the header and reads to EOF gets the same samples either way, and a
    /// player that trusts it plays nothing rather than four gigabytes of noise.
    static let placeholder: UInt32 = 0

    static func header(sampleRate: UInt32, channels: UInt16 = 1, bitsPerSample: UInt16 = 16,
                       dataBytes: UInt32 = placeholder) -> Data
    {
        var d = Data(capacity: bytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let blockAlign = channels * bitsPerSample / 8
        d.append(contentsOf: Array("RIFF".utf8))
        u32(dataBytes == placeholder ? placeholder : dataBytes + 36)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1) // PCM
        u16(channels)
        u32(sampleRate)
        u32(sampleRate * UInt32(blockAlign))
        u16(blockAlign)
        u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return d
    }

    /// Rewrites the two length fields of an existing file from its own size. Used on close, and by
    /// the store's restart repair for a part the last daemon left open.
    static func patchLengths(path: String) throws {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > UInt64(bytes) else { return }
        let dataBytes = UInt32(truncatingIfNeeded: size - UInt64(bytes))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: (dataBytes + 36).littleEndian) { Data($0) })
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: withUnsafeBytes(of: dataBytes.littleEndian) { Data($0) })
    }

    /// True when the header's lengths do not agree with the file's own size: what a recording cut
    /// short by a daemon restart leaves behind.
    static func needsRepair(path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: bytes), head.count == bytes else { return false }
        guard let size = try? handle.seekToEnd(), size > UInt64(bytes) else { return false }
        let declared = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian }
        return UInt64(declared) != size - UInt64(bytes)
    }
}

/// Owns one recording's directory: its manifest, and the one part file that is open at a time.
///
/// Parts close when the part timer elapses, when the gate closes, when the capture's centre or
/// rate changes under an IQ recording, and when the job ends. Peak and mean dBFS are accumulated
/// per part from the samples as they pass.
actor PartWriter {
    /// The store's cap, checked as parts are closed. A recording that would push the store past it
    /// ends rather than writing a file retention would delete a moment later.
    /// 2001-01-01. A derived wall clock below this came from an anchor that was never set, not
    /// from a real clock.
    static let plausibleEpochNs: Int64 = 978_307_200_000_000_000

    nonisolated let directory: String
    private(set) var manifest: RecordingManifest
    private let log = Logger(label: "leyline.recordings")

    private var handle: FileHandle?
    private var partPath: String?
    private var partNumber = 0
    private var partStartSample: UInt64 = 0
    private var partSamples: UInt64 = 0
    private var partBytes: UInt64 = 0
    private var peak: Double = 0
    private var sumSquares: Double = 0
    private var squelchOpens: [RecordingSquelchOpen] = []
    private var pendingOpen: UInt64?
    /// The capture whose timeline the current part's samples are on.
    private var captureID: String
    private var centerHz: UInt64
    private var closed = false
    /// Set when a write failed: the job is told once and the recording ends with what it kept.
    private(set) var writeFailure: String?
    /// True when that failure was the disk running out, which gets a different message and a
    /// different `ended_by` from a file that would not open.
    private(set) var outOfSpace = false

    init(directory: String, manifest: RecordingManifest, captureID: String, centerHz: UInt64) throws {
        self.directory = directory
        self.manifest = manifest
        self.captureID = captureID
        self.centerHz = centerHz
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Self.writeManifest(manifest, to: directory)
    }

    var isPartOpen: Bool { handle != nil }
    var parts: Int { manifest.parts.count }
    var bytes: UInt64 { manifest.bytes + partBytes }
    var currentPartStart: UInt64 { partStartSample }

    /// The capture the following samples are on, and where it sits. An IQ part is closed by the
    /// caller before this changes, so the next part carries the new centre.
    func retarget(captureID: String, centerHz: UInt64) {
        self.captureID = captureID
        self.centerHz = centerHz
    }

    /// A capture's anchor, for the manifest. A capture publishes its anchor with its first block,
    /// so the one a job reads at allocation is a placeholder with a zero host time; the runner
    /// calls this again once samples are flowing, and the real anchor replaces it. Without that
    /// every derived time -- the part's wall clock, its file name -- would date to the epoch.
    func noteAnchor(_ anchor: CaptureAnchor, captureID: String, fromSample: UInt64) {
        let stored = StoredAnchor(hostTimeNs: anchor.hostTimeNsAtSampleZero, sampleRate: anchor.sampleRate,
                                  driftPpm: anchor.driftPPM, fromSample: fromSample, captureID: captureID)
        if let i = manifest.anchors.firstIndex(where: { $0.captureID == captureID && $0.fromSample == fromSample }) {
            // A placeholder is replaced; a real anchor is left alone, because an anchor that has
            // already dated samples must not move under them.
            guard manifest.anchors[i].hostTimeNs == 0, stored.hostTimeNs != 0 else { return }
            manifest.anchors[i] = stored
        } else {
            manifest.anchors.append(stored)
        }
        persist()
    }

    func noteGap(from: UInt64, to: UInt64, reason: String) {
        guard to > from else { return }
        manifest.coverageGaps.append(RecordingGap(fromSample: from, toSample: to, reason: reason))
        persist()
    }

    /// A squelch edge inside the open part, for the sidecar's `squelch_opens` and the manifest's
    /// count. An open with no close yet is held until the close arrives or the part is cut.
    func noteSquelch(open: Bool, at sample: UInt64) {
        if open {
            pendingOpen = sample
        } else if let from = pendingOpen {
            squelchOpens.append(RecordingSquelchOpen(openSample: from, closeSample: sample))
            pendingOpen = nil
        }
    }

    // MARK: Parts

    func openPart(at startSample: UInt64) {
        guard handle == nil, !closed else { return }
        partNumber += 1
        partStartSample = startSample
        partSamples = 0
        partBytes = 0
        peak = 0
        sumSquares = 0
        squelchOpens = []
        pendingOpen = nil
        let name = partFileName(number: partNumber, startSample: startSample)
        let path = directory + "/" + name
        do {
            FileManager.default.createFile(atPath: path, contents: nil)
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            if manifest.format == "wav-s16" {
                let header = WAVHeader.header(sampleRate: UInt32(truncatingIfNeeded: manifest.sampleRate))
                try h.write(contentsOf: header)
                // `bytes` is the file's size, header included: it matches the size Finder shows,
                // and it is what the store's cap counts.
                partBytes = UInt64(header.count)
            }
            handle = h
            partPath = path
        } catch {
            fail("could not open \(name): \(error)", error: error)
        }
    }

    /// Audio, as the f32 the channel produced. Converted to S16 here, off the hot path.
    func append(audio: [Float]) {
        guard let h = handle, !audio.isEmpty else { return }
        var bytes = Data(count: audio.count * 2)
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.baseAddress!.assumingMemoryBound(to: Int16.self)
            for i in 0..<audio.count {
                let v = Swift.max(-1, Swift.min(1, audio[i]))
                out[i] = Int16((Double(v) * 32767).rounded())
                let magnitude = abs(Double(v))
                if magnitude > peak { peak = magnitude }
                sumSquares += Double(v) * Double(v)
            }
        }
        write(bytes, frames: UInt64(audio.count), to: h)
    }

    /// IQ, as the interleaved cf32 the capture delivered. Written through unchanged: it is the
    /// format every reader in the repository already handles.
    func append(iq: Data) {
        guard let h = handle, !iq.isEmpty else { return }
        let samples = UInt64(iq.count / 8)
        iq.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float32.self)
            var i = 0
            while i + 1 < f.count {
                let magnitude = Double(f[i] * f[i] + f[i + 1] * f[i + 1]).squareRoot()
                if magnitude > peak { peak = magnitude }
                sumSquares += magnitude * magnitude
                i += 2
            }
        }
        write(iq, frames: samples, to: h)
    }

    private func write(_ data: Data, frames: UInt64, to h: FileHandle) {
        do {
            try h.write(contentsOf: data)
            partSamples += frames
            partBytes += UInt64(data.count)
        } catch {
            fail("could not write \(partPath ?? directory): \(error)", error: error)
        }
    }

    /// Closes the open part at `endSample`: the WAV header is patched from the file's length, the
    /// sidecar is written, and the part joins the manifest.
    func closePart(endSample: UInt64) {
        guard let h = handle, let path = partPath else { return }
        try? h.close()
        handle = nil
        partPath = nil
        if manifest.format == "wav-s16" {
            do { try WAVHeader.patchLengths(path: path) } catch {
                log.warning("\(path): the header could not be patched (\(error)); ley play reads to the end of the file anyway")
            }
        }
        // An open with no close yet: the part is being cut under a transmission still in progress,
        // so the over ends where the part does rather than being dropped.
        if let from = pendingOpen {
            squelchOpens.append(RecordingSquelchOpen(openSample: from, closeSample: endSample))
            pendingOpen = nil
        }
        // A part with no samples in it has no level: nothing was measured, so no level is written.
        let peakDb: Double? = partSamples > 0 ? dbfs(peak) : nil
        let meanDb: Double? = partSamples > 0 ? dbfs((sumSquares / Double(partSamples)).squareRoot()) : nil
        let part = RecordingPart(part: partNumber, file: (path as NSString).lastPathComponent,
                                 startSample: partStartSample, endSample: endSample,
                                 samples: partSamples, bytes: partBytes,
                                 peakDbfs: peakDb, meanDbfs: meanDb, squelchOpens: squelchOpens.count)
        manifest.parts.append(part)
        manifest.bytes += partBytes
        // The per-part accumulators belong to the part that just closed. `bytes` adds the open
        // part to the manifest's total, so leaving them set counts the last part twice -- which is
        // exactly the number a finished recording reports.
        partBytes = 0
        partSamples = 0
        writeSidecar(for: part, peak: peakDb, mean: meanDb)
        persist()
    }

    /// Ends the recording: the open part is closed and the manifest records how it ended.
    func finish(endedBy: String, endSample: UInt64) {
        guard !closed else { return }
        if handle != nil { closePart(endSample: endSample) }
        closed = true
        manifest.endedBy = manifest.endedBy.isEmpty ? endedBy : manifest.endedBy
        manifest.endedAtNs = realtimeNs()
        persist()
    }

    // MARK: Files

    private func fail(_ message: String, error: (any Error)? = nil) {
        if writeFailure == nil { writeFailure = message }
        if let e = error as NSError?, e.domain == NSPOSIXErrorDomain, e.code == Int(ENOSPC) { outOfSpace = true }
        if (error as NSError?)?.code == NSFileWriteOutOfSpaceError { outOfSpace = true }
        log.warning("\(message)")
    }

    /// Bytes free on the volume the recordings live on, for the message a full-disk ending reports.
    /// nil when the filesystem does not report it.
    nonisolated func freeBytes() -> UInt64? {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory)
        return (attrs?[.systemFreeSize] as? NSNumber)?.uint64Value
    }

    /// `2026-09-17_14-03-22_146.520MHz_NFM_001.wav`: the wall clock of the part's first sample in
    /// the local zone, the channel's frequency and mode, and the part number. The name is for
    /// people browsing in Finder; nothing parses it.
    private func partFileName(number: Int, startSample: UInt64) -> String {
        // A capture whose anchor has no host time -- a fixture, dated from a sidecar that holds
        // zero -- would name every part 1970-01-01, and a few seconds into the file 1969 in any
        // zone west of UTC. The times inside the files stay derived from the anchor (invariant 5);
        // only the name, which nothing parses, falls back to now.
        let derived = wallTime(at: startSample)
        let when = Date(timeIntervalSince1970: Double(derived > Self.plausibleEpochNs ? derived : realtimeNs()) / 1e9)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let mhz = String(format: "%.3f", Double(manifest.frequencyHz) / 1e6)
        let tag = manifest.kind == "iq" ? "IQ" : manifest.mode.uppercased()
        let ext = manifest.format == "wav-s16" ? "wav" : "cf32"
        return String(format: "%@_%@MHz_%@_%03d.%@", f.string(from: when), mhz, tag.isEmpty ? "REC" : tag, number, ext)
    }

    /// Wall clock for a capture sample, through the newest anchor that covers it (invariant 5).
    private func wallTime(at sample: UInt64) -> Int64 {
        let mine = manifest.anchors.filter { ($0.captureID ?? "") == captureID }
        let candidates = mine.isEmpty ? manifest.anchors : mine
        var chosen: StoredAnchor?
        for a in candidates where a.fromSample <= sample {
            if chosen == nil || a.fromSample >= chosen!.fromSample { chosen = a }
        }
        guard let anchor = chosen ?? candidates.first else { return realtimeNs() }
        return anchor.hostTime(at: sample)
    }

    private func writeSidecar(for part: RecordingPart, peak: Double?, mean: Double?) {
        let anchor = manifest.anchors.last { ($0.captureID ?? "") == captureID } ?? manifest.anchors.last
        let sidecar = PartSidecar(
            format: manifest.format,
            sampleRate: manifest.sampleRate,
            centerHz: centerHz,
            samples: part.samples,
            createdAtNs: wallTime(at: part.startSample),
            anchor: .init(captureID: captureID, hostTimeNs: anchor?.hostTimeNs ?? 0,
                          sampleRate: anchor?.sampleRate ?? 0, driftPpm: anchor?.driftPpm ?? 0),
            metadata: [
                "mode": manifest.mode,
                "frequency_hz": String(manifest.frequencyHz),
                "kind": manifest.kind,
            ],
            recording: .init(jobID: manifest.jobID, part: part.part, kind: manifest.kind,
                             startSample: part.startSample, endSample: part.endSample,
                             bandwidthHz: manifest.bandwidthHz,
                             squelchDbfs: manifest.squelchDbfs.isFinite ? manifest.squelchDbfs : nil,
                             peakDbfs: peak, meanDbfs: mean, squelchOpens: squelchOpens))
        let base = (part.file as NSString).deletingPathExtension
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sidecar).write(to: URL(fileURLWithPath: directory + "/" + base + ".json"), options: .atomic)
        } catch {
            fail("could not write the sidecar for \(part.file): \(error)", error: error)
        }
    }

    private func persist() {
        do {
            try Self.writeManifest(manifest, to: directory)
        } catch {
            fail("could not write \(directory)/recording.json: \(error)", error: error)
        }
    }

    static func writeManifest(_ manifest: RecordingManifest, to directory: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: URL(fileURLWithPath: directory + "/recording.json"), options: .atomic)
    }
}

/// Full-scale decibels for a linear amplitude. Silence is -inf, which JSON cannot hold, so the
/// floor is the quietest level a 16-bit sample can represent.
func dbfs(_ amplitude: Double) -> Double {
    guard amplitude > 0 else { return -120 }
    return Swift.max(-120, 20 * log10(Swift.min(1, amplitude)))
}
