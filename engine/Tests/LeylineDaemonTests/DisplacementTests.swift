// SPDX-License-Identifier: GPL-3.0-or-later

// Uniform displacement (docs/design/claims.md, "Displacement, uniformly"; plan CL-3): a capture's
// bulk frames carry the tuning they were made at, views do not flood the event plane, and a job's
// sink is no person at the controls.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineServer
import LeylineProto
import XCTest

final class DisplacementTests: XCTestCase {
    private func attachRetunable(_ c: DaemonClients) async throws -> String {
        let id = try await c.daemon.registry.attachVirtualDevice(RebindableDevice()).descriptor.id.string
        for _ in 0..<150 {
            let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if s.devices.contains(where: { $0.deviceID == id }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return id
    }

    private func capture(_ c: DaemonClients, on device: String, at hz: UInt64) async throws -> String {
        var create = Leyline_V1_CreateCaptureRequest()
        create.deviceID = device
        create.centerHz = hz
        return try await c.control.createCapture(create, metadata: testMetadata).captureID
    }

    private func retune(_ c: DaemonClients, _ captureID: String, tag: UInt64, to hz: UInt64) async throws {
        var w = Leyline_V1_ParamWrite()
        w.tag = tag
        w.targetID = captureID
        w.centerHz = hz
        let message = w
        _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
    }

    private func captureState(_ c: DaemonClients, _ id: String) async throws -> Leyline_V1_Capture? {
        try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata).captures.first { $0.captureID == id }
    }

    /// Streams `stream` into `into` until the task is cancelled.
    private func collect(_ c: DaemonClients, _ stream: String, into frames: LockedValue<[Leyline_V1_Frame]>) -> Task<Void, Never> {
        Task {
            var ref = Leyline_V1_StreamRef()
            ref.streamID = stream
            try? await c.bulk.stream(ref, metadata: testMetadata) { response in
                for try await f in response.messages { frames.value.append(f) }
            }
        }
    }

    private func waitFor(_ frames: LockedValue<[Leyline_V1_Frame]>, _ why: String,
                         _ pred: (Leyline_V1_Frame) -> Bool) async throws -> Leyline_V1_Frame {
        for _ in 0..<250 {
            if let f = frames.value.first(where: pred) { return f }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(frames.value.first(where: pred), why)
    }

    // MARK: Frames

    /// A capture's FFT and IQ frames carry the centre, span and tuning generation they were made
    /// at, so a waterfall drawn across a retune labels each row where it was; the capture itself
    /// carries the same generation.
    func testFramesCarryTheTuningTheyWereMadeAt() async throws {
        try await withDaemon { c in
            let device = try await self.attachRetunable(c)
            let captureID = try await self.capture(c, on: device, at: 100_500_000)
            var fft = Leyline_V1_SubscribeRequest()
            fft.captureID = captureID
            fft.kind = .fft
            fft.fft.rowsPerSecond = 20
            let fftStream = try await c.bulk.subscribe(fft, metadata: testMetadata)
            let rows = LockedValue<[Leyline_V1_Frame]>([])
            let reading = self.collect(c, fftStream.streamID, into: rows)
            defer { reading.cancel() }

            let before = try await self.waitFor(rows, "a row arrives") { $0.centerHz != 0 }
            XCTAssertEqual(before.centerHz, 100_500_000)
            XCTAssertEqual(before.spanHz, 2_400_000)
            let generationState = try await self.captureState(c, captureID)
            let generation = try XCTUnwrap(generationState).tuningGeneration
            XCTAssertEqual(before.tuningGeneration, generation, "the row's generation is the capture's")

            try await self.retune(c, captureID, tag: 1, to: 101_000_000)
            let after = try await self.waitFor(rows, "a row at the new centre") { $0.centerHz == 101_000_000 }
            XCTAssertGreaterThan(after.tuningGeneration, before.tuningGeneration)
            XCTAssertEqual(after.spanHz, 2_400_000)
            let nowState = try await self.captureState(c, captureID)
            let now = try XCTUnwrap(nowState)
            XCTAssertEqual(now.tuningGeneration, after.tuningGeneration, "the capture event's generation is the frame's")
            XCTAssertEqual(fftStream.centerHz, 100_500_000, "the descriptor keeps the tuning at subscribe time")

            // Away and back between two looks: same centre, new generation.
            try await self.retune(c, captureID, tag: 2, to: 102_000_000)
            try await self.retune(c, captureID, tag: 3, to: 101_000_000)
            let back = try await self.waitFor(rows, "a row after the round trip") {
                $0.centerHz == 101_000_000 && $0.tuningGeneration > after.tuningGeneration
            }
            XCTAssertEqual(back.centerHz, after.centerHz)

            // IQ frames carry it too.
            var iq = Leyline_V1_SubscribeRequest()
            iq.captureID = captureID
            iq.kind = .iq
            let iqStream = try await c.bulk.subscribe(iq, metadata: testMetadata)
            let blocks = LockedValue<[Leyline_V1_Frame]>([])
            let iqReading = self.collect(c, iqStream.streamID, into: blocks)
            defer { iqReading.cancel() }
            let block = try await self.waitFor(blocks, "an IQ frame") { _ in true }
            XCTAssertEqual(block.centerHz, 101_000_000)
            XCTAssertEqual(block.spanHz, 2_400_000)
            XCTAssertEqual(block.tuningGeneration, back.tuningGeneration)
        }
    }

    // MARK: Views on the event plane

    /// Opening and closing streams is no flood: a view's claim rides the next capture event or
    /// one a second, so 50 streams opened and closed cannot push the events that matter out of the
    /// 256-event replay window. GetState still lists every view as it stands.
    func testViewsDoNotFloodTheEventPlane() async throws {
        try await withDaemon { c in
            let device = try await self.attachRetunable(c)
            let captureID = try await self.capture(c, on: device, at: 100_500_000)
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            defer { Task { await events.stop() } }
            var fft = Leyline_V1_SubscribeRequest()
            fft.captureID = captureID
            fft.kind = .fft
            let started = ContinuousClock.now
            for i in 0..<50 {
                let stream = try await c.bulk.subscribe(fft, metadata: testMetadata)
                if i == 0 {
                    let heldState = try await self.captureState(c, captureID)
                    let held = try XCTUnwrap(heldState).claims
                    XCTAssertEqual(held.map(\.kind), [.claimSpectrum], "GetState lists the view at once")
                }
                _ = try await c.bulk.unsubscribe(.with { $0.streamID = stream.streamID }, metadata: testMetadata)
            }
            let took = ContinuousClock.now - started
            // Whatever is still waiting goes out within a second.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let captureEvents = await events.events.filter {
                if case .capture(let cap)? = $0.body { return cap.captureID == captureID }
                return false
            }
            let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
            let ceiling = Int(seconds.rounded(.up)) + 2
            print("50 views opened and closed in \(String(format: "%.2f", seconds)) s: \(captureEvents.count) capture events (ceiling \(ceiling))")
            XCTAssertLessThanOrEqual(captureEvents.count, ceiling, "at most one capture event a second comes of views alone")
            let last = try XCTUnwrap(captureEvents.last, "the views' coming and going is published")
            if case .capture(let cap)? = last.body {
                XCTAssertTrue(cap.claims.isEmpty, "the last event says every view has gone: \(cap.claims)")
            }
        }
    }

    // MARK: A job is no person

    /// A sink attached by a job makes no PERSON presence: only a person is at the controls.
    func testAJobsSinkMakesNoPresence() async throws {
        try await withDaemon { c in
            let device = try await self.attachRetunable(c)
            let captureID = try await self.capture(c, on: device, at: 100_500_000)
            let id = try XCTUnwrap(CaptureID(string: captureID))
            await c.daemon.store.notePresence(id, client: .job(JobID()), wroteAtNs: nil)
            await c.daemon.store.publishCapture(id)
            let claimsState = try await self.captureState(c, captureID)
            let claims = try XCTUnwrap(claimsState).claims
            XCTAssertFalse(claims.contains { $0.kind == .claimListen }, "\(claims)")
            // A person's sink does.
            let person = ClientContext(id: "cli_person", kind: "app", label: "Leyline")
            await c.daemon.store.notePresence(id, client: person, wroteAtNs: nil)
            let afterState = try await self.captureState(c, captureID)
            let after = try XCTUnwrap(afterState).claims
            XCTAssertEqual(after.filter { $0.kind == .claimListen }.map(\.holder.clientID), ["cli_person"])
        }
    }
}
