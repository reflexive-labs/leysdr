// SPDX-License-Identifier: GPL-3.0-or-later

// Returns that fail or meet something on the way (plan CL-4, review): a return the radio refuses is
// undone and tried again at the next release; a person's write, a newer claim and a new job's
// allocation each land around a return or a close and never under it; and stacked returns give
// the gain back in either order.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
import LeylineProto
import XCTest

extension CaptureReturnTests {
    // MARK: Harness

    /// Starts a decode without waiting for it to start decoding.
    func startDecode(_ c: DaemonClients, _ decoder: String, at hz: UInt64, takeOver: Bool = false,
                     gainDB: Double? = nil) async throws -> Leyline_V1_Job
    {
        var config = Leyline_V1_DecodeConfig()
        config.decoder = decoder
        config.frequencyHz = hz
        config.takeOver = takeOver
        if let gainDB { config.gains = [.with { $0.element = "TUNER"; $0.db = gainDB }] }
        return try await c.jobs.startJob(.with { $0.decode = config }, metadata: testMetadata)
    }

    func decoding(_ c: DaemonClients, _ decoder: String, at hz: UInt64, takeOver: Bool = false,
                  gainDB: Double? = nil) async throws -> Leyline_V1_Job
    {
        let started = try await startDecode(c, decoder, at: hz, takeOver: takeOver, gainDB: gainDB)
        let j = try await waitForJob(c, started.jobID, "\(decoder) starts decoding") {
            $0.statusDetail.hasPrefix("decoding with") || $0.state == .failed
        }
        XCTAssertEqual(j.state, .running, j.statusDetail)
        return j
    }

    /// Waits for a job to end after its cancel.
    func ended(_ c: DaemonClients, _ id: String) async throws {
        try await waitForJob(c, id, "the job ends") { $0.state != .running && $0.state != .degraded }
    }

    func waitUntil(_ why: String, file: StaticString = #filePath, line: UInt = #line, _ cond: () -> Bool) async throws {
        for _ in 0..<400 where !cond() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(cond(), why, file: file, line: line)
    }

    // MARK: A return that fails

    /// A rate change that lands and a centre the radio refuses: the capture is put back where the
    /// return found it, not left half way, and the return is tried again at the next release.
    func testAFailedReturnIsUndoneAndTriedAgain() async throws {
        let dir = try plugins {
            try writeDedicatedPlugin(in: $0)
            try writeFakePlugin(in: $0)
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let radio = RebindableDevice(blockIntervalNs: 2_000_000)
            let device = try await self.attachRetunable(c, radio)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000, rate: 1_024_000)
            let taking = try await self.decoding(c, "fakewide", at: 100_100_000, takeOver: true)

            radio.refusedTuneHz.value = 100_500_000
            try await self.cancel(c, taking.jobID)
            try await self.ended(c, taking.jobID)
            try await Task.sleep(nanoseconds: 300_000_000)
            let stuck = try await self.capture(c, captureID)
            XCTAssertEqual(stuck?.centerHz, 100_100_000, "the refused return leaves the capture where it was")
            XCTAssertEqual(stuck?.sampleRate, 2_400_000, "rate included")

            radio.refusedTuneHz.value = 0
            let passing = try await self.decoding(c, "fake", at: 100_200_000)
            try await self.cancel(c, passing.jobID)
            try await self.waitForCapture(c, captureID, "the next release carries the return out") {
                $0.centerHz == 100_500_000 && $0.sampleRate == 1_024_000
            }
        }
    }

    // MARK: A person's write during a return

    /// A person's retune sent while the return is on its way lands after it, and stays.
    func testAPersonsWriteDuringAReturnLandsAfterIt() async throws {
        let dir = try plugins { try writeFakePlugin(in: $0) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let radio = RebindableDevice(blockIntervalNs: 2_000_000)
            let device = try await self.attachRetunable(c, radio)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000)
            let taking = try await self.decoding(c, "fake", at: 103_000_000, takeOver: true)

            radio.heldTuneHz.value = 100_500_000
            let cancelling = Task { try await self.cancel(c, taking.jobID) }
            try await self.waitUntil("the return reaches the radio") { radio.held.value >= 1 }
            let writing = Task { try await self.retune(c, captureID, tag: 1, to: 104_000_000) }
            try await Task.sleep(nanoseconds: 300_000_000)
            radio.heldTuneHz.value = 0
            try await writing.value
            try await cancelling.value

            try await self.waitForCapture(c, captureID, "the person's retune lands") { $0.centerHz == 104_000_000 }
            try await Task.sleep(nanoseconds: 300_000_000)
            let after = try await self.capture(c, captureID)
            XCTAssertEqual(after?.centerHz, 104_000_000, "and stays")
            let claim = try await self.personsClaim(c, captureID)
            XCTAssertEqual(claim?.displacedBy.clientID, testClientID, "the last move is the person's")
        }
    }

    // MARK: A new job while a capture closes

    /// A job that asks for the radio while the capture made for the last job is closing gets a
    /// fresh capture, not the closing one.
    func testAJobDuringACloseGetsAFreshCapture() async throws {
        let dir = try plugins {
            try writeFakePlugin(in: $0, name: "fakeiq", signal: .signalIq)
            try writeFakePlugin(in: $0)
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let radio = RebindableDevice(blockIntervalNs: 2_000_000)
            _ = try await self.attachRetunable(c, radio)
            for decoder in ["fakeiq", "fake"] {
                let first = try await self.decoding(c, decoder, at: 100_100_000)
                let madeFound = try await self.state(c).captures.first
                let made = try XCTUnwrap(madeFound).captureID

                radio.held.value = 0
                radio.holdClose.value = true
                let cancelling = Task { try await self.cancel(c, first.jobID) }
                try await self.waitUntil("the capture starts closing") { radio.held.value >= 1 }
                let second = try await self.startDecode(c, decoder, at: 100_100_000)
                try await Task.sleep(nanoseconds: 300_000_000)
                radio.holdClose.value = false
                try await cancelling.value

                try await self.waitForJob(c, second.jobID, "\(decoder) starts decoding") {
                    $0.statusDetail.hasPrefix("decoding with") || $0.state == .failed
                }
                let now = try await self.state(c)
                XCTAssertEqual(now.captures.count, 1, "\(decoder): one capture")
                XCTAssertNotEqual(now.captures.first?.captureID, made, "\(decoder): a fresh one")
                XCTAssertEqual(now.captures.first?.claims.map(\.holder.clientID), [second.jobID])
                let record = try await self.nextRecord(c, job: second.jobID)
                XCTAssertNotNil(record, "\(decoder): the second job reads a live capture")
                try await self.cancel(c, second.jobID)
                try await self.ended(c, second.jobID)
                for _ in 0..<100 {
                    if try await self.state(c).captures.isEmpty { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            }
        }
    }

    // MARK: A claim made during a return

    /// A job that joins on the tuning while a return is changing the rate keeps that tuning: the
    /// return stops before the centre moves, puts the rate back, and goes once that job has gone.
    func testAClaimMadeDuringAReturnStopsIt() async throws {
        let dir = try plugins {
            try writeDedicatedPlugin(in: $0)
            try writeFakePlugin(in: $0)
        }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let radio = RebindableDevice(blockIntervalNs: 2_000_000)
            let device = try await self.attachRetunable(c, radio)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000, rate: 1_024_000)
            let taking = try await self.decoding(c, "fakewide", at: 100_100_000, takeOver: true)

            radio.heldRateHz.value = 1_024_000
            let cancelling = Task { try await self.cancel(c, taking.jobID) }
            try await self.waitUntil("the return reaches the radio") { radio.held.value >= 1 }
            // 99.95 MHz is inside 100.1 MHz at 2.4 MSPS and outside 100.5 MHz at 1.024.
            let joining = try await self.startDecode(c, "fake", at: 99_950_000)
            try await self.waitForJob(c, joining.jobID, "the newcomer joins") { $0.statusDetail.hasPrefix("decoding with") }
            radio.heldRateHz.value = 0
            try await cancelling.value

            try await self.waitForCapture(c, captureID, "the return stops and puts the rate back") {
                $0.centerHz == 100_100_000 && $0.sampleRate == 2_400_000
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let held = try await self.capture(c, captureID)
            XCTAssertEqual(held?.centerHz, 100_100_000)
            XCTAssertEqual(held?.claims.first { $0.holder.clientID == joining.jobID }?.state, .claimSatisfied)

            try await self.cancel(c, joining.jobID)
            try await self.waitForCapture(c, captureID, "back once the newcomer has gone") {
                $0.centerHz == 100_500_000 && $0.sampleRate == 1_024_000
            }
        }
    }

    /// A person's move that lands between a job's move and the job noting where it found the
    /// capture leaves no return behind.
    func testAPersonsMoveBeforeTheReturnPointIsNotedWins() async throws {
        let dir = try plugins { try writeFakePlugin(in: $0) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(decoderSearchPath: [dir]) { c in
            let radio = RebindableDevice(blockIntervalNs: 2_000_000, gain: true)
            let device = try await self.attachRetunable(c, radio)
            let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000)

            radio.holdGain.value = true
            let taking = try await self.startDecode(c, "fake", at: 103_000_000, takeOver: true, gainDB: 30)
            try await self.waitUntil("the job has moved the radio and is setting its gain") { radio.held.value >= 1 }
            try await self.retune(c, captureID, tag: 1, to: 104_000_000)
            try await self.waitForCapture(c, captureID, "the person's retune lands") { $0.centerHz == 104_000_000 }
            radio.holdGain.value = false
            try await self.waitForJob(c, taking.jobID, "the job starts") { $0.statusDetail.hasPrefix("decoding with") }

            try await self.cancel(c, taking.jobID)
            try await self.ended(c, taking.jobID)
            try await Task.sleep(nanoseconds: 300_000_000)
            let after = try await self.capture(c, captureID)
            XCTAssertEqual(after?.centerHz, 104_000_000, "nothing returns over the person's move")
        }
    }

    // MARK: Gains of stacked returns

    /// Two jobs that each moved the radio and set a gain: whichever lets go first, the gain the
    /// person had is back once both have.
    func testStackedReturnsGiveTheGainBackInEitherOrder() async throws {
        let dir = try plugins { try writeFakePlugin(in: $0) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for firstGoesFirst in [true, false] {
            try await withDaemon(decoderSearchPath: [dir]) { c in
                let radio = RebindableDevice(blockIntervalNs: 2_000_000, gain: true)
                let device = try await self.attachRetunable(c, radio)
                let (captureID, _) = try await self.personsChannel(c, on: device, at: 100_500_000)
                let first = try await self.decoding(c, "fake", at: 103_000_000, takeOver: true, gainDB: 30)
                let second = try await self.decoding(c, "fake", at: 100_600_000, takeOver: true, gainDB: 40)
                let stacked = try await self.capture(c, captureID)
                XCTAssertEqual(stacked?.gains.first?.db, 40)
                XCTAssertFalse(stacked.map { [100_500_000, 102_400_000].contains($0.centerHz) } ?? true,
                               "the second job moved the radio again")

                let order = firstGoesFirst ? [first, second] : [second, first]
                try await self.cancel(c, order[0].jobID)
                try await self.ended(c, order[0].jobID)
                try await Task.sleep(nanoseconds: 300_000_000)
                if firstGoesFirst {
                    let between = try await self.capture(c, captureID)
                    XCTAssertEqual(between?.gains.first?.db, 40, "the second job keeps its gain while it runs")
                }
                try await self.cancel(c, order[1].jobID)
                let back = try await self.waitForCapture(c, captureID, "back where the person had it") {
                    $0.centerHz == 100_500_000 && $0.gains.first?.db == 20
                }
                XCTAssertEqual(back?.gains.first?.db, 20, "first goes first: \(firstGoesFirst)")
            }
        }
    }
}
