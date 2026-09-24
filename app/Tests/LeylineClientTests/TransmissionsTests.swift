// SPDX-License-Identifier: Apache-2.0

// The transmissions log, without a daemon: edges to transmissions, the reconstructed start,
// the tone or DCS code under a transmission and its heartbeat, the ring, and another channel's
// edges. The edge rules are the ones `go/internal/cli/transmission_test.go` holds `ley tune` to.

import LeylineProto
import XCTest

@testable import LeylineClient

final class TransmissionsTests: XCTestCase {
    private let rate: UInt64 = 2_400_000
    private let channel = "chan_a"

    private func at(_ index: UInt64) -> Leyline_V1_SampleTime {
        .with {
            $0.captureID = "cap_a"
            $0.sampleIndex = index
        }
    }

    private func edge(
        open: Bool, at index: UInt64, duration: UInt64 = 0, snr: Double = .nan,
        audio: Double = .nan, channel: String? = nil
    ) -> Leyline_V1_TelemetryMsg {
        .with {
            $0.time = at(index)
            $0.squelch = .with {
                $0.channelID = channel ?? self.channel
                $0.open = open
                $0.durationSamples = duration
                $0.peakSnrDb = snr
                $0.peakAudioDbfs = audio
            }
        }
    }

    private func tone(
        _ kind: Leyline_V1_SubAudibleKind, standard: Double = 0, measured: Double = .nan,
        dcs code: UInt32 = 0, inverted: Bool = false, at index: UInt64
    ) -> Leyline_V1_TelemetryMsg {
        .with {
            $0.time = at(index)
            $0.subAudible = .with {
                $0.channelID = channel
                $0.kind = kind
                $0.standardToneHz = standard
                $0.toneHz = measured
                $0.dcsCode = code
                $0.dcsInverted = inverted
            }
        }
    }

    private func meter(at index: UInt64) -> Leyline_V1_TelemetryMsg {
        .with {
            $0.time = at(index)
            $0.meter = .with {
                $0.channelID = channel
                $0.powerDbfs = -30
            }
        }
    }

    func testAnOpenEdgeIsOnAirAndTheCloseEdgeLogsIt() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 2_400_000), captureRate: rate)
        XCTAssertEqual(log.onAir?.since, at(2_400_000))
        XCTAssertEqual(log.timeOnAir(at: at(3_600_000)), 0.5)
        XCTAssertNil(log.timeOnAir(at: at(1_000)), "before the open edge is no time on air")
        XCTAssertTrue(log.closed.isEmpty)

        log.fold(
            edge(open: false, at: 4_800_000, duration: 2_400_000, snr: 26, audio: -7),
            captureRate: rate)
        XCTAssertNil(log.onAir)
        XCTAssertNil(log.timeOnAir(at: at(5_000_000)))
        XCTAssertEqual(log.closed.count, 1)
        let t = log.closed[0]
        XCTAssertEqual(t.start, at(2_400_000), "the open edge's time")
        XCTAssertEqual(t.end, at(4_800_000))
        XCTAssertEqual(t.seconds, 1)
        XCTAssertEqual(t.peakSNRDB, 26)
        XCTAssertEqual(t.peakAudioDBFS, -7)
        XCTAssertNil(t.tone)
    }

    func testACloseWithNoOpenSeenReadsItsStartBackFromTheDuration() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: false, at: 6_000_000, duration: 1_200_000), captureRate: rate)
        XCTAssertEqual(log.closed.count, 1)
        XCTAssertEqual(log.closed[0].start, at(4_800_000), "close time less the duration")
        XCTAssertEqual(log.closed[0].seconds, 0.5)

        // A duration past the timeline's start floors at sample 0, as `listenSummary` does.
        log.fold(edge(open: false, at: 1_000, duration: 1_200_000), captureRate: rate)
        XCTAssertEqual(log.closed[0].start, at(0))
    }

    func testACloseEdgeWithNoDurationIsNothing() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 100), captureRate: rate)
        log.fold(edge(open: false, at: 200, duration: 0), captureRate: rate)
        XCTAssertTrue(log.closed.isEmpty, "nothing measured, nothing logged")
        XCTAssertNil(log.onAir, "but the squelch is closed")
    }

    func testAnOpeningShorterThanAQuarterSecondIsNothing() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 0), captureRate: rate)
        log.fold(edge(open: false, at: 240_000, duration: 240_000, snr: 1), captureRate: rate)
        XCTAssertTrue(log.closed.isEmpty, "a 0.1 s blip on noise is not logged")
        XCTAssertNil(log.onAir, "but the squelch is closed")
        log.fold(edge(open: true, at: 1_000_000), captureRate: rate)
        log.fold(edge(open: false, at: 1_600_000, duration: 600_000), captureRate: rate)
        XCTAssertEqual(log.closed.count, 1, "a quarter second is")
    }

    func testAnUnknownRateCostsTheDurationAndNothingElse() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 100), captureRate: 0)
        XCTAssertNil(log.timeOnAir(at: at(200)))
        log.fold(edge(open: false, at: 200, duration: 100, snr: 12), captureRate: 0)
        XCTAssertEqual(log.closed.count, 1)
        XCTAssertTrue(log.closed[0].seconds.isNaN)
        XCTAssertEqual(log.closed[0].peakSNRDB, 12)
    }

    func testTheToneUnderATransmissionStaysWithItAndTheHeartbeatIsNotANewOne() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 0), captureRate: rate)
        log.fold(
            tone(.subAudibleCtcss, standard: 100, measured: 100.2, at: 240_000), captureRate: rate)
        XCTAssertEqual(log.onAir?.tone, .ctcss(standardHz: 100, measuredHz: 100.2))
        var before = log
        log.fold(
            tone(.subAudibleCtcss, standard: 100, measured: 100.2, at: 2_640_000), captureRate: rate
        )
        XCTAssertEqual(log, before, "the 1 Hz heartbeat repeats the tone; nothing changes")
        // Tone loss is not logged: the transmission keeps the tone it had.
        before = log
        log.fold(
            tone(.subAudibleNone, standard: 0, measured: .nan, at: 4_000_000), captureRate: rate)
        XCTAssertEqual(log, before)
        log.fold(edge(open: false, at: 4_800_000, duration: 4_800_000), captureRate: rate)
        XCTAssertEqual(log.closed[0].tone, .ctcss(standardHz: 100, measuredHz: 100.2))

        // A measurement between two standard tones is not a tone here: picking one is a guess.
        log.fold(edge(open: true, at: 6_000_000), captureRate: rate)
        log.fold(
            tone(.subAudibleCtcss, standard: 0, measured: 68.1, at: 6_240_000), captureRate: rate)
        XCTAssertNil(log.onAir?.tone)
        log.fold(edge(open: false, at: 7_200_000, duration: 1_200_000), captureRate: rate)
        XCTAssertNil(log.closed[0].tone)
        XCTAssertEqual(log.closed.count, 2)
    }

    func testADCSCodeAttachesToItsTransmission() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 0), captureRate: rate)
        log.fold(tone(.subAudibleDcs, dcs: 23, at: 1_300_000), captureRate: rate)
        XCTAssertEqual(log.onAir?.tone, .dcs(code: 23, inverted: false))
        log.fold(edge(open: false, at: 4_800_000, duration: 4_800_000), captureRate: rate)
        XCTAssertEqual(log.closed[0].tone, .dcs(code: 23, inverted: false))
        XCTAssertEqual(log.closed[0].tone?.words, "DCS 023")
        XCTAssertEqual(SubAudibleTone.dcs(code: 754, inverted: true).words, "DCS 754 inverted")
        XCTAssertEqual(SubAudibleTone.ctcss(standardHz: 100, measuredHz: 100.2).words, "PL 100.0")
    }

    func testAReportThatNamesNothingIsNoTone() {
        XCTAssertNil(SubAudibleTone(tone(.subAudibleNone, at: 0).subAudible))
        XCTAssertNil(SubAudibleTone(tone(.unspecified, at: 0).subAudible))
        // A DCS report with no code is not one: a client reads the kind and the code together.
        XCTAssertNil(SubAudibleTone(tone(.subAudibleDcs, at: 0).subAudible))
    }

    func testAToneThenACodeInOneTransmissionEndsWithTheCode() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 0), captureRate: rate)
        // A change of kind is a new tone, as a change of standard tone is: the newest wins.
        log.fold(
            tone(.subAudibleCtcss, standard: 131.8, measured: 131.6, at: 240_000),
            captureRate: rate)
        log.fold(tone(.subAudibleDcs, dcs: 23, at: 1_300_000), captureRate: rate)
        log.fold(edge(open: false, at: 4_800_000, duration: 4_800_000), captureRate: rate)
        XCTAssertEqual(log.closed[0].tone, .dcs(code: 23, inverted: false))
    }

    func testAToneHeardBeforeAnUnseenOpenEdgeGoesWithThatClose() {
        var log = TransmissionLog(channelID: channel)
        // Subscribed mid-transmission: the heartbeat arrives before any edge does.
        log.fold(
            tone(.subAudibleCtcss, standard: 123, measured: 123.0, at: 1_000), captureRate: rate)
        XCTAssertNil(log.onAir)
        log.fold(edge(open: false, at: 2_400_000, duration: 2_400_000), captureRate: rate)
        XCTAssertEqual(log.closed[0].tone, .ctcss(standardHz: 123, measuredHz: 123.0))
        // And it does not leak into the next transmission.
        log.fold(edge(open: true, at: 3_000_000), captureRate: rate)
        log.fold(edge(open: false, at: 4_200_000, duration: 1_200_000), captureRate: rate)
        XCTAssertNil(log.closed[0].tone)
    }

    func testOtherChannelsAndOtherTypesAreIgnored() {
        var log = TransmissionLog(channelID: channel)
        log.fold(edge(open: true, at: 0, channel: "chan_b"), captureRate: rate)
        log.fold(meter(at: 100), captureRate: rate)
        XCTAssertNil(log.onAir)
        log.fold(
            edge(open: false, at: 2_400_000, duration: 2_400_000, channel: "chan_b"),
            captureRate: rate)
        XCTAssertTrue(log.closed.isEmpty)
        XCTAssertEqual(log, TransmissionLog(channelID: channel), "nothing folded")
    }

    func testTheRingKeepsTheNewestFifty() {
        var log = TransmissionLog(channelID: channel)
        for i in 1...(TransmissionLog.capacity + 3) {
            let start = UInt64(i) * 4_800_000
            log.fold(edge(open: true, at: start), captureRate: rate)
            log.fold(
                edge(open: false, at: start + 2_400_000, duration: 2_400_000), captureRate: rate)
        }
        XCTAssertEqual(log.closed.count, TransmissionLog.capacity)
        XCTAssertEqual(
            log.closed.first?.start.sampleIndex, UInt64(TransmissionLog.capacity + 3) * 4_800_000,
            "newest first")
        XCTAssertEqual(log.closed.last?.start.sampleIndex, 4 * 4_800_000, "the oldest three left")
    }

    // MARK: Retunes

    /// The window retunes by writing the capture's centre and then the channel's offset. The
    /// daemon publishes the capture, the channel's offset recomputed to keep its frequency, then
    /// the channel at the offset written: only the last is a new frequency.
    func testARetuneIsTheChannelsOwnOffsetChangingItsFrequency() {
        var watch = ChannelFrequencyWatch()
        XCTAssertFalse(
            watch.observe(offsetHz: 100_000, centerHz: 462_000_000),
            "the first reading is not a change")
        XCTAssertEqual(watch.tunedHz, 462_100_000)
        // The capture's event: new centre, the old offset still in the mirror.
        XCTAssertFalse(
            watch.observe(offsetHz: 100_000, centerHz: 463_000_000),
            "the capture's event alone is not a retune")
        // The channel's recomputed offset: the same frequency as before.
        XCTAssertFalse(
            watch.observe(offsetHz: -900_000, centerHz: 463_000_000),
            "the channel followed its frequency")
        XCTAssertEqual(watch.tunedHz, 462_100_000)
        // The offset the window wrote.
        XCTAssertTrue(watch.observe(offsetHz: 150_000, centerHz: 463_000_000), "the channel moved")
        XCTAssertEqual(watch.tunedHz, 463_150_000)
        XCTAssertFalse(watch.observe(offsetHz: 150_000, centerHz: 463_000_000), "nothing changed")
    }

    func testAnOffsetOnlyRetuneIsARetuneAndAnUnknownCentreIsNot() {
        var watch = ChannelFrequencyWatch()
        _ = watch.observe(offsetHz: 0, centerHz: 146_520_000)
        XCTAssertFalse(watch.observe(offsetHz: 25_000, centerHz: nil), "no capture, no frequency")
        XCTAssertTrue(watch.observe(offsetHz: 25_000, centerHz: 146_520_000))
    }

    // MARK: One log per frequency

    private let gmrs3 = TransmissionLogs.Key(frequencyHz: 462_612_500, mode: .nfm)
    private let gmrs1 = TransmissionLogs.Key(frequencyHz: 462_562_500, mode: .nfm)

    /// A transmission of `seconds` closing at `end`, with its open edge seen.
    private func heard(_ logs: inout TransmissionLogs, openAt start: UInt64, seconds: UInt64) {
        logs.fold(edge(open: true, at: start), captureRate: rate)
        logs.fold(
            edge(open: false, at: start + seconds * rate, duration: seconds * rate),
            captureRate: rate)
    }

    /// The owner, 2026-09-25: "switching channel lost the transmissions". Each frequency keeps
    /// its own rows for the session, and edges fold only into the one tuned.
    func testRowsSurviveASwitchAwayAndBack() {
        var logs = TransmissionLogs()
        XCTAssertNil(logs.log, "no channel, no log")
        XCTAssertTrue(logs.tune(gmrs3, channelID: channel))
        heard(&logs, openAt: 2_400_000, seconds: 2)
        heard(&logs, openAt: 12_000_000, seconds: 1)
        XCTAssertEqual(logs.log?.closed.count, 2)

        XCTAssertTrue(logs.tune(gmrs1, channelID: channel), "a retune switches logs")
        XCTAssertEqual(logs.log?.closed.count, 0, "a new frequency starts empty")
        heard(&logs, openAt: 30_000_000, seconds: 3)
        XCTAssertEqual(logs.log?.closed.map(\.seconds), [3])
        XCTAssertEqual(logs.log(for: gmrs3)?.closed.count, 2, "the old frequency's rows are kept")

        XCTAssertTrue(logs.tune(gmrs3, channelID: channel))
        XCTAssertEqual(logs.log?.closed.map(\.seconds), [1, 2], "back again: the rows are there")
        XCTAssertFalse(logs.tune(gmrs3, channelID: channel), "tuning the current one is nothing")
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs.log(for: gmrs1)?.closed.count, 1, "the other frequency's are kept")
    }

    func testAModeIsItsOwnLog() {
        var logs = TransmissionLogs()
        logs.tune(gmrs3, channelID: channel)
        heard(&logs, openAt: 2_400_000, seconds: 2)
        logs.tune(.init(frequencyHz: gmrs3.frequencyHz, mode: .am), channelID: channel)
        XCTAssertEqual(logs.log?.closed.count, 0)
        XCTAssertEqual(logs.log(for: gmrs3)?.closed.count, 1)
    }

    /// The daemon's close on retune travels on the telemetry stream and the retune on the event
    /// stream, so it can arrive after the switch; it belongs to the log left on air.
    func testTheRetunesCloseEndsTheLogLeftOnAir() {
        var logs = TransmissionLogs()
        logs.tune(gmrs3, channelID: channel)
        logs.fold(edge(open: true, at: 2_400_000), captureRate: rate)
        XCTAssertNotNil(logs.log?.onAir)
        logs.tune(gmrs1, channelID: channel)
        XCTAssertNil(logs.log?.onAir, "nothing is on air on the new frequency yet")
        logs.fold(
            edge(open: false, at: 7_200_000, duration: 4_800_000), captureRate: rate)
        XCTAssertEqual(logs.log?.closed.count, 0, "the close is not the new frequency's")
        XCTAssertNil(logs.log(for: gmrs3)?.onAir, "the old log ends cleanly")
        XCTAssertEqual(logs.log(for: gmrs3)?.closed.map(\.seconds), [2])
        // The next transmission is the new frequency's.
        heard(&logs, openAt: 9_600_000, seconds: 1)
        XCTAssertEqual(logs.log?.closed.map(\.seconds), [1])
        XCTAssertEqual(logs.log(for: gmrs3)?.closed.count, 1)
    }

    /// A daemon that sends no close on retune: the new frequency's open edge comes first, and
    /// the old transmission is dropped rather than left on air for the next visit.
    func testAnOpenEdgeFirstDropsTheTransmissionLeftOnAir() {
        var logs = TransmissionLogs()
        logs.tune(gmrs3, channelID: channel)
        logs.fold(edge(open: true, at: 2_400_000), captureRate: rate)
        logs.tune(gmrs1, channelID: channel)
        logs.fold(edge(open: true, at: 4_800_000), captureRate: rate)
        XCTAssertEqual(logs.log?.onAir?.since, at(4_800_000), "the open edge is the new one's")
        XCTAssertNil(logs.log(for: gmrs3)?.onAir)
        XCTAssertEqual(logs.log(for: gmrs3)?.closed.count, 0)
    }

    /// Two retunes off open transmissions before either close arrives: the closes come in the
    /// order the retunes were made, and each goes to its own log.
    func testClosesAfterTwoQuickRetunesGoToTheirLogsInOrder() {
        var logs = TransmissionLogs()
        let calling = TransmissionLogs.Key(frequencyHz: 146_520_000, mode: .nfm)
        logs.tune(gmrs3, channelID: channel)
        logs.fold(edge(open: true, at: 2_400_000), captureRate: rate)
        logs.tune(gmrs1, channelID: channel)
        logs.tune(calling, channelID: channel)
        logs.fold(edge(open: false, at: 4_800_000, duration: 2_400_000), captureRate: rate)
        XCTAssertEqual(logs.log(for: gmrs3)?.closed.map(\.seconds), [1])
        XCTAssertNil(logs.log(for: gmrs3)?.onAir)
        XCTAssertEqual(logs.log(for: gmrs1)?.closed.count, 0, "nothing was on air there")
        heard(&logs, openAt: 7_200_000, seconds: 2)
        XCTAssertEqual(logs.log?.closed.map(\.seconds), [2], "then edges are the current log's")
    }

    /// Tuned away and straight back before the close arrives: the close ends the current log's
    /// own transmission.
    func testBackBeforeTheCloseLogsItHere() {
        var logs = TransmissionLogs()
        logs.tune(gmrs3, channelID: channel)
        logs.fold(edge(open: true, at: 2_400_000), captureRate: rate)
        logs.tune(gmrs1, channelID: channel)
        logs.tune(gmrs3, channelID: channel)
        XCTAssertNotNil(logs.log?.onAir, "still waiting for its close")
        logs.fold(edge(open: false, at: 4_800_000, duration: 2_400_000), captureRate: rate)
        XCTAssertEqual(logs.log?.closed.map(\.seconds), [1])
        XCTAssertNil(logs.log?.onAir)
    }

    /// A new channel on a frequency already logged (a reconnect, another radio): its rows are
    /// kept and its edges are the new channel's; the old channel's open transmission never
    /// closes on the new subscription, so it is dropped.
    func testANewChannelOnAKnownFrequencyKeepsItsRowsAndDropsTheOpenOne() {
        var logs = TransmissionLogs()
        logs.tune(gmrs3, channelID: channel)
        heard(&logs, openAt: 2_400_000, seconds: 2)
        logs.fold(edge(open: true, at: 12_000_000), captureRate: rate)
        logs.leave()
        XCTAssertNil(logs.log)
        XCTAssertNil(logs.log(for: gmrs3)?.onAir, "the subscription ended: nothing closes it")
        XCTAssertTrue(logs.tune(gmrs3, channelID: "chan_b"))
        XCTAssertEqual(logs.log?.channelID, "chan_b")
        XCTAssertEqual(logs.log?.closed.count, 1)
        logs.fold(edge(open: true, at: 14_400_000), captureRate: rate)
        XCTAssertNil(logs.log?.onAir, "the old channel's edges are not folded")
        logs.fold(edge(open: true, at: 14_400_000, channel: "chan_b"), captureRate: rate)
        XCTAssertNotNil(logs.log?.onAir)
    }

    func testTheLeastRecentlyTunedLogGoesFirst() {
        var logs = TransmissionLogs()
        for i in 0..<TransmissionLogs.capacity {
            logs.tune(
                .init(frequencyHz: 146_000_000 + UInt64(i) * 12_500, mode: .nfm),
                channelID: channel)
        }
        let first = TransmissionLogs.Key(frequencyHz: 146_000_000, mode: .nfm)
        let second = TransmissionLogs.Key(frequencyHz: 146_012_500, mode: .nfm)
        logs.tune(first, channelID: channel)
        heard(&logs, openAt: 2_400_000, seconds: 1)
        logs.tune(gmrs3, channelID: channel)
        XCTAssertEqual(logs.count, TransmissionLogs.capacity)
        XCTAssertNil(logs.log(for: second), "the least recently tuned was dropped")
        XCTAssertEqual(logs.log(for: first)?.closed.count, 1, "tuned again, so it was kept")
    }
}
