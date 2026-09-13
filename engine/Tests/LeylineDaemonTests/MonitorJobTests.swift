// SPDX-License-Identifier: GPL-3.0-or-later

// The stationary band-watch, end to end through the daemon and headless from a fixture. A monitor
// parks one capture on a band and streams detections continuously; unlike a sweep it never retunes,
// so a file device -- whose only tuning point is the frequency its recording was made at -- is a
// good harness for it. scan_band.cf32 is centred at 146.0 MHz, so a band beginning 10% of Fs above
// that centre lands exactly on the file's tuning point and the AM carrier at 146.4 MHz sits inside
// the analysable window. See docs/design/band-watching.md and docs/design/scan.md.

import EngineCore
import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// Collects the detections that arrive on the daemon-wide DETECTION telemetry stream.
private actor DetectionCollector {
    private var dets: [Leyline_V1_Detection] = []
    func add(_ d: Leyline_V1_Detection) { dets.append(d) }
    func all() -> [Leyline_V1_Detection] { dets }
}

final class MonitorJobTests: XCTestCase {
    /// A monitor streams detections for the carriers in its band, completes at its duration, and
    /// hands the radio back -- the lease created the capture, so release destroys it.
    func testMonitorStreamsDetectionsAndHandsBackTheRadio() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("scan_band.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("scan_band.cf32")
            attach.loop = true
            _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            try await Task.sleep(nanoseconds: 200_000_000)

            // Subscribe to detections daemon-wide before the monitor starts, so none is missed.
            let collector = DetectionCollector()
            var sub = Leyline_V1_TelemetrySubscription()
            sub.types = [.detection]
            let subTask = Task {
                try? await c.telemetry.subscribe(sub, metadata: testMetadata) { response in
                    for try await m in response.messages {
                        if case .detection(let d) = m.body { await collector.add(d) }
                    }
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)

            // range_lo - 0.10*Fs = 146.24M - 0.24M = 146.0M, the file's own centre.
            var config = Leyline_V1_MonitorConfig()
            config.range.minHz = 146_240_000
            config.range.maxHz = 146_900_000
            config.durationMs = 2000
            let job = try await c.jobs.startJob(.with { $0.config = .monitor(config) }, metadata: testMetadata)
            XCTAssertEqual(job.state, .running)

            var final = job
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while final.state == .running, ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                final = try await c.jobs.getJob(.with { $0.jobID = job.jobID }, metadata: testMetadata)
            }
            subTask.cancel()
            XCTAssertEqual(final.state, .completed, final.statusDetail)
            XCTAssertTrue(final.statusDetail.contains("watched"), final.statusDetail)

            let dets = await collector.all()
            XCTAssertFalse(dets.isEmpty, "no detections streamed on the DETECTION plane")
            // The AM carrier at 146.4 MHz is ~24 dB over the floor and sits in the analysable window.
            let am = dets.filter { $0.centerHz > 146_380_000 && $0.centerHz < 146_420_000 }
            XCTAssertFalse(am.isEmpty, "nothing near 146.4 MHz in \(dets.map(\.centerHz))")
            let d = am.max { $0.lastSeen.sampleIndex < $1.lastSeen.sampleIndex }!
            // A carrier that stays up re-publishes with a growing last_seen: the client times it by
            // watching first_seen precede an advancing last_seen.
            XCTAssertGreaterThan(d.lastSeen.sampleIndex, d.firstSeen.sampleIndex, "a monitored carrier must accumulate time")
            XCTAssertFalse(d.firstSeen.captureID.isEmpty, "invariant 5: detections carry sample time")
            XCTAssertEqual(d.modulationGuess, "", "invariant 12: v0 has no opinion about modulation")

            // The radio is handed back: nothing is left leased.
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.captures.isEmpty, "the monitor left a capture behind")
        }
    }

    /// A band too wide to fit one analysable quarter-band is declined INVALID_ARGUMENT, and the
    /// decline leaves nothing parked.
    func testTooWideBandIsDeclined() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("scan_band.cf32")) else { throw XCTSkip("fixture missing") }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("scan_band.cf32")
            attach.loop = true
            _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            try await Task.sleep(nanoseconds: 200_000_000)

            // 960 kHz is wider than (edge - begin) * Fs = 0.35 * 2.4 MHz = 840 kHz.
            var config = Leyline_V1_MonitorConfig()
            config.range.minHz = 146_240_000
            config.range.maxHz = 147_200_000
            config.durationMs = 2000
            let job = try await c.jobs.startJob(.with { $0.config = .monitor(config) }, metadata: testMetadata)

            var final = job
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while final.state == .running, ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                final = try await c.jobs.getJob(.with { $0.jobID = job.jobID }, metadata: testMetadata)
            }
            XCTAssertEqual(final.state, .failed, final.statusDetail)
            XCTAssertEqual(final.error.code, EngineError.Code.invalidArgument)
            XCTAssertTrue(final.statusDetail.contains("too wide"), final.statusDetail)
            XCTAssertFalse(final.statusDetail.contains(EngineError.Code.invalidArgument), "the code is a field, not a prefix")

            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.captures.isEmpty, "a declined monitor left a capture behind")
        }
    }
}
