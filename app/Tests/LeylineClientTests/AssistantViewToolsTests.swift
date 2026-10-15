// SPDX-License-Identifier: Apache-2.0

// The app's view tools: what it declares, how a call's input is parsed (a bad one is an error
// answer, never a crash), and how the waterfall's view fits a band inside the span the radio
// captures without moving the radio.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class AssistantViewToolsTests: XCTestCase {
    func testTheDeclaredNamesAreOnesTheWorkerOffers() throws {
        let names = AppViewTools.declarations.map(\.name)
        XCTAssertEqual(names, ["show_band", "select_recording", "show_place"])
        let rule = try NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,64}$")
        for t in AppViewTools.declarations {
            let range = NSRange(t.name.startIndex..., in: t.name)
            XCTAssertNotNil(rule.firstMatch(in: t.name, range: range), t.name)
            XCTAssertFalse(t.description_p.isEmpty)
            XCTAssertNotNil(
                AssistantWords.jsonObject(t.inputSchemaJson), "\(t.name)'s schema is not JSON")
        }
        // No radio tool's name: the worker drops a view tool that shadows one.
        for radio in ["tune", "set", "stop", "scan", "record", "undo", "get_state"] {
            XCTAssertFalse(names.contains(radio))
        }
    }

    func testShowBandTakesABandOrARange() {
        XCTAssertEqual(
            AppViewTools.parse(tool: "show_band", argumentsJSON: #"{"band":"2m"}"#),
            .success(.showRange(lowHz: 144_000_000, highHz: 148_000_000, label: "2 m amateur")))
        XCTAssertEqual(
            AppViewTools.parse(tool: "show_band", argumentsJSON: #"{"band":"Airband"}"#),
            .success(.showRange(lowHz: 118_000_000, highHz: 137_000_000, label: "airband")))
        XCTAssertEqual(
            AppViewTools.parse(
                tool: "show_band", argumentsJSON: #"{"from_hz":145000000,"to_hz":146000000}"#),
            .success(
                .showRange(
                    lowHz: 145_000_000, highHz: 146_000_000,
                    label: "145.000 MHz to 146.000 MHz")))
    }

    func testABadInputIsAnErrorAnswerNeverACrash() {
        let bad: [(String, String)] = [
            ("show_band", "not json"),
            ("show_band", "[1,2]"),
            ("show_band", "{}"),
            ("show_band", #"{"band":"nowhere"}"#),
            ("show_band", #"{"band":7}"#),
            ("show_band", #"{"band":"2m","from_hz":1,"to_hz":2}"#),
            ("show_band", #"{"from_hz":146000000,"to_hz":145000000}"#),
            ("show_band", #"{"from_hz":-5,"to_hz":145000000}"#),
            ("show_band", #"{"from_hz":1.5,"to_hz":145000000}"#),
            ("show_band", #"{"from_hz":1e300,"to_hz":1e301}"#),
            ("show_band", #"{"from_hz":"145","to_hz":"146"}"#),
            ("select_recording", "{}"),
            ("select_recording", #"{"recording":""}"#),
            ("select_recording", #"{"recording":"a/b/c"}"#),
            ("select_recording", #"{"recording":"job_1","part":0}"#),
            ("select_recording", #"{"recording":"job_1","part":2.5}"#),
            ("select_recording", #"{"recording":"job_1","part":"2"}"#),
            ("show_place", #"{"place":"kitchen"}"#),
            ("show_place", "{}"),
            ("tune", #"{"frequency":"noaa"}"#),
        ]
        for (tool, args) in bad {
            guard case .failure(let e) = AppViewTools.parse(tool: tool, argumentsJSON: args) else {
                XCTFail("\(tool) \(args) parsed")
                continue
            }
            XCTAssertTrue(e.answer.isError)
            XCTAssertFalse(e.message.isEmpty)
        }
        guard
            case .failure(let e) = AppViewTools.parse(
                tool: "show_band", argumentsJSON: #"{"band":"nowhere"}"#)
        else { return XCTFail("an unknown band parsed") }
        XCTAssertEqual(e.message, "no band is named nowhere; list_bands gives the names")
    }

    func testSelectRecordingTakesAnIdAURIOrAPartURI() {
        XCTAssertEqual(
            AppViewTools.parse(tool: "select_recording", argumentsJSON: #"{"recording":"job_1"}"#),
            .success(.selectRecording(id: "job_1", part: nil)))
        XCTAssertEqual(
            AppViewTools.parse(
                tool: "select_recording",
                argumentsJSON: #"{"recording":"ley://recordings/job_1","part":3}"#),
            .success(.selectRecording(id: "job_1", part: 3)))
        XCTAssertEqual(
            AppViewTools.parse(
                tool: "select_recording",
                argumentsJSON: #"{"recording":"ley://recordings/job_1/2"}"#),
            .success(.selectRecording(id: "job_1", part: 2)))
        XCTAssertEqual(
            AppViewTools.parse(tool: "show_place", argumentsJSON: #"{"place":"Library"}"#),
            .success(.showPlace(.library)))
    }

    func testTheViewFitsTheBandInsideTheSpan() throws {
        // A 2.4 MSPS capture on 146 MHz covers 144.8 to 147.2 MHz.
        let calling = try XCTUnwrap(
            ViewWindow.fit(
                lowHz: 146_400_000, highHz: 146_600_000, centerHz: 146_000_000,
                sampleRate: 2_400_000))
        XCTAssertEqual(calling.zoom, 8)
        XCTAssertEqual(calling.focusHz, 146_500_000)
        XCTAssertEqual(calling.shown, 146_350_000...146_650_000)
        XCTAssertTrue(calling.whole)

        let wide = try XCTUnwrap(
            ViewWindow.fit(
                lowHz: 144_000_000, highHz: 148_000_000, centerHz: 146_000_000,
                sampleRate: 2_400_000))
        XCTAssertEqual(wide.zoom, 1)
        XCTAssertEqual(wide.shown, 144_800_000...147_200_000)
        XCTAssertFalse(wide.whole)

        XCTAssertNil(
            ViewWindow.fit(
                lowHz: 118_000_000, highHz: 137_000_000, centerHz: 146_000_000,
                sampleRate: 2_400_000))
        XCTAssertNil(
            ViewWindow.fit(lowHz: 1, highHz: 2, centerHz: 146_000_000, sampleRate: 0))
    }

    func testTheZoomedWindowStaysInsideTheSpan() {
        XCTAssertEqual(
            ViewWindow.visible(
                centerHz: 146_000_000, sampleRate: 2_400_000, zoom: 1, focusHz: 0),
            144_800_000...147_200_000)
        XCTAssertEqual(
            ViewWindow.visible(
                centerHz: 146_000_000, sampleRate: 2_400_000, zoom: 4, focusHz: 147_200_000),
            146_600_000...147_200_000)
        XCTAssertEqual(
            ViewWindow.visible(centerHz: 1_000_000, sampleRate: 2_400_000, zoom: 1, focusHz: 0),
            0...2_200_000)
        XCTAssertNil(
            ViewWindow.visible(centerHz: 1, sampleRate: 0, zoom: 1, focusHz: 0))
    }

    func testTheSessionKeepsAFocusOnlyWhileTunedThereAndZoomed() {
        let focus = ViewFocus(hz: 146_500_000, tunedHz: 146_000_000)
        XCTAssertEqual(ViewFocus.kept(focus, tunedHz: 146_000_000, zoom: 4), focus)
        // A tune from any client clears it, and coming back does not bring it back.
        XCTAssertNil(ViewFocus.kept(focus, tunedHz: 146_520_000, zoom: 4))
        XCTAssertNil(ViewFocus.kept(focus, tunedHz: nil, zoom: 4))
        // Zoomed back out to the whole span, there is nothing to centre.
        XCTAssertNil(ViewFocus.kept(focus, tunedHz: 146_000_000, zoom: 1))
        XCTAssertNil(ViewFocus.kept(nil, tunedHz: 146_000_000, zoom: 4))
    }

    func testAFocusLastsUntilTheRadioIsTunedElsewhere() {
        let focus = ViewFocus(hz: 146_500_000, tunedHz: 146_000_000)
        XCTAssertEqual(focus.centre(tunedHz: 146_000_000), 146_500_000)
        XCTAssertNil(focus.centre(tunedHz: 146_520_000))
        XCTAssertNil(focus.centre(tunedHz: nil))
    }

    func testShowRangeAnswersWhatItShowedOrWhyNot() {
        let inside = AppViewTools.showRange(
            lowHz: 146_400_000, highHz: 146_600_000, label: "calling", centerHz: 146_000_000,
            sampleRate: 2_400_000)
        XCTAssertFalse(inside.answer.isError)
        XCTAssertEqual(inside.answer.text, "The waterfall shows 146.350 MHz to 146.650 MHz.")
        XCTAssertEqual(
            inside.answer.json,
            #"{"from_hz":146350000,"place":"radio","to_hz":146650000,"whole":true,"zoom":8}"#)
        XCTAssertEqual(inside.fit?.zoom, 8)

        let partly = AppViewTools.showRange(
            lowHz: 144_000_000, highHz: 148_000_000, label: "2 m amateur", centerHz: 146_000_000,
            sampleRate: 2_400_000)
        XCTAssertFalse(partly.answer.isError)
        XCTAssertTrue(
            partly.answer.text.contains("all of 2 m amateur (144.000 MHz to 148.000 MHz)"),
            partly.answer.text)

        let outside = AppViewTools.showRange(
            lowHz: 118_000_000, highHz: 137_000_000, label: "airband", centerHz: 146_000_000,
            sampleRate: 2_400_000)
        XCTAssertTrue(outside.answer.isError)
        XCTAssertNil(outside.fit)
        XCTAssertTrue(outside.answer.text.contains("Tune the radio there"), outside.answer.text)

        let noRadio = AppViewTools.showRange(
            lowHz: 118_000_000, highHz: 137_000_000, label: "airband", centerHz: nil,
            sampleRate: 0)
        XCTAssertTrue(noRadio.answer.isError)
        XCTAssertNil(noRadio.fit)
    }

    func testTheLibraryAnswersNameWhatTheyShow() {
        let a = AppViewTools.selected(recording: "job_1", part: 2, title: "GMRS CH3")
        XCTAssertEqual(a.text, "The Library shows part 2 of the recording on GMRS CH3.")
        XCTAssertEqual(a.json, #"{"part":2,"place":"library","recording":"job_1"}"#)
        XCTAssertTrue(AppViewTools.unknownRecording("job_9").isError)
        XCTAssertTrue(AppViewTools.unknownRecording("job_1", part: 7).text.contains("no part 7"))
        XCTAssertEqual(AppViewTools.shown(.library).json, #"{"place":"library"}"#)
    }
}
