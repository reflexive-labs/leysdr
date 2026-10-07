// SPDX-License-Identifier: GPL-3.0-or-later

// One kept job's two files. Records append as they arrive; the sidecar is rewritten whenever the
// count or the anchors change, so a query sees a sidecar that matches the records even while the
// job is still running (docs/design/decoders.md, "Decisions": "The store is files").

import EngineCore
import Foundation
import LeylineProto
import Logging

actor RecordWriter {
    /// Records buffered before the bytes reach the file. A crash loses at most this many, and a
    /// decode job that decodes one packet a minute still has its record on disk within a second.
    static let flushEvery = 32
    static let flushInterval: Double = 1

    private let base: String
    private var sidecar: RecordSidecar
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var sinceFlush = 0
    private var lastFlush = ContinuousClock.now
    private var closed = false
    private let log = Logger(label: "leyline.decoders.store")

    init(base: String, sidecar: RecordSidecar) throws {
        self.base = base
        self.sidecar = sidecar
        let path = base + ".records"
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try Self.write(sidecar, to: base)
    }

    var recordCount: UInt64 { sidecar.count }

    func append(_ record: Leyline_V1_DecodeRecord) {
        guard !closed else { return }
        guard let bytes = try? delimitedBytes(record) else { return }
        buffer.append(contentsOf: bytes)
        sidecar.count += 1
        sinceFlush += 1
        if sinceFlush >= Self.flushEvery || ContinuousClock.now - lastFlush > .seconds(Self.flushInterval) {
            flush()
        }
    }

    /// A capture that re-anchored while the job ran. The sidecar keeps every one, because a record
    /// is turned into wall clock by the anchor in force when it arrived, not by the newest. An
    /// anchor for a capture and sample the sidecar already holds replaces it only when the one held
    /// is the placeholder at host time zero (`settleAnchor`).
    func noteAnchor(_ anchor: CaptureAnchor, fromSample: UInt64, captureID: String? = nil) {
        guard !closed else { return }
        let capture = captureID ?? sidecar.captureID
        let stored = StoredAnchor(hostTimeNs: anchor.hostTimeNsAtSampleZero, sampleRate: anchor.sampleRate,
                                  driftPpm: anchor.driftPPM, fromSample: fromSample, captureID: capture)
        if let i = sidecar.anchors.lastIndex(where: {
            ($0.captureID ?? sidecar.captureID) == capture && $0.fromSample == fromSample
        }) {
            guard sidecar.anchors[i].hostTimeNs == 0, stored.hostTimeNs != 0 else { return }
            sidecar.anchors[i] = stored
        } else {
            sidecar.anchors.append(stored)
        }
        try? Self.write(sidecar, to: base)
    }

    /// Set once this run's capture has a real anchor in the sidecar.
    private var anchorSettled = false

    /// The capture's own anchor, once it has one. A capture publishes its anchor with its first
    /// block, so the one read while the job was being allocated can be the placeholder at host
    /// time zero, and every record it dates reads as 1970: a query, which sorts newest first, put a
    /// resumed job's first run ahead of its second. The runner calls this before each record it
    /// keeps until the capture's real anchor has replaced the placeholder; a capture that has not
    /// published one yet is asked again at the next record.
    func settleAnchor(of capture: CaptureID, in store: SessionStore) async {
        guard !anchorSettled, !closed else { return }
        guard let anchor = await store.captureEngine(capture)?.snapshot.anchor,
              anchor.hostTimeNsAtSampleZero != 0, !anchorSettled
        else { return }
        anchorSettled = true
        noteAnchor(anchor, fromSample: 0, captureID: capture.string)
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: Data(buffer))
            buffer.removeAll(keepingCapacity: true)
            sinceFlush = 0
            lastFlush = ContinuousClock.now
            try Self.write(sidecar, to: base)
        } catch {
            log.warning("\(base).records: \(error)")
        }
    }

    func close() {
        guard !closed else { return }
        flush()
        closed = true
        try? handle.close()
        try? Self.write(sidecar, to: base)
    }

    /// Atomically, and nonisolated so the initialiser can write the first one before the actor
    /// exists to be isolated to.
    private static func write(_ sidecar: RecordSidecar, to base: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: URL(fileURLWithPath: base + ".json"), options: .atomic)
    }
}
