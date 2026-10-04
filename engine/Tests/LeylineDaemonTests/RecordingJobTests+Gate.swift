// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs: where a squelch-gated recording cuts, against the fixture's answer key and on a
// carrier that never stops.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
    // MARK: The gate, against the fixture's own answer key

    /// The keying nfm_keyed states in its sidecar, in seconds.
    func keyedSegments() throws -> [(start: Double, end: Double)] {
        let path = fixturePath("nfm_keyed.json")
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("fixture missing: \(path)") }
        struct Sidecar: Decodable {
            struct Expect: Decodable {
                struct Record: Decodable {
                    struct Segment: Decodable {
                        let start_s: Double
                        let end_s: Double
                    }

                    let segments: [Segment]
                }

                let record: Record?
            }

            let expect: [Expect]
        }
        let sidecar = try JSONDecoder().decode(Sidecar.self, from: data)
        let record = try XCTUnwrap(sidecar.expect.first?.record)
        return record.segments.map { ($0.start_s, $0.end_s) }
    }

    func gatedConfig(hangMs: UInt32) -> Leyline_V1_RecordConfig {
        var config = Leyline_V1_RecordConfig()
        config.frequencyHz = recordFrequencyHz
        config.mode = .nfm
        config.gate = .squelch
        config.squelchDbfs = -40
        config.preRollMs = 500
        config.hangMs = hangMs
        // The fixture is 10.5 s; a second past the end leaves room for the last hang to elapse.
        config.durationMs = 11_500
        return config
    }

    func testAShortHangCutsOnePartPerTransmission() async throws {
        let segments = try keyedSegments()
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: false)
            let started = try await self.start(c, self.gatedConfig(hangMs: 1000))
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 30000)
            XCTAssertNotEqual(done.state, .failed, done.statusDetail)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.parts.count, segments.count,
                           "one part per transmission when the hang is shorter than the gaps")
            XCTAssertEqual(manifest.gate?.kind, "squelch")
            let rate = Double(manifest.anchors[0].sampleRate)
            // A cut lands within one capture block of the transition: 16384 samples, 6.8 ms at
            // 2.4 MSPS. The tolerance is 150 ms, which also covers the squelch detector's own
            // attack and the meter interval it decides on.
            for (i, want) in segments.enumerated() where i < manifest.parts.count {
                let part = manifest.parts[i]
                let startS = Double(part.startSample) / rate + 0.5 // the pre-roll is before the key-up
                XCTAssertEqual(startS, want.start, accuracy: 0.15, "part \(i + 1) starts at the key-up")
                XCTAssertEqual(part.squelchOpens, 1, "one over per part at this hang")
                // The fixture's last transmission runs to the end of the file, so there is no
                // key-down for it to find: that part ends where the samples did.
                guard i < segments.count - 1 else { continue }
                let endS = Double(part.endSample) / rate - 1.0 // the hang is after the key-down
                XCTAssertEqual(endS, want.end, accuracy: 0.15, "part \(i + 1) ends at the key-down")
            }
            // Unrecorded time is listed rather than hidden inside one file (invariant 5).
            XCTAssertEqual(manifest.coverageGaps.count, segments.count - 1,
                           "a gap between every pair of parts")
        }
    }

    func testTheDefaultHangKeepsAnExchangeInOnePart() async throws {
        let segments = try keyedSegments()
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: false)
            // The default 5 s hang, which is longer than the fixture's 3 s gaps.
            var config = self.gatedConfig(hangMs: 0)
            config.durationMs = 11_500
            let started = try await self.start(c, config)
            let done = try await self.waitForEnd(c, started.jobID, timeoutMs: 30000)
            XCTAssertNotEqual(done.state, .failed, done.statusDetail)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.parts.count, 1, "one exchange, one part")
            XCTAssertEqual(manifest.parts[0].squelchOpens, segments.count,
                           "every opening inside the part is counted, so the overs stay countable")
            XCTAssertEqual(manifest.gate?.hangMs, JobStore.defaultHangMs)
            XCTAssertEqual(manifest.gate?.preRollMs, 500)

            // The part sidecar lists the overs themselves, on the capture's timeline.
            let base = (manifest.parts[0].file as NSString).deletingPathExtension
            let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + started.jobID + "/" + base + ".json"))
            let sidecar = try JSONDecoder().decode(PartSidecar.self, from: data)
            XCTAssertEqual(sidecar.recording.squelchOpens.count, segments.count)
            let rate = Double(manifest.anchors[0].sampleRate)
            for (i, want) in segments.enumerated() where i < sidecar.recording.squelchOpens.count {
                let open = Double(sidecar.recording.squelchOpens[i].openSample) / rate
                XCTAssertEqual(open, want.start, accuracy: 0.15, "over \(i + 1) opens at the key-up")
            }
        }
    }

    // MARK: The gate on a carrier that never stops

    /// Cancels the job after `seconds` and returns the manifest it left. The part on disk must
    /// agree with the manifest either way.
    private func cancelAfter(_ c: DaemonClients, _ dir: String, _ jobID: String,
                             seconds: Double) async throws -> RecordingManifest {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        var ref = Leyline_V1_JobRef()
        ref.jobID = jobID
        _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
        let done = try await waitForEnd(c, jobID)
        XCTAssertEqual(done.state, .cancelled, done.statusDetail)
        return try manifest(dir, jobID)
    }

    /// What a gated recording of `nfm_tone` cancelled after two seconds must hold: one part of
    /// about two seconds, opened by the squelch that was already open.
    private func assertOneTwoSecondPart(_ manifest: RecordingManifest, _ dir: String, _ jobID: String) throws {
        XCTAssertEqual(manifest.endedBy, "cancelled")
        XCTAssertEqual(manifest.parts.count, 1, "the carrier holds the squelch open, so the whole recording is one part")
        let part = try XCTUnwrap(manifest.parts.first)
        let rate = Double(manifest.anchors[0].sampleRate)
        let seconds = Double(part.endSample - part.startSample) / rate
        // The sleep is two seconds of wall clock; the file device plays in real time, and the
        // first frame arrives a block or two after the job starts.
        XCTAssertEqual(seconds, 2, accuracy: 0.5, "about two seconds on the capture's timeline")
        XCTAssertEqual(Double(part.samples) / Double(manifest.sampleRate), seconds, accuracy: 0.1,
                       "and the WAV holds that much audio")
        XCTAssertEqual(part.squelchOpens, 1, "one over: the one already in progress")
        let file = dir + "/" + jobID + "/" + part.file
        XCTAssertFalse(WAVHeader.needsRepair(path: file), "cancel finalised the open part")
        let tone = dominantTone(try readWAVSamples(file), rate: Double(manifest.sampleRate))
        XCTAssertEqual(tone.hz, 1000, accuracy: 20, "the part holds the fixture's tone, not silence")
    }

    /// A broadcast's squelch is open before the recording starts and never closes, so no transition
    /// arrives. The job's own channel gets its squelch after it is built, in place, and the carrier
    /// keeps it open across that write: no edge there either. A gate that waited for an edge would
    /// finalise an empty recording on cancel.
    func testAGatedRecordingOfACarrierThatNeverStopsHoldsOnePart() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = self.gatedConfig(hangMs: 1000)
            config.durationMs = 0
            let started = try await self.start(c, config)
            let manifest = try await self.cancelAfter(c, dir, started.jobID, seconds: 2)
            try self.assertOneTwoSecondPart(manifest, dir, started.jobID)
        }
    }

    /// The app's channel page has no squelch to copy and sends NaN, which asks a gated recording
    /// for the channel default, not "off": a gate with the squelch off has nothing to watch. The
    /// auto squelch the daemon measures sits over the band's floor, so the carrier opens it.
    func testAGatedRecordingAskingForNoSquelchGetsTheAutoSquelchUnderTheCarrier() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = self.gatedConfig(hangMs: 1000)
            config.durationMs = 0
            config.squelchDbfs = .nan
            let started = try await self.start(c, config)
            let manifest = try await self.cancelAfter(c, dir, started.jobID, seconds: 2)
            XCTAssertTrue(manifest.squelchDbfs.isFinite, "a gated recording always has a squelch")
            // The fixture's carrier is at -20 dBFS.
            XCTAssertLessThan(manifest.squelchDbfs, -30, "the auto squelch sits over the floor, under the carrier")
            XCTAssertEqual(manifest.parts.count, 1, "and the carrier holds it open")
        }
    }

    /// The same through the channel form: somebody listening with the squelch set and open, and
    /// the switch that records their channel.
    func testAGatedRecordingOfABorrowedChannelAlreadyOpenHoldsOnePart() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
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
            // The listener sets a squelch under the carrier, which it holds open: a squelch that
            // was off starts open, so no edge has gone out at all.
            var squelch = Leyline_V1_ParamWrite()
            squelch.tag = 1
            squelch.targetID = listening.channelID
            squelch.squelchDb = -40
            let summary = try await c.control.writeParams(metadata: testMetadata) { try await $0.write(squelch) }
            XCTAssertEqual(summary.writesApplied, 1)
            try await Task.sleep(nanoseconds: 500_000_000)

            var config = Leyline_V1_RecordConfig()
            config.channelID = listening.channelID
            config.gate = .squelch
            config.hangMs = 1000
            let started = try await self.start(c, config)
            let manifest = try await self.cancelAfter(c, dir, started.jobID, seconds: 2)
            try self.assertOneTwoSecondPart(manifest, dir, started.jobID)
        }
    }
}
