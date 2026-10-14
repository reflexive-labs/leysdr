// SPDX-License-Identifier: GPL-3.0-or-later

// SEGMENTED decode jobs end to end against the fake decoder: one record per over, dated where the
// over's audio starts, and nothing sent while the squelch is shut (docs/dev/engine-internals.md,
// "Decoders"). `FAKE_DECODER_SEGMENTS=1` makes the fake answer each segment with its frame and
// sample counts.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

final class SegmentedDecodeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("FAKE_DECODER_SEGMENTS", "1", 1)
    }

    override func tearDown() {
        unsetenv("FAKE_DECODER_SEGMENTS")
        super.tearDown()
    }

    /// A fake whose manifest asks for SEGMENTED audio, on nfm_keyed's carrier.
    func writeSegmentedPlugin(in dir: String, credentialProvider: String = "") throws {
        try writeFakePlugin(in: dir, json: """
        {
          "name": "fake",
          "version": "0.1.0",
          "description": "counts segments, for tests",
          "recipe": {"frequenciesHz": ["\(recordFrequencyHz)"], "bandwidthHz": 12500, "mode": "NFM", "gain": "GAIN_LEAVE"},
          "input": {"mode": "SEGMENTED", "tap": "TAP_AUDIO", "signal": "SIGNAL_AUDIO"},
          "outputs": ["SHAPE_RECORDS"],
          "credentialProvider": "\(credentialProvider)",
          "executable": "\(fakeDecoderPath())"
        }
        """)
    }

    func attach(_ c: DaemonClients, fixture: String, loop: Bool) async throws {
        let path = fixturePath(fixture)
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("fixture missing: \(path)") }
        var request = Leyline_V1_AttachFileDeviceRequest()
        request.path = path
        request.loop = loop
        _ = try await c.control.attachFileDevice(request, metadata: testMetadata)
    }

    func startDecode(_ c: DaemonClients, _ config: Leyline_V1_DecodeConfig) async throws -> Leyline_V1_Job {
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        return try await c.jobs.getJob(ref, metadata: testMetadata)
    }

    func cancel(_ c: DaemonClients, _ id: String) async throws {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
    }

    /// Records from the start of the job's window until `count` arrive or the time runs out.
    func records(_ c: DaemonClients, job: String, count: Int, timeoutMs: Int = 30000) async throws -> [Leyline_V1_DecodeRecord] {
        var subscription = Leyline_V1_RecordSubscription()
        subscription.jobID = job
        subscription.sinceSeq = 0
        return try await withThrowingTaskGroup(of: [Leyline_V1_DecodeRecord]?.self) { group in
            group.addTask {
                try await c.decoders.subscribeRecords(subscription, metadata: testMetadata) { response in
                    var out: [Leyline_V1_DecodeRecord] = []
                    for try await rec in response.messages {
                        out.append(rec)
                        if out.count >= count { return out }
                    }
                    return out
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let first else {
                XCTFail("\(count) records did not arrive within \(timeoutMs) ms")
                return []
            }
            return first
        }
    }

    func integer(_ rec: Leyline_V1_DecodeRecord, _ name: String) -> Int64 {
        rec.fields[name]?.integer ?? -1
    }

    // MARK: Live

    func testALiveJobSendsOneSegmentPerOverAndNothingBetween() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeSegmentedPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            // Looped, so the last over, which runs to the end of the file, has floor after it.
            try await self.attach(c, fixture: "nfm_keyed.cf32", loop: true)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "fake"
            let started = try await self.startDecode(c, config)
            let got = try await self.records(c, job: started.jobID, count: 3, timeoutMs: 30000)
            try await self.cancel(c, started.jobID)
            XCTAssertEqual(got.count, 3, "one record per over: \(got.map { $0.fields["text"]?.text ?? "" })")
            guard got.count == 3 else { return }

            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let rate = Double(state.captures.first?.sampleRate ?? 2_400_000)
            // nfm_keyed keys at 1.0, 5.0 and 8.5 s for 1.0, 0.5 and 2.0 s; a segment reaches 0.5 s
            // before each and 0.5 s after. The squelch decides once per capture block, and the
            // follower's pre-roll is whole audio samples, so the edges are good to 150 ms.
            let keyed: [(start: Double, seconds: Double)] = [(1.0, 1.0), (5.0, 0.5), (8.5, 2.0)]
            for (i, rec) in got.enumerated() {
                let audioRate = Double(self.integer(rec, "rate"))
                XCTAssertEqual(rec.over, UInt32(i + 1), "over counts the segments since the job began")
                XCTAssertTrue(rec.clipUri.isEmpty, "no recording holds a live job's audio")
                XCTAssertEqual(rec.fields["text"]?.text, "segment \(i + 1)")
                XCTAssertEqual(self.integer(rec, "outside"), 0, "no frame arrives while the squelch is shut")
                let startS = Double(rec.time.sampleIndex) / rate
                XCTAssertEqual(startS, keyed[i].start - 0.5, accuracy: 0.15, "over \(i + 1) starts a pre-roll before its key-up")
                let seconds = Double(self.integer(rec, "samples")) / audioRate
                XCTAssertEqual(seconds, keyed[i].seconds + 1.0, accuracy: 0.3,
                               "over \(i + 1) holds its keying plus the pre-roll and the hang")
            }
        }
    }
}
