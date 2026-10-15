// SPDX-License-Identifier: GPL-3.0-or-later

// A live segmented decode job's clips: the gated recording it writes under its own id, which every
// record's `clip_uri` and `over` point into (docs/dev/engine-internals.md, "Decoders").

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import Synchronization
import XCTest

extension SegmentedDecodeTests {
    /// The clips' manifest and each part's sidecar, read off disk.
    func readClips(_ dir: String) throws -> (manifest: RecordingManifest, sidecars: [Int: PartSidecar]) {
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/recording.json")))
        var sidecars: [Int: PartSidecar] = [:]
        for part in manifest.parts {
            let base = (part.file as NSString).deletingPathExtension
            sidecars[part.part] = try JSONDecoder().decode(PartSidecar.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/" + base + ".json")))
        }
        return (manifest, sidecars)
    }

    /// Each record names a part the recording holds, and the over the stored path would give the
    /// segment that starts where the record is dated: `Segmenter.cut` over that part's sidecar, at
    /// the decoder's 500 ms, has a segment with the record's over starting within a capture block
    /// or two of the record's time (the live cut and the stored one read the same edges, but the
    /// live pre-roll is whole audio samples and clipped to what its ring held).
    func checkClips(_ got: [Leyline_V1_DecodeRecord], jobID: String, in recordings: String,
                    file: StaticString = #filePath, line: UInt = #line) throws
    {
        let (manifest, sidecars) = try readClips(recordings + "/" + jobID)
        for rec in got {
            let prefix = "ley://recordings/\(jobID)/"
            XCTAssertTrue(rec.clipUri.hasPrefix(prefix), "clip \(rec.clipUri) is under the job's own id", file: file, line: line)
            guard let part = Int(rec.clipUri.dropFirst(prefix.count)),
                  let entry = manifest.parts.first(where: { $0.part == part }), let sidecar = sidecars[part]
            else {
                XCTFail("\(rec.clipUri) names no part of \(manifest.parts.map(\.part))", file: file, line: line)
                continue
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: recordings + "/" + jobID + "/" + entry.file), file: file, line: line)
            XCTAssertGreaterThanOrEqual(rec.over, 1, file: file, line: line)
            let rate = Double(sidecar.anchor.sampleRate)
            let spans = Segmenter.cut(sidecar.recording.squelchOpens, partStart: entry.startSample, partEnd: entry.endSample,
                                      preRoll: UInt64(0.5 * rate), hang: UInt64(0.5 * rate))
            let slack = Int64(2 * CaptureDSPCore.blockSize)
            let match = spans.first { $0.over == rec.over }
            XCTAssertNotNil(match, "over \(rec.over) of part \(part) is one the stored cut makes: \(spans)", file: file, line: line)
            if let match {
                XCTAssertLessThanOrEqual(abs(Int64(match.start) - Int64(rec.time.sampleIndex)), slack,
                                         "the stored segment for over \(rec.over) starts where the live one did", file: file, line: line)
            }
        }
    }

    func testALiveJobRecordsItsClipsUnderItsOwnID() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: true)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "fake"
            config.keep = true
            let started = try await self.startDecode(c, config)
            XCTAssertEqual(started.resultUris, ["ley://records/\(started.jobID)", "ley://recordings/\(started.jobID)"],
                           "a kept speech job's records and clips are both resources")
            let got = try await self.records(c, job: started.jobID, count: 4, timeoutMs: 30000)
            XCTAssertEqual(got.count, 4)
            try await self.cancel(c, started.jobID)
            try self.checkClips(got, jobID: started.jobID, in: recordings)
            let (manifest, _) = try self.readClips(recordings + "/" + started.jobID)
            XCTAssertEqual(manifest.endedBy, "cancelled")
            XCTAssertEqual(manifest.gate?.hangMs, 5000, "the recorder's own gate, not the segmenter's")
            XCTAssertTrue(manifest.parts.allSatisfy { ($0.squelchOpenMs ?? 0) > 0 }, "every part says how long it was open")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.channels.isEmpty, "the job's one channel goes back with it")
        }
    }

    func testAnUnkeptJobsClipsGoWithIt() async throws {
        let plugins = try makeTempDir("decoders")
        let recordings = try makeTempDir("recordings")
        defer {
            for d in [plugins, recordings] { try? FileManager.default.removeItem(atPath: d) }
        }
        try writeSegmentedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins], recordingsPath: recordings) { c in
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: true)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "fake"
            let started = try await self.startDecode(c, config)
            XCTAssertEqual(started.resultUris, ["ley://recordings/\(started.jobID)"], "the clips are a resource while the job runs")
            let got = try await self.records(c, job: started.jobID, count: 1, timeoutMs: 30000)
            XCTAssertEqual(got.count, 1)
            XCTAssertEqual(got.first?.clipUri.hasPrefix("ley://recordings/\(started.jobID)/"), true)
            let dir = recordings + "/" + started.jobID
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/recording.json"), "the clips are written while it runs")
            try await self.cancel(c, started.jobID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir), "an unkept job's clips are gone when it ends")
        }
    }

    func testAKeptJobCarriesItsClipsOnAfterARestart() async throws {
        let dir = try makeTempDir("restart")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let plugins = dir + "/decoders"
        try writeSegmentedPlugin(in: plugins)
        let store = dir + "/store"
        let recordings = dir + "/recordings"
        let started = Mutex("")
        try await withDaemon(dir: dir + "/run1", decoderSearchPath: [plugins], storePath: store, recordingsPath: recordings) { c in
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: true)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "fake"
            config.keep = true
            let job = try await self.startDecode(c, config)
            started.withLock { $0 = job.jobID }
            let got = try await self.records(c, job: job.jobID, count: 2, timeoutMs: 30000)
            XCTAssertEqual(got.count, 2)
        }
        let jobID = started.withLock { $0 }
        let (stopped, _) = try readClips(recordings + "/" + jobID)
        XCTAssertEqual(stopped.endedBy, "restart", "the daemon going down closes the clips as a restart")
        let firstParts = stopped.parts.map(\.part)
        XCTAssertFalse(firstParts.isEmpty)

        try await withDaemon(dir: dir + "/run2", decoderSearchPath: [plugins], storePath: store, recordingsPath: recordings) { c in
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: true)
            var back: Leyline_V1_Job?
            for _ in 0 ..< 300 {
                if let j = try? await self.job(c, jobID), j.state == .running || j.state == .degraded { back = j; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let job = try XCTUnwrap(back, "the kept job did not come back")
            XCTAssertEqual(job.resultUris, ["ley://records/\(jobID)", "ley://recordings/\(jobID)"])
            let got = try await self.records(c, job: jobID, count: 2, timeoutMs: 30000)
            XCTAssertEqual(got.count, 2)
            let newest = firstParts.max() ?? 0
            for rec in got {
                let part = Int(rec.clipUri.split(separator: "/").last ?? "") ?? 0
                XCTAssertGreaterThan(part, newest, "a resumed job's clips are new parts after the old ones: \(rec.clipUri)")
            }
            try await self.cancel(c, jobID)
            try self.checkClips(got, jobID: jobID, in: recordings)
        }
        let (ended, _) = try readClips(recordings + "/" + jobID)
        XCTAssertEqual(ended.endedBy, "cancelled")
        XCTAssertEqual(Array(ended.parts.map(\.part).prefix(firstParts.count)), firstParts, "the old parts are kept as they were")
        XCTAssertGreaterThan(ended.parts.count, firstParts.count, "and new ones follow them")
        XCTAssertEqual(ended.anchors.count, 2, "one anchor for each capture the job ran on")
    }
}
