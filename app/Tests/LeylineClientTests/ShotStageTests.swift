// SPDX-License-Identifier: Apache-2.0

// The stage file `leyshots` writes and the `regions.json` the app writes back
// (docs/dev/app.md, "Staged runs"), held to the keys the Go driver uses.

import Foundation
import XCTest

@testable import LeylineClient

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

final class ShotStageTests: XCTestCase {
    private func stageFile(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ley-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stage.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    func testEveryKeyTheDriverWritesIsRead() throws {
        let url = try stageFile(
            """
            {"window":{"width":1440,"height":820},"place":"library","inspector":true,
             "expanded_band":"2m","select_bookmark":"Calling","select_part":2,
             "import_chirp":"/tmp/handheld.csv","settle":4.5,"on_air":true}
            """)
        let stage = try ShotStage.read(at: url)
        XCTAssertEqual(
            stage,
            ShotStage(
                window: .init(width: 1440, height: 820), place: .library, inspector: true,
                expandedBand: "2m", selectBookmark: "Calling", selectPart: 2,
                importCHIRP: "/tmp/handheld.csv", settle: 4.5, onAir: true))
    }

    func testAbsentKeysLeaveTheWindowAsLaunched() throws {
        let stage = try ShotStage.read(at: try stageFile("{}"))
        XCTAssertEqual(stage, ShotStage())
        XCTAssertEqual(stage.settle, 0)
    }

    func testUnknownPlaceIsRefused() throws {
        XCTAssertThrowsError(try ShotStage.read(at: try stageFile(#"{"place":"scan"}"#)))
    }

    func testUnusableNumbersAreRefused() throws {
        XCTAssertThrowsError(try ShotStage.read(at: try stageFile(#"{"settle":-1}"#)))
        XCTAssertThrowsError(
            try ShotStage.read(at: try stageFile(#"{"window":{"width":0,"height":820}}"#)))
        XCTAssertThrowsError(try ShotStage.read(at: try stageFile(#"{"select_part":-1}"#)))
    }

    func testThePathComesFromTheVariableAndAnEmptyOneIsUnset() {
        XCTAssertEqual(
            ShotStage.path(environment: ["LEYLINE_APP_STAGE": "/s/stage.json"]), "/s/stage.json")
        XCTAssertNil(ShotStage.path(environment: ["LEYLINE_APP_STAGE": ""]))
        XCTAssertNil(ShotStage.path(environment: [:]))
        XCTAssertEqual(
            ShotStage.regionsURL(besideStage: URL(fileURLWithPath: "/s/stage.json")).path,
            "/s/regions.json")
    }

    func testAWindowRectIsMeasuredFromTheTopLeft() throws {
        // An 820 pt window: a sidebar from 52 pt below the top to 41 pt above the bottom.
        let r = try XCTUnwrap(
            ShotRegions.Rect(
                windowRect: CGRect(x: 0, y: 41, width: 236, height: 727), windowHeight: 820))
        XCTAssertEqual(r, ShotRegions.Rect(x: 0, y: 52, width: 236, height: 727))
        XCTAssertNil(ShotRegions.Rect(windowRect: .zero, windowHeight: 820))
    }

    func testRegionsAreWrittenUnderTheirNames() throws {
        let url = try stageFile("{}").deletingLastPathComponent()
            .appendingPathComponent("regions.json")
        let regions = ShotRegions(
            windowNumber: 4242,
            regions: [
                .window: .init(x: 0, y: 0, width: 1440, height: 820),
                .toolbar: .init(x: 0, y: 0, width: 1440, height: 52),
            ])
        try regions.write(to: url)
        let back = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(back?["window_number"] as? Int, 4242)
        let named = back?["regions"] as? [String: [String: Double]]
        XCTAssertEqual(named?["toolbar"], ["x": 0, "y": 0, "width": 1440, "height": 52])
        XCTAssertEqual(named?.keys.sorted(), ["toolbar", "window"])
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers.sorted(), ["regions.json", "stage.json"])
    }
}
