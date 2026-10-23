// SPDX-License-Identifier: GPL-3.0-or-later

// A recording that falls behind says so (MC-9): samples the capture dropped before the recording
// saw them are listed as gaps, and the part's written duration is the audio its WAV holds.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import Synchronization
import XCTest

/// A capture tap that blocks the DSP thread once, for as long as it is told: the DSP thread runs
/// taps inline, so while it sleeps here the capture's block ring fills and the device's next
/// blocks are dropped, which is what a machine too slow for the radio does.
private final class StallingTap: CaptureTap, Sendable {
    let id = StreamID()
    private let stallMs = Atomic<Int>(0)

    /// The next block the tap sees blocks the DSP thread for `ms`.
    func stallNext(ms: Int) { stallMs.store(ms, ordering: .relaxed) }

    func write(iq _: SampleBuffer, at _: SampleTime) {
        let ms = stallMs.exchange(0, ordering: .relaxed)
        if ms > 0 { usleep(useconds_t(ms) * 1000) }
    }

    func closeTap() async {}
}

extension RecordingJobTests {
    /// The DSP thread is held for a second in the middle of a continuous recording. The capture's
    /// ring holds 64 blocks (0.44 s at 2.4 MSPS), so about 0.56 s of the radio's samples are
    /// dropped. The part lists that gap where it was on the capture's timeline, its `written_ms`
    /// and `samples` are what the WAV holds, its span is the two together, and the job's event
    /// says so while the recording is still running.
    func testARecordingThatFallsBehindListsTheGapsAndClaimsOnlyWhatItWrote() async throws {
        let dir = try recordings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await withDaemon(recordingsPath: dir) { c in
            let device = try await self.attach(c, fixture: "nfm_tone.cf32", loop: true)
            var capture = Leyline_V1_CreateCaptureRequest()
            capture.deviceID = device.deviceID
            capture.centerHz = 146_520_000
            capture.sampleRate = device.sampleRates.first ?? 2_400_000
            let made = try await c.control.createCapture(capture, metadata: testMetadata)
            var channel = Leyline_V1_CreateChannelRequest()
            channel.captureID = made.captureID
            channel.offsetHz = 100_000
            channel.mode = .nfm
            let listening = try await c.control.createChannel(channel, metadata: testMetadata)
            let found = await c.daemon.store.captureEngine(try XCTUnwrap(CaptureID(string: made.captureID)))
            let engine = try XCTUnwrap(found)
            let tap = StallingTap()
            await engine.addTap(tap)
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            defer { Task { await events.stop() } }

            var config = Leyline_V1_RecordConfig()
            config.channelID = listening.channelID
            config.durationMs = 3000
            var started = Leyline_V1_Job()
            let log = try await LogCapture.shared.capture {
                started = try await self.start(c, config)
                try await Task.sleep(nanoseconds: 700_000_000)
                tap.stallNext(ms: 1000)
                let done = try await self.waitForEnd(c, started.jobID)
                XCTAssertEqual(done.state, .completed, done.statusDetail)
                XCTAssertTrue(done.statusDetail.contains("dropped in"), done.statusDetail)
            }
            await engine.removeTap(id: tap.id)

            let manifest = try self.manifest(dir, started.jobID)
            XCTAssertEqual(manifest.parts.count, 1, "a continuous recording is one part, gaps and all")
            let part = try XCTUnwrap(manifest.parts.first)
            let gaps = try XCTUnwrap(part.gaps, "the part lists what was dropped inside it")
            let rate = Double(manifest.anchors[0].sampleRate)
            let dropped = Double(gaps.reduce(UInt64(0)) { $0 + $1.samples }) / rate
            // A second's stall less the ring's 0.44 s. The margin is wide because the file device
            // paces itself on the wall clock and a loaded runner adds drops of its own; what the
            // test is about is that the drops are counted, not how many there were.
            XCTAssertGreaterThan(dropped, 0.2, "\(gaps)")
            XCTAssertLessThan(dropped, 1.5, "\(gaps)")
            for g in gaps {
                XCTAssertGreaterThanOrEqual(g.sample, part.startSample)
                XCTAssertLessThanOrEqual(g.sample + g.samples, part.endSample)
            }
            XCTAssertEqual(manifest.coverageGaps.filter { $0.reason == RecordingGap.samplesDropped }.count, gaps.count)

            // What the manifest claims is what the WAV holds.
            let file = dir + "/" + started.jobID + "/" + part.file
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)
            let wavSeconds = Double(size.uint64Value - UInt64(WAVHeader.bytes)) / 2 / Double(manifest.sampleRate)
            XCTAssertEqual(Double(part.samples) / Double(manifest.sampleRate), wavSeconds, accuracy: 0.001)
            XCTAssertEqual(Double(try XCTUnwrap(part.writtenMs)) / 1000, wavSeconds, accuracy: 0.001)
            XCTAssertEqual(Double(manifest.durationMs) / 1000, wavSeconds, accuracy: 0.002)
            // And the part's span is the audio written plus the gaps, within a block or two of
            // dating at each end (6.8 ms a block at 2.4 MSPS) and the audio filter's delay.
            let span = Double(part.endSample - part.startSample) / rate
            XCTAssertEqual(span, wavSeconds + dropped, accuracy: 0.05,
                           "span \(span) s, written \(wavSeconds) s, dropped \(dropped) s")

            // The job said so while it ran, on its own event, with the total so far.
            let event = await events.waitFor(timeoutMs: 1000) {
                $0.job.jobID == started.jobID && $0.job.state == .running && $0.job.statusDetail.contains("dropped in")
            }
            XCTAssertNotNil(event, "a running job's event names the gap")
            XCTAssertTrue(log.contains("ms of samples dropped at capture sample"), log)

            var ref = Leyline_V1_ResourceRef()
            ref.uri = "ley://recordings/\(started.jobID)"
            let resource = try await c.resources.getResource(ref, metadata: testMetadata)
            XCTAssertEqual(resource.metadata["gaps"], String(gaps.count))
            XCTAssertNotEqual(resource.metadata["dropped_ms"], "0")
        }
    }
}
