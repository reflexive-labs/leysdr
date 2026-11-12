// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// A radio that stops answering and a capture that stops streaming, in the window's words: the
/// device menu's state line, the chip's tooltip, and the empty state.
final class RadioHealthTests: XCTestCase {
    static let advice =
        "NESDR SMArt v5 is not answering: unplug it and plug it back in, ideally into a port on the back of the Mac"

    func device(_ state: Leyline_V1_DeviceState, detail: String = "") -> Leyline_V1_DeviceDescriptor
    {
        var d = Leyline_V1_DeviceDescriptor()
        d.deviceID = "dev_1"
        d.model = "NESDR SMArt v5"
        d.state = state
        d.stateDetail = detail
        return d
    }

    func capture(_ state: Leyline_V1_CaptureState, detail: String = "") -> Leyline_V1_Capture {
        var c = Leyline_V1_Capture()
        c.captureID = "cap_1"
        c.state = state
        c.stateDetail = detail
        return c
    }

    func testStateWords() {
        XCTAssertEqual(RadioHealth.stateWords(device(.available)), "connected")
        XCTAssertEqual(RadioHealth.stateWords(device(.inUse)), "connected, in use")
        XCTAssertEqual(RadioHealth.stateWords(device(.disconnected)), "unplugged")
        XCTAssertEqual(
            RadioHealth.stateWords(device(.notAnswering, detail: Self.advice)), "not answering")
    }

    func testARadioNotAnsweringIsNotUsedAndSaysWhatToDo() {
        let d = device(.notAnswering, detail: Self.advice)
        XCTAssertFalse(RadioHealth.isUsable(d))
        XCTAssertFalse(RadioHealth.isUsable(device(.disconnected)))
        XCTAssertTrue(RadioHealth.isUsable(device(.inUse)))
        XCTAssertEqual(RadioHealth.advice(d), Self.advice)
        XCTAssertNil(RadioHealth.advice(device(.available)))
        XCTAssertEqual(RadioHealth.tooltip(name: "NESDR SMArt v5", device: d), Self.advice)
        XCTAssertEqual(
            RadioHealth.tooltip(name: "NESDR SMArt v5", device: device(.disconnected)),
            "NESDR SMArt v5, unplugged")
        XCTAssertEqual(
            RadioHealth.advice(device(.notAnswering)),
            "NESDR SMArt v5 is not answering: unplug it and plug it back in",
            "an older daemon's state with no sentence still says what to do")
    }

    func testEmptyWords() {
        let stalled = capture(.captureStalled, detail: "no samples from NESDR SMArt v5 for 5 s")
        XCTAssertTrue(RadioHealth.isAttached(stalled))
        let words = RadioHealth.emptyWords(capture: stalled, device: device(.inUse))
        XCTAssertEqual(words?.headline, "The radio has stopped sending samples")
        XCTAssertEqual(words?.detail, "No samples from NESDR SMArt v5 for 5 s.")

        let gone = RadioHealth.emptyWords(
            capture: capture(.captureDetached), device: device(.notAnswering, detail: Self.advice))
        XCTAssertEqual(gone?.headline, "The radio is not answering")
        XCTAssertEqual(gone?.detail, Self.advice)

        let unplugged = RadioHealth.emptyWords(
            capture: capture(.captureDetached), device: device(.disconnected))
        XCTAssertEqual(unplugged?.headline, "The radio was unplugged")
        XCTAssertFalse(RadioHealth.isAttached(capture(.captureDetached)))

        XCTAssertNil(
            RadioHealth.emptyWords(capture: capture(.captureActive), device: device(.inUse)))
    }
}
