// SPDX-License-Identifier: GPL-3.0-or-later

// The store is files (docs/design/decoders.md, "Decisions"): a round trip through the writer and
// every filter a query can ask for, including the wall-clock bounds the sidecar's anchors answer.

import EngineCore
import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

final class RecordStoreTests: XCTestCase {
    private let capture = CaptureID()
    /// 2026-01-01T00:00:00Z, so the wall-clock assertions read as dates rather than as drift.
    private let epochNs: Int64 = 1_767_225_600_000_000_000

    private func record(seq: UInt64, sample: UInt64, device: String, kind: String,
                        lat: Double? = nil, lon: Double? = nil,
                        validity: (Int64, Int64)? = nil, fields: [String: Double] = [:]) -> Leyline_V1_DecodeRecord
    {
        var r = Leyline_V1_DecodeRecord()
        r.recordID = "rec_\(ULID().string)"
        r.protocol = "fake"
        r.seq = seq
        r.deviceID = device
        r.kind = kind
        r.time.captureID = capture.string
        r.time.sampleIndex = sample
        if let lat, let lon {
            r.position.latitude = lat
            r.position.longitude = lon
        }
        if let validity {
            r.validity.startNs = validity.0
            r.validity.endNs = validity.1
        }
        for (name, value) in fields {
            var v = Leyline_V1_FieldValue()
            v.number = value
            r.fields[name] = v
        }
        return r
    }

    /// A store with one job of five records: two anchors, two devices, two kinds, one position,
    /// one validity window.
    private func populated(_ dir: String) async throws -> (store: RecordStore, job: JobID) {
        let store = RecordStore(directory: dir, capBytes: 2 << 30, ageDays: 90)
        let job = JobID()
        var config = Leyline_V1_DecodeConfig()
        config.decoder = "fake"
        config.keep = true
        var manifest = Leyline_V1_DecoderManifest()
        manifest.name = "fake"
        manifest.version = "0.1.0"
        let writer = try await store.open(job: job, config: config, manifest: manifest, capture: capture,
                                          anchor: CaptureAnchor(hostTimeNsAtSampleZero: epochNs, sampleRate: 1_000_000))
        var records = [
            record(seq: 1, sample: 0, device: "A", kind: "position", lat: 37.7749, lon: -122.4194),
            record(seq: 2, sample: 2_000_000, device: "B", kind: "weather", fields: ["temp_c": 11]),
            record(seq: 3, sample: 4_000_000, device: "A", kind: "status"),
        ]
        for r in records { await writer.append(r) }
        // The capture re-anchored: everything after sample 6 000 000 is on a new clock.
        await writer.noteAnchor(CaptureAnchor(hostTimeNsAtSampleZero: epochNs + 10_000_000_000, sampleRate: 1_000_000),
                                fromSample: 6_000_000)
        records = [
            record(seq: 4, sample: 6_000_000, device: "B", kind: "position", lat: 51.5072, lon: -0.1276),
            // Validity is the transmitter's claim on the wall clock and does not go through an
            // anchor, so an "in effect now" record is stated against now.
            record(seq: 5, sample: 8_000_000, device: "A", kind: "alert",
                   validity: (realtimeNs() - 3_600_000_000_000, realtimeNs() + 3_600_000_000_000)),
        ]
        for r in records { await writer.append(r) }
        await writer.close()
        return (store, job)
    }

    func testRoundTripAndFilters() async throws {
        let dir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (store, job) = try await populated(dir)

        var q = Leyline_V1_RecordQuery()
        let all = await store.query(q)
        XCTAssertEqual(all.records.count, 5)
        XCTAssertFalse(all.truncated)
        // Newest first, which for one capture is descending sample index.
        XCTAssertEqual(all.records.map(\.seq), [5, 4, 3, 2, 1])
        XCTAssertEqual(all.records.first?.jobID.isEmpty, true, "the store keeps what it was given")
        XCTAssertEqual(all.anchors.count, 2)
        XCTAssertEqual(all.anchors.map(\.fromSample), [0, 6_000_000])
        XCTAssertEqual(all.anchors.first?.anchor.captureID, capture.string)

        q = Leyline_V1_RecordQuery()
        q.deviceID = "A"
        let page1 = await store.query(q)
        XCTAssertEqual(page1.records.map(\.seq), [5, 3, 1])

        q = Leyline_V1_RecordQuery()
        q.kind = "position"
        let page2 = await store.query(q)
        XCTAssertEqual(page2.records.map(\.seq), [4, 1])

        q = Leyline_V1_RecordQuery()
        q.protocol = "nobody"
        let page3 = await store.query(q)
        XCTAssertEqual(page3.records.count, 0)

        q = Leyline_V1_RecordQuery()
        q.jobID = job.string
        let page4 = await store.query(q)
        XCTAssertEqual(page4.records.count, 5)

        q = Leyline_V1_RecordQuery()
        q.limit = 2
        let cut = await store.query(q)
        XCTAssertEqual(cut.records.map(\.seq), [5, 4])
        XCTAssertTrue(cut.truncated)
    }

    func testWallClockSpatialValidityAndFieldFilters() async throws {
        let dir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (store, _) = try await populated(dir)

        // The second anchor moved the clock on by 10 s, so record 4 sits at epoch + 16 s and not
        // at epoch + 6 s. A bound between them separates the two anchors' records.
        var q = Leyline_V1_RecordQuery()
        q.sinceNs = epochNs + 8_000_000_000
        let page5 = await store.query(q)
        XCTAssertEqual(page5.records.map(\.seq), [5, 4])

        q = Leyline_V1_RecordQuery()
        q.untilNs = epochNs + 5_000_000_000
        let page6 = await store.query(q)
        XCTAssertEqual(page6.records.map(\.seq), [3, 2, 1])

        q = Leyline_V1_RecordQuery()
        q.near.latitude = 37.78
        q.near.longitude = -122.42
        q.radiusM = 10_000
        let page7 = await store.query(q)
        XCTAssertEqual(page7.records.map(\.seq), [1])

        q = Leyline_V1_RecordQuery()
        q.inEffect = true
        let page8 = await store.query(q)
        XCTAssertEqual(page8.records.map(\.seq), [5])

        q = Leyline_V1_RecordQuery()
        var match = Leyline_V1_FieldMatch()
        match.name = "temp_c"
        match.equals.number = 11
        q.fields = [match]
        let page9 = await store.query(q)
        XCTAssertEqual(page9.records.map(\.seq), [2])
    }

    func testRetentionDropsWhatIsTooOldThenWhatDoesNotFit() async throws {
        let dir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try await populated(dir)
        let old = try await populated(dir)
        let path = dir + "/records/" + old.job.string + ".records"
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86400)],
                                              ofItemAtPath: path)
        let aged = RecordStore(directory: dir, capBytes: 2 << 30, ageDays: 90)
        await aged.retain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let left = await aged.query(Leyline_V1_RecordQuery())
        XCTAssertEqual(left.records.count, 5)

        let capped = RecordStore(directory: dir, capBytes: 1, ageDays: 0)
        await capped.retain()
        let none = await capped.query(Leyline_V1_RecordQuery())
        XCTAssertEqual(none.records.count, 0)
        let stats = await capped.stats
        XCTAssertEqual(stats.path, dir)
        XCTAssertEqual(stats.capBytes, 1)
    }
}
