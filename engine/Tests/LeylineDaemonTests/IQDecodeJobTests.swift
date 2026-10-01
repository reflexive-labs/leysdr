// SPDX-License-Identifier: GPL-3.0-or-later

// An IQ decode job end to end against a file device and the fake decoder: a plugin whose manifest
// declares SIGNAL_IQ receives the capture's raw cf32 band rather than a channel's audio, and the
// records it emits are stamped by the daemon with no channel behind them
// (docs/design/decoders.md, "Multiplexing"; DecoderSignal SIGNAL_IQ).

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

final class IQDecodeJobTests: XCTestCase {
    /// The fixture's carrier: 146.520 MHz centre. The IQ decoder takes the whole span, so the
    /// requested frequency need only fall inside it; 146.620 MHz sits +100 kHz up, as the audio
    /// tests use.
    private let iqFrequencyHz: UInt64 = 146_620_000

    /// Attaches nfm_tone on a loop, so the job has something to stream for as long as it runs.
    private func attachFixture(_ c: DaemonClients) async throws {
        var attach = Leyline_V1_AttachFileDeviceRequest()
        attach.path = fixturePath("nfm_tone.cf32")
        attach.loop = true
        _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
    }

    /// Starts an IQ decode job (the manifest's signal is SIGNAL_IQ, so the daemon allocates a
    /// capture-IQ lease and an IQDecodeRunner).
    private func startIQDecode(_ c: DaemonClients, keep: Bool = false, decoder: String = "fakeiq") async throws -> Leyline_V1_Job {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = iqFrequencyHz
        config.keep = keep
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    /// Reads `count` records off the live stream, replayed from the start of the job's window.
    private func records(_ c: DaemonClients, job: String, count: Int, since: UInt64? = 0,
                         timeoutMs: Int = 15000) async throws -> [Leyline_V1_DecodeRecord]
    {
        var subscription = Leyline_V1_RecordSubscription()
        subscription.jobID = job
        if let since { subscription.sinceSeq = since }
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
                XCTFail("no records within \(timeoutMs) ms")
                return []
            }
            return first
        }
    }

    func testAnIQDecoderReceivesCaptureIQ() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startIQDecode(c)
            XCTAssertEqual(started.state, .running)

            let got = try await self.records(c, job: started.jobID, count: 4)
            XCTAssertEqual(got.count, 4)
            XCTAssertEqual(got.map(\.seq), [1, 2, 3, 4], "seq is 1-based and contiguous per job")
            for rec in got {
                XCTAssertTrue(rec.recordID.hasPrefix("rec_"), "record id \(rec.recordID)")
                XCTAssertEqual(rec.jobID, started.jobID)
                XCTAssertEqual(rec.protocol, "fake", "the plugin's own protocol name survives")
                XCTAssertTrue(rec.channelID.isEmpty, "an IQ job has no channel to stamp")
                XCTAssertTrue(rec.rssiDbfs.isNaN, "no channel meter, so rssi is NaN not invented")
                XCTAssertTrue(rec.snrDb.isNaN, "no channel meter, so snr is NaN not invented")
                XCTAssertFalse(rec.time.captureID.isEmpty, "every record is on the capture's timeline")
            }
            XCTAssertEqual(got.map(\.deviceID), ["FAKE-1", "FAKE-2", "FAKE-3", "FAKE-4"],
                           "the plugin's own fields survive the stamping")
            _ = try await c.jobs.cancelJob({ var r = Leyline_V1_JobRef(); r.jobID = started.jobID; return r }(), metadata: testMetadata)
        }
    }

    func testIQJobCancelReleasesTheCapture() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "fakeiq", signal: .signalIq)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            try await self.attachFixture(c)
            let started = try await self.startIQDecode(c)
            _ = try await self.records(c, job: started.jobID, count: 1)

            let during = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(during.captures.count, 1, "the allocator built one capture")
            XCTAssertEqual(during.channels.count, 0, "an IQ decoder taps the capture, it has no channel")

            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            let cancelled = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            XCTAssertEqual(cancelled.state, .cancelled)
            let after = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(after.captures.count, 0, "the capture the lease created goes with the job")
        }
    }
}
