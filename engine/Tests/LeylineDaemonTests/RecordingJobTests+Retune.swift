// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs under a retune (docs/design/claims.md, "Displacement, uniformly"; plan CL-3): an IQ
// recording never writes two tunings into one file, pauses while the capture is away from its
// frequency, and its claim says who moved the radio.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
    private func retunable(_ c: DaemonClients) async throws -> String {
        let id = try await c.daemon.registry.attachVirtualDevice(RebindableDevice(blockIntervalNs: 2_000_000)).descriptor.id.string
        for _ in 0..<150 {
            let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if s.devices.contains(where: { $0.deviceID == id }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return id
    }

    private func tune(_ c: DaemonClients, _ captureID: String, tag: UInt64, to hz: UInt64) async throws {
        var w = Leyline_V1_ParamWrite()
        w.tag = tag
        w.targetID = captureID
        w.centerHz = hz
        let message = w
        _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
    }

    private func claim(_ c: DaemonClients, of jobID: String) async throws -> Leyline_V1_Claim? {
        try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            .captures.flatMap(\.claims).first { $0.holder.clientID == jobID }
    }

    private func waitForJob(_ c: DaemonClients, _ id: String, _ why: String,
                            _ pred: (Leyline_V1_Job) -> Bool) async throws -> Leyline_V1_Job {
        var j = try await job(c, id)
        for _ in 0..<200 where !pred(j) {
            try await Task.sleep(nanoseconds: 50_000_000)
            j = try await job(c, id)
        }
        XCTAssertTrue(pred(j), "\(why): \(j.state) \(j.statusDetail)")
        return j
    }

    private func sidecarCentre(_ dir: String, _ jobID: String, _ part: RecordingPart) throws -> UInt64? {
        let base = (part.file as NSString).deletingPathExtension
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + jobID + "/" + base + ".json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["center_hz"] as? NSNumber)?.uint64Value
    }

    /// A retune that keeps the frequency in span closes the part and opens the next at the new
    /// centre; one that loses it pauses the recording (DEGRADED, naming who moved the radio, the
    /// claim DISPLACED by them) and marks the gap; coming back resumes it in a new part.
    func testAnIQRecordingStartsANewPartAtEveryRetune() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let device = try await self.retunable(c)
            var create = Leyline_V1_CreateCaptureRequest()
            create.deviceID = device
            create.centerHz = 100_500_000
            let captureID = try await c.control.createCapture(create, metadata: testMetadata).captureID

            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 100_100_000
            config.mode = .rawIq
            let started = try await self.start(c, config)
            XCTAssertEqual(started.state, .running, started.statusDetail)
            try await Task.sleep(nanoseconds: 400_000_000)

            // Recentred, 100.1 MHz still in span: a new part at the new centre, still RUNNING.
            try await self.tune(c, captureID, tag: 1, to: 100_300_000)
            try await Task.sleep(nanoseconds: 400_000_000)
            let followed = try await self.job(c, started.jobID)
            XCTAssertEqual(followed.state, .running, followed.statusDetail)
            let satisfiedFound = try await self.claim(c, of: started.jobID)
            let satisfied = try XCTUnwrap(satisfiedFound)
            XCTAssertEqual(satisfied.state, .claimSatisfied)
            XCTAssertFalse(satisfied.hasDisplacedBy)

            // Off it: paused, and the detail and the claim say who moved the radio and where.
            try await self.tune(c, captureID, tag: 2, to: 103_000_000)
            let paused = try await self.waitForJob(c, started.jobID, "paused with who moved it") {
                $0.state == .degraded && $0.statusDetail.contains("tuned")
            }
            XCTAssertTrue(paused.statusDetail.hasPrefix("paused since "), paused.statusDetail)
            XCTAssertTrue(paused.statusDetail.hasSuffix(
                ": a terminal tuned rebindable to 103.000 MHz; resumes when 100.100 MHz is back in the capture"),
                paused.statusDetail)
            let displacedFound = try await self.claim(c, of: started.jobID)
            let displaced = try XCTUnwrap(displacedFound)
            XCTAssertEqual(displaced.state, .claimDisplaced)
            XCTAssertEqual(displaced.displacedBy.clientID, testClientID)
            XCTAssertGreaterThan(displaced.displacedSinceNs, 0)
            try await Task.sleep(nanoseconds: 400_000_000)

            // Back: RUNNING, the claim satisfied again, and a new part.
            try await self.tune(c, captureID, tag: 3, to: 100_100_000)
            _ = try await self.waitForJob(c, started.jobID, "back") { $0.state == .running }
            let backFound = try await self.claim(c, of: started.jobID)
            let back = try XCTUnwrap(backFound)
            XCTAssertEqual(back.state, .claimSatisfied)
            XCTAssertFalse(back.hasDisplacedBy)
            try await Task.sleep(nanoseconds: 400_000_000)

            _ = try await c.jobs.cancelJob(.with { $0.jobID = started.jobID }, metadata: testMetadata)
            _ = try await self.waitForEnd(c, started.jobID)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.parts.count, 3, "\(manifest.parts.map { ($0.startSample, $0.endSample) })")
            guard manifest.parts.count == 3 else { return }
            let centres = try manifest.parts.map { try self.sidecarCentre(dir, started.jobID, $0) }
            XCTAssertEqual(centres, [100_500_000, 100_300_000, 100_100_000], "one tuning per file")
            let (a, b, last) = (manifest.parts[0], manifest.parts[1], manifest.parts[2])
            XCTAssertEqual(a.endSample, b.startSample, "a retune that keeps the frequency loses nothing")
            XCTAssertLessThan(b.endSample, last.startSample, "nothing is written while the capture is away")
            let away = manifest.coverageGaps.filter { $0.reason == "out of capture" }
            XCTAssertEqual(away.count, 1, "\(manifest.coverageGaps.map(\.reason))")
            XCTAssertEqual(away.first?.fromSample, b.endSample)
            XCTAssertEqual(away.first?.toSample, last.startSample)
        }
    }
}
