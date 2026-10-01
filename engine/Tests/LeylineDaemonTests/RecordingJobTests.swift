// SPDX-License-Identifier: GPL-3.0-or-later

// A record job end to end against a file device (docs/design/recording.md): what a continuous
// recording writes, where a gated one cuts, what the Resources service hands back, and which
// requests the daemon refuses before a radio is touched.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

/// The carrier in nfm_tone and nfm_keyed: 146.520 MHz centre, the tone 100 kHz up.
let recordFrequencyHz: UInt64 = 146_620_000

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
    func attach(_ c: DaemonClients, fixture: String, loop: Bool) async throws {
        let path = fixturePath(fixture)
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("fixture missing: \(path)") }
        var request = Leyline_V1_AttachFileDeviceRequest()
        request.path = path
        request.loop = loop
        _ = try await c.control.attachFileDevice(request, metadata: testMetadata)
    }

    func start(_ c: DaemonClients, _ config: Leyline_V1_RecordConfig) async throws -> Leyline_V1_Job {
        var request = Leyline_V1_StartJobRequest()
        request.record = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        return try await c.jobs.getJob(ref, metadata: testMetadata)
    }

    /// Waits for the job to leave RUNNING/DEGRADED, or fails.
    @discardableResult
    func waitForEnd(_ c: DaemonClients, _ id: String, timeoutMs: Int = 20000) async throws -> Leyline_V1_Job {
        for _ in 0..<(timeoutMs / 100) {
            let j = try await job(c, id)
            if j.state != .running, j.state != .degraded { return j }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("job \(id) did not finish within \(timeoutMs) ms")
        return try await job(c, id)
    }

    func manifest(_ dir: String, _ jobID: String) throws -> RecordingManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + jobID + "/recording.json"))
        return try JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    func recordings() throws -> String {
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
            XCTAssertNil(manifest.parts[0].clippedMs, "a -20 dBFS tone never reaches a rail")
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
            XCTAssertEqual(resource.metadata["bandwidth_hz"], String(manifest.bandwidthHz))
            XCTAssertGreaterThan(manifest.bandwidthHz, 0, "an audio recording states its channel's width")
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
    /// (`common.proto`, `GainWrite`). A record path that passed the empty element to the radio and
    /// dropped its refusal would leave a real radio at whatever gain it had; the synthetic device
    /// refuses any element but TUNER, as a real driver does.
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
}
