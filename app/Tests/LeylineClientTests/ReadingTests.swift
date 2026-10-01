// SPDX-License-Identifier: Apache-2.0

// The reading's words on numbers, without a daemon: every band edge in the design's tables, the
// tuning sign, the nominal table and the two time forms, each against the exact string the panel
// prints.

import LeylineProto
import XCTest

@testable import LeylineClient

final class ReadingTests: XCTestCase {
    func testSignalWordBandsHaveTheirEdgesInTheUpperBand() {
        XCTAssertEqual(SignalWord.thresholdsDB, [3, 8, 14, 22])
        XCTAssertEqual(SignalWord(overNoiseDB: -5), .notAudible)
        XCTAssertEqual(SignalWord(overNoiseDB: 2.9), .notAudible)
        XCTAssertEqual(SignalWord(overNoiseDB: 3), .veryWeak, "an edge belongs to the band above")
        XCTAssertEqual(SignalWord(overNoiseDB: 7.9), .veryWeak)
        XCTAssertEqual(SignalWord(overNoiseDB: 8), .weak)
        XCTAssertEqual(SignalWord(overNoiseDB: 13.9), .weak)
        XCTAssertEqual(SignalWord(overNoiseDB: 14), .fair)
        XCTAssertEqual(SignalWord(overNoiseDB: 21.9), .fair)
        XCTAssertEqual(SignalWord(overNoiseDB: 22), .strong)
        XCTAssertEqual(SignalWord(overNoiseDB: 40), .strong)
    }

    func testSignalWordIsNilForAMeasurementNobodyMade() {
        XCTAssertNil(SignalWord(overNoiseDB: nil))
        XCTAssertNil(SignalWord(overNoiseDB: .nan))
    }

    func testSignalWordsPrintAsThePanelDoes() {
        XCTAssertEqual(
            SignalWord.allCases.map(\.word),
            ["Not audible", "Very weak", "Weak", "Fair", "Strong"])
    }

    func testTuningWordFollowsTheSignAndTheTenthOfBandwidth() {
        XCTAssertEqual(TuningWord.offTuneFraction, 0.1)
        // A tenth of 12.5 kHz is 1 250 Hz, so 1 kHz is still centred there and 2 kHz is not.
        XCTAssertEqual(TuningWord(freqErrorHz: 2000, bandwidthHz: 12_500), .offTuneHigh)
        XCTAssertEqual(TuningWord(freqErrorHz: -2000, bandwidthHz: 12_500), .offTuneLow)
        XCTAssertEqual(TuningWord(freqErrorHz: 1000, bandwidthHz: 12_500), .centred)
        XCTAssertEqual(
            TuningWord(freqErrorHz: 1000, bandwidthHz: 25_000), .centred,
            "1 kHz is within a tenth of a 25 kHz channel")
        XCTAssertEqual(TuningWord(freqErrorHz: 3, bandwidthHz: 12_500), .centred)
        XCTAssertEqual(
            TuningWord(freqErrorHz: 1250, bandwidthHz: 12_500), .centred,
            "exactly a tenth is still centred")
        XCTAssertEqual(TuningWord(freqErrorHz: -1250, bandwidthHz: 12_500), .centred)
        XCTAssertEqual(TuningWord(freqErrorHz: 1250.1, bandwidthHz: 12_500), .offTuneHigh)
        XCTAssertEqual(TuningWord(freqErrorHz: -1250.1, bandwidthHz: 12_500), .offTuneLow)
    }

    func testTuningWordIsNilForNaNOrNoBandwidth() {
        XCTAssertNil(TuningWord(freqErrorHz: .nan, bandwidthHz: 12_500))
        XCTAssertNil(TuningWord(freqErrorHz: 100, bandwidthHz: 0))
        XCTAssertNil(
            TuningWord(freqErrorHz: 0, bandwidthHz: 12_500),
            "exactly 0 is a daemon that never set the field, not a centred signal")
        XCTAssertNil(DeviationWord(deviationHz: 0, mode: .nfm, bandwidthHz: 12_500))
    }

    func testTuningWordsPrintAsThePanelDoes() {
        XCTAssertEqual(TuningWord.centred.word, "Centred")
        XCTAssertEqual(TuningWord.offTuneLow.word, "Off tune · low")
        XCTAssertEqual(TuningWord.offTuneHigh.word, "Off tune · high")
        XCTAssertFalse(TuningWord.centred.isOffTune)
        XCTAssertTrue(TuningWord.offTuneLow.isOffTune)
        XCTAssertTrue(TuningWord.offTuneHigh.isOffTune)
    }

    func testNominalDeviationIsAFifthOfNFMAnd75kHzForWFM() {
        XCTAssertEqual(DeviationWord.nominalHz(mode: .nfm, bandwidthHz: 12_500), 2_500)
        XCTAssertEqual(DeviationWord.nominalHz(mode: .nfm, bandwidthHz: 25_000), 5_000)
        XCTAssertEqual(DeviationWord.nominalHz(mode: .wfm, bandwidthHz: 200_000), 75_000)
        XCTAssertEqual(DeviationWord.nominalHz(mode: .wfm, bandwidthHz: 1), 75_000)
        XCTAssertNil(DeviationWord.nominalHz(mode: .am, bandwidthHz: 10_000))
        XCTAssertNil(DeviationWord.nominalHz(mode: .usb, bandwidthHz: 2_800))
        XCTAssertNil(DeviationWord.nominalHz(mode: .unspecified, bandwidthHz: 12_500))
    }

    func testDeviationWordBandsHaveTheirEdgesInNormal() {
        XCTAssertEqual(DeviationWord.quietFraction, 0.4)
        XCTAssertEqual(DeviationWord.overFraction, 1.3)
        // NFM at 12.5 kHz: nominal 2 500 Hz, quiet under 1 000, overdeviating over 3 250.
        XCTAssertEqual(DeviationWord(deviationHz: 1, mode: .nfm, bandwidthHz: 12_500), .quiet)
        XCTAssertEqual(DeviationWord(deviationHz: 999, mode: .nfm, bandwidthHz: 12_500), .quiet)
        XCTAssertEqual(
            DeviationWord(deviationHz: 1000, mode: .nfm, bandwidthHz: 12_500), .normal,
            "exactly 0.4 of nominal is normal")
        XCTAssertEqual(DeviationWord(deviationHz: 2500, mode: .nfm, bandwidthHz: 12_500), .normal)
        XCTAssertEqual(
            DeviationWord(deviationHz: 3250, mode: .nfm, bandwidthHz: 12_500), .normal,
            "exactly 1.3 of nominal is normal")
        XCTAssertEqual(
            DeviationWord(deviationHz: 3251, mode: .nfm, bandwidthHz: 12_500), .overdeviating)
        // WFM: nominal 75 kHz whatever the bandwidth.
        XCTAssertEqual(DeviationWord(deviationHz: 29_999, mode: .wfm, bandwidthHz: 200_000), .quiet)
        XCTAssertEqual(
            DeviationWord(deviationHz: 30_000, mode: .wfm, bandwidthHz: 200_000), .normal)
        XCTAssertEqual(
            DeviationWord(deviationHz: 97_500, mode: .wfm, bandwidthHz: 200_000), .normal)
        XCTAssertEqual(
            DeviationWord(deviationHz: 97_501, mode: .wfm, bandwidthHz: 200_000), .overdeviating)
    }

    func testDeviationWordIsNilWithoutANumberOrANominal() {
        XCTAssertNil(DeviationWord(deviationHz: .nan, mode: .nfm, bandwidthHz: 12_500))
        XCTAssertNil(DeviationWord(deviationHz: 2500, mode: .nfm, bandwidthHz: 0))
        XCTAssertNil(DeviationWord(deviationHz: 2500, mode: .am, bandwidthHz: 10_000))
        XCTAssertNil(DeviationWord(deviationHz: 2500, mode: .wfm, bandwidthHz: 0))
    }

    func testDeviationWordsPrintAsThePanelDoes() {
        XCTAssertEqual(DeviationWord.quiet.word, "Quiet")
        XCTAssertEqual(DeviationWord.normal.word, "Normal")
        XCTAssertEqual(DeviationWord.overdeviating.word, "Overdeviating")
    }

    func testSecondsKeepsTenthsAndSplitsMinutes() {
        XCTAssertEqual(Reading.seconds(4.2), "4.2 s")
        XCTAssertEqual(Reading.seconds(0), "0.0 s")
        XCTAssertEqual(Reading.seconds(59.94), "59.9 s")
        XCTAssertEqual(Reading.seconds(59.96), "1:00.0", "rounded to tenths before the split")
        XCTAssertEqual(Reading.seconds(64.2), "1:04.2")
        XCTAssertEqual(Reading.seconds(600), "10:00.0")
        XCTAssertEqual(Reading.seconds(.nan), "—")
        XCTAssertEqual(Reading.seconds(.infinity), "—")
        XCTAssertEqual(Reading.seconds(-1), "—")
    }

    func testRelativeUsesARealMinusSign() {
        XCTAssertEqual(Reading.relative(secondsAgo: 134), "\u{2212}2:14")
        XCTAssertEqual(Reading.relative(secondsAgo: 134), "−2:14")
        XCTAssertEqual(Reading.relative(secondsAgo: 5), "−0:05")
        XCTAssertEqual(Reading.relative(secondsAgo: 0), "−0:00")
        XCTAssertEqual(Reading.relative(secondsAgo: 3599.6), "−1:00:00", "rounded to whole seconds")
        XCTAssertEqual(Reading.relative(secondsAgo: 3600), "−1:00:00")
        XCTAssertEqual(Reading.relative(secondsAgo: 3734), "−1:02:14")
        XCTAssertEqual(Reading.relative(secondsAgo: .nan), "—")
        XCTAssertEqual(Reading.relative(secondsAgo: -1), "—")
        XCTAssertFalse(Reading.relative(secondsAgo: 134).contains("-"), "never an ASCII hyphen")
    }
}
