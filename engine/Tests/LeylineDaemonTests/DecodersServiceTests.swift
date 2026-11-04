// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Decoders over the socket: what is installed, the live stream and its scopes, and the
// store (docs/design/decoders.md, "Decisions": "Records reach clients on their own service").

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import XCTest

final class DecodersServiceTests: XCTestCase {
    func testListDecodersAnswersManifestsSearchPathAndRetention() async throws {
        let plugins = try makeTempDir("decoders")
        let storeDir = try makeTempDir("store")
        defer {
            try? FileManager.default.removeItem(atPath: plugins)
            try? FileManager.default.removeItem(atPath: storeDir)
        }
        try writeFakePlugin(in: plugins, recipe: (144_390_000, 15_000))
        // Parses, but specifies nothing runnable: not listed, and not fatal either.
        try writeFakePlugin(in: plugins, name: "broken", executable: "/nowhere/leydec-broken")
        try await withDaemon(decoderSearchPath: [plugins], storePath: storeDir) { c in
            let out = try await c.decoders.listDecoders(Leyline_V1_ListDecodersRequest(), metadata: testMetadata)
            XCTAssertEqual(out.decoders.map(\.name), ["fake"])
            XCTAssertEqual(out.decoders.first?.recipe.frequenciesHz, [144_390_000])
            XCTAssertEqual(out.decoders.first?.recipe.mode, .nfm)
            XCTAssertEqual(out.decoders.first?.outputs, [.shapeRecords])
            XCTAssertEqual(out.searchPath, [plugins])
            XCTAssertEqual(out.storePath, storeDir)
            XCTAssertEqual(out.storeCapBytes, 2 << 30)
            XCTAssertEqual(out.storeAgeDays, 90)
        }
    }

    /// A `test_only` manifest is listed only by a `--no-hardware` daemon: a person's daemon hides
    /// the fixture decoders, and a test's, an eval's or a check scene's lists them.
    func testListedHidesTestOnlyManifestsUnlessAsked() {
        var real = Leyline_V1_DecoderManifest()
        real.name = "speech"
        var fixture = Leyline_V1_DecoderManifest()
        fixture.name = "speech-scripted"
        fixture.testOnly = true
        XCTAssertEqual(DecodersService.listed([real, fixture], testOnly: false).map(\.name), ["speech"])
        XCTAssertEqual(DecodersService.listed([real, fixture], testOnly: true).map(\.name), ["speech", "speech-scripted"])
    }

    /// `--no-hardware` lists them; `--hide-test-decoders` hides them again, for a site scene's
    /// daemon; a daemon with hardware never lists them.
    func testHideTestDecodersOverridesNoHardware() {
        var config = Daemon.Config(socketPath: "/tmp/x.sock", enumerateHardware: false, version: "test")
        XCTAssertTrue(config.listsTestOnly)
        config.hideTestDecoders = true
        XCTAssertFalse(config.listsTestOnly)
        XCTAssertFalse(Daemon.Config(socketPath: "/tmp/x.sock", version: "test").listsTestOnly)
    }

    /// The harness's daemon is `--no-hardware`, so it lists a `test_only` decoder beside the rest.
    func testANoHardwareDaemonListsTestOnlyDecoders() async throws {
        let plugins = try makeTempDir("decoders")
        let storeDir = try makeTempDir("store")
        defer {
            try? FileManager.default.removeItem(atPath: plugins)
            try? FileManager.default.removeItem(atPath: storeDir)
        }
        try writeFakePlugin(in: plugins)
        try writeFakePlugin(in: plugins, name: "fixture", json: """
        {
          "name": "fixture",
          "version": "0.1.0",
          "recipe": {"frequenciesHz": ["146000000"], "mode": "NFM"},
          "input": {"mode": "CONTINUOUS", "tap": "TAP_AUDIO"},
          "outputs": ["SHAPE_RECORDS"],
          "testOnly": true,
          "executable": "\(fakeDecoderPath())"
        }
        """)
        try await withDaemon(decoderSearchPath: [plugins], storePath: storeDir) { c in
            let out = try await c.decoders.listDecoders(Leyline_V1_ListDecodersRequest(), metadata: testMetadata)
            XCTAssertEqual(out.decoders.map(\.name).sorted(), ["fake", "fixture"])
            XCTAssertEqual(out.decoders.first { $0.name == "fixture" }?.testOnly, true)
        }
    }

    func testSubscribeRecordsByProtocolAndQueryAnEmptyStore() async throws {
        let plugins = try makeTempDir("decoders")
        let storeDir = try makeTempDir("store")
        defer {
            try? FileManager.default.removeItem(atPath: plugins)
            try? FileManager.default.removeItem(atPath: storeDir)
        }
        try writeFakePlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins], storePath: storeDir) { c in
            // Nothing kept yet: a query is an empty page, not an error.
            let empty = try await c.decoders.queryRecords(Leyline_V1_RecordQuery(), metadata: testMetadata)
            XCTAssertEqual(empty.records.count, 0)
            XCTAssertFalse(empty.truncated)

            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)

            var config = Leyline_V1_DecodeConfig()
            config.decoder = "fake"
            config.frequencyHz = decodeFrequencyHz
            var request = Leyline_V1_StartJobRequest()
            request.decode = config
            let started = try await c.jobs.startJob(request, metadata: testMetadata)

            var subscription = Leyline_V1_RecordSubscription()
            subscription.protocol = "fake"
            let got: [Leyline_V1_DecodeRecord] = try await withThrowingTaskGroup(of: [Leyline_V1_DecodeRecord]?.self) { group in
                group.addTask {
                    try await c.decoders.subscribeRecords(subscription, metadata: testMetadata) { response in
                        var out: [Leyline_V1_DecodeRecord] = []
                        for try await rec in response.messages {
                            out.append(rec)
                            if out.count >= 2 { return out }
                        }
                        return out
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first ?? []
            }
            XCTAssertEqual(got.count, 2, "a protocol scope carries every job's records for that protocol")
            XCTAssertEqual(got.map(\.protocol), ["fake", "fake"])
            XCTAssertEqual(got.map(\.jobID), [started.jobID, started.jobID])

            // A scope that matches nothing is quiet rather than an error.
            var other = Leyline_V1_RecordSubscription()
            other.protocol = "aprs"
            let none: Int = await withTaskGroup(of: Int.self) { group in
                group.addTask {
                    (try? await c.decoders.subscribeRecords(other, metadata: testMetadata) { response in
                        var n = 0
                        for try await _ in response.messages { n += 1; if n > 0 { return n } }
                        return n
                    }) ?? 0
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    return 0
                }
                let first = await group.next() ?? 0
                group.cancelAll()
                return first
            }
            XCTAssertEqual(none, 0)

            var ref = Leyline_V1_JobRef()
            ref.jobID = started.jobID
            _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
            // An ephemeral job kept nothing (invariant 8).
            let after = try await c.decoders.queryRecords(Leyline_V1_RecordQuery(), metadata: testMetadata)
            XCTAssertEqual(after.records.count, 0)
        }
    }
}
