// SPDX-License-Identifier: GPL-3.0-or-later

// Record jobs: deleting a recording (Resources.DeleteResource).

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

extension RecordingJobTests {
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

    /// Deleting a recording stops a playback of its part first, through the path `StopPlayback`
    /// takes, so the tombstone goes out and nothing is left playing a file that is gone.
    func testDeletingARecordingStopsItsPlayback() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let done = try await self.playableRecording(c)
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            defer { Task { await events.stop() } }
            let pb = try await self.play(c, "ley://recordings/\(done.jobID)/1")
            let before = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(before.playbacks.map(\.playbackID), [pb.playbackID])

            _ = try await self.delete(c, "ley://recordings/\(done.jobID)")
            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(after.playbacks.isEmpty, "the playback went with the recording")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + done.jobID))
            let tomb = await events.waitFor {
                $0.playback.playbackID == pb.playbackID && $0.playback.state == .unspecified
            }
            XCTAssertEqual(tomb?.causedBy.clientID, testClientID, "the tombstone is the deleting client's")
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
}
