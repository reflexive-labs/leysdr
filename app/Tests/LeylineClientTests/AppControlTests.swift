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
            .command(.init(id: 1, action: .snapshot(settle: 0, window: .main))))
        XCTAssertEqual(
            parse(#"{"id":2,"cmd":"snapshot","settle":1.5}"#),
            .command(.init(id: 2, action: .snapshot(settle: 1.5, window: .main))))
        XCTAssertEqual(
            parse(#"{"id":2,"cmd":"snapshot","window":"settings"}"#),
            .command(.init(id: 2, action: .snapshot(settle: 0, window: .settings))))
        XCTAssertEqual(
            parse(#"{"id":2,"cmd":"snapshot","window":"popover"}"#),
            .refused(id: 2, reason: "a snapshot's window must be main or settings"))
        XCTAssertEqual(parse(#"{"id":3,"cmd":"state"}"#), .command(.init(id: 3, action: .state)))
        XCTAssertEqual(
            parse(#"{"id":4,"cmd":"ax"}"#), .command(.init(id: 4, action: .ax(window: .main))))
        XCTAssertEqual(
            parse(#"{"id":4,"cmd":"ax","window":"settings"}"#),
            .command(.init(id: 4, action: .ax(window: .settings))))
        XCTAssertEqual(
            parse(#"{"id":4,"cmd":"ax","window":"sheet"}"#),
            .command(.init(id: 4, action: .ax(window: .sheet))))
        XCTAssertEqual(
            parse(#"{"id":4,"cmd":"ax","window":"dock"}"#),
            .refused(id: 4, reason: "window must be main, settings, popover or sheet"))
        XCTAssertEqual(
            parse(#"{"id":20,"cmd":"hover","identifier":"rail.track"}"#),
            .command(.init(id: 20, action: .hover(.identifier("rail.track")))))
        XCTAssertEqual(
            parse(#"{"id":21,"cmd":"click","x":10,"y":20.5,"button":"right"}"#),
            .command(.init(id: 21, action: .click(.point(x: 10, y: 20.5), right: true))))
        XCTAssertEqual(
            parse(#"{"id":22,"cmd":"click","identifier":"rail.track"}"#),
            .command(.init(id: 22, action: .click(.identifier("rail.track"), right: false))))
        XCTAssertEqual(
            parse(#"{"id":25,"cmd":"drag","identifier":"rail.thumb","dx":-40}"#),
            .command(.init(id: 25, action: .drag(.identifier("rail.thumb"), dx: -40, dy: 0))))
        XCTAssertEqual(
            parse(#"{"id":26,"cmd":"drag","x":500,"y":60,"dx":10,"dy":2}"#),
            .command(.init(id: 26, action: .drag(.point(x: 500, y: 60), dx: 10, dy: 2))))
        XCTAssertEqual(
            parse(#"{"id":23,"cmd":"menu","menu":"View>Show Assistant","read":true}"#),
            .command(.init(id: 23, action: .menu(path: "View>Show Assistant", read: true))))
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
            parse(
                #"{"id":24,"cmd":"pick","identifier":"settings.ai.usage.period","text":"By month"}"#
            ),
            .command(
                .init(
                    id: 24, action: .pick(identifier: "settings.ai.usage.period", item: "By month"))
            ))
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
            #"{"id":19,"cmd":"hover"}"#, #"{"id":19,"cmd":"hover","x":1}"#,
            #"{"id":19,"cmd":"hover","identifier":"a","x":1,"y":2}"#,
            #"{"id":19,"cmd":"hover","identifier":"a","button":"right"}"#,
            #"{"id":19,"cmd":"click","identifier":"a","button":"middle"}"#,
            #"{"id":19,"cmd":"menu"}"#, #"{"id":19,"cmd":"menu","menu":"View>"}"#,
            #"{"id":20,"cmd":"pick","identifier":"a"}"#, #"{"id":20,"cmd":"pick","text":"b"}"#,
            #"{"id":21,"cmd":"drag","identifier":"a"}"#,
            #"{"id":21,"cmd":"drag","identifier":"a","dx":0,"dy":0}"#,
            #"{"id":21,"cmd":"drag","dx":5}"#,
            #"{"id":21,"cmd":"drag","identifier":"a","dx":5,"button":"right"}"#,
            #"{"id":21,"cmd":"click","identifier":"a","dx":5}"#,
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
                "alert", "assistant", "assistant_shown", "band", "bandwidth_hz", "bookmark",
                "capture", "capture_id", "channel_id", "filter_caret", "filter_query", "focused",
                "heard", "hits", "inspector_shown", "mode", "muted", "notices", "open_rows",
                "place",
                "popover", "selected_part", "selected_recording_channel", "settings_open", "sink",
                "tooltip", "transport", "tuned_hz", "view", "volume", "window",
            ])
        for key in [
            "alert", "assistant", "capture", "filter_caret", "tooltip", "transport", "view",
            "volume", "window",
        ] {
            XCTAssertTrue(back[key] is NSNull, key)
        }
    }

    func testStateNestsItsObjectsInSnakeCase() throws {
        let state = ControlViewState(
            place: "radio",
            window: ControlWindowSize(width: 1440, height: 820, minWidth: 980, minHeight: 600),
            alert: ControlAlert(title: "Move the radio?", buttons: ["Cancel", "Move"]),
            view: ControlView(
                loHz: 146_000_000, hiHz: 147_000_000, thumbLoHz: 146_000_000,
                thumbHiHz: 147_000_000),
            capture: ControlSpan(loHz: 144_960_000, hiHz: 147_840_000),
            assistant: ControlAssistant(
                turns: [.init(role: "user", text: "hi")], inputFocused: true,
                buttons: [.init(id: "assistant.new", title: "New", enabled: false)]))
        let back = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AppControl.encoded(state)) as? [String: Any])
        let window = try XCTUnwrap(back["window"] as? [String: Any])
        XCTAssertEqual(window["min_width"] as? Int, 980)
        let alert = try XCTUnwrap(back["alert"] as? [String: Any])
        XCTAssertTrue(alert["message"] is NSNull)
        XCTAssertEqual(alert["buttons"] as? [String], ["Cancel", "Move"])
        let view = try XCTUnwrap(back["view"] as? [String: Any])
        XCTAssertEqual(view["hi_hz"] as? Int, 147_000_000)
        XCTAssertEqual(view["span_hz"] as? Int, 1_000_000)
        XCTAssertEqual(view["thumb_lo_hz"] as? Int, 146_000_000)
        XCTAssertTrue(view["edge"] is NSNull)
        XCTAssertEqual((back["capture"] as? [String: Any])?["lo_hz"] as? Int, 144_960_000)
        let assistant = try XCTUnwrap(back["assistant"] as? [String: Any])
        XCTAssertEqual(assistant["input_focused"] as? Bool, true)
        XCTAssertTrue(assistant["state"] is NSNull)
        XCTAssertEqual(
            ((assistant["buttons"] as? [[String: Any]])?.first)?["enabled"] as? Bool, false)
        XCTAssertEqual(back["sink"] as? String, "none")
    }

    func testTheTransportsWordsAreWrittenEveryKeyInSnakeCase() throws {
        let state = ControlViewState(
            place: "radio", tunedHz: 146_940_186,
            transport: ControlTransport(
                tuning: "146.9401", squelchCaption: "open · 33 dB", squelchCaptionShort: true))
        let back = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AppControl.encoded(state)) as? [String: Any])
        let transport = try XCTUnwrap(back["transport"] as? [String: Any])
        XCTAssertEqual(
            transport.keys.sorted(),
            ["squelch_caption", "squelch_caption_short", "squelch_words", "tuning"])
        XCTAssertEqual(transport["squelch_caption_short"] as? Bool, true)
        XCTAssertEqual(transport["tuning"] as? String, "146.9401")
        XCTAssertEqual(transport["squelch_caption"] as? String, "open · 33 dB")
        XCTAssertEqual(transport["squelch_words"] as? String, "")
        XCTAssertEqual(back["tuned_hz"] as? Int, 146_940_186)
        let again = try JSONDecoder().decode(
            ControlViewState.self, from: AppControl.encoded(state))
        XCTAssertEqual(again.transport, state.transport)
        let empty = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AppControl.encoded(ControlTransport()))
                as? [String: Any])
        XCTAssertTrue(empty["tuning"] is NSNull)
        XCTAssertTrue(empty["squelch_caption"] is NSNull)
        XCTAssertTrue(empty["squelch_caption_short"] is NSNull)
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

    func testASlugIsOneLowercaseWordOfTheIdentifier() {
        XCTAssertEqual(ViewIdentifier.slug("Calling"), "calling")
        XCTAssertEqual(ViewIdentifier.slug("Club repeater"), "club-repeater")
        XCTAssertEqual(ViewIdentifier.slug("  GMRS CH3 (local) "), "gmrs-ch3-local")
        XCTAssertEqual(ViewIdentifier.slug("gmrs/ch5"), "gmrs-ch5")
        XCTAssertEqual(ViewIdentifier.slug("Café 2"), "caf-2")
        XCTAssertEqual(ViewIdentifier.slug("—"), "_")
    }

    func testHitSlugsAreUniqueOnlyWhereALabelRepeats() {
        func hit(_ hz: UInt64, _ name: String?) -> SweepHit {
            SweepHit(hz: hz, snrDb: 20, bandwidthHz: 12_500, looks: 8, looksPossible: 8, name: name)
        }
        let hits = [hit(162_550_000, "WX"), hit(162_400_000, "WX"), hit(146_520_000, "Calling")]
        XCTAssertEqual(ViewIdentifier.hitSlug(hits[1], among: hits), "wx")
        XCTAssertEqual(ViewIdentifier.hitSlug(hits[0], among: hits), "wx-2")
        XCTAssertEqual(ViewIdentifier.hitSlug(hits[2], among: hits), "calling")
    }
}
