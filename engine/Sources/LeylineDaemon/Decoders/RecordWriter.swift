// SPDX-License-Identifier: GPL-3.0-or-later

// One kept job's two files. Records append as they arrive; the sidecar is rewritten whenever the
// count or the anchors change, so a query sees an honest file even while the job is still running
// (docs/design/decoders.md, "Decisions": "The store is files").

import EngineCore
import Foundation
import LeylineProto
import Logging

actor RecordWriter {
    /// Records buffered before the bytes reach the file. A crash loses at most this many, and a
    /// decode job that hears one packet a minute still has its record on disk within a second.
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
    /// is turned into wall clock by the anchor in force when it arrived, not by the newest.
    func noteAnchor(_ anchor: CaptureAnchor, fromSample: UInt64) {
        guard !closed else { return }
        let stored = StoredAnchor(hostTimeNs: anchor.hostTimeNsAtSampleZero, sampleRate: anchor.sampleRate,
                                  driftPpm: anchor.driftPPM, fromSample: fromSample)
        if sidecar.anchors.last == nil || sidecar.anchors.last!.fromSample != fromSample {
            sidecar.anchors.append(stored)
            try? Self.write(sidecar, to: base)
        }
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
