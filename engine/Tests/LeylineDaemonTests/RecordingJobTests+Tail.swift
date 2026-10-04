// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs: what a gated part's audio holds around the squelch's own edges -- silence in the
// pre-roll, and no burst of discriminator noise where the carrier dropped and the squelch had not
// yet closed (docs/design/recording.md, "The squelch tail").

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
    /// One closed part of a gated recording, read back from disk.
    struct GatedPart {
        let part: RecordingPart
        let sidecar: PartSidecar
        let samples: [Float]
    }

    /// Records `nfm_keyed` gated, and reads every part back.
    func recordKeyedParts(_ c: DaemonClients, _ dir: String, hangMs: UInt32, partMs: Int64 = 0)
        async throws -> (RecordingManifest, [GatedPart])
    {
        try await attach(c, fixture: "nfm_keyed.cf32", loop: false)
        var config = gatedConfig(hangMs: hangMs)
        config.partMs = partMs
        let started = try await start(c, config)
        let done = try await waitForEnd(c, started.jobID, timeoutMs: 30000)
        XCTAssertNotEqual(done.state, .failed, done.statusDetail)
        let manifest = try manifest(dir, started.jobID)
        var parts: [GatedPart] = []
        for part in manifest.parts {
            let base = dir + "/" + started.jobID + "/" + (part.file as NSString).deletingPathExtension
            let data = try Data(contentsOf: URL(fileURLWithPath: base + ".json"))
            let sidecar = try JSONDecoder().decode(PartSidecar.self, from: data)
            parts.append(GatedPart(part: part, sidecar: sidecar, samples: try readWAVSamples(base + ".wav")))
        }
        return (manifest, parts)
    }

    /// -60 dBFS: S16 rounding of the squelch's zeros is exactly 0, so anything over this is audio.
    private var silence: Float { Float(pow(10, -60.0 / 20)) }

    private func dbText(_ amplitude: Float) -> String {
        String(format: "%.1f dBFS", 20 * log10(Double(Swift.max(amplitude, 1e-9))))
    }

    /// The loudest sample any part holds between `from` and `to` on the capture's timeline.
    private func loudest(_ parts: [GatedPart], _ manifest: RecordingManifest, from: Double, to: Double) -> Float {
        let perAudio = Double(manifest.anchors[0].sampleRate) / Double(manifest.sampleRate)
        var peak: Float = 0
        for gated in parts {
            let start = Double(gated.part.startSample)
            let lo = Int(((from - start) / perAudio).rounded(.down)).clamped(to: 0..<(gated.samples.count + 1))
            let hi = Int(((to - start) / perAudio).rounded(.up)).clamped(to: 0..<(gated.samples.count + 1))
            guard lo < hi else { continue }
            for s in gated.samples[lo..<hi] where abs(s) > peak { peak = abs(s) }
        }
        return peak
    }

    /// Between each key-down the fixture declares and the close transition after it, the
    /// discriminator turns the floor into full-scale noise. Measured on this fixture at 2.4 MSPS,
    /// the close comes at most 7.04 ms after the key-down; 10 ms after it the part must be silent,
    /// whichever part covers it. The last transmission runs to the end of the file, so it has no
    /// key-down.
    private func assertNoSquelchTail(_ parts: [GatedPart], _ manifest: RecordingManifest,
                                     segments: [(start: Double, end: Double)])
    {
        let rate = Double(manifest.anchors[0].sampleRate)
        for (i, segment) in segments.enumerated().dropLast() {
            let peak = loudest(parts, manifest, from: segment.end * rate, to: (segment.end + 0.010) * rate)
            XCTAssertLessThanOrEqual(peak, silence,
                                     "transmission \(i + 1): the squelch tail after its key-down is silenced, but holds \(dbText(peak))")
        }
    }

    /// The pre-roll is the audio from before the squelch opened, and the `.audio` tap is zeros
    /// while the squelch is closed, so every part's WAV is silent up to its open: the fixture's
    /// floor never opens a -40 dBFS squelch. Away from the open block, nothing in a part reaches
    /// -1 dBFS: the fixture's tone deviates 2.5 kHz of the 5 kHz full scale, about -6 dBFS, and the
    /// squelch tail is silenced.
    func testAGatedPartIsSilentBeforeItsOpenAndHoldsNoSquelchTail() async throws {
        let segments = try keyedSegments()
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let (manifest, parts) = try await self.recordKeyedParts(c, dir, hangMs: 1000)
            XCTAssertEqual(parts.count, segments.count, "one part per transmission at a 1 s hang")
            let captureRate = Double(manifest.anchors[0].sampleRate)
            let audioRate = Double(manifest.sampleRate)
            let perAudio = captureRate / audioRate
            for (i, gated) in parts.enumerated() {
                let part = gated.part
                let open = try XCTUnwrap(gated.sidecar.recording.squelchOpens.first, "part \(i + 1) has an over")
                let openIndex = Int(Double(open.openSample - part.startSample) / perAudio)
                XCTAssertEqual(Double(openIndex) / audioRate, 0.5, accuracy: 0.001, "the full pre-roll is kept")
                // A frame is dated within a few capture samples of where it belongs; 1 ms short of
                // the open is pre-roll whatever that jitter.
                let preRoll = gated.samples.prefix(Swift.max(0, openIndex - Int(0.001 * audioRate)))
                let preRollPeak = preRoll.map { abs($0) }.max() ?? 0
                XCTAssertLessThanOrEqual(preRollPeak, self.silence,
                                         "part \(i + 1): the pre-roll is the squelch's silence, but holds \(self.dbText(preRollPeak)) at sample \(preRoll.firstIndex { abs($0) > self.silence } ?? -1)")
                // The block the squelch opened on is noise up to the key-up: the open transition is
                // the block's first sample, and the carrier started inside it. That much is the
                // squelch's own attack and stays. Two blocks after the open, it is all tone.
                let headEnd = openIndex + Int(Double(2 * CaptureDSPCore.blockSize) / perAudio)
                let rest = gated.samples.dropFirst(headEnd).map { abs($0) }.max() ?? 0
                XCTAssertLessThan(rest, Float(pow(10, -1.0 / 20)),
                                  "part \(i + 1): past the open block the loudest sample is the tone, not squelch noise (\(self.dbText(rest)))")
                XCTAssertEqual(Double(part.samples) / audioRate, Double(part.endSample - part.startSample) / captureRate,
                               accuracy: 0.01, "part \(i + 1): the WAV holds the span the manifest gives it")
            }
            self.assertNoSquelchTail(parts, manifest, segments: segments)
        }
    }

    /// At the default hang the three transmissions are one exchange: each close inside the part is
    /// followed by a re-open, and the tails before the closes stay silenced.
    func testEveryTailInsideAnExchangeIsSilenced() async throws {
        let segments = try keyedSegments()
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let (manifest, parts) = try await self.recordKeyedParts(c, dir, hangMs: 0)
            XCTAssertEqual(parts.count, 1, "one exchange, one part")
            XCTAssertEqual(parts.first?.sidecar.recording.squelchOpens.count, segments.count)
            self.assertNoSquelchTail(parts, manifest, segments: segments)
            // The tone is still there between the tails: only the tail was silenced.
            let rate = Double(manifest.anchors[0].sampleRate)
            for (i, segment) in segments.enumerated() {
                let middle = (segment.start + segment.end) / 2
                let peak = self.loudest(parts, manifest, from: (middle - 0.05) * rate, to: (middle + 0.05) * rate)
                XCTAssertGreaterThan(peak, 0.3, "transmission \(i + 1) is in the part")
            }
        }
    }

    /// `--part` cuts a gated part on what has been written, so the audio still held for the tail
    /// carries over to the next part: the parts of one exchange are contiguous, each WAV holds the
    /// span its entry gives, and a tail that falls after a cut is silenced all the same.
    func testAPartCutUnderAGatedRecordingKeepsTheExchangeContiguous() async throws {
        let segments = try keyedSegments()
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let (manifest, parts) = try await self.recordKeyedParts(c, dir, hangMs: 1000, partMs: 700)
            XCTAssertGreaterThan(parts.count, segments.count, "the part timer cut inside the transmissions")
            let captureRate = Double(manifest.anchors[0].sampleRate)
            let audioRate = Double(manifest.sampleRate)
            let gapStarts = Set(manifest.coverageGaps.map(\.fromSample))
            for (i, gated) in parts.enumerated() {
                let part = gated.part
                XCTAssertEqual(Double(part.samples) / audioRate, Double(part.endSample - part.startSample) / captureRate,
                               accuracy: 0.01, "part \(i + 1): the WAV holds the span the manifest gives it")
                guard i + 1 < parts.count, !gapStarts.contains(part.endSample) else { continue }
                XCTAssertEqual(parts[i + 1].part.startSample, part.endSample,
                               "part \(i + 2) begins where part \(i + 1) ended: a cut, not a gap")
            }
            self.assertNoSquelchTail(parts, manifest, segments: segments)
        }
    }
}
