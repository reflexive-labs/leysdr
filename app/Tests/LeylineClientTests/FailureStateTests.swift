// SPDX-License-Identifier: Apache-2.0

// The failure rule on numbers, without a daemon. The quiet rows are the ones
// `go/internal/cli/failure_test.go` uses, so the two clients are held to one answer; the
// clipping rule reads the daemon's CaptureLevel on both sides.

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
        level: Leyline_V1_CaptureLevel? = nil, floor: Float = -64, peak: Float = -30,
        rows: Int = 90, gains: [Leyline_V1_GainState] = [], previous: FailureState? = nil
    ) -> FailureState? {
        FailureState.name(
            level: level, floorDB: floor, peakDB: peak, rows: rows, rowsPerSecond: 30,
            gains: gains, elements: [tuner], previous: previous)
    }
    private func clipping(
        _ clipped: UInt64, total: UInt64 = 600_000, auto: Bool = false, atMinimum: Bool = false
    ) -> FailureState {
        .clipping(clipped: clipped, total: total, gainAuto: auto, gainAtMinimum: atMinimum)
    }

    func testAHealthyBandNamesNothing() {
        XCTAssertNil(name(level: level(clipped: 0), peak: -30))
        XCTAssertNil(name(peak: -49), "15 dB up is the peak rule's edge, and a peak")
        XCTAssertNil(name(floor: .nan, peak: .nan), "no rows yet")
        XCTAssertNil(name(peak: -60, rows: 89), "not quiet for long enough yet")
        XCTAssertNil(name(peak: 1), "a bin near full scale is not a state; only the rails are")
    }

    func testClippingIsMeasuredAndComesFirst() {
        XCTAssertEqual(name(level: level(clipped: 60), peak: -60), clipping(60))
        XCTAssertNil(
            name(level: level(clipped: 59), peak: -30), "under one in ten thousand is a stray")
        XCTAssertEqual(
            name(level: level(clipped: 60), gains: [gain(0, auto: true)]), clipping(60, auto: true))
        XCTAssertEqual(
            name(level: level(clipped: 60), gains: [gain(0)]), clipping(60, atMinimum: true))
        XCTAssertNil(name(level: level(clipped: 0, total: 0)), "an empty interval says nothing")
    }

    func testAStateHoldsUntilItsExitThreshold() {
        // Clipping: named at one in ten thousand, kept down to half that, gone below it.
        XCTAssertEqual(name(level: level(clipped: 40), previous: clipping(60)), clipping(40))
        XCTAssertNil(name(level: level(clipped: 29), previous: clipping(60)))
        XCTAssertNil(name(level: level(clipped: 40)), "without a previous state 40 is not named")
        // Quiet: named under 15 dB over the floor, kept under 18, gone at 18.
        let quiet = FailureState.nothingAboveFloor(floorDB: -64, gainAtMinimum: false)
        XCTAssertEqual(name(peak: -47, previous: quiet), quiet)
        XCTAssertNil(name(peak: -46, previous: quiet))
        XCTAssertNil(name(peak: -47), "without a previous state 17 dB up is a peak")
    }

    func testNothingAboveTheFloorNamesTheGainWhenItIsLowest() {
        XCTAssertEqual(name(peak: -55), .nothingAboveFloor(floorDB: -64, gainAtMinimum: false))
        XCTAssertEqual(
            name(peak: -55, gains: [gain(0)]), .nothingAboveFloor(floorDB: -64, gainAtMinimum: true)
        )
        XCTAssertEqual(
            name(peak: -55, gains: [gain(0, auto: true)]),
            .nothingAboveFloor(floorDB: -64, gainAtMinimum: false),
            "auto is never at the minimum, whatever it chose")
        XCTAssertEqual(
            name(peak: -55, gains: [gain(0.9)]),
            .nothingAboveFloor(floorDB: -64, gainAtMinimum: false),
            "one step up the table is not the minimum")
    }

    func testTheWordsCarryTheNumberAndTheThingToTry() {
        let quiet = FailureState.nothingAboveFloor(floorDB: -64, gainAtMinimum: false)
        XCTAssertEqual(quiet.headline, "Nothing is above the noise")
        XCTAssertEqual(
            quiet.detail,
            "No bin has been 15 dB above the floor (-64 dBFS) for 3 s. Check the antenna; FM broadcast is the band most antennas hear."
        )
        XCTAssertFalse(quiet.namesGain)
        let low = FailureState.nothingAboveFloor(floorDB: -64, gainAtMinimum: true)
        XCTAssertEqual(
            low.detail,
            "No bin has been 15 dB above the floor (-64 dBFS) for 3 s, and the gain is at its lowest. Turn it up, or set it to auto."
        )
        XCTAssertTrue(low.namesGain)
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
