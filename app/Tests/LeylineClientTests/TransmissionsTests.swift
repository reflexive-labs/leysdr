// SPDX-License-Identifier: Apache-2.0

// The transmissions log, without a daemon: edges to transmissions, the reconstructed start,
// the tone under a transmission and its heartbeat, the ring, and another channel's edges. The
// edge rules are the ones `go/internal/cli/transmission_test.go` holds `ley tune` to.

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
        _ kind: Leyline_V1_SubAudibleKind, standard: Double, measured: Double, at index: UInt64
    ) -> Leyline_V1_TelemetryMsg {
        .with {
            $0.time = at(index)
            $0.subAudible = .with {
                $0.channelID = channel
                $0.kind = kind
                $0.standardToneHz = standard
                $0.toneHz = measured
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
        XCTAssertEqual(log.onAir?.tone, CTCSSTone(standardHz: 100, measuredHz: 100.2))
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
        XCTAssertEqual(log.closed[0].tone, CTCSSTone(standardHz: 100, measuredHz: 100.2))

        // A measurement between two standard tones is not a tone here: picking one is a guess.
        log.fold(edge(open: true, at: 6_000_000), captureRate: rate)
        log.fold(
            tone(.subAudibleCtcss, standard: 0, measured: 68.1, at: 6_240_000), captureRate: rate)
        XCTAssertNil(log.onAir?.tone)
        log.fold(edge(open: false, at: 7_200_000, duration: 1_200_000), captureRate: rate)
        XCTAssertNil(log.closed[0].tone)
        XCTAssertEqual(log.closed.count, 2)
    }

    func testAToneHeardBeforeAnUnseenOpenEdgeGoesWithThatClose() {
        var log = TransmissionLog(channelID: channel)
        // Subscribed mid-transmission: the heartbeat arrives before any edge does.
        log.fold(
            tone(.subAudibleCtcss, standard: 123, measured: 123.0, at: 1_000), captureRate: rate)
        XCTAssertNil(log.onAir)
        log.fold(edge(open: false, at: 2_400_000, duration: 2_400_000), captureRate: rate)
        XCTAssertEqual(log.closed[0].tone?.standardHz, 123)
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
}
