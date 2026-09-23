// SPDX-License-Identifier: Apache-2.0

// The failure rule on numbers, without a daemon: clipping from the daemon's CaptureLevel, the
// same floor `ley tune` applies, and the hold the window puts on it (`FailureHold`).

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

    /// Quarter-second readings at 600 kS/s, as the daemon sends them: `clipped` samples of
    /// 150 000 in each, the time the interval's end.
    private struct Readings {
        static let rate: UInt64 = 600_000
        static let interval: UInt64 = 150_000
        var hold = FailureHold()
        var end: UInt64 = 0
        var capture = "cap_a"

        /// Folds `seconds` of readings with `clipped` samples each and returns what was shown
        /// after each one.
        mutating func feed(clipped: UInt64, seconds: Double) -> [FailureState?] {
            let count = Int((seconds * Double(Self.rate) / Double(Self.interval)).rounded())
            return (0..<count).map { _ in
                end += Self.interval
                let level = Leyline_V1_CaptureLevel.with {
                    $0.clippedSamples = clipped
                    $0.totalSamples = Self.interval
                }
                let time = Leyline_V1_SampleTime.with {
                    $0.captureID = capture
                    $0.sampleIndex = end
                }
                return hold.fold(
                    level: level, at: time, sampleRate: Self.rate, gains: [], elements: [])
            }
        }
    }

    func testABurstUnderASecondIsNeverShown() {
        var r = Readings()
        XCTAssertEqual(r.feed(clipped: 0, seconds: 1).compactMap { $0 }, [])
        XCTAssertEqual(r.feed(clipped: 150, seconds: 0.5).compactMap { $0 }, [])
        XCTAssertEqual(r.feed(clipped: 0, seconds: 3).compactMap { $0 }, [])
    }

    func testASecondOfClippingIsShown() {
        var r = Readings()
        let shown = r.feed(clipped: 150, seconds: 1)
        XCTAssertEqual(shown.dropLast().compactMap { $0 }, [], "not before the second")
        XCTAssertEqual(r.hold.state, clipping(150, total: 150_000))
        _ = r.feed(clipped: 300, seconds: 0.25)
        XCTAssertEqual(
            r.hold.state, clipping(300, total: 150_000), "a shown state takes the newest number")
    }

    func testAGapUnderTwoSecondsDoesNotClear() {
        var r = Readings()
        _ = r.feed(clipped: 150, seconds: 1)
        XCTAssertEqual(r.feed(clipped: 0, seconds: 1).compactMap { $0 }.count, 4)
        _ = r.feed(clipped: 150, seconds: 0.25)
        XCTAssertNotNil(r.hold.state, "a second's gap inside a run")
        let clean = r.feed(clipped: 0, seconds: 2)
        XCTAssertEqual(clean.dropLast().compactMap { $0 }.count, 7, "not before two seconds")
        XCTAssertNil(r.hold.state, "two seconds clean clears it")
    }

    func testTheExitFractionStillHolds() {
        var r = Readings()
        _ = r.feed(clipped: 150, seconds: 1)
        // 10 in 150 000 is under the floor (15) and over the exit fraction (7.5): still clipping.
        _ = r.feed(clipped: 10, seconds: 3)
        XCTAssertEqual(r.hold.state, clipping(10, total: 150_000))
        let untimed = r.hold.fold(
            level: .with { $0.totalSamples = 150_000 },
            at: .with {
                $0.captureID = "cap_a"
                $0.sampleIndex = r.end + 600_000
            }, sampleRate: 0, gains: [], elements: [])
        XCTAssertEqual(untimed, clipping(10, total: 150_000), "an unknown rate changes nothing")
    }

    func testAnotherCaptureStartsAgain() {
        var r = Readings()
        _ = r.feed(clipped: 150, seconds: 1)
        XCTAssertNotNil(r.hold.state)
        r.capture = "cap_b"
        _ = r.feed(clipped: 150, seconds: 0.75)
        XCTAssertNil(r.hold.state, "the hold starts again on the new capture")
        _ = r.feed(clipped: 150, seconds: 0.25)
        XCTAssertNotNil(r.hold.state)
    }
}
