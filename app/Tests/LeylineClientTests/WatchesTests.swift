// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import SwiftProtobuf
import XCTest

@testable import LeylineClient

/// Watches (DA-10): the predicate the Notify Me… sheet builds is the one `ley watch` sends for the
/// same input. testdata/decoders/watch-cases.json holds the cases, which
/// go/internal/cli/watch_vectors_test.go runs against `buildPredicate`.
final class WatchesTests: XCTestCase {
    struct Case: Decodable {
        var name: String
        var `where`: [String]?
        var county: [String]?
        var near: String?
        var radius: String?
        var predicate: JSONValue?
        var error: Bool?
    }

    struct File: Decodable { var cases: [Case] }

    func testTheSharedVectors() throws {
        let url = DecoderVectorsTests.dir.appendingPathComponent("watch-cases.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        XCTAssertFalse(file.cases.isEmpty)
        for c in file.cases {
            let built: Leyline_V1_Predicate?
            do {
                built = try Watches.predicate(
                    where: c.where ?? [], counties: c.county ?? [], near: c.near ?? "",
                    radius: c.radius ?? "")
            } catch {
                XCTAssertTrue(c.error ?? false, "\(c.name): refused with \(error)")
                continue
            }
            XCTAssertFalse(c.error ?? false, "\(c.name): built \(String(describing: built))")
            var want: Leyline_V1_Predicate?
            if let p = c.predicate, p != .null {
                let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
                want = try Leyline_V1_Predicate(jsonString: json)
            }
            XCTAssertEqual(built, want, c.name)
        }
    }

    func manifest() -> Leyline_V1_DecoderManifest {
        var m = Leyline_V1_DecoderManifest()
        m.name = "same"
        m.fields = [
            .with {
                $0.name = "fips"
                $0.label = "County"
                $0.type = .text
                $0.description_p = "affected counties"
            },
            .with {
                $0.name = "event_count"
                $0.type = .integer
            },
            .with {
                $0.name = "temp_c"
                $0.type = .number
            },
            .with {
                $0.name = "alive"
                $0.type = .flag
            },
        ]
        return m
    }

    func testTheSheetOffersTextAndIntegerFieldsAfterTheDevice() {
        let fields = Watches.fields(manifest())
        XCTAssertEqual(fields.map(\.name), ["device_id", "fips", "event_count"])
        // The pop-up reads labels: the promoted device_id is the transmitter, and a field with
        // no label goes by its name.
        XCTAssertEqual(fields.map(\.label), ["Transmitter", "County", "event_count"])
        XCTAssertEqual(Watches.tests(for: .text), [.equals, .contains])
        XCTAssertEqual(Watches.tests(for: .integer), [.equals, .above, .below])
    }

    /// SAME's county is its `fips` field, tested as `--county` and `--where fips~` test it: the
    /// sheet's "contains" is the same CONTAINS clause.
    func testTheSheetBuildsWhatLeyWatchSends() throws {
        let sheet = try Watches.predicate(field: "fips", test: .contains, value: " 06009 ")
        XCTAssertEqual(sheet, try Watches.predicate(where: ["fips~06009"]))
        XCTAssertEqual(sheet, try Watches.predicate(counties: ["006009"]))
        let both = try Watches.predicate(
            field: "device_id", test: .equals, value: "N0CALL-3", near: "37.76,-122.42",
            radius: "10km")
        XCTAssertEqual(
            both,
            try Watches.predicate(
                where: ["device_id=N0CALL-3"], near: "37.76,-122.42", radius: "10km"))
        let place = try Watches.predicate(
            field: "device_id", test: .equals, value: "", near: "37.76,-122.42", radius: "10km")
        XCTAssertEqual(place.all.count, 1)
        XCTAssertThrowsError(try Watches.predicate(field: "fips", test: .equals, value: " "))
        XCTAssertThrowsError(
            try Watches.predicate(field: "event_count", test: .above, value: "many"))
    }

    func testAWatchIsAJobWithAPredicate() throws {
        var m = Leyline_V1_DecoderManifest()
        m.name = "aprs"
        func job(_ id: String, predicate: Bool, state: Leyline_V1_JobState = .running)
            -> Leyline_V1_Job
        {
            .with {
                $0.jobID = id
                $0.state = state
                $0.config = .decode(
                    .with {
                        $0.decoder = "aprs"
                        if predicate { $0.predicate = .with { $0.all = [] } }
                    })
            }
        }
        let jobs = [
            job("job_1", predicate: false), job("job_2", predicate: true),
            job("job_3", predicate: true, state: .cancelled), job("job_4", predicate: true),
        ]
        XCTAssertEqual(Watches.watches(of: m, in: jobs).map(\.jobID), ["job_4", "job_2"])
        XCTAssertEqual(DecoderPages.jobs(of: m, in: jobs).map(\.jobID), ["job_1"])
        XCTAssertTrue(Watches.isWatch(jobs[1]))
        XCTAssertFalse(Watches.isWatch(jobs[0]))
    }

    func testTheConfigIsAKeptJobThatNotifies() throws {
        let p = try XCTUnwrap(try Watches.predicate(where: ["device_id=N0CALL-3"]))
        let c = Watches.config(decoder: "aprs", frequencyHz: 144_390_000, predicate: p)
        XCTAssertTrue(c.keep)
        XCTAssertFalse(c.takeOver)
        XCTAssertEqual(c.frequencyHz, 144_390_000)
        XCTAssertEqual(c.predicate, p)
        XCTAssertTrue(c.notify.macosNotification)
    }

    func testTheConditionInWords() throws {
        var m = manifest()
        m.fields.append(
            .with {
                $0.name = "callsign"
                $0.label = "Callsign"
                $0.type = .text
            })
        m.fields.append(
            .with {
                $0.name = "altitude_ft"
                $0.label = "Altitude"
                $0.type = .integer
                $0.unit = "ft"
            })
        func words(_ p: Leyline_V1_Predicate?) -> String {
            Watches.words(p ?? .init(), manifest: m)
        }
        XCTAssertEqual(words(try Watches.predicate(where: ["fips=06009"])), "County is 06009")
        XCTAssertEqual(
            words(try Watches.predicate(counties: ["06009", "06001"])),
            "County contains 06009 or 06001")
        XCTAssertEqual(
            words(try Watches.predicate(where: ["callsign~K6"])), "Callsign contains K6")
        XCTAssertEqual(
            words(try Watches.predicate(where: ["altitude_ft>10000"])),
            "Altitude is over 10000")
        XCTAssertEqual(
            words(try Watches.predicate(where: ["altitude_ft<500"])), "Altitude is under 500")
        // No label: the name.
        XCTAssertEqual(words(try Watches.predicate(where: ["temp_c>25.5"])), "temp_c is over 25.5")
        XCTAssertEqual(
            Watches.words(
                try XCTUnwrap(try Watches.predicate(where: ["fips=06009"])), manifest: nil),
            "fips is 06009")
        XCTAssertEqual(
            words(
                try Watches.predicate(
                    where: ["device_id=N0CALL-3"], near: "37.76,-122.42", radius: "10km")),
            "Transmitter is N0CALL-3 and within 10 km of 37.7600N 122.4200W")
        XCTAssertEqual(
            words(try Watches.predicate(near: "0,0", radius: "500m")),
            "within 500 m of 0.0000N 0.0000E")
        XCTAssertEqual(words(nil), "every record")
    }
}
