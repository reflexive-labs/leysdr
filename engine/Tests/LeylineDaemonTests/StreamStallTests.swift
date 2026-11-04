// SPDX-License-Identifier: GPL-3.0-or-later

// A live decode job whose capture stops delivering samples says so (StreamStall): DEGRADED with
// "no samples from <radio> for N s", and RUNNING again when blocks come back. No records is not
// this: a quiet band is legitimately silent (DEC-16), and the job stays RUNNING through it.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class StreamStallTests: XCTestCase {
    /// The rule on its own clock: blocks moving, a rate change and a detached capture are not a
    /// stall; the same count for `after` is, and its seconds stay put while it lasts.
    func testTheStallRule() {
        var stall = StreamStall(after: .seconds(5))
        let t0 = ContinuousClock.now
        func at(_ s: Double) -> ContinuousClock.Instant { t0 + .milliseconds(Int(s * 1000)) }
        func look(_ blocks: UInt64, generation: UInt64 = 0, detached: Bool = false, _ s: Double) -> String? {
            stall.look(StreamProgress(blocks: blocks, generation: generation, detached: detached, radio: "NESDR"), now: at(s))
        }
        XCTAssertNil(look(1, 0))
        XCTAssertNil(look(2, 3), "blocks arrived")
        XCTAssertNil(look(2, 7.9), "4.9 s quiet is inside the limit")
        XCTAssertEqual(look(2, 8.1), "no samples from NESDR for 5 s")
        XCTAssertEqual(look(2, 20), "no samples from NESDR for 5 s", "the detail does not tick, so it is published once")
        XCTAssertNil(look(3, 20.1), "the first block back ends it")
        XCTAssertNil(look(3, generation: 1, 24), "a rate change restarts the stream and the count")
        XCTAssertNil(look(3, generation: 1, 28.9))
        XCTAssertNil(look(3, generation: 1, detached: true, 40), "a detached capture is away, not stalled")
        XCTAssertNil(look(3, generation: 1, 44))
        XCTAssertEqual(look(3, generation: 1, 46), "no samples from NESDR for 6 s")
    }

    func testAnIQJobSaysWhenItsRadioStopsDelivering() async throws {
        try await stallAndRecover(signal: .signalIq, decoder: "fakeiq")
    }

    func testAnAudioJobSaysWhenItsRadioStopsDelivering() async throws {
        try await stallAndRecover(signal: .signalAudio, decoder: "fake")
    }

    /// Starts a decode job on a ScriptedRadio, stops its stream, waits for the DEGRADED detail,
    /// then lets the stream go again and waits for RUNNING.
    private func stallAndRecover(signal: Leyline_V1_DecoderSignal, decoder: String) async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: decoder, signal: signal)
        try await withDaemon(decoderSearchPath: [plugins], decodeStallAfter: .seconds(1)) { c in
            let radio = ScriptedRadio()
            _ = try await c.daemon.registry.attachVirtualDevice(radio)
            try await Task.sleep(nanoseconds: 200_000_000)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = decoder
            var request = Leyline_V1_StartJobRequest()
            request.decode = config
            let started = try await c.jobs.startJob(request, metadata: testMetadata)

            var job = try await self.wait(c, started.jobID) { $0.statusDetail.hasPrefix("decoding with") }
            XCTAssertEqual(job.state, .running, job.statusDetail)

            radio.stalled.value = true
            job = try await self.wait(c, started.jobID) { $0.state == .degraded }
            XCTAssertEqual(job.statusDetail, "no samples from Scripted RTL for 1 s")

            radio.stalled.value = false
            job = try await self.wait(c, started.jobID) { $0.state == .running }
            XCTAssertTrue(job.statusDetail.hasPrefix("decoding with \(decoder)"), job.statusDetail)

            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
        }
    }

    /// The job once `done` holds for it, failing after 10 s.
    private func wait(_ c: DaemonClients, _ id: String,
                      until done: (Leyline_V1_Job) -> Bool) async throws -> Leyline_V1_Job
    {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        var last = try await c.jobs.getJob(ref, metadata: testMetadata)
        for _ in 0..<200 where !done(last) {
            try await Task.sleep(nanoseconds: 50_000_000)
            last = try await c.jobs.getJob(ref, metadata: testMetadata)
        }
        XCTAssertTrue(done(last), "the job never got there: \(last.state) \(last.statusDetail)")
        return last
    }
}
