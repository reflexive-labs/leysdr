// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import EngineCore

final class ChannelTests: XCTestCase {
    private func nfmTonePath() throws -> String {
        let p = Fixtures.dir + "/nfm_tone.cf32"
        guard FileManager.default.fileExists(atPath: p) else { throw XCTSkip("nfm_tone fixture missing") }
        return p
    }

    private func telemetryRecord(_ capID: CaptureID, index: UInt64) -> ChannelTelemetryRecord {
        ChannelTelemetryRecord(kind: .meter, time: SampleTime(captureID: capID, sampleIndex: index), powerDBFS: Float(index), snrDB: 0, squelchOpen: true)
    }

    /// The telemetry ring is drop-oldest: overflow evicts the oldest unread records, counts them, and
    /// keeps the newest so a stalled drain never reads a stale prefix.
    func testTelemetryQueueDropsOldestAndCountsEvictions() {
        let queue = ChannelTelemetryQueue()
        let capID = CaptureID()
        let n = queue.capacity + 10
        for i in 0..<n { queue.push(telemetryRecord(capID, index: UInt64(i))) }
        XCTAssertEqual(queue.dropped, 10)
        var popped: [UInt64] = []
        while let r = queue.pop() { popped.append(r.time.sampleIndex) }
        XCTAssertEqual(popped.count, queue.capacity)
        XCTAssertEqual(popped, Array(UInt64(10)..<UInt64(n)), "oldest 10 evicted, newest kept in order")
        XCTAssertEqual(popped.last, UInt64(n - 1), "the last pushed record must survive")
        XCTAssertNil(queue.pop())
        // Steady state after an overflow: push/pop still round-trips; the drop count is cumulative.
        queue.push(ChannelTelemetryRecord(kind: .squelch, time: SampleTime(captureID: capID, sampleIndex: 999), powerDBFS: 0, snrDB: 0, squelchOpen: false))
        XCTAssertEqual(queue.pop()?.time.sampleIndex, 999)
        XCTAssertEqual(queue.dropped, 10)
        queue.finish()
    }

    /// The fan-out buffer behind each telemetry subscriber is drop-oldest: a subscriber that stops
    /// reading loses the oldest records past the hub capacity, every loss is counted on its own
    /// subscription, and a subscriber that keeps up is not charged for the slow one's drops.
    func testTelemetryHubCountsDropsPerSubscriber() async {
        let hub = TelemetryHub()
        let capID = CaptureID()
        let stalled = hub.subscribe()
        let reader = hub.subscribe()
        let n = TelemetryHub.capacity + 40
        for i in 0..<n { hub.publish(telemetryRecord(capID, index: UInt64(i))) }
        XCTAssertEqual(stalled.dropped, 40, "drops past the buffer capacity are counted")
        XCTAssertEqual(reader.dropped, 40, "nobody read yet: the reader lost the same prefix")
        // The reader catches up; the stalled subscriber keeps losing its oldest and only it is charged.
        var readCount = 0
        for await _ in reader.stream { readCount += 1; if readCount == TelemetryHub.capacity { break } }
        for i in n..<(n + 10) { hub.publish(telemetryRecord(capID, index: UInt64(i))) }
        XCTAssertEqual(stalled.dropped, 50, "the stalled subscriber keeps losing the oldest")
        XCTAssertEqual(reader.dropped, 40, "a subscriber that keeps up is not charged for a sibling's drops")
        for await _ in reader.stream { readCount += 1; if readCount == TelemetryHub.capacity + 10 { break } }
        XCTAssertEqual(readCount, TelemetryHub.capacity + 10)
        // The survivors are the newest `capacity` records in order; reading does not change the count.
        var got: [UInt64] = []
        for await t in stalled.stream {
            if case let .meter(time, _, _, _, _, _) = t { got.append(time.sampleIndex) }
            if got.count == TelemetryHub.capacity { break }
        }
        XCTAssertEqual(got, Array(UInt64(50)..<UInt64(n + 10)), "oldest 50 evicted, newest kept in order")
        XCTAssertEqual(stalled.dropped, 50)
        hub.finishAll()
        XCTAssertEqual(stalled.dropped, 50)
    }

    /// Producer and consumer race on the ring: every record is either delivered or counted dropped,
    /// delivered records are in order, and no torn record slips through the seqlock.
    func testTelemetryQueueConcurrentPushPopAccountsForEveryRecord() {
        let queue = ChannelTelemetryQueue(capacity: 8)
        let capID = CaptureID()
        let total: UInt64 = 200_000
        let done = DispatchSemaphore(value: 0)
        let producer = Thread {
            for i in 1...total { queue.push(self.telemetryRecord(capID, index: i)) }
            done.signal()
        }
        producer.start()
        var popped: [UInt64] = []
        var last: UInt64 = 0
        var finished = false
        while true {
            if let r = queue.pop() {
                XCTAssertEqual(r.powerDBFS, Float(r.time.sampleIndex), "torn record")
                XCTAssertGreaterThan(r.time.sampleIndex, last, "out of order")
                last = r.time.sampleIndex
                popped.append(r.time.sampleIndex)
            } else if finished {
                break
            } else if done.wait(timeout: .now()) == .success {
                finished = true // one more sweep for anything pushed before the signal
            }
        }
        XCTAssertEqual(popped.last, total, "the newest record always survives")
        XCTAssertEqual(UInt64(popped.count) + UInt64(queue.dropped), total, "delivered + dropped == pushed")
        XCTAssertNil(queue.pop())
        queue.finish()
    }

    /// Narrow modes cannot ask for more than 0.9·r2: the channel would be filtered narrower than it reports.
    func testNarrowBandwidthAboveAudioRateIsRejected() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        do {
            _ = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 50_000, mode: .nfm))
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .am)) as! DefaultChannelEngine
        let core = try XCTUnwrap(channel.slot.load())
        do {
            try await channel.update(ChannelConfig(offsetHz: 100_000, bandwidthHz: 50_000, mode: .am))
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let kept = await channel.config
        XCTAssertEqual(kept.bandwidthHz, 12_500)
        XCTAssertTrue(channel.slot.load() === core)
        // WFM is the wide path.
        _ = try await capture.addChannel(ChannelConfig(offsetHz: 300_000, bandwidthHz: 200_000, mode: .wfm))
    }

    func testOffsetOutsideCaptureIsRejected() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        do {
            _ = try await capture.addChannel(ChannelConfig(offsetHz: 1_300_000, bandwidthHz: 12_500, mode: .nfm))
            XCTFail("expected OFFSET_OUT_OF_CAPTURE")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "OFFSET_OUT_OF_CAPTURE")
        }
        let channels = await capture.channels
        XCTAssertTrue(channels.isEmpty)
    }

    func testRetuneMovesChannelOutOfCaptureAndBack() async throws {
        let device = BurstDevice(blocks: 0)
        let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        XCTAssertEqual(channel.audioRate, 48_000)
        var state = await channel.state
        XCTAssertEqual(state, .active)
        XCTAssertNotNil(channel.slot.load())

        try await capture.retune(centerHz: 101_500_000)
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        XCTAssertNil(channel.slot.load(), "out-of-capture channel must be skipped by the DSP thread")
        var config = await channel.config
        XCTAssertEqual(config.offsetHz, -1_400_000, "offset follows the absolute frequency (100.1 MHz) while out of capture")

        try await capture.retune(centerHz: 100_500_000)
        state = await channel.state
        XCTAssertEqual(state, .active)
        config = await channel.config
        XCTAssertEqual(config.offsetHz, -400_000, "channel keeps its absolute frequency (100.1 MHz)")
        XCTAssertNotNil(channel.slot.load())
        let snap = await capture.snapshot
        XCTAssertEqual(snap.centerHz, 100_500_000)
        await capture.stop()
    }

    /// FU-2: mode and bandwidth writes on an OUT_OF_CAPTURE channel are stored, not rejected; the
    /// channel stays out at its absolute frequency and the rebuild on re-entry uses the stored config.
    /// An offset write while out is still validated against the capture (and can bring it back in).
    /// A stored write must still respect the offset-independent bound, or re-entry would fail later.
    func testUpdateWhileOutOfCaptureRejectsBandwidthWiderThanCapture() async throws {
        let rate: UInt64 = 2_400_000
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: rate)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm))
        try await capture.retune(centerHz: 110_000_000)
        var state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        var cfg = await channel.config
        cfg.mode = .wfm
        cfg.bandwidthHz = UInt32(rate) + 1
        do {
            try await channel.update(cfg)
            XCTFail("a bandwidth wider than the capture must be rejected even while out of capture")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        let kept = await channel.config
        XCTAssertEqual(kept.bandwidthHz, 12_500, "a rejected write leaves the stored config untouched")
        await capture.stop()
    }

    func testStructuralUpdateWhileOutOfCaptureIsStoredAndAppliedOnReentry() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        try await capture.retune(centerHz: 101_500_000)
        var state = await channel.state
        XCTAssertEqual(state, .outOfCapture)

        // Mode + bandwidth in one write, offset untouched: accepted, still out, frequency untouched.
        var cfg = await channel.config
        cfg.mode = .am
        cfg.bandwidthHz = 8_000
        try await channel.update(cfg)
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        XCTAssertNil(channel.slot.load(), "no core is built while out of capture")
        var config = await channel.config
        XCTAssertEqual(config.mode, .am)
        XCTAssertEqual(config.bandwidthHz, 8_000)
        XCTAssertEqual(config.offsetHz, -1_400_000, "offset keeps following the absolute frequency (100.1 MHz)")

        // A mode/bandwidth pair the planner cannot build (AM wider than r2) is still rejected while out.
        cfg = config
        cfg.bandwidthHz = 100_000
        do {
            try await channel.update(cfg)
            XCTFail("expected INVALID_ARGUMENT from the planner")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        config = await channel.config
        XCTAssertEqual(config.bandwidthHz, 8_000, "rejected write leaves the stored config untouched")

        // An offset write while out is validated against the current capture as before.
        cfg = config
        cfg.offsetHz = -2_000_000
        do {
            try await channel.update(cfg)
            XCTFail("expected OFFSET_OUT_OF_CAPTURE")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "OFFSET_OUT_OF_CAPTURE")
        }
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)

        // Retune back: active with the stored mode/bandwidth at the original absolute frequency.
        try await capture.retune(centerHz: 100_000_000)
        state = await channel.state
        XCTAssertEqual(state, .active)
        let core = try XCTUnwrap(channel.slot.load())
        XCTAssertEqual(core.config.mode, .am)
        XCTAssertEqual(core.config.bandwidthHz, 8_000)
        XCTAssertEqual(core.config.offsetHz, 100_000)
        config = await channel.config
        XCTAssertEqual(config.offsetHz, 100_000)

        // An offset write while out that brings the channel back in fits: active immediately.
        try await capture.retune(centerHz: 101_500_000)
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        cfg = await channel.config
        cfg.offsetHz = -500_000
        try await channel.update(cfg)
        state = await channel.state
        XCTAssertEqual(state, .active)
        config = await channel.config
        XCTAssertEqual(config.offsetHz, -500_000)
        XCTAssertEqual(config.mode, .am)
        await capture.stop()
    }

    /// A retune pushes the channel out of capture; a squelch/AGC write while out is kept without
    /// resurrecting the channel or moving it, and a retune back resumes at the original frequency.
    func testUpdateWhileOutOfCaptureKeepsAbsoluteFrequency() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        try await capture.retune(centerHz: 101_500_000)
        var state = await channel.state
        XCTAssertEqual(state, .outOfCapture)

        // Non-structural write with no core: stored, still out of capture, frequency untouched.
        var cfg = await channel.config
        cfg.squelchDB = -50
        cfg.agc = .manual
        try await channel.update(cfg)
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        XCTAssertNil(channel.slot.load())
        var config = await channel.config
        XCTAssertEqual(config.squelchDB, -50)
        XCTAssertEqual(config.agc, .manual)
        XCTAssertEqual(config.offsetHz, -1_400_000)

        // Structural write that does not touch the offset (bandwidth) while out: stored, the channel
        // stays out of capture at its absolute frequency (the stale offset is not re-validated as-is).
        cfg = config
        cfg.bandwidthHz = 10_000
        try await channel.update(cfg)
        state = await channel.state
        XCTAssertEqual(state, .outOfCapture)
        XCTAssertNil(channel.slot.load())
        config = await channel.config
        XCTAssertEqual(config.bandwidthHz, 10_000)
        XCTAssertEqual(config.offsetHz, -1_400_000)

        // Retune back: active again at 100.1 MHz with the stored squelch/AGC applied.
        try await capture.retune(centerHz: 100_000_000)
        state = await channel.state
        XCTAssertEqual(state, .active)
        let core = try XCTUnwrap(channel.slot.load())
        config = await channel.config
        XCTAssertEqual(config.offsetHz, 100_000, "original absolute frequency")
        XCTAssertEqual(core.config.offsetHz, 100_000)
        XCTAssertEqual(core.config.squelchDB, -50)
        XCTAssertEqual(core.config.agc, .manual)
        XCTAssertEqual(channel.audioRate, 48_000)
        await capture.stop()
    }

    /// A structural update while in capture that does not change the offset keeps the absolute
    /// frequency even after the capture has moved (the offset is re-derived, not taken from the write).
    func testStructuralUpdateAfterRetuneKeepsAbsoluteFrequency() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        try await capture.retune(centerHz: 100_500_000)
        var config = await channel.config
        XCTAssertEqual(config.offsetHz, -400_000)
        // Mode change carrying the (now re-derived) offset: stays at 100.1 MHz.
        var cfg = config
        cfg.mode = .am
        cfg.bandwidthHz = 10_000
        try await channel.update(cfg)
        config = await channel.config
        XCTAssertEqual(config.offsetHz, -400_000)
        XCTAssertEqual(config.mode, .am)
        // Explicit offset change moves the absolute frequency: retune back shows the new one.
        cfg = config
        cfg.offsetHz = 0
        try await channel.update(cfg)
        try await capture.retune(centerHz: 100_000_000)
        config = await channel.config
        XCTAssertEqual(config.offsetHz, 500_000, "absolute frequency moved to 100.5 MHz by the explicit offset write")
        let state = await channel.state
        XCTAssertEqual(state, .active)
        await capture.stop()
    }

    func testUpdateInPlaceVersusStructural() async throws {
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        let sink = NullSink()
        try await channel.attach(sink)
        let core1 = try XCTUnwrap(channel.slot.load())
        // Squelch/AGC-only change: same core.
        try await channel.update(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: -50, agc: .manual))
        XCTAssertTrue(channel.slot.load() === core1)
        // Structural change: new core, sinks carried over, audio rate re-derived.
        try await channel.update(ChannelConfig(offsetHz: 200_000, bandwidthHz: 10_000, mode: .am, squelchDB: -50))
        let core2 = try XCTUnwrap(channel.slot.load())
        XCTAssertFalse(core2 === core1)
        XCTAssertEqual(core2.config.mode, .am)
        XCTAssertEqual(core2.currentSinks.count, 1)
        XCTAssertEqual(channel.audioRate, 48_000)
        let sinks = await channel.sinks
        XCTAssertEqual(sinks.count, 1)
        await channel.detach(sink.id)
        let after = await channel.sinks
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(core2.currentSinks.count, 0)
        await capture.stop()
    }

    /// A PCM-only sink (system audio) must never receive a raw-IQ channel's cf32 blocks: attach to a
    /// raw-IQ channel is refused, and so is switching a channel to raw IQ while one is attached.
    func testPCMOnlySinkRejectedOnRawIQChannel() async throws {
        final class PCMOnlyNull: PCMOnlyAudioSink, @unchecked Sendable {
            let id = SinkID()
            func write(_ audio: SampleBuffer, at time: SampleTime) {}
            func flush() async {}
            func closeSink() async {}
        }
        let capture = DefaultCaptureEngine(device: BurstDevice(blocks: 0), centerHz: 100_000_000, sampleRate: 2_400_000)
        let raw = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .rawIQ)) as! DefaultChannelEngine
        do {
            try await raw.attach(PCMOnlyNull())
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let rawSinks = await raw.sinks
        XCTAssertTrue(rawSinks.isEmpty)
        // A plain sink is still fine on raw IQ.
        try await raw.attach(NullSink())

        let nfm = try await capture.addChannel(ChannelConfig(offsetHz: 200_000, bandwidthHz: 12_500, mode: .nfm)) as! DefaultChannelEngine
        try await nfm.attach(PCMOnlyNull())
        do {
            try await nfm.update(ChannelConfig(offsetHz: 200_000, bandwidthHz: 12_500, mode: .rawIQ))
            XCTFail("expected INVALID_ARGUMENT")
        } catch let e as EngineError {
            XCTAssertEqual(e.code, "INVALID_ARGUMENT")
        }
        let cfg = await nfm.config
        XCTAssertEqual(cfg.mode, .nfm)
        await capture.stop()
    }

    /// The audio level is measured on the demodulated block, not on the channel IQ. A steady FM
    /// carrier makes the point: the channel is loud in `powerDBFS` whatever it carries, and the
    /// audio level reflects the tone that was actually recovered.
    func testMeterReportsAudioLevelSeparatelyFromChannelPower() async throws {
        let path = try nfmTonePath()
        let device = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let capture = DefaultCaptureEngine(device: device, centerHz: UInt64(device.sidecar.centerHz), sampleRate: UInt64(device.sidecar.sampleRate))
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40)) as! DefaultChannelEngine
        let collector = AudioCollector()
        try await channel.attach(collector.sink)
        let events = Task<[ChannelTelemetry], Never> {
            var out: [ChannelTelemetry] = []
            for await t in channel.telemetrySubscription().stream { out.append(t) }
            return out
        }
        try await capture.start()
        let deadline = Date().addingTimeInterval(10)
        while collector.count < 24_000, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await capture.stop()

        var audio: [Double] = []
        var peaks: [Double] = []
        var powers: [Double] = []
        for e in await events.value {
            if case let .meter(_, power, _, _, a, p) = e, !a.isNaN {
                audio.append(a); peaks.append(p); powers.append(power)
            }
        }
        XCTAssertGreaterThanOrEqual(audio.count, 3, "expected several meters carrying an audio level")
        for (i, a) in audio.enumerated() {
            XCTAssertFalse(a.isNaN, "a demodulating channel reports an audio level")
            XCTAssertLessThanOrEqual(a, 0.001, "RMS cannot exceed full scale: \(a) dBFS")
            XCTAssertGreaterThanOrEqual(peaks[i], a, "peak is never under RMS: \(peaks[i]) < \(a)")
            XCTAssertLessThanOrEqual(peaks[i], 0.001, "the demodulator clips to +-1, so the peak cannot exceed 0 dBFS")
        }
        // The two are different measurements of different things, so they must not be equal.
        XCTAssertNotEqual(audio[0], powers[0], accuracy: 0.001,
                          "audio level and channel power must be measured separately")
    }

    /// The close edge of a squelch transition summarises the transmission that just ended: how long
    /// it ran and how loud it got. The open edge carries no summary, because a transmission still in
    /// progress has neither a duration nor a final peak, and a client must be able to tell that
    /// apart from a transmission that really was zero samples long.
    func testSquelchCloseEdgeSummarisesTheTransmission() async throws {
        let path = try nfmTonePath()
        let device = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let capture = DefaultCaptureEngine(device: device, centerHz: UInt64(device.sidecar.centerHz), sampleRate: UInt64(device.sidecar.sampleRate))
        // Open to begin with: the -20 dBFS tone clears -40 comfortably.
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40)) as! DefaultChannelEngine
        let collector = AudioCollector()
        try await channel.attach(collector.sink)
        let events = Task<[ChannelTelemetry], Never> {
            var out: [ChannelTelemetry] = []
            for await t in channel.telemetrySubscription().stream { out.append(t) }
            return out
        }
        try await capture.start()
        // PowerMeter reports NaN SNR until it has measured a second of samples, so the transmission
        // has to run past that before the close edge can carry a real peak SNR. The channel runs at
        // ~48 kHz, so 72000 frames is comfortably over a second.
        let deadline = Date().addingTimeInterval(20)
        while collector.count < 72_000, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        // Shut it: threshold above the tone forces a close edge, which carries the summary.
        try await channel.update(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: 0))
        let mark = collector.count
        while collector.count < mark + 9600, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await capture.stop()
        let all = await events.value

        var opens: [ChannelTelemetry] = []
        var closes: [ChannelTelemetry] = []
        for e in all {
            if case let .squelch(_, open, _, _, _) = e { if open { opens.append(e) } else { closes.append(e) } }
        }
        guard case let .squelch(_, _, closeSamples, closeSNR, closePower)? = closes.last else {
            return XCTFail("expected a squelch-close transition, got \(all.count) events")
        }
        XCTAssertGreaterThan(closeSamples, 0, "a transmission that carried audio must report a duration")
        XCTAssertFalse(closeSNR.isNaN, "the close edge must carry a peak SNR")
        XCTAssertFalse(closePower.isNaN, "the close edge must carry a peak level")
        // The fixture's tone sits near -20 dBFS; the peak is the loudest block, so it must be at
        // least as loud as the threshold the squelch was holding open against.
        XCTAssertGreaterThan(closePower, -40, "peak level \(closePower) should reflect the -20 dBFS tone")
        for e in opens {
            guard case let .squelch(_, _, samples, snr, power) = e else { continue }
            XCTAssertEqual(samples, 0, "an open edge has no duration to report")
            XCTAssertTrue(snr.isNaN, "an open edge has no peak SNR yet")
            XCTAssertTrue(power.isNaN, "an open edge has no peak level yet")
        }
    }

    func testSquelchTelemetryTransitionsAndZeros() async throws {
        let path = try nfmTonePath()
        let device = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let capture = DefaultCaptureEngine(device: device, centerHz: UInt64(device.sidecar.centerHz), sampleRate: UInt64(device.sidecar.sampleRate))
        // Threshold far above the −20 dBFS tone: squelch stays closed, audio must be all zeros.
        let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: 0)) as! DefaultChannelEngine
        let collector = AudioCollector()
        try await channel.attach(collector.sink)
        let events = Task<[ChannelTelemetry], Never> {
            var out: [ChannelTelemetry] = []
            for await t in channel.telemetrySubscription().stream { out.append(t) }
            return out
        }
        try await capture.start()
        let deadline = Date().addingTimeInterval(5)
        while collector.count < 9600, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(collector.all.allSatisfy { $0 == 0 }, "closed squelch must write zeros")
        // Open it: threshold below the signal → a .squelch(open: true) transition and non-zero audio.
        try await channel.update(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40))
        let before = collector.count
        while collector.count < before + 9600, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        await capture.stop()
        let all = await events.value
        let opens = all.compactMap { (e) -> Bool? in
            if case let .squelch(_, open, _, _, _) = e { return open } else { return nil }
        }
        XCTAssertEqual(opens.last, true, "expected a squelch-open transition after lowering the threshold: \(opens)")
        let meters = all.filter { if case .meter = $0 { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(meters.count, 3, "meter cadence is 100 ms of samples")
        XCTAssertTrue(collector.all.suffix(4800).contains { $0 != 0 }, "audio flows once open")
        let state = await channel.state
        XCTAssertEqual(state, .active)
    }

    /// A stream restart starts the channel over: the transmission in progress belonged to the
    /// samples before the gap, so the squelch re-arms and the signal after it opens a new one whose
    /// duration counts only post-restart samples.
    func testResetDropsTheTransmissionInProgress() throws {
        let rate: UInt64 = 240_000
        let queue = ChannelTelemetryQueue()
        let core = try ChannelDSPCore(captureRate: rate,
                                      config: ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40),
                                      telemetry: queue)
        let block = 4096
        let loud = DSPTest.storage(DSPTest.fmTone(carrierHz: 0, audioHz: 1000, deviationHz: 2500, rate: Double(rate), count: block))
        let quiet = DSPTest.storage([Float](repeating: 0, count: block * 2))
        let cap = CaptureID()
        var index: UInt64 = 0
        func feed(_ storage: SampleStorage, blocks: Int) {
            for _ in 0 ..< blocks {
                core.process(block: storage.view(count: block), at: SampleTime(captureID: cap, sampleIndex: index))
                index &+= UInt64(block)
            }
        }
        func edges() -> [ChannelTelemetryRecord] {
            var out: [ChannelTelemetryRecord] = []
            while let r = queue.pop() { if r.kind == .squelch { out.append(r) } }
            return out
        }

        feed(loud, blocks: 8)
        XCTAssertEqual(edges().map(\.squelchOpen), [true], "the tone opens the squelch once")
        core.reset()
        feed(loud, blocks: 4)
        let afterReset = edges()
        XCTAssertEqual(afterReset.map(\.squelchOpen), [false, true],
                       "the reset ends the open transmission, then the same tone opens a new one")
        feed(quiet, blocks: 4)
        let closes = edges().filter { !$0.squelchOpen }
        let close = try XCTUnwrap(closes.first, "silence must close the squelch")
        // Four loud blocks plus the silence it takes to close; the eight blocks before the restart
        // are not in there, and would double it if they were.
        XCTAssertLessThanOrEqual(close.openSamples, UInt64(8 * block),
                                 "the reported duration must not span the samples before the restart")
        XCTAssertGreaterThan(close.openSamples, 0)
    }

    /// Every transmission that ends bumps the close count. The sub-audible detector reads it to
    /// know the signal it has been measuring is over: a count rather than a flag, because that task
    /// polls at 20 Hz and a whole transmission can start and finish between two of its looks.
    func testSquelchCloseCountCountsTransmissions() throws {
        let rate: UInt64 = 240_000
        let queue = ChannelTelemetryQueue()
        let core = try ChannelDSPCore(captureRate: rate,
                                      config: ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40),
                                      telemetry: queue)
        let block = 4096
        let loud = DSPTest.storage(DSPTest.fmTone(carrierHz: 0, audioHz: 1000, deviationHz: 2500, rate: Double(rate), count: block))
        let quiet = DSPTest.storage([Float](repeating: 0, count: block * 2))
        let cap = CaptureID()
        var index: UInt64 = 0
        func feed(_ storage: SampleStorage, blocks: Int) {
            for _ in 0 ..< blocks {
                core.process(block: storage.view(count: block), at: SampleTime(captureID: cap, sampleIndex: index))
                index &+= UInt64(block)
            }
        }
        feed(loud, blocks: 8)
        XCTAssertEqual(core.squelchCloseCount, 0, "an open squelch has ended nothing")
        feed(quiet, blocks: 8)
        XCTAssertEqual(core.squelchCloseCount, 1, "silence ends the transmission")
        feed(loud, blocks: 8)
        XCTAssertEqual(core.squelchCloseCount, 1, "opening again ends nothing")
        feed(quiet, blocks: 8)
        XCTAssertEqual(core.squelchCloseCount, 2)
    }

    /// A stream restart across an open squelch is a close edge like any other: the fresh squelch
    /// starts closed, and without a record for the transition every watcher of the edge -- the
    /// transmission summary on the wire, the sub-audible detector's phase history -- would carry
    /// pre-gap state into the new stream.
    func testResetClosesAnOpenSquelch() throws {
        let rate: UInt64 = 240_000
        let queue = ChannelTelemetryQueue()
        let core = try ChannelDSPCore(captureRate: rate,
                                      config: ChannelConfig(offsetHz: 0, bandwidthHz: 12_500, mode: .nfm, squelchDB: -40),
                                      telemetry: queue)
        let block = 4096
        let loud = DSPTest.storage(DSPTest.fmTone(carrierHz: 0, audioHz: 1000, deviationHz: 2500, rate: Double(rate), count: block))
        let cap = CaptureID()
        var index: UInt64 = 0
        for _ in 0 ..< 8 {
            core.process(block: loud.view(count: block), at: SampleTime(captureID: cap, sampleIndex: index))
            index &+= UInt64(block)
        }
        var opens = 0
        while let r = queue.pop() { if r.kind == .squelch, r.squelchOpen { opens += 1 } }
        XCTAssertEqual(opens, 1, "the tone opens the squelch once")
        XCTAssertEqual(core.squelchCloseCount, 0)

        core.reset()
        XCTAssertEqual(core.squelchCloseCount, 1, "the restart ends the transmission in progress")
        var closes: [ChannelTelemetryRecord] = []
        while let r = queue.pop() { if r.kind == .squelch { closes.append(r) } }
        XCTAssertEqual(closes.count, 1, "one record for the close edge, none for anything else")
        let close = try XCTUnwrap(closes.first)
        XCTAssertFalse(close.squelchOpen)
        XCTAssertEqual(close.time.sampleIndex, index - UInt64(block), "stamped with the last block the channel saw")
        XCTAssertEqual(close.openSamples, UInt64(8 * block), "the summary covers the whole transmission")

        // A reset with the squelch already closed has no transmission to end.
        core.reset()
        XCTAssertEqual(core.squelchCloseCount, 1)
        XCTAssertNil(queue.pop())
    }

    func testStopLeavesNoEngineThreads() async throws {
        let path = try nfmTonePath()
        let device = try FilePlaybackDevice(path: path, loop: true, realtime: true)
        let capture = DefaultCaptureEngine(device: device, centerHz: UInt64(device.sidecar.centerHz), sampleRate: UInt64(device.sidecar.sampleRate))
        _ = try await capture.addChannel(ChannelConfig(offsetHz: 100_000, bandwidthHz: 12_500, mode: .nfm))
        try await capture.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(capture.core.isRunning)
        XCTAssertTrue(Self.engineThreadNames().contains { $0.hasPrefix("leyline.dsp") }, "DSP thread should be named leyline.dsp.<id>: \(Self.engineThreadNames())")
        await capture.stop()
        XCTAssertFalse(capture.core.isRunning)
        XCTAssertTrue(Self.engineThreadNames().isEmpty, "engine threads still alive: \(Self.engineThreadNames())")
        let channels = await capture.channels
        XCTAssertTrue(channels.isEmpty)
    }

    /// Names of live threads in this process that belong to the engine.
    /// Darwin: walk the task's threads with Mach and read each pthread name. Linux: /proc/self/task/*/comm.
    #if canImport(Darwin)
    static func engineThreadNames() -> [String] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            let bytes = vm_size_t(count) * vm_size_t(MemoryLayout<thread_act_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), bytes)
        }
        var names: [String] = []
        for i in 0..<Int(count) {
            let thread = list[i]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            // Typed as Optional explicitly so the guard compiles whether or not the SDK marks the
            // return value nullable.
            let pthreadOrNil: pthread_t? = pthread_from_mach_thread_np(thread)
            guard let pthread = pthreadOrNil else { continue }
            var buf = [CChar](repeating: 0, count: 128)
            guard pthread_getname_np(pthread, &buf, buf.count) == 0 else { continue }
            let name = String(cString: buf)
            if name.hasPrefix("leyline.") { names.append(name) }
        }
        return names
    }
    #else
    /// Names of live threads in this process that belong to the engine (Linux: /proc/self/task/*/comm).
    static func engineThreadNames() -> [String] {
        #if os(Linux)
        let tasks = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/task")) ?? []
        return tasks.compactMap { t in
            (try? String(contentsOfFile: "/proc/self/task/\(t)/comm", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.hasPrefix("leyline") }
        #else
        return []
        #endif
    }
    #endif
}
