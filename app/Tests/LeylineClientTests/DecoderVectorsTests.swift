// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import SwiftProtobuf
import XCTest

@testable import LeylineClient

/// The shared vectors in testdata/decoders, which `go/pkg/records/vectors_test.go` reads too, so
/// the app and `ley` print the same line and fold the same rows for the same records. The files'
/// shape is testdata/decoders/README.md.
final class DecoderVectorsTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("testdata/decoders")

    struct VDisplay: Decodable {
        var title: String?
        var symbol: String?
        var summaries: [String: String]?
        var entityName: String?
        var columns: [String]?
        var positions: Bool?

        enum CodingKeys: String, CodingKey {
            case title, symbol, summaries, columns, positions
            case entityName = "entity_name"
        }

        var proto: Leyline_V1_DecoderDisplay {
            var d = Leyline_V1_DecoderDisplay()
            d.title = title ?? ""
            d.symbol = symbol ?? ""
            d.summaries = summaries ?? [:]
            d.entityName = entityName ?? ""
            d.columns = columns ?? []
            d.positions = positions ?? false
            return d
        }
    }

    struct VValue: Decodable {
        var text: String?
        var integer: Int64?
        var number: Double?
        var flag: Bool?
        var data: String?

        func proto() throws -> Leyline_V1_FieldValue {
            var v = Leyline_V1_FieldValue()
            let set = [text != nil, integer != nil, number != nil, flag != nil, data != nil]
            guard set.filter({ $0 }).count == 1 else {
                throw XCTSkip("a field value carries exactly one key")
            }
            if let text { v.text = text }
            if let integer { v.integer = integer }
            if let number { v.number = number }
            if let flag { v.flag = flag }
            if let data { v.data = try Self.unhex(data) }
            return v
        }

        static func unhex(_ s: String) throws -> Data {
            let chars = Array(s.utf8)
            guard chars.count % 2 == 0 else { throw CocoaError(.coderInvalidValue) }
            var out = Data()
            for i in stride(from: 0, to: chars.count, by: 2) {
                guard let b = UInt8(String(decoding: chars[i..<(i + 2)], as: UTF8.self), radix: 16)
                else { throw CocoaError(.coderInvalidValue) }
                out.append(b)
            }
            return out
        }
    }

    struct VPosition: Decodable {
        var latitude: Double
        var longitude: Double
        var altitudeM: Double?

        enum CodingKeys: String, CodingKey {
            case latitude, longitude
            case altitudeM = "altitude_m"
        }

        var proto: Leyline_V1_Position {
            var p = Leyline_V1_Position()
            p.latitude = latitude
            p.longitude = longitude
            if let altitudeM { p.altitudeM = altitudeM }
            return p
        }
    }

    struct VRecord: Decodable {
        var `protocol`: String?
        var kind: String?
        var deviceID: String?
        var position: VPosition?
        var rssiDbfs: Double?
        var snrDb: Double?
        var fields: [String: VValue]?
        var raw: String?

        enum CodingKeys: String, CodingKey {
            case `protocol`, kind, position, fields, raw
            case deviceID = "device_id"
            case rssiDbfs = "rssi_dbfs"
            case snrDb = "snr_db"
        }

        func proto() throws -> Leyline_V1_DecodeRecord {
            var r = Leyline_V1_DecodeRecord()
            r.protocol = self.protocol ?? ""
            r.kind = kind ?? ""
            r.deviceID = deviceID ?? ""
            if let position { r.position = position.proto }
            r.rssiDbfs = rssiDbfs ?? .nan
            r.snrDb = snrDb ?? .nan
            r.fields = try (fields ?? [:]).mapValues { try $0.proto() }
            r.raw = Data((raw ?? "").utf8)
            return r
        }
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return d
    }

    static func read<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        try decoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }

    // MARK: Summaries

    struct SummaryFile: Decodable {
        struct Case: Decodable {
            var name: String
            var display: String
            var record: VRecord
            var label: String?
            var summary: String
            var fallback: Bool?
        }
        var displays: [String: VDisplay]
        var cases: [Case]
    }

    func testEverySummaryCase() throws {
        let file = try Self.read("summary-cases.json", as: SummaryFile.self)
        XCTAssertGreaterThan(file.cases.count, 40)
        for c in file.cases {
            let display = try XCTUnwrap(file.displays[c.display], c.name).proto
            let rec = try c.record.proto()
            let label = c.label ?? ""
            if c.fallback == true {
                // A fallback case is one no template renders; the line is the client's own,
                // which this client ports, so it is checked too.
                if let t = DisplayTemplate.template(display, kind: rec.kind) {
                    XCTAssertNil(
                        DisplayTemplate.render(t, record: rec, label: label), "\(c.name) rendered")
                }
            }
            XCTAssertEqual(
                DisplayTemplate.summary(display, record: rec, label: label), c.summary, c.name)
        }
    }

    /// Every bundled manifest's display parses, so none falls back on every record, and the
    /// vectors' copy of a decoder's display is the one it ships.
    func testBundledDisplaysParseAndMatchTheVectors() throws {
        let file = try Self.read("summary-cases.json", as: SummaryFile.self)
        let decoders = Self.dir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("decoders")
        let names = try FileManager.default.contentsOfDirectory(atPath: decoders.path)
        var checked = 0
        for name in names {
            let url = decoders.appendingPathComponent(name).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            var opts = JSONDecodingOptions()
            opts.ignoreUnknownFields = true
            let m = try Leyline_V1_DecoderManifest(jsonUTF8Data: data, options: opts)
            for (kind, t) in m.display.summaries {
                XCTAssertTrue(DisplayTemplate.isValid(t), "\(name) summaries[\(kind)]")
            }
            if !m.display.entityName.isEmpty {
                XCTAssertTrue(DisplayTemplate.isValid(m.display.entityName), "\(name) entity")
            }
            for c in m.display.columns {
                XCTAssertTrue(DisplayTemplate.isValidColumn(c), "\(name) columns[\(c)]")
            }
            if let v = file.displays[name] {
                XCTAssertEqual(m.display, v.proto, name)
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 5)
    }

    // MARK: The fold

    struct FoldFile: Decodable {
        struct Step: Decodable {
            var atS: Double
            var record: VRecord?
            var expire: Bool?

            enum CodingKeys: String, CodingKey {
                case record, expire
                case atS = "at_s"
            }
        }
        struct Row: Decodable {
            var deviceID: String
            var `protocol`: String
            var name: String
            var kind: String
            var summary: String
            var count: Int
            var firstHeardS: Double
            var lastHeardS: Double
            var position: VPosition?
            var fields: [String: VValue]
            var columns: [String: String]

            enum CodingKeys: String, CodingKey {
                case `protocol`, name, kind, summary, count, position, fields, columns
                case deviceID = "device_id"
                case firstHeardS = "first_heard_s"
                case lastHeardS = "last_heard_s"
            }
        }
        var name: String
        var decoder: String
        var display: VDisplay
        var entitySilenceS: Double
        var steps: [Step]
        var rows: [Row]

        enum CodingKeys: String, CodingKey {
            case name, decoder, display, steps, rows
            case entitySilenceS = "entity_silence_s"
        }
    }

    func testEveryFoldVector() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.dir.path)
            .filter { $0.hasPrefix("fold-") && $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(names.isEmpty, "no fold vectors in \(Self.dir.path)")
        for file in names {
            let v = try Self.read(file, as: FoldFile.self)
            let epoch = Date(timeIntervalSince1970: 1_700_000_000)
            var table = EntityTable(display: v.display.proto)
            for step in v.steps {
                let now = epoch.addingTimeInterval(step.atS)
                if let r = step.record { table.apply(try r.proto(), at: now) }
                if step.expire == true { table.expire(now: now, silence: v.entitySilenceS) }
            }
            let rows = table.rows
            XCTAssertEqual(rows.count, v.rows.count, file)
            for (i, (got, want)) in zip(rows, v.rows).enumerated() {
                let at = "\(file) row \(i)"
                XCTAssertEqual(got.deviceID, want.deviceID, at)
                XCTAssertEqual(got.protocolName, want.protocol, at)
                XCTAssertEqual(table.name(of: got), want.name, at)
                XCTAssertEqual(got.kind, want.kind, at)
                XCTAssertEqual(got.summary, want.summary, at)
                XCTAssertEqual(got.count, want.count, at)
                XCTAssertEqual(got.firstHeard.timeIntervalSince(epoch), want.firstHeardS, at)
                XCTAssertEqual(got.lastHeard.timeIntervalSince(epoch), want.lastHeardS, at)
                XCTAssertEqual(got.position, want.position?.proto, at)
                XCTAssertEqual(got.fields, try want.fields.mapValues { try $0.proto() }, at)
                var columns: [String: String] = [:]
                for name in v.display.columns ?? [] {
                    if let c = table.column(name, of: got) { columns[name] = c }
                }
                XCTAssertEqual(columns, want.columns, at)
            }
        }
    }

    // MARK: Columns

    struct ColumnFile: Decodable {
        struct Case: Decodable {
            var name: String
            var column: String
            var record: VRecord
            var value: String?
            var valid: Bool
        }
        var cases: [Case]
    }

    /// A `columns` entry, `name` or `name:N`, prints as the template `{name}` or `{name:N}`
    /// would, and one with a bad precision never resolves.
    func testEveryColumnCase() throws {
        let file = try Self.read("column-cases.json", as: ColumnFile.self)
        XCTAssertGreaterThanOrEqual(file.cases.count, 10)
        for c in file.cases {
            var table = EntityTable()
            table.apply(try c.record.proto(), at: Date(timeIntervalSince1970: 1_700_000_000))
            let row = try XCTUnwrap(table.rows.first, c.name)
            XCTAssertEqual(table.column(c.column, of: row), c.value, c.name)
            XCTAssertEqual(DisplayTemplate.isValidColumn(c.column), c.valid, c.name)
        }
    }
}
