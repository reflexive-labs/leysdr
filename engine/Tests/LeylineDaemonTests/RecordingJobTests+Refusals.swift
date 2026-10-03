// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs: the requests the daemon refuses before a radio is touched.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
    // MARK: Refusals, before a radio is touched

    func testTheRefusalsTheDaemonOwns() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            func refusal(_ config: Leyline_V1_RecordConfig) async -> RPCError? {
                do {
                    _ = try await self.start(c, config)
                    return nil
                } catch let e as RPCError {
                    return e
                } catch {
                    return nil
                }
            }
            var gateOnIQ = Leyline_V1_RecordConfig()
            gateOnIQ.frequencyHz = recordFrequencyHz
            gateOnIQ.mode = .rawIq
            gateOnIQ.gate = .squelch
            var got = await refusal(gateOnIQ)
            var e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .invalidArgument)
            XCTAssertTrue(e.message.contains("IQ recording has no channel"), e.message)

            var quietWithoutGate = Leyline_V1_RecordConfig()
            quietWithoutGate.frequencyHz = recordFrequencyHz
            quietWithoutGate.mode = .nfm
            quietWithoutGate.stopAfterQuietMs = 10_000
            got = await refusal(quietWithoutGate)
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .invalidArgument)
            XCTAssertTrue(e.message.contains("squelch gate"), e.message)

            var missingChannel = Leyline_V1_RecordConfig()
            missingChannel.channelID = "chan_01J8XQ2M7V3N9K5R4T6W8Y0ZAB"
            got = await refusal(missingChannel)
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .notFound)

            var scheduled = Leyline_V1_RecordConfig()
            scheduled.frequencyHz = recordFrequencyHz
            scheduled.startAtNs = WallClock.realNowNs() + 60_000_000_000
            got = await refusal(scheduled)
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .unimplemented)
        }
    }

    func testAGatedRecordingOfAChannelWithNoSquelchIsRefused() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            // Somebody listening, with the squelch off, is the case the refusal exists for.
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let device = try XCTUnwrap(state.devices.first)
            var capture = Leyline_V1_CreateCaptureRequest()
            capture.deviceID = device.deviceID
            capture.centerHz = 146_520_000
            capture.sampleRate = device.sampleRates.first ?? 2_400_000
            let made = try await c.control.createCapture(capture, metadata: testMetadata)
            var channel = Leyline_V1_CreateChannelRequest()
            channel.captureID = made.captureID
            channel.offsetHz = 100_000
            channel.mode = .nfm
            let listening = try await c.control.createChannel(channel, metadata: testMetadata)
            XCTAssertTrue(listening.squelchDb.isNaN, "a fresh channel has no squelch")

            var config = Leyline_V1_RecordConfig()
            config.channelID = listening.channelID
            config.gate = .squelch
            do {
                _ = try await self.start(c, config)
                XCTFail("a gate with no squelch to watch should be refused")
            } catch let e as RPCError {
                XCTAssertEqual(e.code, .failedPrecondition)
                XCTAssertTrue(e.message.contains("ley set squelch"), e.message)
            }
        }
    }
}
