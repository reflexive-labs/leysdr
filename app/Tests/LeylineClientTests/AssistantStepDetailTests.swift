// SPDX-License-Identifier: Apache-2.0

// An opened step's readable lines: the arguments as `key value`, a result of rows as a small
// table, anything else as compact text, and the JSON for the toggle.

import LeylineProto
import XCTest

@testable import LeylineClient

final class AssistantStepDetailTests: XCTestCase {
    func testArgumentsReadAsKeyValueLinesInNameOrder() {
        let d = StepDetail(
            argumentsJSON: #"{"take_over": true, "frequency": "146.94", "gains": {"LNA": 16}}"#,
            resultText: "", resultJSON: "")
        XCTAssertEqual(
            d.arguments,
            [
                .init(key: "frequency", value: "146.94"),
                .init(key: "gains", value: #"{"LNA":16}"#),
                .init(key: "take_over", value: "true"),
            ])
        XCTAssertEqual(d.result, .none)
        XCTAssertTrue(d.hasJSON)
        XCTAssertEqual(
            StepDetail(argumentsJSON: "{}", resultText: "", resultJSON: "").arguments, [])
        XCTAssertFalse(StepDetail(argumentsJSON: "{}", resultText: "", resultJSON: "").hasJSON)
        XCTAssertEqual(
            StepDetail(argumentsJSON: "not\n json", resultText: "", resultJSON: "").arguments,
            [.init(key: "", value: "not json")])
    }

    func testRowsAreATableOfNameFrequencyAndModeWithTheRestCounted() throws {
        let rows = (1...26).map { i in
            #"{"name":"murs\#(i)","aliases":["\#(i)"],"hz":\#(151_820_000 + i * 60_000),"mode":"nfm","bandwidth_hz":11250,"description":"MURS \#(i)"}"#
        }
        let d = StepDetail(
            argumentsJSON: "{}", resultText: "  NAME  FREQUENCY  MODE\n  murs1 ...",
            resultJSON: "[" + rows.joined(separator: ",") + "]")
        guard case .table(let t) = d.result else { return XCTFail("\(d.result)") }
        XCTAssertEqual(t.columns, ["name", "frequency", "mode"])
        XCTAssertEqual(t.rows.count, StepDetail.rowLimit)
        XCTAssertEqual(t.rows[0], ["murs1", "151.880 MHz", "nfm"])
        XCTAssertEqual(t.more, 26 - StepDetail.rowLimit)
        XCTAssertEqual(t.moreWords, "\u{2026} 18 more")
        XCTAssertTrue(d.resultJSON.hasPrefix("[\n"), "the toggle shows the JSON indented")
    }

    func testRowsWithoutTheUsualKeysTakeTheirScalarKeysProseLast() throws {
        let d = StepDetail(
            argumentsJSON: "", resultText: "",
            resultJSON:
                #"{"recordings": [{"kind":"audio","description":"long words","bytes":12,"parts":[1]}]}"#
        )
        guard case .table(let t) = d.result else { return XCTFail("\(d.result)") }
        XCTAssertEqual(t.columns, ["bytes", "kind", "description"])
        XCTAssertEqual(t.rows, [["12", "audio", "long words"]])
        XCTAssertNil(t.moreWords)
    }

    func testAnythingButRowsIsCompactText() {
        let d = StepDetail(
            argumentsJSON: "",
            resultText: "\n\n1 capture, 1 channel   \n\n\n  chan_1 on 146.520 MHz\n\n",
            resultJSON: #"{"captures": 1, "channels": [{"id": "chan_1"}], "ok": true}"#)
        XCTAssertEqual(d.result, .text("1 capture, 1 channel\n\n  chan_1 on 146.520 MHz"))
        XCTAssertEqual(
            StepDetail(argumentsJSON: "", resultText: "", resultJSON: #"{"b":1,"a":2}"#).result,
            .text(#"{"a":2,"b":1}"#), "with no prose the JSON is the text, on one line")
        XCTAssertEqual(
            StepDetail(argumentsJSON: "", resultText: "", resultJSON: "[1, 2]").result,
            .text("[1,2]"), "an array of numbers is not rows")
        XCTAssertEqual(
            StepDetail(argumentsJSON: "", resultText: "", resultJSON: "").result, .none)
    }

    func testAStepOpensToItsCallsDetail() {
        var c = Leyline_V1_ToolCall()
        c.callID = "c1"
        c.tool = "tune"
        c.argumentsJson = #"{"frequency":"146.52"}"#
        c.resultText = "tuned"
        c.state = .toolCallDone
        let detail = StepRow(c).detail
        XCTAssertEqual(detail.arguments, [.init(key: "frequency", value: "146.52")])
        XCTAssertEqual(detail.result, .text("tuned"))
        XCTAssertEqual(detail.resultJSON, "")
    }
}
