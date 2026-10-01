// SPDX-License-Identifier: GPL-3.0-or-later

// The recordings store: a plain directory Finder can open and Spotlight can index, beside the
// kept-records store (docs/design/recording.md, "Files"). One directory per recording, named by
// the job id. There is no index: a listing is a scan of the manifests, exactly as the kept-records
// index is a scan of its sidecars, so a recording deleted in Finder drops out of the listing with
// no index to update.

import EngineCore
import Foundation
import Logging

actor RecordingStore {
    struct Stats: Sendable {
        var path: String
        var capBytes: UInt64
        var ageDays: UInt32
    }

    let directory: String
    let capBytes: UInt64
    let ageDays: UInt32
    private let log = Logger(label: "leyline.recordings")

    init(directory: String, capBytes: UInt64, ageDays: UInt32) {
        self.directory = directory
        self.capBytes = capBytes
        self.ageDays = ageDays
    }

    var stats: Stats { Stats(path: directory, capBytes: capBytes, ageDays: ageDays) }

    nonisolated func directory(for job: JobID) -> String { directory + "/" + job.string }

    /// Opens a recording: the job's directory and its first manifest. Retention runs first, so the
    /// store is inside its cap before anything is written to it.
    func open(job: JobID, manifest: RecordingManifest, captureID: String, centerHz: UInt64) throws -> PartWriter {
        retain(keeping: [job.string])
        return try PartWriter(directory: directory(for: job), manifest: manifest,
                              captureID: captureID, centerHz: centerHz)
    }

    // MARK: Reading

    /// Every manifest in the store, newest first by the time its recording started.
    func manifests() -> [RecordingManifest] {
        entries().map(\.manifest).sorted { $0.startedAtNs > $1.startedAtNs }
    }

    func manifest(jobID: String) -> RecordingManifest? {
        guard JobID(string: jobID) != nil,
              let data = FileManager.default.contents(atPath: directory + "/" + jobID + "/recording.json")
        else { return nil }
        return try? JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    /// Where a recording's files are, and where one part's samples are. The two forms of
    /// `ResolveLocalPath`: a client on this machine opens the file, and nothing is streamed.
    func localPath(jobID: String, part: Int?) -> String? {
        guard let manifest = manifest(jobID: jobID) else { return nil }
        let dir = directory + "/" + jobID
        guard let part else { return dir }
        guard let entry = manifest.parts.first(where: { $0.part == part }) else { return nil }
        return dir + "/" + entry.file
    }

    /// The size of a recording on disk: what the manifest counted, plus the sidecars and the part
    /// that is still being written.
    func sizeOnDisk(jobID: String) -> UInt64 { size(of: directory + "/" + jobID) }

    /// Removes one recording whole, every part, sidecar and the manifest, and returns the bytes it
    /// held; nil when there is no such recording. The caller has already refused a recording whose
    /// job is running (`Resources.DeleteResource`, docs/design/recording.md, "The wire"). Nothing
    /// else needs updating: the listing is a scan of the manifests.
    func delete(jobID: String, by client: String) throws -> UInt64? {
        guard manifest(jobID: jobID) != nil else { return nil }
        let path = directory + "/" + jobID
        let bytes = size(of: path)
        try FileManager.default.removeItem(atPath: path)
        log.info("deleted \(path): \(bytes) bytes, asked by \(client.isEmpty ? "an unnamed client" : client)")
        return bytes
    }

    // MARK: Retention and repair

    /// Age first, then size, oldest first by manifest time -- and never a recording whose job is
    /// still running (docs/design/recording.md, "Retention"). Runs when a job ends and at daemon
    /// start.
    func retain(keeping running: Set<String> = []) {
        var all = entries().filter { !running.contains($0.manifest.jobID) }
        if ageDays > 0 {
            let cutoff = Int64(Date().addingTimeInterval(-Double(ageDays) * 86400).timeIntervalSince1970 * 1e9)
            for e in all where e.manifest.startedAtNs < cutoff {
                remove(e.path)
            }
            all.removeAll { $0.manifest.startedAtNs < cutoff }
        }
        all.sort { $0.manifest.startedAtNs < $1.manifest.startedAtNs }
        // The running recordings count against the cap even though they are never dropped: a cap
        // that ignored them would overrun by the size of whatever is being written.
        var total = entries().reduce(UInt64(0)) { $0 + $1.bytes }
        var index = 0
        while total > capBytes, index < all.count {
            remove(all[index].path)
            total -= Swift.min(total, all[index].bytes)
            index += 1
        }
    }

    /// What is left of a recording the last daemon was still writing (docs/design/recording.md,
    /// "Retune, detach and restart"): the part's WAV header is repaired from the file's length and
    /// the manifest is closed with `ended_by = restart`. The recording is not resumed; a
    /// longer one needs a new job. One with no part holding samples is removed instead.
    ///
    /// Returns the job ids it closed or removed, so the daemon can log them.
    @discardableResult
    func repairUnfinished() -> [String] {
        var repaired: [String] = []
        for entry in entries() where entry.manifest.endedBy.isEmpty {
            var manifest = entry.manifest
            // Any part file the manifest does not list is one the last daemon had open. Its header
            // is patched from the file's own length, and it joins the manifest with what it holds.
            let listed = Set(manifest.parts.map(\.file))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: entry.path)) ?? []
            for name in names.sorted() where !listed.contains(name) {
                guard name.hasSuffix(".wav") || name.hasSuffix(".cf32") else { continue }
                let path = entry.path + "/" + name
                let bytes = size(ofFile: path)
                if name.hasSuffix(".wav") {
                    if WAVHeader.needsRepair(path: path) {
                        do { try WAVHeader.patchLengths(path: path) } catch {
                            log.warning("\(path): could not repair the WAV header (\(error))")
                        }
                    }
                }
                let audio = name.hasSuffix(".wav")
                let frames = audio
                    ? (bytes > UInt64(WAVHeader.bytes) ? (bytes - UInt64(WAVHeader.bytes)) / 2 : 0)
                    : bytes / 8
                let start = manifest.parts.last.map { $0.endSample } ?? 0
                let span = manifest.sampleRate > 0 ? frames : 0
                manifest.parts.append(RecordingPart(
                    part: manifest.parts.count + 1, file: name, startSample: start,
                    endSample: start + span, samples: frames, bytes: bytes,
                    // Nobody measured these: the daemon that was accumulating them is gone, and a
                    // number invented here would be indistinguishable from one that was measured.
                    peakDbfs: nil, meanDbfs: nil, squelchOpens: 0))
                manifest.bytes += bytes
            }
            manifest.endedBy = "restart"
            manifest.endedAtNs = realtimeNs()
            // A recording that heard nothing before the last daemon went is discarded, as one
            // that ends under a running daemon is (docs/design/recording.md, "Nothing heard").
            if !manifest.parts.contains(where: { $0.samples > 0 }) {
                log.info("dropping \(entry.path): the recording the last daemon left heard nothing")
                try? FileManager.default.removeItem(atPath: entry.path)
                repaired.append(manifest.jobID)
                continue
            }
            do {
                try PartWriter.writeManifest(manifest, to: entry.path)
                repaired.append(manifest.jobID)
            } catch {
                log.warning("\(entry.path): could not close the manifest (\(error))")
            }
        }
        return repaired
    }

    // MARK: The directory

    private struct Entry {
        var path: String
        var manifest: RecordingManifest
        var bytes: UInt64
    }

    private func entries() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names.sorted().compactMap { name in
            let path = directory + "/" + name
            guard let data = fm.contents(atPath: path + "/recording.json") else { return nil }
            do {
                let manifest = try JSONDecoder().decode(RecordingManifest.self, from: data)
                return Entry(path: path, manifest: manifest, bytes: size(of: path))
            } catch {
                log.warning("\(path)/recording.json does not parse (\(error)); skipping")
                return nil
            }
        }
    }

    private func remove(_ path: String) {
        log.info("dropping \(path): the recordings store is over its cap or its age")
        try? FileManager.default.removeItem(atPath: path)
    }

    private func size(of directory: String) -> UInt64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        return names.reduce(UInt64(0)) { $0 + size(ofFile: directory + "/" + $1) }
    }

    private func size(ofFile path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
