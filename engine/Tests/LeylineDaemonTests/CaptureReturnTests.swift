// SPDX-License-Identifier: GPL-3.0-or-later

// Return and sharing (docs/design/claims.md, "Displacement, uniformly"; plan CL-4): a capture a job
// moved goes back to where the job found it, rate and gain included, when the job lets go, unless
// a person has moved it since or a claim made since would lose by it; and a capture the allocator
// made lives while any claim holds it (DEC-19).

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
import LeylineProto
import XCTest

final class CaptureReturnTests: XCTestCase {
    // MARK: Harness

    private func state(_ c: DaemonClients) async throws -> Leyline_V1_GetStateResponse {
        try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
    }

    private func attachRetunable(_ c: DaemonClients) async throws -> String {
        let id = try await c.daemon.registry.attachVirtualDevice(RebindableDevice(blockIntervalNs: 2_000_000)).descriptor.id.string
        for _ in 0..<150 {
            if try await state(c).devices.contains(where: { $0.deviceID == id }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return id
    }

    /// A person's capture at `hz` with their channel on its centre.
    private func personsChannel(_ c: DaemonClients, on device: String, at hz: UInt64,
                                rate: UInt64 = 0) async throws -> (capture: String, channel: String)
    {
        let cap = try await c.control.createCapture(.with {
            $0.deviceID = device
            $0.centerHz = hz
            $0.sampleRate = rate
        }, metadata: testMetadata)
        let ch = try await c.control.createChannel(.with {
            $0.captureID = cap.captureID
            $0.offsetHz = 0
            $0.mode = .nfm
        }, metadata: testMetadata)
        return (cap.captureID, ch.channelID)
    }

    private func capture(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Capture? {
        try await state(c).captures.first { $0.captureID == id }
    }

    /// The person's channel claim on the capture.
    private func personsClaim(_ c: DaemonClients, _ captureID: String) async throws -> Leyline_V1_Claim? {
        try await capture(c, captureID)?.claims.first { $0.kind == .claimChannel && $0.holder.clientID == testClientID }
    }

    /// Polls the capture until `pred` holds; fails with what it last saw.
    @discardableResult
    private func waitForCapture(_ c: DaemonClients, _ id: String, _ why: String, file: StaticString = #filePath,
                                line: UInt = #line, _ pred: (Leyline_V1_Capture) -> Bool) async throws -> Leyline_V1_Capture?
    {
        var last: Leyline_V1_Capture?
        for _ in 0..<200 {
            last = try await capture(c, id)
            if let l = last, pred(l) { return l }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("\(why); the capture was \(last.map { "\($0.centerHz) Hz at \($0.sampleRate)" } ?? "gone")", file: file, line: line)
        return last
    }

    private func retune(_ c: DaemonClients, _ captureID: String, tag: UInt64, to hz: UInt64) async throws {
        var w = Leyline_V1_ParamWrite()
        w.tag = tag
        w.targetID = captureID
        w.centerHz = hz
        let message = w
        _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
    }

    private func job(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Job {
        try await c.jobs.getJob(.with { $0.jobID = id }, metadata: testMetadata)
    }

    @discardableResult
    private func waitForJob(_ c: DaemonClients, _ id: String, _ why: String, file: StaticString = #filePath,
                            line: UInt = #line, _ pred: (Leyline_V1_Job) -> Bool) async throws -> Leyline_V1_Job
    {
        var j = try await job(c, id)
        for _ in 0..<200 where !pred(j) {
            try await Task.sleep(nanoseconds: 50_000_000)
            j = try await job(c, id)
        }
        XCTAssertTrue(pred(j), "\(why): \(j.state) \(j.statusDetail)", file: file, line: line)
        return j
    }

    private func cancel(_ c: DaemonClients, _ id: String) async throws {
        _ = try await c.jobs.cancelJob(.with { $0.jobID = id }, metadata: testMetadata)
    }

    private func decode(_ c: DaemonClients, _ decoder: String, at hz: UInt64, takeOver: Bool = false) async throws -> Leyline_V1_Job {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = hz
        config.takeOver = takeOver
        let started = try await c.jobs.startJob(.with { $0.decode = config }, metadata: testMetadata)
        return try await waitForJob(c, started.jobID, "\(decoder) starts decoding") {
            $0.statusDetail.hasPrefix("decoding with") || $0.state == .failed
        }
    }

    /// The next record the job's live stream delivers, or nil after 10 s.
    private func nextRecord(_ c: DaemonClients, job: String) async throws -> Leyline_V1_DecodeRecord? {
        var subscription = Leyline_V1_RecordSubscription()
        subscription.jobID = job
        let s = subscription
        return try await withThrowingTaskGroup(of: Leyline_V1_DecodeRecord?.self) { group in
            group.addTask {
                try await c.decoders.subscribeRecords(s, metadata: testMetadata) { response in
                    for try await rec in response.messages { return rec }
                    return nil
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A dedicated IQ decoder on 100.1 MHz, at the radio's default rate.
    private func writeDedicatedPlugin(in dir: String) throws {
        try writeFakePlugin(in: dir, name: "fakewide", json: """
        {
          "name": "fakewide",
          "version": "0.1.0",
          "recipe": {"frequenciesHz": ["100100000"]},
          "input": {"mode": "CONTINUOUS", "signal": "SIGNAL_IQ"},
          "needsDedicatedCapture": true,
          "outputs": ["SHAPE_RECORDS"],
          "executable": "\(fakeDecoderPath())"
        }
        """)
    }

    private func plugins(_ body: (String) throws -> Void) throws -> String {
        let dir = try makeTempDir("decoders")
        try body(dir)
        return dir
    }

    // MARK: Return

    /// A take_over decode moves the person's capture off their channel and an IQ recording's
    /// frequency; when it ends the capture goes back, the person's claim is SATISFIED again, the
    /// recording leaves DEGRADED, and it goes on in a new part.
    func testATakeOverDecodeGivesTheRadioBackWhenItEnds() async throws {
        let dir = try plugins { try writeFakePlugin(in: $0) }
        let recordings = try makeTempDir("recordings")
        defer { for d in [dir, recordings] { try? FileManager.default.removeItem(atPath: d) } }
        try await withDaemon(decoderSearchPath: [dir], recordingsPath: recordings) { c in
            let device = try await self.attachRetunable(c)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000)
            var config = Leyline_V1_RecordConfig()
            config.frequencyHz = 100_400_000
            config.mode = .rawIq
            let recording = try await c.jobs.startJob(.with { $0.record = config }, metadata: testMetadata)
            XCTAssertEqual(recording.state, .running, recording.statusDetail)
            try await Task.sleep(nanoseconds: 300_000_000)

            let taking = try await self.decode(c, "fake", at: 103_000_000, takeOver: true)
            XCTAssertEqual(taking.state, .running, taking.statusDetail)
            let moved = try await self.capture(c, captureID)
            XCTAssertNotEqual(moved?.centerHz, 100_500_000, "the take_over moved the radio")
            let displacedFound = try await self.personsClaim(c, captureID)
            let displaced = try XCTUnwrap(displacedFound)
            XCTAssertEqual(displaced.state, .claimDisplaced)
            XCTAssertEqual(displaced.displacedBy.clientID, taking.jobID)
            try await self.waitForJob(c, recording.jobID, "the recording pauses") { $0.state == .degraded }

            try await self.cancel(c, taking.jobID)
            let back = try await self.waitForCapture(c, captureID, "the capture goes back") { $0.centerHz == 100_500_000 }
            XCTAssertEqual(back?.sampleRate, 2_400_000)
            let returnedFound = try await self.personsClaim(c, captureID)
            let returned = try XCTUnwrap(returnedFound)
            XCTAssertEqual(returned.state, .claimSatisfied)
            XCTAssertFalse(returned.hasDisplacedBy)
            let channel = try await self.state(c).channels.first { $0.captureID == captureID }
            XCTAssertEqual(channel?.state, .channelActive, "the person's channel is back in the capture")
            try await self.waitForJob(c, recording.jobID, "the recording resumes") { $0.state == .running }
            try await Task.sleep(nanoseconds: 300_000_000)

            try await self.cancel(c, recording.jobID)
            var ended = try await self.job(c, recording.jobID)
            for _ in 0..<100 where ended.state == .running || ended.state == .degraded {
                try await Task.sleep(nanoseconds: 100_000_000)
                ended = try await self.job(c, recording.jobID)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: recordings + "/" + recording.jobID + "/recording.json"))
            let manifest = try JSONDecoder().decode(RecordingManifest.self, from: data)
            XCTAssertEqual(manifest.parts.count, 2, "a new part after the return: \(manifest.parts.map(\.file))")
        }
    }

    /// A dedicated decoder that took the capture over at its own rate puts the rate back with the
    /// centre.
    func testTheRateComesBack() async throws {
        let dir = try plugins { try writeDedicatedPlugin(in: $0) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let device = try await self.attachRetunable(c)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000, rate: 1_024_000)
            let taking = try await self.decode(c, "fakewide", at: 100_100_000, takeOver: true)
            XCTAssertEqual(taking.state, .running, taking.statusDetail)
            let moved = try await self.capture(c, captureID)
            XCTAssertEqual(moved?.centerHz, 100_100_000)
            XCTAssertEqual(moved?.sampleRate, 2_400_000, "the decoder runs at its own rate")

            try await self.cancel(c, taking.jobID)
            let back = try await self.waitForCapture(c, captureID, "centre and rate go back") {
                $0.centerHz == 100_500_000 && $0.sampleRate == 1_024_000
            }
            XCTAssertNotNil(back)
            let claim = try await self.personsClaim(c, captureID)
            XCTAssertEqual(claim?.state, .claimSatisfied)
        }
    }

    /// A sweep that borrowed a person's radio gives back the centre and the gain, and their claim
    /// is SATISFIED again.
    func testASweepGivesTheRadioAndItsGainBack() async throws {
        try await withDaemon { c in
            let desc = try await c.daemon.registry.attachVirtualDevice(SyntheticBandDevice(carriers: [])).descriptor
            try await Task.sleep(nanoseconds: 200_000_000)
            let (captureID, _) = try await self.personsChannel(c, on: desc.id.string, at: 146_900_000)
            _ = try await c.control.writeParams(metadata: testMetadata) { writer in
                try await writer.write(.with {
                    $0.tag = 1
                    $0.targetID = captureID
                    $0.gain = .with { $0.db = 27 }
                })
            }
            try await self.waitForCapture(c, captureID, "the gain lands") { $0.gains.first?.db == 27 }

            var config = Leyline_V1_ScanConfig()
            config.range.minHz = 145_000_000
            config.range.maxHz = 146_000_000
            config.dwellMs = 120
            config.once = true
            config.takeOver = true
            config.gains = [.with { $0.element = "TUNER"; $0.db = 40 }]
            let scan = try await c.jobs.startJob(.with { $0.config = .scan(config) }, metadata: testMetadata)
            let done = try await self.waitForJob(c, scan.jobID, "the scan ends") { $0.state != .running }
            XCTAssertEqual(done.state, .completed, done.statusDetail)

            let back = try await self.waitForCapture(c, captureID, "the capture goes back") { $0.centerHz == 146_900_000 }
            XCTAssertEqual(back?.gains.first?.db, 27, "and its gain")
            XCTAssertEqual(back?.gains.first?.auto, false)
            let claim = try await self.personsClaim(c, captureID)
            XCTAssertEqual(claim?.state, .claimSatisfied)
        }
    }

    /// Once a person has moved the capture, nothing goes back over their head.
    func testNothingReturnsAfterAPersonsRetune() async throws {
        let dir = try plugins { try writeFakePlugin(in: $0) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let device = try await self.attachRetunable(c)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000)
            let taking = try await self.decode(c, "fake", at: 103_000_000, takeOver: true)
            XCTAssertEqual(taking.state, .running, taking.statusDetail)
            try await self.retune(c, captureID, tag: 1, to: 104_000_000)
            try await self.waitForCapture(c, captureID, "the person's retune lands") { $0.centerHz == 104_000_000 }

            try await self.cancel(c, taking.jobID)
            try await Task.sleep(nanoseconds: 300_000_000)
            let after = try await self.capture(c, captureID)
            XCTAssertEqual(after?.centerHz, 104_000_000, "the person's tuning stays")
            let claim = try await self.personsClaim(c, captureID)
            XCTAssertEqual(claim?.state, .claimDisplaced, "their channel waits for them")
            XCTAssertEqual(claim?.displacedBy.clientID, testClientID)
        }
    }

    /// A claim made on the new tuning keeps it: the return waits until that claim has gone too.
    func testANewerClaimHoldsTheReturnUntilItGoes() async throws {
        let dir = try plugins { try writeFakePlugin(in: $0) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let device = try await self.attachRetunable(c)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000)
            let taking = try await self.decode(c, "fake", at: 103_000_000, takeOver: true)
            XCTAssertEqual(taking.state, .running, taking.statusDetail)
            let moved = try await self.capture(c, captureID)
            let movedTo = try XCTUnwrap(moved).centerHz
            let joining = try await self.decode(c, "fake", at: 103_100_000)
            XCTAssertEqual(joining.state, .running, joining.statusDetail)

            try await self.cancel(c, taking.jobID)
            try await Task.sleep(nanoseconds: 300_000_000)
            let held = try await self.capture(c, captureID)
            XCTAssertEqual(held?.centerHz, movedTo, "the job that joined on the new tuning keeps it")
            let still = try await self.job(c, joining.jobID)
            XCTAssertEqual(still.state, .running, still.statusDetail)

            try await self.cancel(c, joining.jobID)
            try await self.waitForCapture(c, captureID, "back once that job has gone too") { $0.centerHz == 100_500_000 }
            let claim = try await self.personsClaim(c, captureID)
            XCTAssertEqual(claim?.state, .claimSatisfied)
        }
    }

    // MARK: Sharing (DEC-19)

    /// Two IQ decoders on the capture the first one's job made: cancelling the first leaves the
    /// second reading it, and the capture goes with the last.
    func testTwoIQDecodersShareACreatedCapture() async throws {
        guard FileManager.default.fileExists(atPath: fixturePath("nfm_tone.cf32")) else { throw XCTSkip("fixture missing") }
        let dir = try plugins { try writeFakePlugin(in: $0, name: "fakeiq", signal: .signalIq) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            _ = try await c.control.attachFileDevice(.with {
                $0.path = fixturePath("nfm_tone.cf32")
                $0.loop = true
            }, metadata: testMetadata)
            let first = try await self.decode(c, "fakeiq", at: 146_620_000)
            XCTAssertEqual(first.state, .running, first.statusDetail)
            let second = try await self.decode(c, "fakeiq", at: 146_620_000)
            XCTAssertEqual(second.state, .running, second.statusDetail)
            let shared = try await self.state(c).captures
            XCTAssertEqual(shared.count, 1, "the second decoder shares the first one's capture")
            let captureID = try XCTUnwrap(shared.first).captureID

            try await self.cancel(c, first.jobID)
            try await Task.sleep(nanoseconds: 300_000_000)
            let left = try await self.capture(c, captureID)
            XCTAssertNotNil(left, "the capture lives while the second decoder holds it")
            XCTAssertEqual(left?.claims.map(\.holder.clientID), [second.jobID], "its claims are the second decoder's alone")
            XCTAssertEqual(left?.claims.first?.state, .claimSatisfied)
            let reading = try await self.job(c, second.jobID)
            XCTAssertEqual(reading.state, .running, reading.statusDetail)
            let more = try await self.nextRecord(c, job: second.jobID)
            XCTAssertNotNil(more, "it goes on decoding")

            try await self.cancel(c, second.jobID)
            let none = try await self.state(c).captures
            XCTAssertTrue(none.isEmpty, "the capture goes with its last claim")
        }
    }

    /// The job that made a capture ending does not take it from another kind of claim on it: an
    /// audio decode on the IQ decoder's capture keeps it, and it goes when that ends.
    func testCancellingTheCreatorLeavesTheCaptureToTheNextClaim() async throws {
        let dir = try plugins {
            try writeFakePlugin(in: $0, name: "fakeiq", signal: .signalIq)
            try writeFakePlugin(in: $0)
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            _ = try await self.attachRetunable(c)
            let creator = try await self.decode(c, "fakeiq", at: 100_100_000)
            XCTAssertEqual(creator.state, .running, creator.statusDetail)
            let made = try await self.state(c).captures
            XCTAssertEqual(made.count, 1)
            let captureID = try XCTUnwrap(made.first).captureID
            let listener = try await self.decode(c, "fake", at: 100_200_000)
            XCTAssertEqual(listener.state, .running, listener.statusDetail)
            let joined = try await self.state(c)
            XCTAssertEqual(joined.captures.count, 1, "the audio decode shares the capture")

            try await self.cancel(c, creator.jobID)
            try await Task.sleep(nanoseconds: 300_000_000)
            let after = try await self.state(c)
            XCTAssertEqual(after.captures.map(\.captureID), [captureID], "the capture outlives the job that made it")
            XCTAssertEqual(after.captures.first?.centerHz, 100_100_000, "and stays where it was made")
            XCTAssertEqual(after.channels.count, 1)
            let still = try await self.job(c, listener.jobID)
            XCTAssertEqual(still.state, .running, still.statusDetail)

            try await self.cancel(c, listener.jobID)
            let none = try await self.state(c).captures
            XCTAssertTrue(none.isEmpty, "the capture goes with its last claim")
        }
    }
}
