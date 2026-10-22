// SPDX-License-Identifier: Apache-2.0

// The command file's shapes (docs/dev/app.md, "The command file"), held to the keys
// `leyshots check` writes and reads, and the key spellings its `key` command sends.

import Foundation
import XCTest

@testable import LeylineClient

final class AppControlTests: XCTestCase {
    private func parse(_ json: String) -> ControlCommand.Parsed {
        ControlCommand.parse(Data(json.utf8))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEveryCommandOfTheProtocolParses() {
        XCTAssertEqual(
            parse(#"{"id":1,"cmd":"snapshot"}"#),
            .command(.init(id: 1, action: .snapshot(settle: 0))))
        XCTAssertEqual(
            parse(#"{"id":2,"cmd":"snapshot","settle":1.5}"#),
            .command(.init(id: 2, action: .snapshot(settle: 1.5))))
        XCTAssertEqual(parse(#"{"id":3,"cmd":"state"}"#), .command(.init(id: 3, action: .state)))
        XCTAssertEqual(parse(#"{"id":4,"cmd":"ax"}"#), .command(.init(id: 4, action: .ax)))
        XCTAssertEqual(
            parse(#"{"id":5,"cmd":"key","keys":"cmd+g"}"#),
            .command(
                .init(id: 5, action: .key(KeyChord(modifiers: [.command], key: .character("g"))))))
        XCTAssertEqual(
            parse(#"{"id":6,"cmd":"type","text":"wx3"}"#),
            .command(.init(id: 6, action: .type("wx3"))))
        XCTAssertEqual(
            parse(#"{"id":7,"cmd":"press","identifier":"transport.play"}"#),
            .command(.init(id: 7, action: .press(identifier: "transport.play"))))
        XCTAssertEqual(
            parse(#"{"id":8,"cmd":"wait","seconds":0.5}"#),
            .command(.init(id: 8, action: .wait(seconds: 0.5))))
        XCTAssertEqual(parse(#"{"id":9,"cmd":"quit"}"#), .command(.init(id: 9, action: .quit)))
        XCTAssertEqual(
            parse(#"{"id":10,"cmd":"stage","stage":{"place":"library","settle":1}}"#),
            .command(.init(id: 10, action: .stage(ShotStage(place: .library, settle: 1)))))
    }

    func testABadCommandIsRefusedWithItsId() {
        for line in [
            #"{"id":11,"cmd":"dance"}"#, #"{"id":12}"#, #"{"id":13,"cmd":"key","keys":"cmd+"}"#,
            #"{"id":14,"cmd":"wait","seconds":-1}"#, #"{"id":15,"cmd":"press"}"#,
            #"{"id":16,"cmd":"stage","stage":{"zoom":3}}"#, #"{"id":17,"cmd":"type","text":""}"#,
            #"{"id":18,"cmd":"stage","stage":{"place":"scan"}}"#,
        ] {
            guard case .refused(let id, let reason) = parse(line) else {
                return XCTFail("\(line) was not refused")
            }
            XCTAssertNotNil(id, line)
            XCTAssertFalse(reason.isEmpty, line)
        }
        guard case .refused(nil, _) = parse("not json") else { return XCTFail("not refused") }
        guard case .refused(nil, _) = parse(#"{"cmd":"state"}"#) else {
            return XCTFail("a command without an id was not refused")
        }
    }

    func testAnswersCarryTheProtocolKeys() throws {
        let answer = ControlAnswer(
            id: 7, ok: true, files: ["out/7.png"],
            result: try ControlAnswer.result(
                ControlSnapshot(
                    scale: 2, widthPt: 1440, heightPt: 820,
                    regions: [.window: .init(x: 0, y: 0, width: 1440, height: 820)])))
        let back = try object(AppControl.encoded(answer))
        XCTAssertEqual(back.keys.sorted(), ["error", "files", "id", "ok", "result"])
        XCTAssertEqual(back["files"] as? [String], ["out/7.png"])
        let result = try XCTUnwrap(back["result"] as? [String: Any])
        XCTAssertEqual(result.keys.sorted(), ["height_pt", "regions", "scale", "width_pt"])
        XCTAssertEqual(result["scale"] as? Double, 2)
        let regions = try XCTUnwrap(result["regions"] as? [String: [String: Double]])
        XCTAssertEqual(regions["window"]?["width"], 1440)
        XCTAssertEqual(ControlAnswer.path(id: 7), "out/7.json")

        let empty = try object(AppControl.encoded(ControlAnswer(id: 8, ok: false, error: "no")))
        XCTAssertEqual((empty["result"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual(empty["error"] as? String, "no")
    }

    func testReadyCarriesTheProtocolKeys() throws {
        let back = try object(
            AppControl.encoded(ControlReady(ok: true, pid: 123, windowNumber: 456, scale: 2)))
        XCTAssertEqual(back.keys.sorted(), ["error", "ok", "pid", "scale", "window_number"])
        XCTAssertEqual(back["window_number"] as? Int, 456)
        XCTAssertEqual(back["error"] as? String, "")
    }

    func testTheViewStateWritesEveryKeyNullWhenAbsent() throws {
        let back = try object(
            AppControl.encoded(ControlViewState(place: "radio", tunedHz: 162_475_000)))
        XCTAssertEqual(back["tuned_hz"] as? Int, 162_475_000)
        XCTAssertTrue(back["channel_id"] is NSNull)
        XCTAssertEqual(
            back.keys.sorted(),
            [
                "assistant_shown", "band", "bandwidth_hz", "bookmark", "capture_id", "channel_id",
                "filter_query", "focused", "inspector_shown", "mode", "notices", "open_rows",
                "place", "popover", "selected_part", "selected_recording_channel", "tuned_hz",
                "zoom",
            ])
    }

    func testTheEnvironmentStagesTheRunWithEitherVariable() {
        XCTAssertTrue(AppControl.isStaged(environment: ["LEYLINE_APP_CONTROL": "/c"]))
        XCTAssertTrue(AppControl.isStaged(environment: ["LEYLINE_APP_STAGE": "/s/stage.json"]))
        XCTAssertFalse(AppControl.isStaged(environment: ["LEYLINE_APP_CONTROL": ""]))
        XCTAssertEqual(AppControl.directory(environment: ["LEYLINE_APP_CONTROL": "/c"]), "/c")
    }

    func testOnlyCompleteLinesComeOut() {
        var lines = ControlLines()
        XCTAssertEqual(lines.append(Data(#"{"id":1,"cmd":"state"}"#.utf8)), [])
        XCTAssertEqual(
            lines.append(Data("\n\n  \n{\"id\":2,\"cmd\":\"ax\"}\n{\"id\"".utf8)),
            [Data(#"{"id":1,"cmd":"state"}"#.utf8), Data(#"{"id":2,"cmd":"ax"}"#.utf8)])
        XCTAssertEqual(
            lines.append(Data(":3,\"cmd\":\"quit\"}\n".utf8)),
            [Data(#"{"id":3,"cmd":"quit"}"#.utf8)])
    }

    func testAnswersAreReplacedWholeWithNoTempLeft() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ley-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("1.json")
        try AppControl.writeReplacing(Data("{}".utf8), to: url)
        try AppControl.writeReplacing(Data("{\"id\":1}".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"id\":1}")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["1.json"])
    }
}

final class KeyChordTests: XCTestCase {
    func testTheProtocolsSpellingsParse() throws {
        let g = try XCTUnwrap(KeyChord("cmd+g"))
        XCTAssertEqual(g.modifiers, [.command])
        XCTAssertEqual(g.characters, "g")
        XCTAssertEqual(g.keyCode, 5)
        let esc = try XCTUnwrap(KeyChord("escape"))
        XCTAssertEqual(esc.characters, "\u{1B}")
        XCTAssertEqual(esc.keyCode, 53)
        let down = try XCTUnwrap(KeyChord("down"))
        XCTAssertEqual(down.characters.unicodeScalars.first?.value, 0xF701)
        XCTAssertTrue(down.isFunctionKey)
        XCTAssertTrue(down.isArrow)
        let ret = try XCTUnwrap(KeyChord("return"))
        XCTAssertEqual(ret.characters, "\r")
        XCTAssertFalse(ret.isFunctionKey)
        XCTAssertEqual(KeyChord("Shift+Cmd+B")?.modifiers, [.shift, .command])
        XCTAssertEqual(KeyChord("cmd++")?.key, .character("+"))
        XCTAssertEqual(KeyChord("cmd+,")?.keyCode, 43)
    }

    func testUnknownSpellingsAreRefused() {
        XCTAssertNil(KeyChord("hyper+g"))
        XCTAssertNil(KeyChord("cmd+gg"))
        XCTAssertNil(KeyChord(""))
        XCTAssertNil(KeyChord("cmd+"))
    }

    func testTypingACapitalHoldsShift() {
        XCTAssertEqual(KeyChord.typing("W").modifiers, [.shift])
        XCTAssertEqual(KeyChord.typing("W").charactersIgnoringModifiers, "w")
        XCTAssertEqual(KeyChord.typing("W").keyCode, 13)
        XCTAssertEqual(KeyChord.typing("3").modifiers, [])
    }
}
