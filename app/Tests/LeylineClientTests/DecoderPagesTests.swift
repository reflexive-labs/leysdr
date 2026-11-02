// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// The Decoders place's rules: tabs by output shape, the jobs under a decoder, the record log
/// and its dedupe, the alerts in effect, the inspector's words, the trails and the labels file.
final class DecoderPagesTests: XCTestCase {
    func manifest(entities: Bool = true) -> Leyline_V1_DecoderManifest {
        var m = Leyline_V1_DecoderManifest()
        m.name = "ais"
        m.aliases = ["vessels"]
        m.outputs = entities ? [.shapeRecords, .shapeEntities] : [.shapeRecords]
        var sog = Leyline_V1_FieldHint()
        sog.name = "sog_kn"
        sog.type = .number
        sog.unit = "kn"
        sog.description_p = "speed over ground"
        var cog = Leyline_V1_FieldHint()
        cog.name = "cog_deg"
        cog.type = .number
        cog.unit = "deg"
        var name = Leyline_V1_FieldHint()
        name.name = "name"
        name.type = .text
        m.fields = [sog, cog, name]
        return m
    }

    func record(_ id: String, seq: UInt64 = 0, device: String = "", kind: String = "")
        -> Leyline_V1_DecodeRecord
    {
        var r = Leyline_V1_DecodeRecord()
        r.recordID = id
        r.seq = seq
        r.deviceID = device
        r.kind = kind
        r.protocol = "ais"
        r.rssiDbfs = .nan
        r.snrDb = .nan
        return r
    }

    func job(_ id: String, decoder: String, state: Leyline_V1_JobState, source: String = "")
        -> Leyline_V1_Job
    {
        var j = Leyline_V1_Job()
        j.jobID = id
        j.state = state
        var d = Leyline_V1_DecodeConfig()
        d.decoder = decoder
        d.sourceUri = source
        j.config = .decode(d)
        return j
    }

    func testTabsFollowTheOutputShapesAndPositions() {
        XCTAssertEqual(DecoderTab.available(manifest(), anyPosition: false), [.log, .table])
        XCTAssertEqual(DecoderTab.available(manifest(), anyPosition: true), [.log, .table, .map])
        XCTAssertEqual(
            DecoderTab.available(manifest(entities: false), anyPosition: true), [.log, .map])
        XCTAssertEqual(DecoderTab.available(manifest(entities: false), anyPosition: false), [.log])
    }

    func testAJobIsUnderItsDecoderByNameOrAliasAndATranscriptionIsNot() {
        let jobs = [
            job("job_1", decoder: "ais", state: .running),
            job("job_2", decoder: "vessels", state: .degraded),
            job("job_3", decoder: "ais", state: .cancelled),
            job("job_4", decoder: "ais", state: .running, source: "ley://recordings/job_0"),
            job("job_5", decoder: "aprs", state: .running),
        ]
        XCTAssertEqual(
            DecoderPages.jobs(of: manifest(), in: jobs).map(\.jobID), ["job_3", "job_2", "job_1"])
        XCTAssertEqual(
            DecoderPages.running(of: manifest(), in: jobs).map(\.jobID), ["job_2", "job_1"])
    }

    func testAJobsDetailIsItsStatusElseItsFailure() {
        var j = job("job_1", decoder: "ais", state: .running)
        j.statusDetail = "12 records, last 3 s ago"
        XCTAssertEqual(DecoderPages.stateWord(j), "Running")
        XCTAssertEqual(DecoderPages.detail(j), "12 records, last 3 s ago")
        j.state = .failed
        j.statusDetail = ""
        j.error.message = "no radio here can hear 161.975 MHz"
        XCTAssertEqual(DecoderPages.stateWord(j), "Failed")
        XCTAssertEqual(DecoderPages.detail(j), "no radio here can hear 161.975 MHz")
    }

    func testTheLogKeepsEachRecordOnceNewestFirst() {
        var log = RecordLog(limit: 3)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        // Live records arrive before the history lands, and the history holds one of them.
        let live = log.insert([
            RecordEntry(record: record("rec_c", seq: 3), at: t + 30, dated: true)
        ])
        XCTAssertEqual(live.count, 1)
        let added = log.insert([
            RecordEntry(record: record("rec_c", seq: 3), at: t + 30, dated: true),
            RecordEntry(record: record("rec_b", seq: 2), at: t + 20, dated: true),
            RecordEntry(record: record("rec_a", seq: 1), at: t + 10, dated: true),
        ])
        XCTAssertEqual(added.map(\.id), ["rec_b", "rec_a"])
        XCTAssertEqual(log.entries.map(\.id), ["rec_c", "rec_b", "rec_a"])
        log.insert([RecordEntry(record: record("rec_d", seq: 4), at: t + 40, dated: true)])
        XCTAssertEqual(log.entries.map(\.id), ["rec_d", "rec_c", "rec_b"])
        // The oldest went past the limit, so it may come back.
        XCTAssertEqual(
            log.insert([RecordEntry(record: record("rec_a", seq: 1), at: t, dated: true)]).count, 1)
        XCTAssertEqual(log.entries.count, 3)
    }

    func testARecordIsDatedThroughThePagesAnchorElseWhenItArrived() {
        var r = record("rec_a")
        r.time.captureID = "cap_1"
        r.time.sampleIndex = 2_400_000
        var a = Leyline_V1_RecordAnchor()
        a.anchor.captureID = "cap_1"
        a.anchor.sampleRate = 2_400_000
        a.anchor.hostTimeNs = 1_800_000_000_000_000_000
        let fallback = Date(timeIntervalSince1970: 5)
        let e = RecordEntry.dated(r, anchors: [a], fallback: fallback)
        XCTAssertTrue(e.dated)
        XCTAssertEqual(e.at.timeIntervalSince1970, 1_800_000_001, accuracy: 1e-6)
        let other = RecordEntry.dated(r, anchors: [], fallback: fallback)
        XCTAssertFalse(other.dated)
        XCTAssertEqual(other.at, fallback)
    }

    func testAlertsInEffectAreThoseWhoseWindowHoldsNowOnceEach() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ns = { (s: Double) in Int64((now.timeIntervalSince1970 + s) * 1e9) }
        var current = record("rec_1", device: "KEC61", kind: "alert")
        current.validity.startNs = ns(-600)
        current.validity.endNs = ns(1800)
        var repeated = current
        repeated.recordID = "rec_2"
        var over = record("rec_3", device: "KEC61", kind: "alert")
        over.validity.startNs = ns(-7200)
        over.validity.endNs = ns(-60)
        over.fields["org"] = .with { $0.text = "WXR" }
        var open = record("rec_4", device: "KEC62", kind: "alert")
        open.validity.startNs = 0
        let plain = record("rec_5", device: "KEC61")
        let entries = [current, repeated, over, open, plain].map {
            RecordEntry(record: $0, at: now, dated: true)
        }
        XCTAssertEqual(
            DecoderPages.alerts(entries, display: nil, now: now).map(\.id), ["rec_1", "rec_4"])
        XCTAssertEqual(
            DecoderPages.untilWords(current, timeZone: TimeZone(identifier: "UTC")!),
            "until "
                + DecoderPages.clock(
                    now + 1800, seconds: false, timeZone: TimeZone(identifier: "UTC")!))
        XCTAssertNil(DecoderPages.untilWords(open))
    }

    func testTheInspectorsFieldsCarryTheHintsUnitsAndDescriptions() {
        let fields: [String: Leyline_V1_FieldValue] = [
            "name": .with { $0.text = "EVER GIVEN" },
            "sog_kn": .with { $0.number = 12.34567891 },
            "cog_deg": .with { $0.number = 254 },
            "mmsi": .with { $0.integer = 366_999_101 },
            "alive": .with { $0.flag = false },
        ]
        let rows = DecoderPages.fieldRows(fields, manifest: manifest())
        XCTAssertEqual(rows.map(\.name), ["sog_kn", "cog_deg", "name", "mmsi"])
        XCTAssertEqual(rows.map(\.value), ["12.345679 kn", "254°", "EVER GIVEN", "366999101"])
        XCTAssertEqual(rows[0].description, "speed over ground")
    }

    func testColumnHeadsAreLeyTracks() {
        XCTAssertEqual(DecoderPages.columnHead("sog_kn", manifest: manifest()), "SOG (kn)")
        XCTAssertEqual(DecoderPages.columnHead("cog_deg", manifest: manifest()), "COG (°)")
        XCTAssertEqual(DecoderPages.columnHead("call_sign", manifest: manifest()), "CALL SIGN")
        XCTAssertTrue(DecoderPages.columnIsNumeric("sog_kn", manifest: manifest()))
        XCTAssertFalse(DecoderPages.columnIsNumeric("name", manifest: manifest()))
    }

    func testAgesAreCoarsenedAsAPersonSaysThem() {
        XCTAssertEqual(DecoderPages.agoWords(0.5), "just now")
        XCTAssertEqual(DecoderPages.agoWords(12), "12 s ago")
        XCTAssertEqual(DecoderPages.agoWords(250), "4 min ago")
        XCTAssertEqual(DecoderPages.agoWords(3 * 3600 + 5), "3 h ago")
        XCTAssertEqual(DecoderPages.agoWords(-5), "just now")
    }

    func testRawBytesAreHexSixteenALine() {
        let d = Data((0..<18).map { UInt8($0 * 15) })
        XCTAssertEqual(
            DecoderPages.hexLines(d),
            ["00 0f 1e 2d 3c 4b 5a 69 78 87 96 a5 b4 c3 d2 e1", "f0 ff"])
    }

    func testSignalWordsNameWhatWasMeasured() {
        var r = record("rec_1")
        XCTAssertNil(DecoderPages.signalWords(r))
        r.rssiDbfs = -42.13
        XCTAssertEqual(DecoderPages.signalWords(r), "-42.1 dBFS")
        r.snrDb = 18
        XCTAssertEqual(DecoderPages.signalWords(r), "-42.1 dBFS · 18.0 dB SNR")
    }

    func testATrailKeepsTheLastFiftyDistinctPositions() {
        var table = EntityTable()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<60 {
            var r = record("rec_\(i)", device: "A1F001", kind: "position")
            r.position.latitude = 37 + Double(i) / 100
            r.position.longitude = -122
            table.apply(r, at: t + Double(i))
            // The same position again adds nothing.
            table.apply(r, at: t + Double(i) + 0.5)
        }
        var heading = record("rec_v", device: "A1F001", kind: "velocity")
        heading.fields["track_deg"] = .with { $0.number = 284 }
        table.apply(heading, at: t + 100)
        let e = try! XCTUnwrap(table.rows.first)
        XCTAssertEqual(e.trail.count, EntityTable.trailLength)
        XCTAssertEqual(e.trail.first?.latitude ?? 0, 37.10, accuracy: 1e-9)
        XCTAssertEqual(e.trail.last?.latitude ?? 0, 37.59, accuracy: 1e-9)
        XCTAssertEqual(e.count, 121)
        XCTAssertEqual(e.heading, 284)
    }

    func testTheSidebarListsEachDecoderOnce() {
        var a = manifest()
        a.name = "speech"
        var b = a
        b.version = "scripted"
        var c = manifest()
        c.display.title = "Vessels"
        XCTAssertEqual(DecoderPages.listed([a, b, c]).map(\.name), ["speech", "ais"])
        XCTAssertEqual(DecoderPages.title(c), "Vessels")
        XCTAssertEqual(DecoderPages.title(a), "speech")
    }

    // MARK: The labels file

    func testLabelsRoundTripTheFileLeyWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("labels.json").path
        // As go/pkg/labels writes it; the map key wins over the entry's own id.
        try Data(
            #"{"labels":{"N0CALL-9":{"device_id":"x","name":"Bob's car","protocol":"aprs","updated_ns":5},"A1F001":{"device_id":"A1F001","name":"Medevac","updated_ns":6}}}"#
                .utf8
        ).write(to: URL(fileURLWithPath: path))
        var store = LabelStore(path: path)
        XCTAssertThrowsError(try store.set(deviceID: "a", name: "b", protocolName: ""))
        try store.load()
        XCTAssertEqual(store.name(of: "N0CALL-9"), "Bob's car")
        XCTAssertEqual(store.labels["N0CALL-9"]?.deviceID, "N0CALL-9")
        store.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        try store.set(deviceID: "366999101", name: "  Pilot boat ", protocolName: "ais")
        try store.set(deviceID: "A1F001", name: "", protocolName: "adsb")
        var again = LabelStore(path: path)
        try again.load()
        XCTAssertEqual(again.name(of: "366999101"), "Pilot boat")
        XCTAssertEqual(again.labels["366999101"]?.protocolName, "ais")
        XCTAssertEqual(again.labels["366999101"]?.updatedNs, 1_800_000_000_000_000_000)
        XCTAssertNil(again.name(of: "A1F001"))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains(#""device_id" : "366999101""#), text)
        XCTAssertFalse(text.contains(#""protocol" : """#), text)
    }

    func testAMalformedLabelsFileIsNotWrittenOver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("labels.json").path
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        var store = LabelStore(path: path)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.set(deviceID: "a", name: "b", protocolName: ""))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{not json")
    }

    func testTheLabelsPathIsLeysOwn() {
        XCTAssertEqual(
            LabelStore.defaultPath(environment: ["LEYLINE_LABELS": "/tmp/l.json"]), "/tmp/l.json")
        #if os(macOS)
            XCTAssertEqual(
                LabelStore.defaultPath(environment: ["HOME": "/Users/x"]),
                "/Users/x/Library/Application Support/Leyline/labels.json")
        #endif
    }
}
