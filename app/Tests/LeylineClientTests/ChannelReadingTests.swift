// SPDX-License-Identifier: Apache-2.0

// The steadied reading without a daemon: the ballistics' attack and release, the words'
// hysteresis at their band edges, the last transmission held after the squelch closes, and the
// reset on a new channel (`ChannelReading.swift`).

import LeylineProto
import XCTest

@testable import LeylineClient

final class ChannelReadingTests: XCTestCase {
    private func meter(
        powerDbfs: Double = -40, freqErrorHz: Double = .nan, deviationHz: Double = .nan,
        squelchOpen: Bool = true
    ) -> Leyline_V1_Meter {
        var m = Leyline_V1_Meter()
        m.powerDbfs = powerDbfs
        m.freqErrorHz = freqErrorHz
        m.deviationHz = deviationHz
        m.squelchOpen = squelchOpen
        return m
    }

    func testBallisticsRiseAtOnceAndFallWithTheTimeConstant() {
        var b = Ballistics(releaseSeconds: 0.3)
        XCTAssertTrue(b.value.isNaN)
        XCTAssertEqual(b.fold(10, atSeconds: 0), 10)
        XCTAssertEqual(b.fold(20, atSeconds: 0.1), 20, "a rise is taken at once")
        // One time constant later a fall to 0 has come down to 1/e of the way.
        XCTAssertEqual(b.fold(0, atSeconds: 0.4), 20 * exp(-1), accuracy: 1e-9)
    }

    func testBallisticsHoldThroughNaNAndRestartAfterAGap() {
        var b = Ballistics(releaseSeconds: 0.3)
        b.fold(20, atSeconds: 0)
        XCTAssertEqual(b.fold(.nan, atSeconds: 0.1), 20, "NaN leaves the value held")
        XCTAssertEqual(b.fold(5, atSeconds: 10), 5, "a gap is not a fall")
        XCTAssertEqual(b.fold(1, atSeconds: 9), 1, "a clock that ran backwards is not a fall")
    }

    func testSignalWordHoldsWithinTheHysteresisOfItsBand() {
        XCTAssertEqual(SignalWord.hysteresisDB, 1.5)
        // Fair is 14 to 22 dB.
        XCTAssertEqual(SignalWord(overNoiseDB: 13, previous: .fair), .fair)
        XCTAssertEqual(SignalWord(overNoiseDB: 12.5, previous: .fair), .fair)
        XCTAssertEqual(SignalWord(overNoiseDB: 12.4, previous: .fair), .weak)
        XCTAssertEqual(SignalWord(overNoiseDB: 23.4, previous: .fair), .fair)
        XCTAssertEqual(SignalWord(overNoiseDB: 23.5, previous: .fair), .strong)
        XCTAssertEqual(SignalWord(overNoiseDB: 40, previous: .strong), .strong)
        XCTAssertEqual(SignalWord(overNoiseDB: 14, previous: nil), .fair)
        XCTAssertNil(SignalWord(overNoiseDB: .nan, previous: .fair))
        XCTAssertEqual(SignalWord(overNoiseDB: 2, previous: .strong), .notAudible)
    }

    func testTuningWordHoldsAroundTheTenthOfBandwidth() {
        // At 12.5 kHz a tenth is 1 250 Hz and the margin 250 Hz.
        XCTAssertEqual(
            TuningWord(freqErrorHz: 1400, bandwidthHz: 12_500, previous: .centred), .centred)
        XCTAssertEqual(
            TuningWord(freqErrorHz: 1501, bandwidthHz: 12_500, previous: .centred), .offTuneHigh)
        XCTAssertEqual(
            TuningWord(freqErrorHz: 1100, bandwidthHz: 12_500, previous: .offTuneHigh),
            .offTuneHigh)
        XCTAssertEqual(
            TuningWord(freqErrorHz: 1000, bandwidthHz: 12_500, previous: .offTuneHigh), .centred)
        XCTAssertEqual(
            TuningWord(freqErrorHz: -2000, bandwidthHz: 12_500, previous: .offTuneHigh),
            .offTuneLow, "the two off-tune words switch directly")
        XCTAssertEqual(
            TuningWord(freqErrorHz: 1400, bandwidthHz: 12_500, previous: nil), .offTuneHigh)
    }

    func testReadingSmoothsTheSignalAndReadsTheWordFromTheSmoothedLevel() {
        var r = ChannelReading()
        r.fold(
            meter(powerDbfs: -40), atSeconds: 0, channelID: "chan_a", floorDB: -60,
            mode: .nfm, bandwidthHz: 12_500)
        XCTAssertEqual(r.overNoiseDB, 20)
        XCTAssertEqual(r.signalWord, .fair)
        r.fold(
            meter(powerDbfs: -60), atSeconds: 0.1, channelID: "chan_a", floorDB: -60,
            mode: .nfm, bandwidthHz: 12_500)
        XCTAssertGreaterThan(r.overNoiseDB, 14, "one interval's drop is released, not taken")
        XCTAssertEqual(r.signalWord, .fair)
    }

    func testReadingWithoutAFloorHasNoSignal() {
        var r = ChannelReading()
        r.fold(
            meter(), atSeconds: 0, channelID: "chan_a", floorDB: nil, mode: .nfm,
            bandwidthHz: 12_500)
        XCTAssertTrue(r.overNoiseDB.isNaN)
        XCTAssertNil(r.signalWord)
    }

    func testReadingKeepsTheLastTransmissionAfterTheSquelchCloses() {
        var r = ChannelReading()
        r.fold(
            meter(freqErrorHz: 300, deviationHz: 2_000), atSeconds: 0, channelID: "chan_a",
            floorDB: -60, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertTrue(r.isLive)
        XCTAssertEqual(r.freqErrorHz, 300)
        XCTAssertEqual(r.tuningWord, .centred)
        XCTAssertEqual(r.deviationHz, 2_000)
        XCTAssertEqual(r.deviationWord, .normal)
        r.fold(
            meter(freqErrorHz: .nan, deviationHz: 400, squelchOpen: false), atSeconds: 0.1,
            channelID: "chan_a", floorDB: -60, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertFalse(r.isLive)
        XCTAssertEqual(r.freqErrorHz, 300, "the last transmission's tuning stays")
        XCTAssertEqual(r.deviationHz, 2_000, "noise under a closed squelch is not a reading")
        XCTAssertEqual(r.tuningWord, .centred)
    }

    func testANewTransmissionStartsTheDeviationFromItsOwnLevel() {
        var r = ChannelReading()
        r.fold(
            meter(freqErrorHz: 300, deviationHz: 3_000), atSeconds: 0, channelID: "chan_a",
            floorDB: -60, mode: .nfm, bandwidthHz: 12_500)
        r.fold(
            meter(squelchOpen: false), atSeconds: 1, channelID: "chan_a", floorDB: -60,
            mode: .nfm, bandwidthHz: 12_500)
        r.fold(
            meter(freqErrorHz: 300, deviationHz: 800), atSeconds: 1.1, channelID: "chan_a",
            floorDB: -60, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertEqual(r.deviationHz, 800)
        XCTAssertEqual(r.deviationWord, .quiet)
    }

    func testDeviationWordIsReadFromTheHeldLevel() {
        var r = ChannelReading()
        r.fold(
            meter(freqErrorHz: 300, deviationHz: 3_500), atSeconds: 0, channelID: "chan_a",
            floorDB: -60, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertEqual(r.deviationWord, .overdeviating)
        r.fold(
            meter(freqErrorHz: 300, deviationHz: 500), atSeconds: 0.1, channelID: "chan_a",
            floorDB: -60, mode: .nfm, bandwidthHz: 12_500)
        XCTAssertGreaterThan(r.deviationHz, 2_500)
        XCTAssertEqual(
            r.deviationWord,
            DeviationWord(deviationHz: r.deviationHz, mode: .nfm, bandwidthHz: 12_500))
    }

    func testANewChannelStartsFromNothing() {
        var r = ChannelReading()
        r.fold(
            meter(freqErrorHz: 300, deviationHz: 2_000), atSeconds: 0, channelID: "chan_a",
            floorDB: -60, mode: .nfm, bandwidthHz: 12_500)
        r.fold(
            meter(squelchOpen: false), atSeconds: 0.1, channelID: "chan_b", floorDB: -60,
            mode: .nfm, bandwidthHz: 12_500)
        XCTAssertEqual(r.channelID, "chan_b")
        XCTAssertTrue(r.freqErrorHz.isNaN)
        XCTAssertTrue(r.deviationHz.isNaN)
        XCTAssertNil(r.tuningWord)
    }

    func testSquelchOnTheSignalScaleIsOverTheFloor() {
        XCTAssertEqual(ChannelReading.squelchOverNoiseDB(squelchDB: -50, floorDB: -62), 12)
        XCTAssertTrue(ChannelReading.squelchOverNoiseDB(squelchDB: .nan, floorDB: -62).isNaN)
        XCTAssertTrue(ChannelReading.squelchOverNoiseDB(squelchDB: -50, floorDB: nil).isNaN)
    }

    func testAgoIsCoarseEnoughNotToFlicker() {
        XCTAssertEqual(Reading.ago(seconds: 0.4), "0 s ago")
        XCTAssertEqual(Reading.ago(seconds: 59.9), "59 s ago")
        XCTAssertEqual(Reading.ago(seconds: 60), "1 min ago")
        XCTAssertEqual(Reading.ago(seconds: 3599), "59 min ago")
        XCTAssertEqual(Reading.ago(seconds: 7300), "2 h ago")
        XCTAssertEqual(Reading.ago(seconds: .nan), "—")
        XCTAssertEqual(Reading.ago(seconds: -1), "—")
    }
}
