// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs: IQ parts, and what the WAV and IQ files and their sidecars hold.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
    // MARK: IQ

    func testAnIQRecordingIsCutIntoContiguousParts() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_520_000
            config.mode = .rawIq
            config.partMs = 300
            config.durationMs = 1200
            let started = try await self.start(c, config)
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 20000)
            XCTAssertNotEqual(done.state, .failed, done.statusDetail)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.kind, "iq")
            XCTAssertEqual(manifest.format, "cf32")
            XCTAssertGreaterThanOrEqual(manifest.parts.count, 3, "a part every 300 ms of a 1.2 s recording")
            for (a, b) in zip(manifest.parts, manifest.parts.dropFirst()) {
                XCTAssertEqual(a.endSample, b.startSample, "parts are contiguous on the sample timebase")
            }
            XCTAssertTrue(manifest.coverageGaps.isEmpty, "and nothing between them is missing")
            for part in manifest.parts {
                XCTAssertEqual(part.bytes, part.samples * 8, "cf32 has no header")
                XCTAssertTrue(part.file.hasSuffix(".cf32"))
            }
        }
    }

    // MARK: What the files actually hold

    /// A recorder that wrote perfectly-formed silence would pass every structural test there is.
    /// This test catches that: the WAV a recording of `nfm_tone` produced carries the 1 kHz tone
    /// at the SNR the fixture's own sidecar specifies for that channel.
    func testARecordedWAVHoldsTheFixturesTone() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = recordFrequencyHz
            config.mode = .nfm
            config.durationMs = 1200
            config.squelchDbfs = -80
            let started = try await self.start(c, config)
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)

            let manifest = try self.manifest(dir, started.jobID)
            let samples = try readWAVSamples(dir + "/" + started.jobID + "/" + manifest.parts[0].file)
            XCTAssertGreaterThan(samples.count, 24000, "at least half a second of audio to measure")
            let (toneHz, snrDB) = dominantTone(samples, rate: Double(manifest.sampleRate))
            // The fixture's own expectation for this channel: a 1 kHz tone at 30 dB or better.
            // Measured 2026-09-18: 1001.95 Hz at 77 dB, against the fixture's own 1 kHz / 30 dB.
            XCTAssertEqual(toneHz, 1000, accuracy: 20, "the recorded audio carries the fixture's tone")
            XCTAssertGreaterThan(snrDB, 30, "and carries it as cleanly as the fixture promises")
        }
    }

    /// The IQ counterpart: the samples a recording wrote are still the band that went in, so a
    /// part is usable in another tool. `scan_band` carries four carriers at known offsets, and
    /// they have to survive the round trip through the ring and the file.
    func testARecordedIQPartHoldsTheCarriersThatWentIn() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "scan_band.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_000_000
            config.mode = .rawIq
            config.durationMs = 1000
            let started = try await self.start(c, config)
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 20000)
            XCTAssertNotEqual(done.state, .failed, done.statusDetail)

            let manifest = try self.manifest(dir, started.jobID)
            let part = try XCTUnwrap(manifest.parts.first)
            let row = try spectrumOf(dir + "/" + started.jobID + "/" + part.file, bins: 4096)
            // scan_band's four carriers, at -800/-400/+400/+800 kHz of the centre.
            let rate = Double(manifest.sampleRate)
            for offset in [-800_000.0, -400_000.0, 400_000.0, 800_000.0] {
                let bin = Int((offset / rate + 0.5) * Double(row.count)).clamped(to: 0..<row.count)
                let peak = (max(0, bin - 6)..<Swift.min(row.count, bin + 7)).map { row[$0] }.max() ?? -200
                let floor = medianOf(row)
                // Measured 2026-09-18 against a -96.7 dB floor: 70.6, 63.8, 60.1 and 27.4 dB over
                // it, in the order the fixture declares (-20, -28, -36, -44 dBFS). The last is the
                // WFM carrier, whose energy is spread over 75 kHz of deviation rather than a bin.
                XCTAssertGreaterThan(peak - floor, 10,
                                     "the carrier at \(offset / 1000) kHz survived the recording (peak \(peak), floor \(floor))")
            }
        }
    }

    // MARK: What a recording holds

    /// A capture whose every sample is at the rails: the recording's part reports how long the
    /// capture's `CaptureLevel` said it clipped, read off the meter the telemetry service
    /// publishes from.
    func testAPartRecordedWhileTheRadioClipsSaysForHowLong() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fixtures = try recordings()
        defer { try? FileManager.default.removeItem(atPath: fixtures) }
        // Half a second at 2.4 MSPS with I at +1 on every sample: a DC carrier at full scale.
        let samples = 1_200_000
        var data = Data(count: samples * 8)
        data.withUnsafeMutableBytes { raw in
            let f = raw.bindMemory(to: Float32.self)
            for i in 0..<samples { f[2 * i] = 1; f[2 * i + 1] = 0 }
        }
        let path = fixtures + "/rails.cf32"
        try data.write(to: URL(fileURLWithPath: path))
        let sidecar = #"{"format":"cf32","sample_rate":2400000,"center_hz":146520000,"samples":1200000,"created_at_ns":0,"anchor":{"host_time_ns":0,"drift_ppm":0}}"#
        try Data(sidecar.utf8).write(to: URL(fileURLWithPath: fixtures + "/rails.json"))

        try await withDaemon(recordingsPath: dir) { c in
            var request = Leyline_V1_AttachFileDeviceRequest()
            request.path = path
            request.loop = true
            _ = try await c.control.attachFileDevice(request, metadata: testMetadata)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_520_000
            config.mode = .nfm
            config.durationMs = 1500
            config.squelchDbfs = -120
            let done = try await self.waitForEnd(c, try await self.start(c, config).jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            let manifest = try self.manifest(dir, done.jobID)
            XCTAssertEqual(manifest.parts.count, 1)
            let clipped = try XCTUnwrap(manifest.parts[0].clippedMs, "a part recorded at the rails says it clipped")
            // Every reading clipped, so the part is charged all of it but the reading still being
            // measured when it closed (at most a quarter second) and whatever the first reading
            // spent before the part opened.
            XCTAssertGreaterThan(clipped, 1000, "\(clipped) ms of 1500")
            XCTAssertLessThanOrEqual(clipped, 1500)
        }
    }

    /// A gated recording of the noise floor with a squelch nothing reaches never opens a part.
    /// Cancelled after a second, it leaves no directory, the job ends COMPLETED saying nothing was
    /// heard, and the recording's URI resolves to nothing (docs/design/recording.md, "Nothing
    /// heard").
    func testARecordingThatHeardNothingIsDiscarded() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "noise_floor.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = recordFrequencyHz
            config.mode = .nfm
            config.gate = .squelch
            config.squelchDbfs = -10
            let started = try await self.start(c, config)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + started.jobID),
                          "the recording exists while it runs")
            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            let cancelled = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            XCTAssertEqual(cancelled.state, .completed)
            XCTAssertEqual(cancelled.statusDetail, "nothing was heard")
            XCTAssertEqual(cancelled.resultUris, ["ley://recordings/\(started.jobID)"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + started.jobID),
                           "the directory went with it")

            var list = Leyline_V1_ListResourcesRequest()
            list.kind = .recording
            let listed = try await c.resources.listResources(list, metadata: testMetadata)
            XCTAssertTrue(listed.resources.isEmpty, "\(listed.resources.map(\.uri))")
            var resource = Leyline_V1_ResourceRef()
            resource.uri = "ley://recordings/\(started.jobID)"
            do {
                _ = try await c.resources.getResource(resource, metadata: testMetadata)
                XCTFail("a discarded recording resolved")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.jobNotFound)
            }

            // The same on its own ending: a duration that runs out with nothing heard.
            config.durationMs = 600
            let timed = try await self.waitForEnd(c, try await self.start(c, config).jobID)
            XCTAssertEqual(timed.state, .completed)
            XCTAssertEqual(timed.statusDetail, "nothing was heard")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + timed.jobID))
        }
    }
}
