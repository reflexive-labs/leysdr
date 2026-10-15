// SPDX-License-Identifier: GPL-3.0-or-later

// A live speech job's clips at the file level: a record never waits on a recorder that has gone,
// unkept clips a dead daemon left are removed at the next boot, and kept clips stay inside their
// share of the store (docs/dev/engine-internals.md, "Decoders", "The clips").

import EngineCore
import Foundation
@testable import LeylineServer
import XCTest

final class LiveClipsTests: XCTestCase {
    /// A recorder that does nothing: the clips' own bookkeeping is what is under test.
    final class IdleRecorder: RecordRunning {
        func start() async {}
        func stop(endedBy _: String) async {}
    }

    func manifest(_ id: String, keep: Bool? = nil) -> RecordingManifest {
        var m = RecordingManifest(
            jobID: id, kind: "audio", frequencyHz: 146_940_000, mode: "NFM", bandwidthHz: 12_500,
            sampleRate: 48_000, format: "wav-s16", device: nil, gains: [], squelchDbfs: -40,
            gate: RecordingGateInfo(kind: "squelch", preRollMs: 500, hangMs: 5000), partMs: 0,
            startedAtNs: WallClock.nowNs(), createdBy: RecordingClient(clientID: "", kind: "job", label: "decode"),
            anchors: [StoredAnchor(hostTimeNs: WallClock.nowNs(), sampleRate: 480_000, driftPpm: 0, fromSample: 0,
                                   captureID: "cap_test")])
        m.keep = keep
        return m
    }

    /// One part from `from` to `to` (capture samples, ten per audio sample) with one opening.
    func writePart(_ w: PartWriter, from: UInt64, to: UInt64, open: UInt64, close: UInt64) async {
        await w.openPart(at: from)
        await w.append(audio: [Float](repeating: 0.1, count: Int((to - from) / 10)))
        await w.noteSquelch(open: true, at: open)
        await w.noteSquelch(open: false, at: close)
        await w.closePart(endSample: to)
    }

    func testARecordDoesNotWaitForARecorderThatHasStopped() async throws {
        let dir = try makeTempDir("clips")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let id = JobID().string
        let store = RecordingStore(directory: dir, capBytes: 1 << 30, ageDays: 0)
        let writer = try PartWriter(directory: dir + "/" + id, manifest: manifest(id), captureID: "cap_test", centerHz: 146_940_000)
        // A part is open and nothing in it is the segment's yet: a running recorder would be waited for.
        await writer.openPart(at: 0)
        let clips = LiveClips(recordingID: id, recorder: IdleRecorder(), writer: writer, recordings: store, keep: true)
        await clips.stop(endedBy: "cancelled")
        let began = ContinuousClock.now
        let found = await clips.locate(segmentStart: 10_000, preRoll: 240_000)
        XCTAssertNil(found, "a stopped recorder holds no clip for the segment")
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(100), "and the record goes out at once")
    }

    func testARecordDoesNotWaitWhenTheRecordingHasMovedPastIt() async throws {
        let dir = try makeTempDir("clips")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let id = JobID().string
        let store = RecordingStore(directory: dir, capBytes: 1 << 30, ageDays: 0)
        let writer = try PartWriter(directory: dir + "/" + id, manifest: manifest(id), captureID: "cap_test", centerHz: 146_940_000)
        await writePart(writer, from: 0, to: 4_800_000, open: 480_000, close: 960_000)
        let clips = LiveClips(recordingID: id, recorder: IdleRecorder(), writer: writer, recordings: store, keep: true)
        let hit = await clips.locate(segmentStart: 240_000, preRoll: 240_000)
        XCTAssertEqual(hit?.uri, "ley://recordings/\(id)/1")
        XCTAssertEqual(hit?.over, 1)
        // A segment inside the closed part that the part never listed: no part is open, so no
        // recorder is on its way to it.
        let began = ContinuousClock.now
        let miss = await clips.locate(segmentStart: 2_400_000, preRoll: 240_000)
        XCTAssertNil(miss)
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(100))
    }

    func testUnkeptClipsADeadDaemonLeftAreRemovedAtBoot() async throws {
        let dir = try makeTempDir("clips")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let unkept = JobID().string, kept = JobID().string
        for (id, keep) in [(unkept, false as Bool?), (kept, nil)] {
            // A daemon killed mid-part: a part open, its header unpatched, no `ended_by`.
            let w = try PartWriter(directory: dir + "/" + id, manifest: manifest(id, keep: keep), captureID: "cap_test",
                                   centerHz: 146_940_000)
            await w.openPart(at: 0)
            await w.append(audio: [Float](repeating: 0.1, count: 4800))
        }
        let store = RecordingStore(directory: dir, capBytes: 1 << 30, ageDays: 0)
        let repaired = await store.repairUnfinished()
        XCTAssertEqual(Set(repaired), [unkept, kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + unkept), "unkept clips are not kept by a restart")
        let closed = await store.manifest(jobID: kept)
        XCTAssertEqual(closed?.endedBy, "restart", "every other recording is closed as before")
        XCTAssertNil(closed?.keep, "and keeps no keep field of its own")
    }

    func testKeptClipsDropTheirOwnOldestPartsPastTheirCap() async throws {
        let dir = try makeTempDir("clips")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let id = JobID().string
        let writer = try PartWriter(directory: dir + "/" + id, manifest: manifest(id), captureID: "cap_test", centerHz: 146_940_000)
        // Each part is 4800 audio samples, 9644 bytes with its header: two fit, three do not.
        await writer.setCap(20_000)
        for i in 0..<4 {
            let from = UInt64(i) * 480_000
            await writePart(writer, from: from, to: from + 48_000, open: from + 4800, close: from + 9600)
        }
        let m = await writer.manifest
        XCTAssertEqual(m.parts.map(\.part), [3, 4], "the newest parts stay, numbered as they were")
        XCTAssertLessThanOrEqual(m.bytes, 20_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir + "/" + id).filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(files.count, 2, "the dropped parts' files are gone: \(files)")
        let found = await writer.clip(forSegmentAt: 3 * 480_000, preRoll: 4800)
        XCTAssertEqual(found, .found(part: 4, over: 1))
    }
}
