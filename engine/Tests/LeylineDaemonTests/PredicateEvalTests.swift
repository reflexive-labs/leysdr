// SPDX-License-Identifier: GPL-3.0-or-later

// The stateless predicate evaluator, judged directly on hand-built records (docs/design/decoders.md,
// "Predicates and delivery"): every operator, numeric vs text, CONTAINS on a FIPS list, geo in and
// out, the empty predicate, and a field that is not there.

@testable import LeylineDaemon
import LeylineProto
import XCTest

final class PredicateEvalTests: XCTestCase {
    // MARK: builders

    private func text(_ s: String) -> Leyline_V1_FieldValue { var v = Leyline_V1_FieldValue(); v.text = s; return v }
    private func number(_ d: Double) -> Leyline_V1_FieldValue { var v = Leyline_V1_FieldValue(); v.number = d; return v }

    private func fieldClause(_ field: String, _ op: Leyline_V1_PredicateOp,
                             _ values: [Leyline_V1_FieldValue] = []) -> Leyline_V1_Clause
    {
        var t = Leyline_V1_FieldTest()
        t.field = field
        t.op = op
        t.values = values
        var c = Leyline_V1_Clause()
        c.field = t
        return c
    }

    private func predicate(_ clauses: [Leyline_V1_Clause]) -> Leyline_V1_Predicate {
        var p = Leyline_V1_Predicate()
        p.all = clauses
        return p
    }

    private func record(deviceID: String = "", kind: String = "", proto: String = "",
                        fields: [String: Leyline_V1_FieldValue] = [:],
                        position: (lat: Double, lon: Double)? = nil) -> Leyline_V1_DecodeRecord
    {
        var r = Leyline_V1_DecodeRecord()
        r.deviceID = deviceID
        r.kind = kind
        r.protocol = proto
        r.fields = fields
        if let position {
            r.position.latitude = position.lat
            r.position.longitude = position.lon
        }
        return r
    }

    // MARK: tests

    func testEmptyPredicateMatchesEverything() {
        XCTAssertTrue(matches(record(deviceID: "FAKE-1"), Leyline_V1_Predicate()))
    }

    func testEqAndNeOnAPromotedString() {
        let r = record(deviceID: "N0CALL-9")
        XCTAssertTrue(matches(r, predicate([fieldClause("device_id", .predEq, [text("N0CALL-9")])])))
        XCTAssertFalse(matches(r, predicate([fieldClause("device_id", .predEq, [text("N0TEST")])])))
        XCTAssertTrue(matches(r, predicate([fieldClause("device_id", .predNe, [text("N0TEST")])])))
        // Text compare is case- and space-insensitive.
        XCTAssertTrue(matches(r, predicate([fieldClause("device_id", .predEq, [text(" n0call-9 ")])])))
    }

    func testNumericComparisonsAreNumberAware() {
        let r = record(fields: ["altitude_m": number(1500)])
        XCTAssertTrue(matches(r, predicate([fieldClause("altitude_m", .predLt, [number(3000)])])))
        XCTAssertFalse(matches(r, predicate([fieldClause("altitude_m", .predGt, [number(3000)])])))
        XCTAssertTrue(matches(r, predicate([fieldClause("altitude_m", .predGte, [number(1500)])])))
        XCTAssertTrue(matches(r, predicate([fieldClause("altitude_m", .predLte, [number(1500)])])))
        // "9" < "10" numerically, though as text "9" > "10".
        let n = record(fields: ["n": number(9)])
        XCTAssertTrue(matches(n, predicate([fieldClause("n", .predLt, [number(10)])])))
        // EQ on numbers ignores formatting: 1500 == 1500.0.
        XCTAssertTrue(matches(r, predicate([fieldClause("altitude_m", .predEq, [text("1500")])])))
    }

    func testOrderingOperatorsAreFalseOnNonNumbers() {
        let r = record(deviceID: "N0TEST")
        XCTAssertFalse(matches(r, predicate([fieldClause("device_id", .predLt, [number(5)])])))
        XCTAssertFalse(matches(r, predicate([fieldClause("device_id", .predGt, [text("A")])])))
    }

    func testInAndNotIn() {
        let r = record(deviceID: "FAKE-2")
        XCTAssertTrue(matches(r, predicate([fieldClause("device_id", .predIn, [text("FAKE-1"), text("FAKE-2")])])))
        XCTAssertFalse(matches(r, predicate([fieldClause("device_id", .predIn, [text("FAKE-1"), text("FAKE-3")])])))
        XCTAssertTrue(matches(r, predicate([fieldClause("device_id", .predNotIn, [text("FAKE-1")])])))
        // NOT_IN on a missing field is true; IN on a missing field is false.
        XCTAssertTrue(matches(record(), predicate([fieldClause("nope", .predNotIn, [text("x")])])))
        XCTAssertFalse(matches(record(), predicate([fieldClause("nope", .predIn, [text("x")])])))
    }

    func testContainsOnAFipsList() {
        // A SAME alert's FIPS county list, both delimiter styles.
        let dash = record(fields: ["fips": text("006001-006013")])
        let space = record(fields: ["fips": text("006001 006013")])
        XCTAssertTrue(matches(dash, predicate([fieldClause("fips", .predContains, [text("006013")])])))
        XCTAssertTrue(matches(space, predicate([fieldClause("fips", .predContains, [text("006001")])])))
        XCTAssertFalse(matches(dash, predicate([fieldClause("fips", .predContains, [text("006009")])])))
    }

    func testExists() {
        XCTAssertTrue(matches(record(deviceID: "x"), predicate([fieldClause("device_id", .predExists)])))
        XCTAssertFalse(matches(record(), predicate([fieldClause("device_id", .predExists)])))
        XCTAssertTrue(matches(record(fields: ["k": text("v")]), predicate([fieldClause("k", .predExists)])))
        XCTAssertFalse(matches(record(fields: ["k": text("")]), predicate([fieldClause("k", .predExists)])))
    }

    func testMissingFieldFailsScalarTests() {
        let r = record(deviceID: "x")
        XCTAssertFalse(matches(r, predicate([fieldClause("missing", .predEq, [text("y")])])))
        XCTAssertFalse(matches(r, predicate([fieldClause("missing", .predGt, [number(1)])])))
    }

    func testGeoInAndOut() {
        var near = Leyline_V1_GeoTest()
        near.center.latitude = 37.0
        near.center.longitude = -122.0
        near.radiusM = 10_000
        var clause = Leyline_V1_Clause()
        clause.geo = near
        // ~1.5 km away is in; 10 degrees away is out; no position is out.
        XCTAssertTrue(matches(record(position: (37.01, -122.0)), predicate([clause])))
        XCTAssertFalse(matches(record(position: (47.0, -122.0)), predicate([clause])))
        XCTAssertFalse(matches(record(), predicate([clause])))
    }

    func testAndOverClauses() {
        let r = record(deviceID: "FAKE-2", kind: "position")
        XCTAssertTrue(matches(r, predicate([
            fieldClause("device_id", .predEq, [text("FAKE-2")]),
            fieldClause("kind", .predEq, [text("position")]),
        ])))
        XCTAssertFalse(matches(r, predicate([
            fieldClause("device_id", .predEq, [text("FAKE-2")]),
            fieldClause("kind", .predEq, [text("weather")]),
        ])))
    }
}
