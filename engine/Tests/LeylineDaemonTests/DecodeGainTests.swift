// SPDX-License-Identifier: GPL-3.0-or-later

// A decode job's gain (DA-12): a recipe's GAIN_FIXED level, or the config's own, goes on a capture
// the job creates or retunes and is put back when it ends; a capture the job shares keeps its
// owner's gain and the job says what it was left at (decode.proto, GainPolicy). A file radio has
// no gain stage, so these run on the synthetic radio, which has one (TUNER), as the recording's
// gain tests do.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class DecodeGainTests: XCTestCase {
    /// Inside the synthetic radio's 100 to 200 MHz.
    private let frequencyHz: UInt64 = 146_000_000

    /// A fake decoder whose recipe fixes the gain at `gainDb`.
    private func writeFixedGainPlugin(in dir: String, name: String = "fake", gainDb: Double = 40,
                                      signal: String = "SIGNAL_AUDIO") throws
    {
        try writeFakePlugin(in: dir, name: name, json: """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "decodes nothing, for tests",
          "recipe": {"frequenciesHz": ["\(frequencyHz)"], "bandwidthHz": 15000, "mode": "NFM",
                     "gain": "GAIN_FIXED", "gainDb": \(gainDb)},
          "input": {"mode": "CONTINUOUS", "tap": "TAP_AUDIO", "signal": "\(signal)"},
          "outputs": ["SHAPE_RECORDS"],
          "executable": "\(fakeDecoderPath())"
        }
        """)
    }

    private func start(_ c: DaemonClients, decoder: String = "fake", takeOver: Bool = false,
                       _ edit: (inout Leyline_V1_DecodeConfig) -> Void = { _ in }) async throws -> Leyline_V1_Job
    {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.takeOver = takeOver
        edit(&config)
        var request = Leyline_V1_StartJobRequest()
        request.decode = config
        return try await c.jobs.startJob(request, metadata: testMetadata)
    }

    private func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        return try await c.jobs.getJob(ref, metadata: testMetadata)
    }

    /// The job once its runner has started (its detail is the decoder's), or once it has ended.
    private func decoding(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        var last = try await job(c, id)
        for _ in 0..<200 {
            if last.statusDetail.hasPrefix("decoding with") || [.failed, .completed, .cancelled].contains(last.state) {
                return last
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            last = try await job(c, id)
        }
        XCTFail("the job never started decoding: \(last.statusDetail)")
        return last
    }

    private func cancel(_ c: DaemonClients, _ id: String) async throws {
        var ref = Leyline_V1_JobRef()
        ref.jobID = id
        _ = try await c.jobs.cancelJob(ref, metadata: testMetadata)
    }

    /// The TUNER gain of the radio's one capture, nil for auto or no capture.
    private func tunerDb(_ c: DaemonClients) async throws -> Double? {
        let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
        guard let g = state.captures.first?.gains.first(where: { $0.element == "TUNER" }), !g.auto else { return nil }
        return g.db
    }

    /// The synthetic radio, attached and listed.
    private func attachRadio(_ c: DaemonClients) async throws -> DeviceID {
        let id = try await c.daemon.registry.attachVirtualDevice(SyntheticBandDevice(carriers: [])).descriptor.id
        try await Task.sleep(nanoseconds: 200_000_000)
        return id
    }

    /// A capture somebody made at `centerHz` with TUNER at `db`.
    private func ownCapture(_ c: DaemonClients, device: DeviceID, centerHz: UInt64, db: Double) async throws -> String {
        var cc = Leyline_V1_CreateCaptureRequest()
        cc.deviceID = device.string
        cc.centerHz = centerHz
        let cap = try await c.control.createCapture(cc, metadata: testMetadata)
        let summary = try await c.control.writeParams(metadata: testMetadata) { writer in
            var w = Leyline_V1_ParamWrite()
            w.tag = 1
            w.targetID = cap.captureID
            w.gain = .with { $0.db = db }
            try await writer.write(w)
        }
        XCTAssertEqual(summary.writesApplied, 1)
        for _ in 0..<40 where try await tunerDb(c) != db {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return cap.captureID
    }

    func testACreatedCaptureTakesTheRecipeGain() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            _ = try await self.attachRadio(c)
            let started = try await self.start(c)
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            XCTAssertFalse(running.statusDetail.contains("gain"), "a gain the job set needs no word: \(running.statusDetail)")
            let db = try await self.tunerDb(c)
            XCTAssertEqual(db, 40, "the recipe's GAIN_FIXED level on the capture the job made")
            try await self.cancel(c, started.jobID)
        }
    }

    func testTheConfigGainOverridesTheRecipe() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            _ = try await self.attachRadio(c)
            let started = try await self.start(c) { $0.gains = [.with { $0.element = "tuner"; $0.db = 20 }] }
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            let db = try await self.tunerDb(c)
            XCTAssertEqual(db, 20, "`ley decode --gain` wins over the recipe, and a stage matches ignoring case")
            try await self.cancel(c, started.jobID)
        }
    }

    /// A stage the radio does not have fails the job, as a recording's does: a decode at another
    /// gain than the one asked for is not the one asked for.
    func testAConfigGainTheRadioRefusesFailsTheJob() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            _ = try await self.attachRadio(c)
            let started = try await self.start(c) { $0.gain = .with { $0.element = "IF"; $0.db = 20 } }
            let failed = try await self.decoding(c, started.jobID)
            XCTAssertEqual(failed.state, .failed, failed.statusDetail)
            XCTAssertEqual(failed.error.code, EngineError.Code.gainElementUnknown)
            XCTAssertEqual(failed.statusDetail,
                           "the gain asked for could not be set: no gain element named IF; this radio's are TUNER")
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.captures.isEmpty, "the capture the job made goes with it")
        }
    }

    func testASharedCaptureKeepsItsGainAndTheDetailSaysSo() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let device = try await self.attachRadio(c)
            _ = try await self.ownCapture(c, device: device, centerHz: self.frequencyHz - 100_000, db: 27)
            let started = try await self.start(c)
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            XCTAssertTrue(running.statusDetail.hasSuffix("; gain left at the radio's 27 dB"), running.statusDetail)
            let db = try await self.tunerDb(c)
            XCTAssertEqual(db, 27, "a capture the job shares keeps its owner's gain")
            try await self.cancel(c, started.jobID)
        }
    }

    /// Under take_over the job retunes somebody's capture and sets its gain; when it ends the
    /// capture has its centre and its gain back, as a sweep's lease leaves it.
    func testARetunedCaptureGetsItsGainBack() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let device = try await self.attachRadio(c)
            _ = try await self.ownCapture(c, device: device, centerHz: 120_000_000, db: 27)
            let started = try await self.start(c, takeOver: true)
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            var db = try await self.tunerDb(c)
            XCTAssertEqual(db, 40, "the retuned capture takes the recipe's gain")
            try await self.cancel(c, started.jobID)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.first?.centerHz, 120_000_000, "the centre comes back")
            db = try await self.tunerDb(c)
            XCTAssertEqual(db, 27, "and so does the gain")
        }
    }

    func testAnIQDecoderTakesTheRecipeGainAndGivesItBack() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins, name: "fakeiq", signal: "SIGNAL_IQ")
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let device = try await self.attachRadio(c)
            let started = try await self.start(c, decoder: "fakeiq")
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            var db = try await self.tunerDb(c)
            XCTAssertEqual(db, 40, "the created capture takes the recipe's gain")
            try await self.cancel(c, started.jobID)

            _ = try await self.ownCapture(c, device: device, centerHz: 120_000_000, db: 27)
            let retuning = try await self.start(c, decoder: "fakeiq", takeOver: true)
            let retuned = try await self.decoding(c, retuning.jobID)
            XCTAssertEqual(retuned.state, .running, retuned.statusDetail)
            db = try await self.tunerDb(c)
            XCTAssertEqual(db, 40, "the retuned capture takes the recipe's gain")
            try await self.cancel(c, retuning.jobID)
            db = try await self.tunerDb(c)
            XCTAssertEqual(db, 27, "and gives it back when the job ends")
        }
    }

    /// A file radio has no gain stage, so a recipe's gain has nothing to set: the job runs and its
    /// detail says nothing about a gain. A gain the config sends is still refused, as a recording's.
    func testAFileRadioRunsARecipeGainWithoutOne() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_tone.cf32")) else { throw XCTSkip("fixture missing") }
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins)
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            let started = try await self.start(c) { $0.frequencyHz = 146_620_000 }
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            XCTAssertFalse(running.statusDetail.contains("gain"), running.statusDetail)
            try await self.cancel(c, started.jobID)

            let sent = try await self.start(c) { $0.frequencyHz = 146_620_000; $0.gain = .with { $0.db = 20 } }
            let failed = try await self.decoding(c, sent.jobID)
            XCTAssertEqual(failed.state, .failed, failed.statusDetail)
            XCTAssertEqual(failed.statusDetail, "the gain asked for could not be set: this radio reports no gain elements")
        }
    }

    /// The 2026-11-03 failure: the daemon listed the dongle while rtl_tcp held it, so it had no gain
    /// table, and an ADS-B job's 40 dB was clamped into 0 to 0 dB. The capture's open now reads the
    /// table, the registry publishes the device with it, and the recipe's 40 dB lands on the
    /// table's nearest step.
    func testARadioListedWithoutItsGainTableTakesTheRecipeGainOnceOpened() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins, name: "fakeiq", signal: "SIGNAL_IQ")
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let radio = ScriptedRadio(tableUntilOpen: false)
            let id = try await c.daemon.registry.attachVirtualDevice(radio).descriptor.id
            try await Task.sleep(nanoseconds: 200_000_000)
            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let listed = try XCTUnwrap(state.devices.first { $0.deviceID == id.string })
            XCTAssertEqual(listed.gainElements.first?.validDb, [], "listed before anything opened it")
            XCTAssertEqual(listed.gainElements.first?.maxDb, 0)
            let (changes, collecting) = self.collectChanges(c.daemon.registry)
            defer { collecting.cancel() }

            let started = try await self.start(c, decoder: "fakeiq")
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            let db = try await self.tunerDb(c)
            XCTAssertEqual(db, 40.2, "the recipe's 40 dB on the table's nearest step, not clamped to 0")

            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let opened = try XCTUnwrap(state.devices.first { $0.deviceID == id.string })
            XCTAssertEqual(opened.gainElements.first?.validDb, ScriptedRadio.r820tTableDB, "the table the open read")
            XCTAssertEqual(opened.state, .inUse)
            let changed = try await self.firstChange(changes) { $0.id == id && $0.gainElements.first?.validDB.isEmpty == false }
            XCTAssertEqual(changed?.features["tuner"], .text("R820T"), "the registry published the device as opened")
            try await self.cancel(c, started.jobID)
        }
    }

    /// A radio whose open could not read the table either refuses a level rather than setting
    /// 0 dB: the recipe's refusal is said in the detail, and the tuner is left on auto.
    func testALevelAskedOfAnUnknownTableIsRefusedNotClamped() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFixedGainPlugin(in: plugins, name: "fakeiq", signal: "SIGNAL_IQ")
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            let radio = ScriptedRadio(tableUntilOpen: false, learnsTableOnOpen: false)
            _ = try await c.daemon.registry.attachVirtualDevice(radio)
            try await Task.sleep(nanoseconds: 200_000_000)
            let started = try await self.start(c, decoder: "fakeiq")
            let running = try await self.decoding(c, started.jobID)
            XCTAssertEqual(running.state, .running, running.statusDetail)
            XCTAssertTrue(running.statusDetail.contains("Scripted RTL has not reported its gain table, so 40 dB cannot be set"),
                          running.statusDetail)
            let db = try await self.tunerDb(c)
            XCTAssertNil(db, "left on auto, never set to 0 dB")
            try await self.cancel(c, started.jobID)
        }
    }

    /// Every `changed` the registry publishes from now on, in a box the test reads.
    private func collectChanges(_ registry: DefaultDeviceRegistry) -> (LockedValue<[DeviceDescriptor]>, Task<Void, Never>) {
        let seen = LockedValue<[DeviceDescriptor]>([])
        let events = registry.events()
        let task = Task {
            for await event in events {
                if case .changed(let d) = event { seen.value.append(d) }
            }
        }
        return (seen, task)
    }

    /// The first change in `seen` that `match` accepts, waiting up to 5 s for it.
    private func firstChange(_ seen: LockedValue<[DeviceDescriptor]>,
                             _ match: (DeviceDescriptor) -> Bool) async throws -> DeviceDescriptor?
    {
        for _ in 0..<100 {
            if let d = seen.value.first(where: match) { return d }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func testGainWords() {
        let tuner = [GainElement(name: "TUNER", minDB: 0, maxDB: 49.6, stepDB: 0.9, supportsAuto: true)]
        XCTAssertEqual(JobStore.gainWords([GainState(element: "TUNER", value: .db(49.6))], tuner), "49.6 dB")
        XCTAssertEqual(JobStore.gainWords([GainState(element: "TUNER", value: .auto)], tuner), "auto")
        let hackrf = ["LNA", "VGA"].map { GainElement(name: $0, minDB: 0, maxDB: 40, stepDB: 8, supportsAuto: false) }
        XCTAssertEqual(JobStore.gainWords([GainState(element: "LNA", value: .db(16)), GainState(element: "VGA", value: .db(20))], hackrf),
                       "LNA 16 dB, VGA 20 dB")
    }
}
