// SPDX-License-Identifier: Apache-2.0

// The failure rule on numbers, without a daemon: clipping from the daemon's CaptureLevel, the
// same floor `ley tune` applies.

import LeylineProto
import XCTest

@testable import LeylineClient

final class FailureStateTests: XCTestCase {
    private let tuner = Leyline_V1_GainElement.with {
        $0.name = "TUNER"
        $0.minDb = 0
        $0.maxDb = 49.6
        $0.supportsAuto = true
        $0.validDb = [0, 0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6, 19.7, 20.7, 22.9]
    }
    private func gain(_ db: Double, auto: Bool = false) -> Leyline_V1_GainState {
        .with {
            $0.element = "TUNER"
            $0.db = db
            $0.auto = auto
        }
    }
    private func level(clipped: UInt64, total: UInt64 = 600_000) -> Leyline_V1_CaptureLevel {
        .with {
            $0.clippedSamples = clipped
            $0.totalSamples = total
        }
    }
    private func name(
        level: Leyline_V1_CaptureLevel?, gains: [Leyline_V1_GainState] = [],
        previous: FailureState? = nil
    ) -> FailureState? {
        FailureState.name(level: level, gains: gains, elements: [tuner], previous: previous)
    }
    private func clipping(
        _ clipped: UInt64, total: UInt64 = 600_000, auto: Bool = false, atMinimum: Bool = false
    ) -> FailureState {
        .clipping(clipped: clipped, total: total, gainAuto: auto, gainAtMinimum: atMinimum)
    }

    func testClippingIsMeasured() {
        XCTAssertNil(name(level: nil), "no reading yet")
        XCTAssertNil(name(level: level(clipped: 0)))
        XCTAssertEqual(name(level: level(clipped: 60)), clipping(60))
        XCTAssertNil(name(level: level(clipped: 59)), "under one in ten thousand is a stray")
        XCTAssertEqual(
            name(level: level(clipped: 60), gains: [gain(0, auto: true)]), clipping(60, auto: true))
        XCTAssertEqual(
            name(level: level(clipped: 60), gains: [gain(0)]), clipping(60, atMinimum: true))
        XCTAssertNil(name(level: level(clipped: 0, total: 0)), "an empty interval says nothing")
    }

    func testTheStateHoldsUntilItsExitThreshold() {
        XCTAssertEqual(name(level: level(clipped: 40), previous: clipping(60)), clipping(40))
        XCTAssertNil(name(level: level(clipped: 29), previous: clipping(60)))
        XCTAssertNil(name(level: level(clipped: 40)), "without a previous state 40 is not named")
    }

    func testTheWordsCarryTheNumberAndTheThingToTry() {
        let hot = clipping(300)
        XCTAssertEqual(hot.headline, "The radio is clipping")
        XCTAssertEqual(
            hot.detail, "300 of 600000 samples (0.05 %) hit the converter's rails. Lower the gain.")
        XCTAssertTrue(hot.namesGain)
        XCTAssertEqual(
            clipping(6000, auto: true).detail,
            "6000 of 600000 samples (1.0 %) hit the converter's rails with the gain on auto. Take the gain by hand and lower it."
        )
        XCTAssertEqual(
            clipping(300, atMinimum: true).detail,
            "300 of 600000 samples (0.05 %) hit the converter's rails at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
        )
        XCTAssertFalse(clipping(300, atMinimum: true).namesGain)
    }
}
