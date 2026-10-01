// SPDX-License-Identifier: GPL-3.0-or-later

@testable import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineServer
import LeylineProto
import XCTest

final class DaemonTests: XCTestCase {
    /// `DaemonInfo.recordings_cap_bytes` is `--recordings-cap`, so a client shows the store's use
    /// against the cap the daemon enforces.
    func testGetStateCarriesTheRecordingsCap() async throws {
        try await withDaemon(recordingsCapBytes: 5 << 20) { c in
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.daemon.recordingsCapBytes, 5 << 20)
        }
    }

    func testGetStateEmptyWithDaemonInfo() async throws {
        try await withDaemon { c in
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(testDevices(state.devices).isEmpty)
            XCTAssertTrue(state.captures.isEmpty)
            XCTAssertTrue(state.channels.isEmpty)
            XCTAssertTrue(state.sinks.isEmpty)
            XCTAssertEqual(state.daemon.version, testDaemonVersion)
            XCTAssertEqual(state.daemon.pid, Int64(getpid()))
            XCTAssertEqual(state.daemon.socketPath, c.socketPath)
            XCTAssertGreaterThan(state.daemon.startedAtNs, 1_600_000_000_000_000_000)
            XCTAssertEqual(state.daemon.recordingsCapBytes, 20 << 30)  // the harness's default cap
            XCTAssertEqual(state.eventSeq, 0)

            // Scan jobs are implemented (D.13): an idle daemon has none, and that is not an error.
            let none = try await c.jobs.listJobs(Leyline_V1_ListJobsRequest(), metadata: testMetadata)
            XCTAssertTrue(none.jobs.isEmpty)
            XCTAssertTrue(state.jobs.isEmpty)

            // What the durable job store still owns is UNIMPLEMENTED, with the leyline trailer.
            do {
                _ = try await c.jobs.getTranscript(Leyline_V1_TranscriptRequest(), metadata: testMetadata)
                XCTFail("expected UNIMPLEMENTED")
            } catch {
                let (code, detail) = errorCode(error)
                XCTAssertEqual(code, "UNIMPLEMENTED")
                XCTAssertEqual(detail?.code, "UNIMPLEMENTED")
                XCTAssertEqual((error as? RPCError)?.code, .unimplemented)
            }
            // Resources is implemented (C.12). An idle daemon holds none, and an empty list is the
            // correct answer rather than an error.
            let resources = try await c.resources.listResources(Leyline_V1_ListResourcesRequest(), metadata: testMetadata)
            XCTAssertTrue(resources.resources.isEmpty)
        }
    }

    func testPipelineFromFixture() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture missing: \(fixture) (run leyfix generate)")
        }
        try await withDaemon { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)

            // AttachFileDevice -> device appears.
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            XCTAssertEqual(device.driver, "file")
            XCTAssertTrue(device.deviceID.hasPrefix("dev_"))
            XCTAssertEqual(device.sampleRates, [2_400_000])
            XCTAssertEqual(device.nativeFormat, .cf32)
            let listed = try await c.control.listDevices(Leyline_V1_ListDevicesRequest(), metadata: testMetadata)
            XCTAssertEqual(testDevices(listed.devices).map(\.deviceID), [device.deviceID])

            // CreateCapture with rate 0 -> file rate.
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertTrue(capture.captureID.hasPrefix("cap_"))
            XCTAssertEqual(capture.sampleRate, 2_400_000)
            XCTAssertEqual(capture.state, .captureActive)
            XCTAssertEqual(capture.createdBy.clientID, testClientID)
            XCTAssertEqual(capture.anchor.captureID, capture.captureID)
            XCTAssertEqual(capture.anchor.sampleRate, 2_400_000)
            // Second capture on the same device -> DEVICE_BUSY.
            do {
                _ = try await c.control.createCapture(cc, metadata: testMetadata)
                XCTFail("expected DEVICE_BUSY")
            } catch {
                XCTAssertEqual(errorCode(error).code, "DEVICE_BUSY")
                XCTAssertEqual(errorCode(error).trailer?.target, device.deviceID)
            }
            let capEvent = await events.waitFor { ev in
                if case .capture(let cap)? = ev.body { return cap.captureID == capture.captureID }
                return false
            }
            XCTAssertEqual(capEvent?.causedBy.clientID, testClientID, "capture event caused_by must be the metadata client id")
            XCTAssertEqual(capEvent?.causedBy.kind, "cli")
            let devEvent = await events.waitFor { ev in
                if case .device(let d)? = ev.body { return d.deviceID == device.deviceID && d.state == .inUse }
                return false
            }
            XCTAssertNotNil(devEvent, "device should be IN_USE once captured")

            // CreateChannel: bad offset rejected, good one active with mode-default bandwidth.
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 10_000_000
            cch.mode = .nfm
            do {
                _ = try await c.control.createChannel(cch, metadata: testMetadata)
                XCTFail("expected OFFSET_OUT_OF_CAPTURE")
            } catch {
                XCTAssertEqual(errorCode(error).code, "OFFSET_OUT_OF_CAPTURE")
            }
            cch.offsetHz = 100_000
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            XCTAssertTrue(channel.channelID.hasPrefix("chan_"))
            XCTAssertEqual(channel.bandwidthHz, 12_500)
            XCTAssertEqual(channel.state, .channelActive)
            XCTAssertTrue(channel.squelchDb.isNaN)
            XCTAssertEqual(channel.owner.clientID, testClientID)

            try await self.checkTelemetry(c, capture: capture, channel: channel)
            try await self.checkFFT(c, capture: capture)
            try await self.checkIQ(c, capture: capture)
            try await self.checkWrites(c, capture: capture, channel: channel, events: events)
            try await self.checkContractParity(c, capture: capture, channel: channel)

            // system_audio AttachSink -> PLATFORM_UNSUPPORTED on Linux. On macOS it succeeds when an
            // output device exists; a headless runner fails AVAudioEngine.start with DEVICE_IO, which is
            // the sink's correct error, not a contract failure.
            var sinkReq = Leyline_V1_AttachSinkRequest()
            sinkReq.channelID = channel.channelID
            sinkReq.sink.systemAudio = Leyline_V1_SystemAudioSink()
            do {
                _ = try await c.control.attachSink(sinkReq, metadata: testMetadata)
                #if !canImport(AVFoundation)
                XCTFail("expected PLATFORM_UNSUPPORTED")
                #endif
            } catch {
                #if canImport(AVFoundation)
                let code = errorCode(error).code
                XCTAssertTrue(["DEVICE_IO", "INVALID_ARGUMENT"].contains(code), "unexpected system_audio error \(code)")
                XCTAssertEqual(errorCode(error).trailer?.code, code)
                #else
                XCTAssertEqual(errorCode(error).code, "PLATFORM_UNSUPPORTED")
                XCTAssertEqual(errorCode(error).trailer?.code, "PLATFORM_UNSUPPORTED")
                #endif
            }

            // DestroyChannel -> terminal event, gone from state.
            var dc = Leyline_V1_DestroyChannelRequest()
            dc.channelID = channel.channelID
            _ = try await c.control.destroyChannel(dc, metadata: testMetadata)
            let gone = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.state == .unspecified }
                return false
            }
            XCTAssertNotNil(gone, "terminal channel event")
            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.channels.isEmpty)
            XCTAssertEqual(state.captures.count, 1)
            do {
                _ = try await c.control.destroyChannel(dc, metadata: testMetadata)
                XCTFail("expected CHANNEL_NOT_FOUND")
            } catch {
                XCTAssertEqual(errorCode(error).code, "CHANNEL_NOT_FOUND")
            }

            // Sequence numbers are strictly increasing and the snapshot seq matches the last event.
            let seqs = await events.events.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted())
            XCTAssertEqual(Set(seqs).count, seqs.count)
            XCTAssertEqual(state.eventSeq, seqs.last)

            var dcap = Leyline_V1_DestroyCaptureRequest()
            dcap.captureID = capture.captureID
            _ = try await c.control.destroyCapture(dcap, metadata: testMetadata)
            // State unset, not CAPTURE_DETACHED: a client has to be able to tell a destroyed
            // capture from one whose dongle was unplugged and will rebind.
            let capGone = await events.waitFor { ev in
                if case .capture(let cap)? = ev.body { return cap.captureID == capture.captureID && cap.state == .unspecified }
                return false
            }
            XCTAssertNotNil(capGone, "terminal capture event")
            let lookedLikeLoss = await events.events.contains { ev in
                if case .capture(let cap)? = ev.body { return cap.captureID == capture.captureID && cap.state == .captureDetached }
                return false
            }
            XCTAssertFalse(lookedLikeLoss, "destroy never looks like device loss")
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.captures.isEmpty)
            XCTAssertEqual(testDevices(state.devices).first?.state, .available)
            await events.stop()
        }
    }

    /// Meters arrive on the sample timebase of the capture.
    private func checkTelemetry(_ c: DaemonClients, capture: Leyline_V1_Capture, channel: Leyline_V1_Channel) async throws {
        var sub = Leyline_V1_TelemetrySubscription()
        sub.channelID = channel.channelID
        sub.types = [.meter]
        let meters: [Leyline_V1_TelemetryMsg] = try await c.telemetry.subscribe(sub, metadata: testMetadata) { response in
            var out: [Leyline_V1_TelemetryMsg] = []
            for try await m in response.messages {
                out.append(m)
                if out.count >= 3 { break }
            }
            return out
        }
        XCTAssertEqual(meters.count, 3)
        for (i, m) in meters.enumerated() {
            XCTAssertEqual(m.seq, UInt64(i + 1))
            XCTAssertEqual(m.time.captureID, capture.captureID)
            XCTAssertEqual(m.meter.channelID, channel.channelID)
            XCTAssertTrue(m.meter.squelchOpen, "squelch off -> open")
        }
        XCTAssertGreaterThan(meters[2].time.sampleIndex, meters[0].time.sampleIndex)
        // The tone is at -20 dBFS; the strongest reading should be well above the floor.
        XCTAssertGreaterThan(meters.map(\.meter.powerDbfs).max()!, -40)
    }

    /// Bulk FFT: negotiated bins, DB_F32 payloads of bins*4 bytes, sample-timed frames.
    private func checkFFT(_ c: DaemonClients, capture: Leyline_V1_Capture) async throws {
        var req = Leyline_V1_SubscribeRequest()
        req.captureID = capture.captureID
        req.kind = .fft
        req.policy = .gapMarked
        req.transport = .shmRing
        req.fft.bins = 500
        req.fft.rowsPerSecond = 10
        req.fft.binFormat = .dbF32
        let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
        XCTAssertTrue(desc.streamID.hasPrefix("strm_"))
        XCTAssertEqual(desc.kind, .fft)
        XCTAssertEqual(desc.policy, .gapMarked)
        XCTAssertEqual(desc.transport, .grpc(true), "SHM_RING must downgrade to grpc in v0")
        XCTAssertEqual(desc.fft.bins, 512)
        XCTAssertEqual(desc.fft.rowsPerSecond, 10)
        XCTAssertEqual(desc.centerHz, 146_520_000)
        XCTAssertEqual(desc.spanHz, 2_400_000)
        var ref = Leyline_V1_StreamRef()
        ref.streamID = desc.streamID
        let frames: [Leyline_V1_Frame] = try await c.bulk.stream(ref, metadata: testMetadata) { response in
            var out: [Leyline_V1_Frame] = []
            for try await f in response.messages {
                out.append(f)
                if out.count >= 3 { break }
            }
            return out
        }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.seq), [1, 2, 3])
        for f in frames {
            XCTAssertEqual(f.streamID, desc.streamID)
            XCTAssertEqual(f.time.captureID, capture.captureID)
            XCTAssertEqual(f.payload.count, 512 * 4)
        }
        let row = frames[2].payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Tone at +100 kHz of a 2.4 MHz span: bin 256 + 100e3/2.4e6*512 ≈ 277 is the peak.
        let peak = row.indices.max { row[$0] < row[$1] }!
        XCTAssertEqual(peak, 277, accuracy: 2)
        XCTAssertGreaterThan(row[peak] - row[100], 20, "tone should stand well above the noise floor")
        _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        do {
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
            XCTFail("expected STREAM_NOT_FOUND")
        } catch {
            XCTAssertEqual(errorCode(error).code, "STREAM_NOT_FOUND")
        }
        // Non-live start is UNIMPLEMENTED.
        req.start.atHostTimeNs = 1
        do {
            _ = try await c.bulk.subscribe(req, metadata: testMetadata)
            XCTFail("expected UNIMPLEMENTED")
        } catch {
            XCTAssertEqual(errorCode(error).code, "UNIMPLEMENTED")
        }
    }

    /// Bulk IQ (v0 contract): default params answer CF32 at the capture rate; payloads are whole
    /// cf32 sample blocks (8 bytes each) that tile the sample timeline; CS16 or a foreign rate is
    /// refused with INVALID_ARGUMENT instead of being overridden.
    private func checkIQ(_ c: DaemonClients, capture: Leyline_V1_Capture) async throws {
        var req = Leyline_V1_SubscribeRequest()
        req.captureID = capture.captureID
        req.kind = .iq
        req.policy = .gapMarked
        req.transport = .grpc
        let desc = try await c.bulk.subscribe(req, metadata: testMetadata)
        XCTAssertTrue(desc.streamID.hasPrefix("strm_"))
        XCTAssertEqual(desc.kind, .iq)
        XCTAssertEqual(desc.policy, .gapMarked)
        XCTAssertEqual(desc.transport, .grpc(true))
        XCTAssertEqual(desc.iq.format, .cf32)
        XCTAssertEqual(desc.iq.sampleRate, capture.sampleRate)
        XCTAssertEqual(desc.centerHz, capture.centerHz)
        XCTAssertEqual(desc.spanHz, capture.sampleRate)
        var ref = Leyline_V1_StreamRef()
        ref.streamID = desc.streamID
        let frames: [Leyline_V1_Frame] = try await c.bulk.stream(ref, metadata: testMetadata) { response in
            var out: [Leyline_V1_Frame] = []
            for try await f in response.messages {
                out.append(f)
                if out.count >= 3 { break }
            }
            return out
        }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.seq), [1, 2, 3])
        for f in frames {
            XCTAssertEqual(f.streamID, desc.streamID)
            XCTAssertEqual(f.time.captureID, capture.captureID)
            XCTAssertGreaterThan(f.payload.count, 0)
            XCTAssertEqual(f.payload.count % 8, 0, "cf32 payloads are whole 8-byte samples")
        }
        // Consecutive frames tile the timeline: the sample span of frame N is exactly its cf32 block.
        for (a, b) in zip(frames, frames.dropFirst()) where !b.hasGap {
            let spanned = Int(b.time.sampleIndex - a.time.sampleIndex)
            XCTAssertEqual(a.payload.count, spanned * 8)
        }
        // The -20 dBFS tone is visible as non-trivial magnitude in the raw samples.
        let iq = frames[2].payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let peakMag = stride(from: 0, to: iq.count, by: 2).map { hypot(iq[$0], iq[$0 + 1]) }.max()!
        XCTAssertGreaterThan(peakMag, 0.01)
        XCTAssertLessThanOrEqual(peakMag, 1.5)
        _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
        do {
            _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
            XCTFail("expected STREAM_NOT_FOUND")
        } catch {
            XCTAssertEqual(errorCode(error).code, "STREAM_NOT_FOUND")
        }
        do {
            _ = try await c.bulk.stream(ref, metadata: testMetadata) { response in
                for try await _ in response.messages {}
            }
            XCTFail("expected STREAM_NOT_FOUND")
        } catch {
            XCTAssertEqual(errorCode(error).code, "STREAM_NOT_FOUND")
        }
        // Integer formats and foreign rates are refused, never silently overridden.
        var badFormat = req
        badFormat.iq.format = .cs16
        do {
            _ = try await c.bulk.subscribe(badFormat, metadata: testMetadata)
            XCTFail("expected INVALID_ARGUMENT for CS16")
        } catch {
            XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
        }
        var badRate = req
        badRate.iq.sampleRate = capture.sampleRate / 2
        do {
            _ = try await c.bulk.subscribe(badRate, metadata: testMetadata)
            XCTFail("expected INVALID_ARGUMENT for a foreign sample rate")
        } catch {
            XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
        }
        // Explicit CF32 at the capture rate is accepted verbatim.
        var explicit = req
        explicit.iq.format = .cf32
        explicit.iq.sampleRate = capture.sampleRate
        let desc2 = try await c.bulk.subscribe(explicit, metadata: testMetadata)
        XCTAssertEqual(desc2.iq.format, .cf32)
        XCTAssertEqual(desc2.iq.sampleRate, capture.sampleRate)
        ref.streamID = desc2.streamID
        _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
    }

    /// Rules the Go reference daemon also enforces: unknown capture scope fails, UNSPECIFIED mode
    /// defaults to NFM, a foreign audio rate is refused, one Stream reader per subscription.
    private func checkContractParity(_ c: DaemonClients, capture: Leyline_V1_Capture, channel: Leyline_V1_Channel) async throws {
        var bad = Leyline_V1_GetStateRequest()
        bad.scope.captureID = "cap_typo"
        do {
            _ = try await c.control.getState(bad, metadata: testMetadata)
            XCTFail("expected CAPTURE_NOT_FOUND")
        } catch {
            XCTAssertEqual(errorCode(error).code, "CAPTURE_NOT_FOUND")
        }
        var badScope = Leyline_V1_EventScope()
        badScope.captureID = "cap_01ARZ3NDEKTSV4RRFFQ69G5FAV"
        do {
            try await c.control.watchEvents(badScope, metadata: testMetadata) { response in
                for try await _ in response.messages { break }
            }
            XCTFail("expected CAPTURE_NOT_FOUND")
        } catch {
            XCTAssertEqual(errorCode(error).code, "CAPTURE_NOT_FOUND")
        }
        var scoped = Leyline_V1_GetStateRequest()
        scoped.scope.captureID = capture.captureID
        let snap = try await c.control.getState(scoped, metadata: testMetadata)
        XCTAssertEqual(snap.captures.map(\.captureID), [capture.captureID])

        var cch = Leyline_V1_CreateChannelRequest()
        cch.captureID = capture.captureID
        cch.offsetHz = -200_000
        cch.mode = .unspecified
        let defaulted = try await c.control.createChannel(cch, metadata: testMetadata)
        XCTAssertEqual(defaulted.mode, .nfm, "UNSPECIFIED mode defaults to NFM (Go parity)")
        var dc = Leyline_V1_DestroyChannelRequest()
        dc.channelID = defaulted.channelID
        _ = try await c.control.destroyChannel(dc, metadata: testMetadata)

        var audio = Leyline_V1_SubscribeRequest()
        audio.channelID = channel.channelID
        audio.kind = .audio
        audio.audio.sampleRate = 16_000
        do {
            _ = try await c.bulk.subscribe(audio, metadata: testMetadata)
            XCTFail("expected INVALID_ARGUMENT")
        } catch {
            XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
        }
        audio.audio.sampleRate = 0
        let desc = try await c.bulk.subscribe(audio, metadata: testMetadata)
        XCTAssertGreaterThan(desc.audio.sampleRate, 0)
        var ref = Leyline_V1_StreamRef()
        ref.streamID = desc.streamID
        let firstReader = Task {
            try await c.bulk.stream(ref, metadata: testMetadata) { response in
                for try await _ in response.messages {}
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            try await c.bulk.stream(ref, metadata: testMetadata) { response in
                for try await _ in response.messages { break }
            }
            XCTFail("expected FAILED_PRECONDITION for a second reader")
        } catch {
            XCTAssertEqual(errorCode(error).code, "FAILED_PRECONDITION")
        }
        firstReader.cancel()
        _ = try? await firstReader.value
        _ = try await c.bulk.unsubscribe(ref, metadata: testMetadata)
    }

    /// WriteParams: squelch applied (channel event), bad offset -> WriteRejected with the tag.
    private func checkWrites(_ c: DaemonClients, capture: Leyline_V1_Capture, channel: Leyline_V1_Channel, events: EventCollector) async throws {
        let summary = try await c.control.writeParams(metadata: testMetadata) { writer in
            var w = Leyline_V1_ParamWrite()
            w.tag = 7
            w.targetID = channel.channelID
            w.squelchDb = -40
            try await writer.write(w)
            var bad = Leyline_V1_ParamWrite()
            bad.tag = 8
            bad.targetID = channel.channelID
            bad.offsetHz = 10_000_000
            try await writer.write(bad)
            var squelchAgain = Leyline_V1_ParamWrite()
            squelchAgain.tag = 9
            squelchAgain.targetID = channel.channelID
            squelchAgain.squelchDb = -50
            try await writer.write(squelchAgain)
        }
        XCTAssertEqual(summary.writesReceived, 3)
        XCTAssertLessThanOrEqual(summary.writesApplied, 2, "coalesced: last squelch wins, offset rejected")
        XCTAssertGreaterThanOrEqual(summary.writesApplied, 1)
        let rejected = await events.waitFor { ev in
            if case .writeRejected(let wr)? = ev.body { return wr.tag == 8 }
            return false
        }
        XCTAssertEqual(rejected?.writeRejected.error.code, "OFFSET_OUT_OF_CAPTURE")
        XCTAssertEqual(rejected?.writeRejected.error.target, channel.channelID)
        XCTAssertEqual(rejected?.causedBy.clientID, testClientID)
        let updated = await events.waitFor { ev in
            if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.squelchDb == -50 }
            return false
        }
        XCTAssertNotNil(updated, "channel event with the applied squelch")
        XCTAssertEqual(updated?.channel.offsetHz, 100_000, "rejected offset must not apply")
        let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
        XCTAssertEqual(state.channels.first?.squelchDb, -50)
        XCTAssertGreaterThan(state.captures.first?.activity.lastInteractiveWriteNs ?? 0, 0, "cli writes are interactive")

        // A long-lived stream (tuning-knob pattern) must see its writes applied on the 20 ms tick,
        // not only when the client half-closes.
        let openSummary = try await c.control.writeParams(metadata: testMetadata) { writer in
            var w = Leyline_V1_ParamWrite()
            w.tag = 10
            w.targetID = channel.channelID
            w.squelchDb = -60
            try await writer.write(w)
            let applied = await events.waitFor(timeoutMs: 500) { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.squelchDb == -60 }
                return false
            }
            XCTAssertNotNil(applied, "write must apply while the WriteParams stream is still open")
            var bad = Leyline_V1_ParamWrite()
            bad.tag = 11
            bad.targetID = channel.channelID
            bad.offsetHz = 10_000_000
            try await writer.write(bad)
            let rejected = await events.waitFor(timeoutMs: 500) { ev in
                if case .writeRejected(let wr)? = ev.body { return wr.tag == 11 }
                return false
            }
            XCTAssertNotNil(rejected, "rejection must be reported while the stream is still open")
        }
        XCTAssertEqual(openSummary.writesReceived, 2)
        XCTAssertEqual(openSummary.writesApplied, 1)
    }
}
