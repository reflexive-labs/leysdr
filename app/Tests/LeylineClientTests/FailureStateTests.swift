// SPDX-License-Identifier: Apache-2.0

// The failure rule on numbers, without a daemon. The rows here are the ones
// `go/internal/cli/failure_test.go` uses, so the two clients are held to one answer.

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
    private func name(
        floor: Float, peak: Float, rows: Int = 90, gains: [Leyline_V1_GainState] = [],
        previous: FailureState? = nil
    ) -> FailureState? {
        FailureState.name(
            floorDB: floor, peakDB: peak, rows: rows, rowsPerSecond: 30, gains: gains,
            elements: [tuner], previous: previous)
    }
    private func hot(_ peak: Float, auto: Bool = false, atMinimum: Bool = false) -> FailureState {
        .nearFullScale(peakDB: peak, gainAuto: auto, gainAtMinimum: atMinimum)
    }

    func testAHealthyBandNamesNothing() {
        XCTAssertNil(name(floor: -64, peak: -30))
        XCTAssertNil(name(floor: -64, peak: -49), "15 dB up is the peak rule's edge, and a peak")
        XCTAssertNil(name(floor: .nan, peak: .nan), "no rows yet")
        XCTAssertNil(name(floor: -64, peak: -60, rows: 89), "not quiet for long enough yet")
    }

    func testNearFullScaleComesFirst() {
        XCTAssertEqual(name(floor: -64, peak: -3), hot(-3))
        XCTAssertEqual(name(floor: -64, peak: 1), hot(1))
        XCTAssertNil(name(floor: -64, peak: -3.5))
        XCTAssertEqual(
            name(floor: -10, peak: -2, rows: 0), hot(-2),
            "full scale is a fact about one row; it does not wait")
        XCTAssertEqual(
            name(floor: -64, peak: -2, gains: [gain(0, auto: true)]), hot(-2, auto: true))
        XCTAssertEqual(name(floor: -64, peak: -2, gains: [gain(0)]), hot(-2, atMinimum: true))
    }

    func testAStateHoldsUntilItsExitThreshold() {
        // Full scale: named at -3, kept down to -6, gone below it.
        XCTAssertEqual(name(floor: -64, peak: -5, previous: hot(-3)), hot(-5))
        XCTAssertNil(name(floor: -64, peak: -6.5, previous: hot(-3)))
        XCTAssertNil(name(floor: -64, peak: -5), "without a previous state -5 is not named")
        // Quiet: named under 15 dB over the floor, kept under 18, gone at 18.
        let quiet = FailureState.nothingAboveFloor(floorDB: -64, gainAtMinimum: false)
        XCTAssertEqual(name(floor: -64, peak: -47, previous: quiet), quiet)
        XCTAssertNil(name(floor: -64, peak: -46, previous: quiet))
        XCTAssertNil(name(floor: -64, peak: -47), "without a previous state 17 dB up is a peak")
    }

    func testNothingAboveTheFloorNamesTheGainWhenItIsLowest() {
        XCTAssertEqual(
            name(floor: -64, peak: -55), .nothingAboveFloor(floorDB: -64, gainAtMinimum: false))
        XCTAssertEqual(
            name(floor: -64, peak: -55, gains: [gain(0)]),
            .nothingAboveFloor(floorDB: -64, gainAtMinimum: true))
        XCTAssertEqual(
            name(floor: -64, peak: -55, gains: [gain(0, auto: true)]),
            .nothingAboveFloor(floorDB: -64, gainAtMinimum: false),
            "auto is never at the minimum, whatever it chose")
        XCTAssertEqual(
            name(floor: -64, peak: -55, gains: [gain(0.9)]),
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
        let low = FailureState.nothingAboveFloor(floorDB: -64, gainAtMinimum: true)
        XCTAssertEqual(
            low.detail,
            "No bin has been 15 dB above the floor (-64 dBFS) for 3 s, and the gain is at its lowest. Turn it up, or set it to auto."
        )
        let manual = hot(-2)
        XCTAssertEqual(manual.headline, "A signal is within 3 dB of full scale")
        XCTAssertEqual(
            manual.detail, "The loudest bin reads -2 dBFS. Lower the gain before the radio clips.")
        XCTAssertTrue(manual.namesGain)
        XCTAssertEqual(
            hot(-2, auto: true).detail,
            "The loudest bin reads -2 dBFS with the gain on auto. Take the gain by hand and lower it before the radio clips."
        )
        XCTAssertEqual(
            hot(-2, atMinimum: true).detail,
            "The loudest bin reads -2 dBFS at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
        )
        XCTAssertFalse(hot(-2, atMinimum: true).namesGain)
        XCTAssertFalse(quiet.namesGain)
        XCTAssertTrue(low.namesGain)
    }
}
