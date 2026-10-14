// SPDX-License-Identifier: GPL-3.0-or-later

// A decoder whose provider refuses a request: a kept job waits it out on the restart backoff and
// comes back, any other job ends with PROVIDER_REFUSED and the provider's words
// (docs/dev/engine-internals.md, "Decoders").

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

final class DecodeRefusalTests: XCTestCase {
    private let providerWords = "rate_limit_error: this request would exceed your rate limit (fake provider)"

    private func startRefusingJob(_ c: DaemonClients, keep: Bool) async throws -> Leyline_V1_Job {
        var attach = Leyline_V1_AttachFileDeviceRequest()
        attach.path = fixturePath("nfm_tone.cf32")
        attach.loop = true
        _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
        var config = Leyline_V1_DecodeConfig()
        config.decoder = "speechy"
        config.frequencyHz = decodeFrequencyHz
        config.keep = keep
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    private func jobEvent(_ events: EventCollector, _ id: String, timeoutMs: Int = 15000,
                          _ pred: @escaping (Leyline_V1_Job) -> Bool) async -> Leyline_V1_Job?
    {
        let event = await events.waitFor(timeoutMs: timeoutMs) {
            if case .job(let j)? = $0.body { return j.jobID == id && pred(j) }
            return false
        }
        if case .job(let j)? = event?.body { return j }
        return nil
    }

    func testAKeptJobDegradesOnARefusalAndComesBack() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "speechy", args: ["--refuse-after=3"], credentialProvider: "fakeprov")
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            let job = try await self.startRefusingJob(c, keep: true)
            let degraded = await self.jobEvent(events, job.jobID) { $0.state == .degraded }
            XCTAssertEqual(degraded?.statusDetail.hasPrefix("the provider refused: \(self.providerWords)"), true,
                           degraded?.statusDetail ?? "no DEGRADED event")
            let seq = await events.events.last?.seq ?? 0
            let back = await events.waitFor(timeoutMs: 15000) {
                if case .job(let j)? = $0.body { return $0.seq > seq && j.jobID == job.jobID && j.state == .running }
                return false
            }
            XCTAssertNotNil(back, "the job comes back once the provider stops refusing")
            let now = try await c.jobs.getJob({ var r = Leyline_V1_JobRef(); r.jobID = job.jobID; return r }(), metadata: testMetadata)
            XCTAssertTrue(JobStore.isLive(now.state), "a kept job outlasts a refusal: \(now.state)")
            XCTAssertFalse(now.hasError)
            await events.stop()
            _ = try await c.jobs.cancelJob({ var r = Leyline_V1_JobRef(); r.jobID = job.jobID; return r }(), metadata: testMetadata)
        }
    }

    func testAJobNotKeptEndsWithTheProvidersRefusal() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "speechy", args: ["--refuse-after=3"], credentialProvider: "fakeprov")
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            let job = try await self.startRefusingJob(c, keep: false)
            let failed = await self.jobEvent(events, job.jobID) { $0.state == .failed }
            XCTAssertEqual(failed?.error.code, EngineError.Code.providerRefused)
            XCTAssertEqual(failed?.error.message, "fakeprov refused the request: \(self.providerWords)")
            XCTAssertEqual(failed?.statusDetail, failed?.error.message)
            let degraded = await events.events.contains {
                if case .job(let j)? = $0.body { return j.jobID == job.jobID && j.state == .degraded }
                return false
            }
            XCTAssertFalse(degraded, "a job nobody kept is not retried")
            await events.stop()
        }
    }
}
