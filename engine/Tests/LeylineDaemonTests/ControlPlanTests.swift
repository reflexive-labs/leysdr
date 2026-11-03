// SPDX-License-Identifier: GPL-3.0-or-later

// Control.Plan (docs/design/claims.md, "One decision: plan"): the placement StartJob would make,
// returned without making it.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
import LeylineProto
import XCTest

final class ControlPlanTests: XCTestCase {
    private func plan(_ c: DaemonClients, _ build: (inout Leyline_V1_PlanRequest) -> Void) async throws -> Leyline_V1_CapturePlan {
        var request = Leyline_V1_PlanRequest()
        build(&request)
        return try await c.control.plan(request, metadata: testMetadata)
    }

    func testPlansWithoutCarryingOut() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_tone.cf32")) else { throw XCTSkip("fixture missing") }
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fake", recipe: (146_520_000, 15_000))
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata).deviceID

            // An idle radio: a decode would open a capture on it.
            var p = try await self.plan(c) { $0.decode = .with { $0.decoder = "fake" } }
            XCTAssertEqual(p.create.deviceID, device, "\(p)")
            XCTAssertEqual(p.create.centerHz, 146_520_000)

            // A person's capture and channel.
            var create = Leyline_V1_CreateCaptureRequest()
            create.deviceID = device
            create.centerHz = 146_520_000
            let captureID = try await c.control.createCapture(create, metadata: testMetadata).captureID
            var ch = Leyline_V1_CreateChannelRequest()
            ch.captureID = captureID
            ch.offsetHz = 100_000
            ch.mode = .nfm
            let channel = try await c.control.createChannel(ch, metadata: testMetadata)

            // Inside the span: shared.
            p = try await self.plan(c) { $0.decode = .with { $0.decoder = "fake" } }
            XCTAssertEqual(p.share.captureID, captureID, "\(p)")
            XCTAssertEqual(p.share.deviceID, device)
            XCTAssertEqual(p.share.centerHz, 146_520_000)

            // Outside it, on the only radio, a person listening: declined, naming the person.
            p = try await self.plan(c) {
                $0.record = .with {
                    $0.frequencyHz = 162_400_000
                    $0.mode = .nfm
                }
            }
            XCTAssertEqual(p.decline.code, "DEVICE_BUSY", "\(p)")
            XCTAssertEqual(p.decline.reason, "a terminal is listening on 146.620 MHz")
            XCTAssertTrue(p.decline.blocking.contains { $0.kind == .claimChannel && $0.holder.clientID == testClientID }, "\(p)")

            // A recording of the channel shares its capture.
            p = try await self.plan(c) { $0.record = .with { $0.channelID = channel.channelID } }
            XCTAssertEqual(p.share.captureID, captureID, "\(p)")

            // A retune by the person: their own channel is not counted as displaced.
            p = try await self.plan(c) {
                $0.retune = .with {
                    $0.captureID = captureID
                    $0.centerHz = 146_520_000
                }
            }
            XCTAssertEqual(p.retune.captureID, captureID, "\(p)")
            XCTAssertTrue(p.retune.displaced.isEmpty, "\(p)")
            p = try await self.plan(c) {
                $0.retune = .with {
                    $0.captureID = captureID
                    $0.centerHz = 433_920_000
                }
            }
            XCTAssertEqual(p.decline.code, "FREQ_OUT_OF_RANGE", "a file radio tunes only where it recorded: \(p)")

            // A request StartJob would refuse is the same RPC error.
            do {
                _ = try await self.plan(c) { $0.decode = .with { $0.decoder = "nosuch" } }
                XCTFail("an unknown decoder has no plan")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.decoderNotFound)
            }
            do {
                _ = try await self.plan(c) { _ in }
                XCTFail("an empty request has no plan")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.invalidArgument)
            }

            // Nothing was carried out.
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.count, 1)
            XCTAssertEqual(state.captures.first?.centerHz, 146_520_000)
            XCTAssertEqual(state.channels.count, 1)
            XCTAssertTrue(state.jobs.isEmpty, "\(state.jobs)")
        }
    }
}
