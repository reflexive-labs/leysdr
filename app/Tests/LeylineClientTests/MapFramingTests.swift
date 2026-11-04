// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class MapFramingTests: XCTestCase {
    func at(_ lat: Double, _ lon: Double) -> MapCoordinate {
        MapCoordinate(latitude: lat, longitude: lon)
    }

    func testTheFirstPositionsAreFramedOnce() throws {
        var f = MapFraming()
        XCTAssertNil(f.update([]), "no position, no camera")
        let first = try XCTUnwrap(f.update([at(37.0, -122.0), at(38.0, -121.0)]))
        XCTAssertEqual(first.latitude, 37.5, accuracy: 1e-9)
        XCTAssertEqual(first.longitude, -121.5, accuracy: 1e-9)
        XCTAssertEqual(first.latitudeSpan, 1.0 * (1 + 2 * MapFraming.padding), accuracy: 1e-9)
        XCTAssertTrue(f.following)
        // The same positions, or ones moved inside the region, leave the camera.
        XCTAssertNil(f.update([at(37.0, -122.0), at(38.0, -121.0)]))
        XCTAssertNil(f.update([at(37.2, -121.8), at(37.9, -121.1)]))
        XCTAssertEqual(f.region, first)
    }

    func testOneTransmitterIsFramedAtTheLeastSpan() throws {
        var f = MapFraming()
        let r = try XCTUnwrap(f.update([at(51.5, -0.1)]))
        XCTAssertEqual(r.latitudeSpan, MapFraming.leastSpan)
        XCTAssertEqual(r.longitudeSpan, MapFraming.leastSpan)
    }

    func testItOnlyZoomsOut() throws {
        var f = MapFraming()
        let first = try XCTUnwrap(f.update([at(37.0, -122.0), at(38.0, -121.0)]))
        // One flies out to the north: the region grows to hold it and still holds the old one.
        let grown = try XCTUnwrap(f.update([at(37.0, -122.0), at(38.0, -121.0), at(39.0, -121.5)]))
        XCTAssertGreaterThanOrEqual(grown.north, 39.0)
        XCTAssertLessThanOrEqual(grown.south, first.south)
        XCTAssertLessThanOrEqual(grown.west, first.west)
        XCTAssertGreaterThanOrEqual(grown.east, first.east)
        // Nearer the edge than the margin counts as outside.
        let edge = grown.north - grown.latitudeSpan * MapFraming.margin / 2
        XCTAssertNotNil(f.update([at(edge, -121.5)]))
        // All gathered in one corner: it never zooms in.
        let before = try XCTUnwrap(f.region)
        XCTAssertNil(f.update([at(37.5, -121.5)]))
        XCTAssertEqual(f.region, before)
    }

    func testATransmitterGoneNeverMovesTheCamera() throws {
        var f = MapFraming()
        let first = try XCTUnwrap(f.update([at(37.0, -122.0), at(38.0, -121.0), at(37.5, -121.5)]))
        XCTAssertNil(f.update([at(37.5, -121.5)]))
        XCTAssertNil(f.update([]))
        XCTAssertEqual(f.region, first)
    }

    func testThePersonsMoveStopsTheRuleUntilFitAll() throws {
        var f = MapFraming()
        _ = try XCTUnwrap(f.update([at(37.0, -122.0), at(38.0, -121.0)]))
        let theirs = MapRegion(
            latitude: 37.2, longitude: -121.9, latitudeSpan: 0.2, longitudeSpan: 0.2)
        f.personMoved(to: theirs)
        XCTAssertFalse(f.following)
        // A transmitter far outside their view: the camera stays theirs.
        XCTAssertNil(f.update([at(37.0, -122.0), at(40.0, -118.0)]))
        XCTAssertEqual(f.region, theirs)
        // Fit All frames everything, closer or wider, and the rule follows again.
        let fit = try XCTUnwrap(f.fitAll([at(37.0, -122.0), at(40.0, -118.0)]))
        XCTAssertTrue(f.following)
        XCTAssertEqual(fit.latitude, 38.5, accuracy: 1e-9)
        XCTAssertNotNil(f.update([at(37.0, -122.0), at(42.0, -118.0)]))
    }
}

final class DecoderFoldTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ id: String, device: String, lat: Double? = nil, at s: Double) -> RecordEntry {
        var r = Leyline_V1_DecodeRecord()
        r.recordID = id
        r.protocol = "adsb"
        r.deviceID = device
        r.kind = "position"
        if let lat {
            var p = Leyline_V1_Position()
            p.latitude = lat
            p.longitude = -122
            r.position = p
        }
        return RecordEntry(record: r, at: t0.addingTimeInterval(s), dated: true)
    }

    /// The session's fold is not touched by a tab switch, a job event, the plan's clock or a
    /// selection; what can reach it is a history read again when the stream reopens (after an
    /// error, or a daemon restart). That merges: it never clears, never drops a transmitter whose
    /// records the log has let go, and never moves the camera back.
    func testAHistoryReadAgainMergesAndNeverClears() throws {
        var f = DecoderFold()
        f.landHistory([entry("r1", device: "A", lat: 37.0, at: 0)], truncated: false)
        let framed = try XCTUnwrap(f.framing.region)
        // Live records past the log's limit: A's own records leave the log, A stays.
        for i in 0..<(DecoderPages.logLimit + 5) {
            f.landLive(entry("live\(i)", device: "B", lat: 37.01, at: 1 + Double(i) * 0.01))
        }
        XCTAssertFalse(f.records.entries.contains { $0.record.deviceID == "A" })
        XCTAssertNotNil(f.table.entities["A"])
        XCTAssertEqual(f.table.entities["B"]?.count, DecoderPages.logLimit + 5)
        // The stream reopens and the history lands again, with one record missed meanwhile.
        let missed = entry("gap", device: "C", lat: 37.02, at: 5)
        let added = f.landHistory(
            f.records.entries + [missed, entry("r1", device: "A", lat: 37.0, at: 0)],
            truncated: true)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(Set(f.table.entities.keys), ["A", "B", "C"])
        XCTAssertEqual(f.table.entities["B"]?.count, DecoderPages.logLimit + 5)
        XCTAssertEqual(f.framing.region, framed, "nothing outside the framed region")
        // The same live record twice is folded once.
        let newest = DecoderPages.logLimit + 4
        XCTAssertFalse(
            f.landLive(
                entry("live\(newest)", device: "B", lat: 37.01, at: 1 + Double(newest) * 0.01)))
    }

    func testAnOlderRecordMergedLeavesTheNewestValues() throws {
        var f = DecoderFold()
        f.landLive(entry("new", device: "A", lat: 37.5, at: 10))
        var old = entry("old", device: "A", lat: 37.0, at: 2)
        old.record.kind = "identification"
        old.record.fields["callsign"] = .with { $0.text = "LEY101" }
        f.landHistory([old], truncated: false)
        let a = try XCTUnwrap(f.table.entities["A"])
        XCTAssertEqual(a.position?.latitude, 37.5)
        XCTAssertEqual(a.kind, "position")
        XCTAssertEqual(a.lastHeard, t0.addingTimeInterval(10))
        XCTAssertEqual(a.firstHeard, t0.addingTimeInterval(2))
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a.fields["callsign"]?.text, "LEY101")
        XCTAssertEqual(a.trail.map(\.latitude), [37.0, 37.5])
    }

    func testATransmitterFadesAtHalfItsSilenceAndGoesAtIt() throws {
        var f = DecoderFold()
        f.landLive(entry("a", device: "A", lat: 37.0, at: 0))
        f.landLive(entry("b", device: "B", lat: 37.5, at: 0))
        f.landLive(entry("b2", device: "B", lat: 37.6, at: 100))
        let framed = f.framing.region
        let a = try XCTUnwrap(f.table.entities["A"])
        XCTAssertFalse(EntityTable.fading(a, now: t0.addingTimeInterval(60), silence: 120))
        XCTAssertTrue(EntityTable.fading(a, now: t0.addingTimeInterval(61), silence: 120))
        XCTAssertFalse(EntityTable.fading(a, now: t0.addingTimeInterval(1e6), silence: 0))
        XCTAssertEqual(f.expire(now: t0.addingTimeInterval(120), silence: 120), 0)
        XCTAssertEqual(f.expire(now: t0.addingTimeInterval(121), silence: 120), 1)
        XCTAssertNil(f.table.entities["A"], "its trail goes with it")
        XCTAssertNotNil(f.table.entities["B"])
        XCTAssertEqual(f.framing.region, framed, "an aircraft gone never moves the camera")
    }
}
