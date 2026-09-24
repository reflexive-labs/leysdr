// SPDX-License-Identifier: GPL-3.0-or-later

// A record job end to end against a file device (docs/design/recording.md): what a continuous
// recording writes, where a gated one cuts, what the Resources service hands back, and which
// requests the daemon refuses before a radio is touched.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// The carrier in nfm_tone and nfm_keyed: 146.520 MHz centre, the tone 100 kHz up.
private let recordFrequencyHz: UInt64 = 146_620_000

/// The S16 samples of a recorded WAV part, as the floats they were written from.
func readWAVSamples(_ path: String) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count > WAVHeader.bytes else { return [] }
    let body = data.dropFirst(WAVHeader.bytes)
    var out = [Float](repeating: 0, count: body.count / 2)
    body.withUnsafeBytes { raw in
        for i in 0..<out.count {
            out[i] = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian) / 32768
        }
    }
    return out
}

/// The dominant spectral peak of a real signal and how far it stands over the rest of the band --
/// the same pair the fixtures' own `audio` expectation is written in.
func dominantTone(_ samples: [Float], rate: Double) -> (hz: Double, snrDB: Double) {
    let n = 8192
    guard samples.count >= n else { return (0, 0) }
    // Skip the filter's settling transient, as leyfix check does.
    let start = Swift.min(samples.count - n, Int(0.05 * rate))
    var power = [Double](repeating: 0, count: n / 2)
    var blocks = 0
    var offset = start
    while offset + n <= samples.count, blocks < 8 {
        var re = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            re[i] = Double(samples[offset + i]) * w
        }
        for k in 1..<(n / 2) {
            var sr = 0.0, si = 0.0
            // A Goertzel per bin of interest would be faster; the band is small and this runs once.
            let w = 2 * Double.pi * Double(k) / Double(n)
            var cosw = cos(w), sinw = sin(w)
            var c = 1.0, s = 0.0
            for i in 0..<n {
                sr += re[i] * c
                si -= re[i] * s
                let nc = c * cosw - s * sinw
                s = c * sinw + s * cosw
                c = nc
            }
            power[k] += sr * sr + si * si
            _ = (cosw, sinw)
        }
        blocks += 1
        offset += n
    }
    guard blocks > 0 else { return (0, 0) }
    var peakBin = 1
    for k in 1..<power.count where power[k] > power[peakBin] { peakBin = k }
    let peak = power[peakBin]
    var rest = 0.0
    for k in 1..<power.count where abs(k - peakBin) > 3 { rest += power[k] }
    let snr = rest > 0 ? 10 * log10(peak / (rest / Double(power.count))) : 99
    return (Double(peakBin) * rate / Double(n), snr)
}

/// One averaged spectrum row of a recorded cf32 part, DC-centred, in dB.
func spectrumOf(_ path: String, bins: Int) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let complexCount = data.count / 8
    guard complexCount >= bins else { return [] }
    let analyzer = SpectrumAnalyzer(size: bins)
    var acc = [Float](repeating: 0, count: bins)
    var rows = 0
    var samples = [Float](repeating: 0, count: complexCount * 2)
    data.withUnsafeBytes { raw in
        for i in 0..<(complexCount * 2) {
            samples[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian)
        }
    }
    var row = [Float](repeating: 0, count: bins)
    samples.withUnsafeMutableBufferPointer { buf in
        var offset = 0
        while offset + bins <= complexCount, rows < 16 {
            let block = SampleBuffer(base: UnsafeMutableRawPointer(buf.baseAddress! + offset * 2),
                                     count: bins, format: .cf32)
            row.withUnsafeMutableBufferPointer { out in
                analyzer.analyze(block, into: out)
            }
            for i in 0..<bins { acc[i] += row[i] }
            rows += 1
            offset += bins
        }
    }
    guard rows > 0 else { return [] }
    return acc.map { $0 / Float(rows) }
}

/// The median of a spectrum row, which is the noise floor for a band with a few carriers in it.
func medianOf(_ row: [Float]) -> Float {
    guard !row.isEmpty else { return -200 }
    return row.sorted()[row.count / 2]
}

extension Int {
    func clamped(to range: Range<Int>) -> Int { Swift.max(range.lowerBound, Swift.min(range.upperBound - 1, self)) }
}

final class RecordingJobTests: XCTestCase {
    private func attach(_ c: DaemonClients, fixture: String, loop: Bool) async throws {
        let path = fixturePath(fixture)
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("fixture missing: \(path)") }
        var request = Leyline_V1_AttachFileDeviceRequest()
        request.path = path
        request.loop = loop
        _ = try await c.control.attachFileDevice(request, metadata: testMetadata)
    }

    private func start(_ c: DaemonClients, _ config: Leyline_V1_RecordConfig) async throws -> Leyline_V1_Job {
        var request = Leyline_V1_StartJobRequest()
        request.record = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    private func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        return try await c.jobs.getJob(ref, metadata: testMetadata)
    }

    /// Waits for the job to leave RUNNING/DEGRADED, or fails.
    @discardableResult
    private func waitForEnd(_ c: DaemonClients, _ id: String, timeoutMs: Int = 20000) async throws -> Leyline_V1_Job {
        for _ in 0..<(timeoutMs / 100) {
            let j = try await job(c, id)
            if j.state != .running, j.state != .degraded { return j }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("job \(id) did not finish within \(timeoutMs) ms")
        return try await job(c, id)
    }

    private func manifest(_ dir: String, _ jobID: String) throws -> RecordingManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + jobID + "/recording.json"))
        return try JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    private func recordings() throws -> String {
        let dir = NSTemporaryDirectory() + "leyline-recordings-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Continuous audio

    func testAContinuousAudioRecordingWritesOneWAVAndAResource() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = recordFrequencyHz
            config.mode = .nfm
            config.durationMs = 1000
            config.squelchDbfs = -80
            let started = try await self.start(c, config)
            XCTAssertEqual(started.state, .running)
            XCTAssertEqual(started.resultUris, ["ley://recordings/\(started.jobID)"],
                           "a recording is a resource from the moment the job exists")

            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.endedBy, "duration")
            XCTAssertEqual(manifest.kind, "audio")
            XCTAssertEqual(manifest.format, "wav-s16")
            XCTAssertEqual(manifest.mode, "NFM")
            XCTAssertEqual(manifest.frequencyHz, recordFrequencyHz)
            XCTAssertEqual(manifest.parts.count, 1, "a continuous audio recording is one part")
            XCTAssertEqual(manifest.coverageGaps.count, 0, "and it covers everything it claims")
            XCTAssertEqual(manifest.anchors.count, 1)
            XCTAssertFalse(manifest.anchors[0].captureID?.isEmpty ?? true, "the anchor dates its own capture")
            // A capture publishes its anchor with its first block, so the one read while allocating
            // is a placeholder. The real one has to replace it, or every wall clock the recording
            // derives -- the part's own name included -- dates to the epoch.
            XCTAssertGreaterThan(manifest.anchors[0].hostTimeNs, PartWriter.plausibleEpochNs,
                                 "the placeholder anchor was replaced once samples arrived")
            XCTAssertFalse(manifest.parts[0].file.hasPrefix("1970"), manifest.parts[0].file)
            // One second at the channel's audio rate, within one capture block of it. The block is
            // 16384 capture samples: 6.8 ms at 2.4 MSPS, which is 328 audio frames at 48 kHz.
            let want = Double(manifest.sampleRate)
            XCTAssertEqual(Double(manifest.parts[0].samples), want, accuracy: want * 0.05,
                           "about a second of audio at \(manifest.sampleRate) Hz")
            // The file on disk is the header plus the frames the header declares.
            let file = dir + "/" + started.jobID + "/" + manifest.parts[0].file
            let size = try FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber
            XCTAssertEqual(size?.uint64Value, UInt64(WAVHeader.bytes) + manifest.parts[0].samples * 2)
            XCTAssertFalse(WAVHeader.needsRepair(path: file), "the header was patched on close")
            XCTAssertNotNil(manifest.parts[0].peakDbfs)

            // The Resources service, over the same manifest.
            var list = Leyline_V1_ListResourcesRequest()
            list.kind = .recording
            let listed = try await c.resources.listResources(list, metadata: testMetadata)
            XCTAssertEqual(listed.resources.count, 1)
            let resource = try XCTUnwrap(listed.resources.first)
            XCTAssertEqual(resource.uri, "ley://recordings/\(started.jobID)")
            XCTAssertEqual(resource.originatingJobID, started.jobID)
            XCTAssertEqual(resource.metadata["kind"], "audio")
            XCTAssertEqual(resource.metadata["mode"], "NFM")
            XCTAssertEqual(resource.metadata["ended_by"], "duration")
            XCTAssertGreaterThan(resource.sizeBytes, 0)

            var ref = Leyline_V1_ResourceRef()
            ref.uri = resource.uri
            let got = try await c.resources.getResource(ref, metadata: testMetadata)
            XCTAssertEqual(got.uri, resource.uri)

            let dirPath = try await c.resources.resolveLocalPath(ref, metadata: testMetadata)
            XCTAssertEqual(dirPath.path, dir + "/" + started.jobID)
            ref.uri = resource.uri + "/1"
            let partPath = try await c.resources.resolveLocalPath(ref, metadata: testMetadata)
            XCTAssertEqual(partPath.path, file, "a part resolves to its samples file")

            // A filter that cannot match returns nothing rather than everything.
            list.metadataFilter = ["mode": "AM"]
            let none = try await c.resources.listResources(list, metadata: testMetadata)
            XCTAssertTrue(none.resources.isEmpty)
        }
    }

    // MARK: The gain

    /// `ley record --gain 20` sends a level with no element, which is the device's first stage
    /// (`common.proto`, `GainWrite`). Until 2026-09-24 the record path passed the empty element to
    /// the radio and dropped its refusal, so a real radio kept whatever gain it had
    /// (plans/app.md, M2-10); the synthetic device refuses any element but TUNER, as a real
    /// driver does.
    func testTheGainAskedForReachesTheRadio() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            _ = try await c.daemon.registry.attachVirtualDevice(SyntheticBandDevice(carriers: []))
            try await Task.sleep(nanoseconds: 200_000_000)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_520_000
            config.mode = .rawIq
            config.durationMs = 300
            config.gain = .with { $0.db = 20 }
            let one = try await self.waitForEnd(c, try await self.start(c, config).jobID)
            XCTAssertEqual(one.state, .completed, one.statusDetail)
            var manifest = try self.manifest(dir, one.jobID)
            XCTAssertEqual(manifest.gains.map(\.element), ["TUNER"])
            XCTAssertEqual(manifest.gains.first?.valueDb ?? -1, 20, accuracy: 0.5, "the take ran at the gain asked for")

            // `gains` wins over `gain`, its writes land in order, and a name matches ignoring case.
            config.gains = [.with { $0.db = 10 }, .with { $0.element = "tuner"; $0.db = 30 }]
            let two = try await self.waitForEnd(c, try await self.start(c, config).jobID)
            XCTAssertEqual(two.state, .completed, two.statusDetail)
            manifest = try self.manifest(dir, two.jobID)
            XCTAssertEqual(manifest.gains.first?.valueDb ?? -1, 30, accuracy: 0.5, "the last write is the one in force")
        }
    }

    /// A stage the radio does not have fails the job before a sample is written, with the
    /// device's code and the stages it does have, because a take at some other gain is not the
    /// one asked for.
    func testAGainTheRadioRefusesFailsTheJob() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            _ = try await c.daemon.registry.attachVirtualDevice(SyntheticBandDevice(carriers: []))
            try await Task.sleep(nanoseconds: 200_000_000)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_520_000
            config.mode = .rawIq
            config.durationMs = 300
            config.gains = [.with { $0.db = 20 }, .with { $0.element = "IF"; $0.db = 20 }]
            let failed = try await self.waitForEnd(c, try await self.start(c, config).jobID)
            XCTAssertEqual(failed.state, .failed, failed.statusDetail)
            XCTAssertEqual(failed.error.code, EngineError.Code.gainElementUnknown)
            XCTAssertEqual(failed.statusDetail,
                           "the gain asked for could not be set: no gain element named IF; this radio's are TUNER")
        }
    }

    func testTheRadioGoesBackWhenTheRecordingEnds() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = recordFrequencyHz
            config.mode = .nfm
            config.squelchDbfs = -80
            let started = try await self.start(c, config)
            // Give the runner time to have the radio before taking it away again.
            try await Task.sleep(nanoseconds: 700_000_000)
            let during = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(during.channels.count, 1, "the job owns one channel")
            XCTAssertEqual(during.channels.first?.owner.kind, "job")

            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            let cancelled = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            XCTAssertEqual(cancelled.state, .cancelled)
            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.endedBy, "cancelled")
            XCTAssertEqual(manifest.parts.count, 1, "a cancelled recording is complete, not damaged")
            XCTAssertFalse(WAVHeader.needsRepair(path: dir + "/" + started.jobID + "/" + manifest.parts[0].file))

            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(after.channels.count, 0, "the channel goes with the job")
            XCTAssertEqual(after.captures.count, 0, "so does the capture the lease created")
        }
    }

    // MARK: The gate, against the fixture's own answer key

    /// The keying nfm_keyed states in its sidecar, in seconds.
    private func keyedSegments() throws -> [(start: Double, end: Double)] {
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

    private func gatedConfig(hangMs: UInt32) -> Leyline_V1_RecordConfig {
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

    // MARK: Playing a recording back

    /// The daemon owns the speakers, so a recording plays where the radio is. This container has
    /// no CoreAudio, so what is asserted here is the contract either way: an IQ recording is
    /// refused because those are tuned, a nonexistent recording is not found, and a host with no
    /// audio returns PLATFORM_UNSUPPORTED rather than failing some other way.
    func testPlaybackRefusesWhatItCannotPlay() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 146_520_000
            config.mode = .rawIq
            config.durationMs = 500
            let iq = try await self.start(c, config)
            _ = try await self.waitForEnd(c, iq.jobID)

            func play(_ uri: String) async -> RPCError? {
                var request = Leyline_V1_StartPlaybackRequest()
                request.resourceUri = uri
                do {
                    _ = try await c.control.startPlayback(request, metadata: testMetadata)
                    return nil
                } catch let e as RPCError {
                    return e
                } catch {
                    return nil
                }
            }
            // Raw samples are tuned, not played.
            var got = await play("ley://recordings/\(iq.jobID)")
            var e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .invalidArgument)
            XCTAssertTrue(e.message.contains("tuned rather than played"), e.message)

            got = await play("ley://recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB")
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .notFound)

            got = await play("file:///etc/passwd")
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .invalidArgument)

            // An audio recording is playable; on a host with no audio device the daemon returns an
            // error rather than faking playback, and `ley` falls back on that error.
            var audio = Leyline_V1_RecordConfig()
            audio.frequencyHz = recordFrequencyHz
            audio.mode = .nfm
            audio.durationMs = 500
            audio.squelchDbfs = -80
            let made = try await self.start(c, audio)
            _ = try await self.waitForEnd(c, made.jobID)
            got = await play("ley://recordings/\(made.jobID)")
            #if canImport(AVFoundation)
            XCTAssertNil(got, "a macOS daemon plays it")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.playbacks.count, 1, "and a second client can see it")
            XCTAssertEqual(state.playbacks.first?.state, .playbackPlaying)
            var stop = Leyline_V1_StopPlaybackRequest()
            stop.playbackID = state.playbacks[0].playbackID
            _ = try await c.control.stopPlayback(stop, metadata: testMetadata)
            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(after.playbacks.isEmpty, "stopping takes it out of the daemon's state")
            #else
            e = try XCTUnwrap(got)
            XCTAssertEqual(e.code, .unimplemented, "a host with no audio device says so")
            #endif
        }
    }

    // MARK: Deleting (Resources.DeleteResource)

    private func delete(_ c: DaemonClients, _ uri: String) async throws -> Leyline_V1_DeletedResource {
        var ref = Leyline_V1_ResourceRef()
        ref.uri = uri
        return try await c.resources.deleteResource(ref, metadata: testMetadata)
    }

    /// A finished recording goes whole: the directory, every part and the manifest. The listing
    /// drops it because the listing is a scan of the manifests, and the bytes reported are what
    /// was on disk. The job stays in the table as it was, since jobs are never tombstoned.
    func testDeletingAFinishedRecordingRemovesItsDirectory() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = recordFrequencyHz
            config.mode = .nfm
            config.durationMs = 500
            config.squelchDbfs = -80
            let done = try await self.waitForEnd(c, try await self.start(c, config).jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            let uri = "ley://recordings/\(done.jobID)"

            var list = Leyline_V1_ListResourcesRequest()
            list.kind = .recording
            let before = try await c.resources.listResources(list, metadata: testMetadata)
            let size = try XCTUnwrap(before.resources.first { $0.uri == uri }).sizeBytes
            XCTAssertGreaterThan(size, 0)

            let deleted = try await self.delete(c, uri)
            XCTAssertEqual(deleted.uri, uri)
            XCTAssertEqual(deleted.freedBytes, size, "the bytes freed are the size the listing reported")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + done.jobID))

            let after = try await c.resources.listResources(list, metadata: testMetadata)
            XCTAssertFalse(after.resources.contains { $0.uri == uri }, "the listing no longer has it")
            let job = try await self.job(c, done.jobID)
            XCTAssertEqual(job.state, .completed, "the job's entry is left as it was")

            // A second delete finds nothing, as GetResource would.
            do {
                _ = try await self.delete(c, uri)
                XCTFail("a deleted recording deleted again")
            } catch {
                XCTAssertEqual(errorCode(error).code, EngineError.Code.jobNotFound)
            }
        }
    }

    /// The runner has a part open in the directory while the job runs, so the delete is refused
    /// and names what to do; once the job is cancelled the recording is complete and goes.
    func testDeletingARunningRecordingIsRefused() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = recordFrequencyHz
            config.mode = .nfm
            config.squelchDbfs = -80
            let started = try await self.start(c, config)
            let uri = "ley://recordings/\(started.jobID)"
            // The manifest is written when the runner has its capture.
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: dir + "/" + started.jobID + "/recording.json") {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            do {
                _ = try await self.delete(c, uri)
                XCTFail("a running recording was deleted")
            } catch let e as RPCError {
                XCTAssertEqual(e.code, .failedPrecondition)
                XCTAssertEqual(errorCode(e).code, EngineError.Code.failedPrecondition)
                XCTAssertTrue(e.message.contains("cancel the job first"), e.message)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + started.jobID + "/recording.json"),
                          "the refusal leaves every file where it was")

            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            let deleted = try await self.delete(c, uri)
            XCTAssertGreaterThan(deleted.freedBytes, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + started.jobID))
        }
    }

    /// A part URI is refused, since a recording is deleted whole; an id the store has never seen
    /// is JOB_NOT_FOUND, as GetResource reports it; and only recordings are deleted.
    func testTheDeleteRefusals() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = recordFrequencyHz
            config.mode = .nfm
            config.durationMs = 300
            config.squelchDbfs = -80
            let done = try await self.waitForEnd(c, try await self.start(c, config).jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)

            func refusal(_ uri: String) async -> (RPCError.Code?, String) {
                do {
                    _ = try await self.delete(c, uri)
                    return (nil, "")
                } catch let e as RPCError {
                    return (e.code, errorCode(e).code)
                } catch {
                    return (nil, "")
                }
            }
            var (status, code) = await refusal("ley://recordings/\(done.jobID)/1")
            XCTAssertEqual(status, .invalidArgument)
            XCTAssertEqual(code, EngineError.Code.invalidArgument)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + done.jobID + "/recording.json"),
                          "a refused part delete leaves the recording alone")

            (status, code) = await refusal("ley://recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB")
            XCTAssertEqual(status, .notFound)
            XCTAssertEqual(code, EngineError.Code.jobNotFound)

            (status, code) = await refusal("ley://recordings/../../etc")
            XCTAssertEqual(status, .invalidArgument, "a path outside the store is not a recording uri")

            (status, code) = await refusal("ley://scans/scan_01J8XQ2M7V3N9K5R4T6W8Y0ZAB")
            XCTAssertEqual(status, .invalidArgument)
        }
    }

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
            scheduled.startAtNs = realtimeNs() + 60_000_000_000
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

    // MARK: The channel going away under a recording

    /// The channel form borrows: when its owner closes the channel the job ends COMPLETED rather
    /// than orphaning a sink, and the recording is complete (docs/design/recording.md, "The wire":
    /// "the job borrows the channel and does not own it").
    ///
    /// The retune counterpart of this -- a capture moved out from under a recording, which degrades
    /// the job and logs the gap -- needs a radio that can be tuned somewhere else, and a file
    /// device's tuning range is the single frequency its fixture was recorded at. It is covered by
    /// the client-side guard's test in `go/internal/cli` and on a real dongle by the release
    /// checklist.
    func testTheChannelClosingEndsTheRecording() async throws {
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

            var config = Leyline_V1_RecordConfig()
            config.channelID = listening.channelID
            let started = try await self.start(c, config)
            try await Task.sleep(nanoseconds: 600_000_000)

            // The listener stops listening.
            var destroy = Leyline_V1_DestroyChannelRequest()
            destroy.channelID = listening.channelID
            _ = try await c.control.destroyChannel(destroy, metadata: testMetadata)

            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)
            XCTAssertTrue(done.statusDetail.contains("channel"), done.statusDetail)
            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.endedBy, "channel ended")
            XCTAssertEqual(manifest.parts.count, 1, "what it heard before the channel closed is kept")
            XCTAssertFalse(WAVHeader.needsRepair(path: dir + "/" + started.jobID + "/" + manifest.parts[0].file))
        }
    }

    // MARK: The channel form

    func testRecordingABorrowedChannelLeavesItAlone() async throws {
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

            var config = Leyline_V1_RecordConfig()
            config.channelID = listening.channelID
            config.durationMs = 800
            let started = try await self.start(c, config)
            let done = try await self.waitForEnd(c, started.jobID)
            XCTAssertEqual(done.state, .completed, done.statusDetail)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.frequencyHz, recordFrequencyHz, "the channel's own frequency")
            XCTAssertEqual(manifest.mode, "NFM", "and its mode")
            XCTAssertEqual(manifest.parts.count, 1)

            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(after.channels.count, 1, "the listener still has their channel")
            XCTAssertEqual(after.channels.first?.channelID, listening.channelID)
            XCTAssertEqual(after.captures.count, 1, "and their radio")
        }
    }
}
