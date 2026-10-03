// SPDX-License-Identifier: GPL-3.0-or-later

// Recording (docs/design/recording.md): the part writer's files, the gate state machine driven
// with synthetic transitions and no DSP, retention, and the restart repair. The parts that need a
// radio signal are `RecordingJobTests`; these need nothing at all.

import EngineCore
import Foundation
@testable import LeylineServer
import XCTest

final class RecordingTests: XCTestCase {
    private func tempDir(_ name: String) throws -> String {
        let dir = NSTemporaryDirectory() + "leyline-\(name)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifest(jobID: String = "job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB", kind: String = "audio",
                          format: String = "wav-s16", sampleRate: UInt64 = 48000) -> RecordingManifest
    {
        RecordingManifest(
            jobID: jobID, kind: kind, frequencyHz: 146_520_000, mode: "NFM", bandwidthHz: 12500,
            sampleRate: sampleRate, format: format, device: nil, gains: [], squelchDbfs: -80,
            gate: nil, partMs: 0, startedAtNs: 1_789_653_802_000_000_000,
            createdBy: RecordingClient(clientID: "cli_x", kind: "cli", label: "ley record"),
            anchors: [StoredAnchor(hostTimeNs: 1_789_653_700_000_000_000, sampleRate: 2_400_000,
                                   driftPpm: 0, fromSample: 0, captureID: "cap_x")])
    }

    // MARK: The part writer

    func testAWAVPartsHeaderAgreesWithItsLength() async throws {
        let dir = try tempDir("rec")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let writer = try PartWriter(directory: dir, manifest: manifest(), captureID: "cap_x", centerHz: 146_520_000)
        await writer.openPart(at: 0)
        await writer.append(audio: [Float](repeating: 0.5, count: 48000))
        await writer.closePart(endSample: 2_400_000)
        await writer.finish(endedBy: "duration", endSample: 2_400_000)

        let parts = await writer.manifest.parts
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].samples, 48000)
        XCTAssertEqual(parts[0].bytes, UInt64(WAVHeader.bytes + 48000 * 2))
        // The recording holds one part's worth, not two: `bytes` adds the open part to the
        // manifest's total, so a closed part must not still be counted as open.
        let total = await writer.bytes
        XCTAssertEqual(total, parts[0].bytes, "a closed part is counted once")
        // -6 dBFS is what a half-scale sample is, and the writer measured it rather than copying
        // a number from the request.
        XCTAssertEqual(try XCTUnwrap(parts[0].peakDbfs), -6.02, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(parts[0].meanDbfs), -6.02, accuracy: 0.05)

        let path = dir + "/" + parts[0].file
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(data.count, WAVHeader.bytes + 48000 * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let declaredData = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian }
        let declaredRIFF = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(declaredData), data.count - WAVHeader.bytes, "the data chunk is patched on close")
        XCTAssertEqual(Int(declaredRIFF), data.count - 8, "and so is the RIFF size")
        XCTAssertFalse(WAVHeader.needsRepair(path: path))

        // The sidecar `ley play` reads, beside the samples.
        let sidecarPath = dir + "/" + (parts[0].file as NSString).deletingPathExtension + ".json"
        let sidecar = try JSONDecoder().decode(PartSidecar.self, from: Data(contentsOf: URL(fileURLWithPath: sidecarPath)))
        XCTAssertEqual(sidecar.format, "wav-s16")
        XCTAssertEqual(sidecar.sampleRate, 48000)
        XCTAssertEqual(sidecar.centerHz, 146_520_000)
        XCTAssertEqual(sidecar.metadata["mode"], "NFM")
        XCTAssertEqual(sidecar.recording.startSample, 0)
        XCTAssertEqual(sidecar.recording.endSample, 2_400_000)
        XCTAssertEqual(sidecar.anchor.captureID, "cap_x")
    }

    /// `clipped_ms` from a synthetic level feed: the capture's `CaptureLevel` readings, each a
    /// quarter second ending at its `sampleIndex`, charged to a part by overlap when they clipped
    /// (docs/design/recording.md, "The part sidecar"). A clean part leaves the key out of both files.
    func testAPartIsChargedTheClippingThatOverlapsIt() async throws {
        let dir = try tempDir("rec")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let rate: UInt64 = 2_400_000
        let quarter = rate / 4
        func reading(endingAt end: UInt64, clipped: UInt64) -> CaptureLevelReading {
            CaptureLevelReading(sampleIndex: end, clippedSamples: clipped, totalSamples: quarter, peak: 1)
        }
        let writer = try PartWriter(directory: dir, manifest: manifest(), captureID: "cap_x", centerHz: 146_520_000)
        // Part 1 spans 0 ..< 1 s. Two readings clip (0.25 s each, over the floor), one is under the
        // 1e-4 floor (59 of 600,000), and one straddles the part's end by half.
        await writer.openPart(at: 0)
        await writer.append(audio: [Float](repeating: 0.5, count: 48000))
        await writer.noteLevel(reading(endingAt: quarter, clipped: 600), captureRate: rate)
        await writer.noteLevel(reading(endingAt: 2 * quarter, clipped: 59), captureRate: rate)
        await writer.noteLevel(reading(endingAt: 3 * quarter, clipped: 60), captureRate: rate)
        await writer.noteLevel(reading(endingAt: 3 * quarter, clipped: 60), captureRate: rate) // read twice
        await writer.noteLevel(reading(endingAt: rate + quarter / 2, clipped: 1000), captureRate: rate)
        await writer.closePart(endSample: rate)
        // Part 2 spans 2 s ..< 3 s with nothing clipping inside it.
        await writer.openPart(at: 2 * rate)
        await writer.append(audio: [Float](repeating: 0.5, count: 48000))
        await writer.noteLevel(reading(endingAt: 2 * rate + quarter, clipped: 0), captureRate: rate)
        await writer.closePart(endSample: 3 * rate)
        await writer.finish(endedBy: "duration", endSample: 3 * rate)

        let parts = await writer.manifest.parts
        XCTAssertEqual(parts.count, 2)
        // 0.25 + 0.25 + the 0.125 s of the straddling reading inside the part.
        XCTAssertEqual(parts[0].clippedMs, 625)
        XCTAssertNil(parts[1].clippedMs, "a part that did not clip has no clipped_ms")

        let manifestJSON = try String(contentsOfFile: dir + "/recording.json", encoding: .utf8)
        XCTAssertEqual(manifestJSON.components(separatedBy: "\"clipped_ms\"").count - 1, 1,
                       "only the part that clipped carries the key: \(manifestJSON)")
        func sidecar(_ part: RecordingPart) throws -> String {
            try String(contentsOfFile: dir + "/" + (part.file as NSString).deletingPathExtension + ".json", encoding: .utf8)
        }
        let first = try JSONDecoder().decode(PartSidecar.self, from: Data(try sidecar(parts[0]).utf8))
        XCTAssertEqual(first.recording.clippedMs, 625)
        XCTAssertFalse(try sidecar(parts[1]).contains("clipped_ms"))
        // The manifest reads back with the field, and one written before it existed still reads.
        let back = try JSONDecoder().decode(RecordingManifest.self, from: Data(manifestJSON.utf8))
        XCTAssertEqual(back.parts.map(\.clippedMs), [625, nil])
    }

    func testACF32PartsByteCountIsItsSampleCount() async throws {
        let dir = try tempDir("rec")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var m = manifest(kind: "iq", format: "cf32", sampleRate: 2_400_000)
        m.mode = ""
        let writer = try PartWriter(directory: dir, manifest: m, captureID: "cap_x", centerHz: 146_520_000)
        await writer.openPart(at: 1000)
        var block = Data()
        for _ in 0..<4096 {
            withUnsafeBytes(of: Float32(0.25).bitPattern.littleEndian) { block.append(contentsOf: $0) }
            withUnsafeBytes(of: Float32(0).bitPattern.littleEndian) { block.append(contentsOf: $0) }
        }
        await writer.append(iq: block)
        await writer.closePart(endSample: 1000 + 4096)
        let parts = await writer.manifest.parts
        XCTAssertEqual(parts[0].samples, 4096)
        XCTAssertEqual(parts[0].bytes, 4096 * 8)
        XCTAssertTrue(parts[0].file.hasSuffix(".cf32"))
        XCTAssertTrue(parts[0].file.contains("_IQ_001"), "an IQ part says so in its name: \(parts[0].file)")
        let size = try FileManager.default.attributesOfItem(atPath: dir + "/" + parts[0].file)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, 4096 * 8, "cf32 has no header: the file is exactly its samples")
    }

    func testAHeaderLeftWithPlaceholdersIsRepaired() throws {
        let dir = try tempDir("rec")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/unfinished.wav"
        var data = WAVHeader.header(sampleRate: 48000)
        data.append(Data(count: 2000))
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(WAVHeader.needsRepair(path: path))
        try WAVHeader.patchLengths(path: path)
        XCTAssertFalse(WAVHeader.needsRepair(path: path))
        let repaired = try Data(contentsOf: URL(fileURLWithPath: path))
        let declared = repaired.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(declared), 2000)
    }

    // MARK: The gate

    /// One second of capture at 2.4 MSPS, the unit the machine counts in.
    private let rate: UInt64 = 2_400_000

    private func gate(preRollMs: UInt64 = 500, hangMs: UInt64 = 1000, quietMs: UInt64 = 0) -> RecordGateMachine {
        RecordGateMachine(preRollSamples: preRollMs * rate / 1000, hangSamples: hangMs * rate / 1000,
                          quietSamples: quietMs * rate / 1000, startSample: 0)
    }

    func testTheGateOpensAPartBeforeTheSquelchDid() {
        var g = gate()
        let actions = g.squelch(open: true, at: 10 * rate)
        XCTAssertEqual(actions, [.openPart(startSample: 10 * rate - rate / 2), .squelchOpened(at: 10 * rate)],
                       "the part begins a pre-roll before the transition")
        XCTAssertTrue(g.partIsOpen)
    }

    func testAPartOpeningInsideThePreRollOfSampleZeroStartsAtZero() {
        var g = gate()
        XCTAssertEqual(g.squelch(open: true, at: 1000).first, .openPart(startSample: 0),
                       "there is no audio before sample zero to keep")
    }

    func testAReopenInsideTheHangContinuesTheSamePart() {
        var g = gate(hangMs: 5000)
        _ = g.squelch(open: true, at: 1 * rate)
        XCTAssertEqual(g.squelch(open: false, at: 2 * rate), [.squelchClosed(at: 2 * rate)])
        // Three seconds later, inside the five-second hang: one exchange, two overs.
        XCTAssertTrue(g.advance(to: 5 * rate).isEmpty, "the hang has not elapsed")
        XCTAssertEqual(g.squelch(open: true, at: 5 * rate), [.squelchOpened(at: 5 * rate)],
                       "no second part: the part was never closed")
        XCTAssertTrue(g.partIsOpen)
    }

    func testTheHangElapsingClosesThePart() {
        var g = gate(hangMs: 1000)
        _ = g.squelch(open: true, at: 1 * rate)
        _ = g.squelch(open: false, at: 2 * rate)
        XCTAssertTrue(g.advance(to: 2 * rate + rate / 2).isEmpty)
        XCTAssertEqual(g.advance(to: 3 * rate), [.closePart(endSample: 3 * rate)],
                       "the part ends at the close transition plus the hang")
        XCTAssertFalse(g.partIsOpen)
    }

    func testQuietEndsTheJob() {
        var g = gate(hangMs: 1000, quietMs: 2000)
        _ = g.squelch(open: true, at: 1 * rate)
        _ = g.squelch(open: false, at: 2 * rate)
        _ = g.advance(to: 3 * rate)
        // The quiet runs from the close transition at 2 s, not from the cut at 3 s.
        XCTAssertTrue(g.advance(to: 3 * rate + rate / 2).isEmpty)
        XCTAssertEqual(g.advance(to: 4 * rate), [.quiet])
        // Once quiet has ended the job the machine emits nothing more.
        XCTAssertTrue(g.advance(to: 10 * rate).isEmpty)
    }

    func testFinishingClosesWhateverIsOpen() {
        var g = gate()
        _ = g.squelch(open: true, at: 1 * rate)
        XCTAssertEqual(g.finish(at: 4 * rate), [.squelchClosed(at: 4 * rate), .closePart(endSample: 4 * rate)])
    }

    func testASquelchAlreadyOpenSeedsAPartAtTheFirstFrameWithNoPreRoll() {
        var g = gate()
        XCTAssertEqual(g.seedOpen(at: 3 * rate), [.openPart(startSample: 3 * rate), .squelchOpened(at: 3 * rate)],
                       "there is no audio from before the recording to keep")
        XCTAssertTrue(g.squelchIsOpen)
        XCTAssertTrue(g.seedOpen(at: 4 * rate).isEmpty, "a gate already open is not seeded twice")
        XCTAssertEqual(g.finish(at: 5 * rate), [.squelchClosed(at: 5 * rate), .closePart(endSample: 5 * rate)],
                       "cancel closes the seeded part with what it holds")
    }

    func testLosingCoverageClosesThePartAndTheNextOpeningStartsANewOne() {
        var g = gate(hangMs: 5000)
        _ = g.squelch(open: true, at: 1 * rate)
        XCTAssertEqual(g.coverageLost(at: 2 * rate), [.squelchClosed(at: 2 * rate), .closePart(endSample: 2 * rate)])
        XCTAssertFalse(g.partIsOpen)
        XCTAssertEqual(g.seedOpen(at: 4 * rate).first, .openPart(startSample: 4 * rate),
                       "back in capture on an open squelch, a new part")
    }

    // MARK: The store

    func testRetentionDropsTheOldestAndNeverTheRunningOne() async throws {
        let dir = try tempDir("recordings")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Three recordings of about 100 KB each; the cap holds two.
        let store = RecordingStore(directory: dir, capBytes: 250_000, ageDays: 0)
        var ids: [String] = []
        for i in 0..<3 {
            let id = JobID()
            ids.append(id.string)
            var m = manifest(jobID: id.string)
            m.startedAtNs = Int64(1_000_000_000 * (i + 1))
            m.endedBy = "duration"
            let writer = try await store.open(job: id, manifest: m, captureID: "cap_x", centerHz: 146_520_000)
            await writer.openPart(at: 0)
            await writer.append(audio: [Float](repeating: 0.1, count: 50_000))
            await writer.closePart(endSample: 1)
            await writer.finish(endedBy: "duration", endSample: 1)
        }
        await store.retain()
        let left = await store.manifests().map(\.jobID)
        XCTAssertEqual(Set(left), Set(ids.dropFirst()), "the oldest went first")

        // The same store with the oldest survivor still running: it is never the one dropped.
        await store.retain(keeping: [ids[1]])
        let after = await store.manifests().map(\.jobID)
        XCTAssertTrue(after.contains(ids[1]), "a running recording is never dropped")
    }

    func testAgeDropsRecordingsOlderThanTheLimit() async throws {
        let dir = try tempDir("recordings")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RecordingStore(directory: dir, capBytes: 1 << 30, ageDays: 1)
        let old = JobID(), fresh = JobID()
        for (id, startedAt) in [(old, WallClock.nowNs() - 3 * 86_400_000_000_000), (fresh, WallClock.nowNs())] {
            var m = manifest(jobID: id.string)
            m.startedAtNs = startedAt
            let writer = try await store.open(job: id, manifest: m, captureID: "cap_x", centerHz: 1)
            await writer.finish(endedBy: "duration", endSample: 0)
        }
        await store.retain()
        let kept = await store.manifests().map(\.jobID)
        XCTAssertEqual(kept, [fresh.string])
    }

    func testAManifestLeftOpenIsClosedWithRestart() async throws {
        let dir = try tempDir("recordings")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RecordingStore(directory: dir, capBytes: 1 << 30, ageDays: 0)
        let id = JobID()
        // What a daemon that went away mid-part leaves: a manifest with no `ended_by` and a WAV
        // whose header still carries its placeholders.
        let writer = try await store.open(job: id, manifest: manifest(jobID: id.string),
                                          captureID: "cap_x", centerHz: 146_520_000)
        await writer.openPart(at: 0)
        await writer.append(audio: [Float](repeating: 0.25, count: 24000))
        let jobDir = dir + "/" + id.string
        let names = try FileManager.default.contentsOfDirectory(atPath: jobDir)
        let wav = try XCTUnwrap(names.first { $0.hasSuffix(".wav") })
        XCTAssertTrue(WAVHeader.needsRepair(path: jobDir + "/" + wav), "the part is still open")

        let repaired = await store.repairUnfinished()
        XCTAssertEqual(repaired, [id.string])
        let reread = await store.manifest(jobID: id.string)
        let closed = try XCTUnwrap(reread)
        XCTAssertEqual(closed.endedBy, "restart")
        XCTAssertEqual(closed.parts.count, 1, "the part the last daemon had open joins the manifest")
        XCTAssertEqual(closed.parts[0].samples, 24000)
        XCTAssertFalse(WAVHeader.needsRepair(path: jobDir + "/" + wav), "and its header agrees with its length")
        // Idempotent: a second boot finds nothing to do.
        let again = await store.repairUnfinished()
        XCTAssertTrue(again.isEmpty)
    }

    /// A gated recording the last daemon left before its squelch ever opened holds no part; the
    /// repair discards it, as a job ending under a running daemon would.
    func testARecordingLeftOpenThatHeardNothingIsDiscardedAtRepair() async throws {
        let dir = try tempDir("recordings")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RecordingStore(directory: dir, capBytes: 1 << 30, ageDays: 0)
        let id = JobID()
        _ = try await store.open(job: id, manifest: manifest(jobID: id.string), captureID: "cap_x", centerHz: 146_520_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + id.string))
        _ = await store.repairUnfinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + id.string))
        let left = await store.manifests()
        XCTAssertTrue(left.isEmpty)
    }

    func testTheManifestCarriesTheFrozenResourceKeys() {
        var m = manifest()
        m.endedBy = "duration"
        m.parts = [RecordingPart(part: 1, file: "a.wav", startSample: 0, endSample: 48000, samples: 96000,
                                 bytes: 100, peakDbfs: -6, meanDbfs: -18, squelchOpens: 2)]
        let metadata = m.resourceMetadata
        XCTAssertEqual(Set(metadata.keys), ["kind", "frequency_hz", "mode", "bandwidth_hz", "sample_rate",
                                            "format", "duration_ms", "parts", "started_at_ns",
                                            "ended_at_ns", "ended_by", "device"])
        XCTAssertEqual(metadata["bandwidth_hz"], "12500", "the width recorded, so a client tunes back to it")
        XCTAssertEqual(metadata["duration_ms"], "2000", "two seconds of 48 kHz audio")
        XCTAssertEqual(metadata["parts"], "1")
        XCTAssertEqual(metadata["mode"], "NFM")
    }

    func testResourceURIsParse() {
        guard case .recording(let job, let part) = ResourceURI("ley://recordings/job_01J") else {
            return XCTFail("a recording uri")
        }
        XCTAssertEqual(job, "job_01J")
        XCTAssertNil(part)
        guard case .recording(_, let third) = ResourceURI("ley://recordings/job_01J/3") else {
            return XCTFail("a part uri")
        }
        XCTAssertEqual(third, 3)
        guard case .records(let records) = ResourceURI("ley://records/job_01J") else {
            return XCTFail("a records uri")
        }
        XCTAssertEqual(records, "job_01J")
        guard case .unknown = ResourceURI("file:///etc/passwd") else { return XCTFail("not a ley uri") }
        guard case .unknown = ResourceURI("ley://recordings/job_01J/0") else { return XCTFail("parts are 1-based") }
    }
}

// MARK: Playing a recording back

extension RecordingTests {
    /// The reader takes what `PartWriter` writes, and only that: a file that is not mono 16-bit
    /// PCM is refused with what is wrong rather than played as noise.
    func testTheWAVReaderTakesWhatTheWriterWrites() async throws {
        let dir = try tempDir("rec")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let writer = try PartWriter(directory: dir, manifest: manifest(), captureID: "cap_x", centerHz: 146_520_000)
        await writer.openPart(at: 0)
        // A 1 kHz tone at half scale, so the samples read back as something rather than silence.
        var tone = [Float](repeating: 0, count: 4800)
        for i in 0..<tone.count { tone[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(i) / 48000)) }
        await writer.append(audio: tone)
        await writer.closePart(endSample: 240_000)
        let parts = await writer.manifest.parts
        let path = dir + "/" + parts[0].file

        let reader = try WAVReader(path: path)
        XCTAssertEqual(reader.sampleRate, 48000)
        XCTAssertEqual(reader.channels, 1)
        XCTAssertEqual(reader.frames, 4800)
        let block = reader.read(frames: 1000)
        XCTAssertEqual(block.count, 1000)
        XCTAssertEqual(block.map { abs($0) }.max() ?? 0, 0.5, accuracy: 0.01, "the samples come back at the level they went in")
        // Reading to the end and past it stops rather than looping or throwing.
        var total = block.count
        while true {
            let more = reader.read(frames: 1000)
            if more.isEmpty { break }
            total += more.count
        }
        XCTAssertEqual(total, 4800)
        reader.close()

        // Anything else is refused with the reason, because the daemon writes only this shape.
        let notAWAV = dir + "/not.wav"
        try Data("this is not a RIFF file at all".utf8).write(to: URL(fileURLWithPath: notAWAV))
        XCTAssertThrowsError(try WAVReader(path: notAWAV)) { error in
            XCTAssertEqual((error as? EngineError)?.code, EngineError.Code.invalidArgument)
        }
        XCTAssertThrowsError(try WAVReader(path: dir + "/nothing-here.wav"))
    }

    /// A part a daemon restart left with a zero-length data chunk still plays: the data length is
    /// taken from the file's size, which is the same rule the restart repair follows.
    func testTheReaderPlaysAPartLeftWithAPlaceholderLength() throws {
        let dir = try tempDir("rec")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/unfinished.wav"
        var data = WAVHeader.header(sampleRate: 48000)
        data.append(Data(count: 2000))
        try data.write(to: URL(fileURLWithPath: path))
        let reader = try WAVReader(path: path)
        XCTAssertEqual(reader.frames, 1000, "the file's length is what it holds")
        reader.close()
    }
}
