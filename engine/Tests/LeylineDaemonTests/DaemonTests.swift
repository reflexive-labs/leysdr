@testable import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineDaemon
import LeylineProto
import XCTest

final class DaemonTests: XCTestCase {
    func testGetStateEmptyWithDaemonInfo() async throws {
        try await withDaemon { c in
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(testDevices(state.devices).isEmpty)
            XCTAssertTrue(state.captures.isEmpty)
            XCTAssertTrue(state.channels.isEmpty)
            XCTAssertTrue(state.sinks.isEmpty)
            XCTAssertEqual(state.daemon.version, "0.1.0-dev")
            XCTAssertEqual(state.daemon.pid, Int64(getpid()))
            XCTAssertEqual(state.daemon.socketPath, c.socketPath)
            XCTAssertGreaterThan(state.daemon.startedAtNs, 1_600_000_000_000_000_000)
            XCTAssertEqual(state.eventSeq, 0)

            // Scan jobs are implemented (D.13): an idle daemon has none, and that is not an error.
            let none = try await c.jobs.listJobs(Leyline_V1_ListJobsRequest(), metadata: testMetadata)
            XCTAssertTrue(none.jobs.isEmpty)
            XCTAssertTrue(state.jobs.isEmpty)

            // Everything the durable job store owns is still UNIMPLEMENTED, with the leyline trailer.
            do {
                _ = try await c.jobs.getTranscript(Leyline_V1_TranscriptRequest(), metadata: testMetadata)
                XCTFail("expected UNIMPLEMENTED")
            } catch {
                let (code, detail) = errorCode(error)
                XCTAssertEqual(code, "UNIMPLEMENTED")
                XCTAssertEqual(detail?.code, "UNIMPLEMENTED")
                XCTAssertEqual((error as? RPCError)?.code, .unimplemented)
            }
            do {
                _ = try await c.resources.listResources(Leyline_V1_ListResourcesRequest(), metadata: testMetadata)
                XCTFail("expected UNIMPLEMENTED")
            } catch {
                XCTAssertEqual((error as? RPCError)?.code, .unimplemented)
            }
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
            // the sink's honest answer, not a contract failure.
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

    func testPresenceReapsNonPersistentChannels() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing") }
        try await withDaemon(presenceGraceNs: 300_000_000) { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let ephemeral = try await c.control.createChannel(cch, metadata: testMetadata)
            cch.persistent = true
            let persistent = try await c.control.createChannel(cch, metadata: testMetadata)
            // A second client's channel must not be touched.
            let other: Metadata = ["leyline-client-id": .string("cli_OTHER"), "leyline-client-kind": .string("app")]
            let otherEvents = Task {
                var scope = Leyline_V1_EventScope()
                scope.daemon = true
                try? await c.control.watchEvents(scope, metadata: other) { r in for try await _ in r.messages {} }
            }
            cch.persistent = false
            let held = try await c.control.createChannel(cch, metadata: other)

            var state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: other)
            XCTAssertEqual(state.channels.count, 3)
            // Only unary calls from our client: present for 300 ms, then reaped.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: other)
            let ids = Set(state.channels.map(\.channelID))
            XCTAssertFalse(ids.contains(ephemeral.channelID), "ephemeral channel of the absent client is reaped")
            XCTAssertTrue(ids.contains(persistent.channelID), "persistent channel survives")
            XCTAssertTrue(ids.contains(held.channelID), "channel held open by WatchEvents survives")
            otherEvents.cancel()
        }
    }

    /// A drain that falls behind the telemetry ring loses the oldest readings; the subscriber sees every
    /// eviction as a `seq` gap instead of a silently contiguous stream.
    func testTelemetrySeqGapsAfterQueueOverflow() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing: \(fixture)") }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let anyEngine = await c.daemon.store.channelEngine(ChannelID(string: channel.channelID)!)
            let engine = try XCTUnwrap(anyEngine as? DefaultChannelEngine)
            let queue = engine.telemetryQueue
            let capID = CaptureID(string: capture.captureID)!
            func squelchRecord(_ index: UInt64) -> ChannelTelemetryRecord {
                ChannelTelemetryRecord(kind: .squelch, time: SampleTime(captureID: capID, sampleIndex: index), powerDBFS: 0, snrDB: 0, squelchOpen: true)
            }

            // Squelch is off, so every squelch transition this subscription receives is one the test pushed
            // (tagged by sample index). Meters stay subscribed so the live channel keeps the RPC flowing.
            // The DSP thread's own 10 Hz meter pushes overlap the microsecond burst only by coincidence.
            var sub = Leyline_V1_TelemetrySubscription()
            sub.channelID = channel.channelID
            let burst = UInt64(queue.capacity * 8)
            let lastIndex = burst + 1
            let collector = TelemetryCollector()
            // Leave only once a meter follows the last pushed record, so the server has no backlog in
            // flight when the client goes away (an in-flight write can otherwise outlive the RPC).
            let rpc = Task {
                try await c.telemetry.subscribe(sub, metadata: testMetadata) { response in
                    var sawLast = false
                    for try await m in response.messages {
                        await collector.append(m)
                        if case .squelch? = m.body, m.time.sampleIndex == lastIndex { sawLast = true }
                        else if sawLast, case .meter? = m.body { break }
                    }
                }
            }
            func pushed(_ all: [Leyline_V1_TelemetryMsg]) -> [Leyline_V1_TelemetryMsg] {
                all.filter { if case .squelch? = $0.body { return true } else { return false } }
            }
            // Probe until the server-side drain is attached (index 1 may arrive more than once).
            let deadline = Date().addingTimeInterval(10)
            while await pushed(collector.messages).isEmpty, Date() < deadline {
                queue.push(squelchRecord(1))
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let probed = await pushed(collector.messages).count
            XCTAssertGreaterThan(probed, 0, "subscription never delivered the probe")
            // Push the burst faster than the drain task can pop: the ring overflows and evicts oldest-first.
            for i in 2...lastIndex { queue.push(squelchRecord(i)) }
            while await pushed(collector.messages).last?.time.sampleIndex != lastIndex, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let watchdog = Task { try await Task.sleep(nanoseconds: 5_000_000_000); rpc.cancel() }
            _ = try? await rpc.value
            watchdog.cancel()

            let all = await collector.messages
            let msgs = pushed(all).filter { $0.time.sampleIndex >= 2 }
            XCTAssertEqual(msgs.last?.time.sampleIndex, lastIndex, "the newest record always survives an overflow")
            XCTAssertLessThan(UInt64(msgs.count), burst, "the burst must overflow the ring (\(queue.capacity) slots)")
            XCTAssertGreaterThan(engine.telemetryDropped, 0)
            let seqs = all.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "seq must be monotonic")
            XCTAssertEqual(Set(seqs).count, seqs.count, "seq must be unique")
            let jumps = zip(seqs, seqs.dropFirst()).map { $1 - $0 }
            XCTAssertGreaterThan(jumps.max() ?? 0, 1, "evictions must show up as a seq gap")
            // Every pushed record was either delivered (+1) or evicted (+1): seq runs ahead of the delivered count.
            if let last = msgs.last, let position = all.firstIndex(where: { $0.seq == last.seq }) {
                XCTAssertGreaterThan(last.seq, UInt64(position + 1), "seq advances past the delivered count by the evictions")
            }
        }
    }

    /// The same accounting when the *reader* stalls instead of the ring: the service's `write` is held,
    /// the merged buffer (and the fan-out buffer behind it) overflow and discard their oldest items, and
    /// every record lost downstream of the ring still widens `seq`: it advances by exactly the number of
    /// records pushed, whether they were delivered or lost in any of the three buffers.
    func testTelemetrySeqGapsAfterReaderStall() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("fixture missing: \(fixture)") }
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            let anyEngine = await c.daemon.store.channelEngine(ChannelID(string: channel.channelID)!)
            let engine = try XCTUnwrap(anyEngine as? DefaultChannelEngine)
            let queue = engine.telemetryQueue
            let capID = CaptureID(string: capture.captureID)!
            func squelchRecord(_ index: UInt64) -> ChannelTelemetryRecord {
                ChannelTelemetryRecord(kind: .squelch, time: SampleTime(captureID: capID, sampleIndex: index), powerDBFS: 0, snrDB: 0, squelchOpen: true)
            }

            // Squelch transitions only: every message this subscription delivers is one the test pushed,
            // and the DSP thread's 10 Hz meters are filtered out by the drain (they can only reach `seq`
            // by being lost upstream of it, which a stalled writer alone never causes).
            var sub = Leyline_V1_TelemetrySubscription()
            sub.channelID = channel.channelID
            sub.types = [.squelchTransition]
            let collector = TelemetryCollector()
            let gate = TestGate()
            let writer = RPCWriter(wrapping: StallingTelemetryWriter(collector: collector, gate: gate))
            let service = TelemetryService(store: c.daemon.store, jobs: c.daemon.jobs)
            let descriptor = MethodDescriptor(fullyQualifiedService: "leyline.v1.Telemetry", method: "Subscribe")
            let cancellation = LockedValue<ServerContext.RPCCancellationHandle?>(nil)
            // Drive the service directly with a writer we can hold, so the stall is deterministic.
            let rpc = Task {
                try await withServerContextRPCCancellationHandle { handle in
                    cancellation.value = handle
                    let context = ServerContext(descriptor: descriptor, remotePeer: "test", localPeer: "test", cancellation: handle)
                    try await ClientContext.$current.withValue(ClientContext(id: "stall-test", kind: "test", label: "stall")) {
                        try await service.subscribe(request: sub, response: writer, context: context)
                    }
                }
            }
            // Probe until the server-side drain is attached (index 1 may arrive more than once).
            let deadline = Date().addingTimeInterval(10)
            while await collector.messages.isEmpty, Date() < deadline {
                queue.push(squelchRecord(1))
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let probeDelivered = await !collector.messages.isEmpty
            XCTAssertTrue(probeDelivered, "subscription never delivered the probe")
            // Let any in-flight probe land before the writer stalls: every index-1 record then counts as delivered.
            try await Task.sleep(nanoseconds: 100_000_000)
            let probes = await collector.messages.count
            let windowStart = Date()
            await gate.close()
            let evictedBefore = engine.telemetryDropped
            // Burst in rounds the ring can absorb, so most records survive the ring and pile into the
            // fan-out and merged buffers, which (with `write` held) discard all but their newest.
            let rounds = 8
            let burst = rounds * queue.capacity
            let lastIndex = UInt64(burst) + 1
            var next: UInt64 = 2
            for _ in 0..<rounds {
                for _ in 0..<queue.capacity { queue.push(squelchRecord(next)); next += 1 }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(next, lastIndex + 1)
            // Let the drains settle into the full merged buffer; nothing gets through the held writer.
            try await Task.sleep(nanoseconds: 200_000_000)
            let heldCount = await collector.messages.count
            XCTAssertEqual(heldCount, probes, "nothing is delivered while the writer is held")
            await gate.open()
            while await collector.messages.last?.time.sampleIndex != lastIndex, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let windowSeconds = Date().timeIntervalSince(windowStart)
            cancellation.value?.cancel()
            let watchdog = Task { try await Task.sleep(nanoseconds: 5_000_000_000); rpc.cancel() }
            _ = try? await rpc.value
            watchdog.cancel()

            let all = await collector.messages
            XCTAssertTrue(all.allSatisfy { if case .squelch? = $0.body { return true } else { return false } }, "meters are filtered out")
            let delivered = all.filter { $0.time.sampleIndex >= 2 }
            XCTAssertEqual(delivered.last?.time.sampleIndex, lastIndex, "the newest record survives every drop-oldest buffer")
            XCTAssertLessThan(delivered.count, burst, "the stall must lose records")
            let evicted = engine.telemetryDropped - evictedBefore
            let lostDownstream = burst - evicted - delivered.count
            XCTAssertGreaterThan(lostDownstream, 0, "the stall must lose records in the fan-out/merged buffers, not only the ring")
            let seqs = all.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "seq must be monotonic")
            XCTAssertEqual(Set(seqs).count, seqs.count, "seq must be unique")
            // Every record pushed after the first delivered message was delivered (+1) or lost (+1 via a gap),
            // wherever it was lost. Meters pushed inside the window are filtered, so they add to `seq` only
            // if the ring or the fan-out evicted one — at 10 Hz that bounds the slack.
            let first = try XCTUnwrap(all.first)
            let last = try XCTUnwrap(delivered.last)
            let extraProbes = UInt64(all.filter { $0.time.sampleIndex == 1 }.count - 1)
            let expected = extraProbes + UInt64(burst)
            let advance = last.seq - first.seq
            let meterSlack = UInt64(windowSeconds * 10) + 2
            XCTAssertGreaterThanOrEqual(advance, expected, "seq must account for every lost record (\(lostDownstream) lost past the ring)")
            XCTAssertLessThanOrEqual(advance, expected + meterSlack, "seq must not count more than was pushed")
        }
    }

    /// `SystemAudioSink.volume` is proto3-optional: absent means 1.0, an explicit 0 means muted, and
    /// anything outside 0..1 is INVALID_ARGUMENT. The range check runs before the platform sink is
    /// built, so on hosts without AVFoundation the two valid shapes reach PLATFORM_UNSUPPORTED (proof
    /// they passed validation) while 1.5 is refused everywhere.
    func testAttachSinkVolumePresence() async throws {
        let fixture = fixturePath("nfm_tone.cf32")
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture missing: \(fixture) (run leyfix generate)")
        }
        try await withDaemon { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixture
            attach.loop = true
            let device = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = device.deviceID
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)

            func attachSink(_ sa: Leyline_V1_SystemAudioSink) async throws -> Leyline_V1_Sink {
                var req = Leyline_V1_AttachSinkRequest()
                req.channelID = channel.channelID
                req.sink.systemAudio = sa
                return try await c.control.attachSink(req, metadata: testMetadata)
            }
            /// Attaches and, where the host can build a system-audio sink, asserts the volume the
            /// daemon settled on in both the reply and the Sink event.
            func expectVolume(_ sa: Leyline_V1_SystemAudioSink, _ expected: Double, _ label: String) async throws {
                do {
                    let sink = try await attachSink(sa)
                    XCTAssertTrue(sink.systemAudio.hasVolume, "\(label): reply must carry volume presence")
                    XCTAssertEqual(sink.systemAudio.volume, expected, "\(label): reply volume")
                    let ev = await events.waitFor { ev in
                        if case .sink(let s)? = ev.body { return s.sinkID == sink.sinkID }
                        return false
                    }
                    XCTAssertNotNil(ev, "\(label): Sink event")
                    XCTAssertEqual(ev?.sink.systemAudio.hasVolume, true, "\(label): event presence")
                    XCTAssertEqual(ev?.sink.systemAudio.volume, expected, "\(label): event volume")
                } catch {
                    let code = errorCode(error).code
                    #if canImport(AVFoundation)
                    XCTAssertEqual(code, "DEVICE_IO", "\(label): headless runner may fail AVAudioEngine.start; got \(code)")
                    #else
                    XCTAssertEqual(code, "PLATFORM_UNSUPPORTED", "\(label): got \(code)")
                    #endif
                }
            }

            // Absent -> 1.0.
            try await expectVolume(Leyline_V1_SystemAudioSink(), 1.0, "absent volume")
            // Explicit 0 -> muted, not "unset".
            var muted = Leyline_V1_SystemAudioSink()
            muted.volume = 0
            try await expectVolume(muted, 0, "explicit zero")
            // Out of range -> INVALID_ARGUMENT before any platform sink is built.
            var loud = Leyline_V1_SystemAudioSink()
            loud.volume = 1.5
            do {
                _ = try await attachSink(loud)
                XCTFail("expected INVALID_ARGUMENT for volume 1.5")
            } catch {
                XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
                XCTAssertEqual(errorCode(error).trailer?.code, "INVALID_ARGUMENT")
            }
            await events.stop()
        }
    }

    /// FU-2: WriteParams on an OUT_OF_CAPTURE channel. `bandwidth_hz` and `mode` are stored (the
    /// Channel event carries the new values with state OUT_OF_CAPTURE, no WriteRejected), and the
    /// channel comes back ACTIVE with them once `center_hz` moves the capture back over it.
    func testStructuralWritesOnOutOfCaptureChannelAreStored() async throws {
        try await withDaemon { c in
            let device = RebindableDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(device)
            for _ in 0..<150 {
                let s = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                if s.devices.contains(where: { $0.deviceID == d.id.string }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let events = await EventCollector.start(c.control, daemon: c.daemon)

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 100_000_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.sampleRate, 2_400_000)
            var cch = Leyline_V1_CreateChannelRequest()
            cch.captureID = capture.captureID
            cch.offsetHz = 100_000
            cch.mode = .nfm
            let channel = try await c.control.createChannel(cch, metadata: testMetadata)
            XCTAssertEqual(channel.state, .channelActive)
            XCTAssertEqual(channel.bandwidthHz, 12_500)

            func write(tag: UInt64, target: String, _ fill: (inout Leyline_V1_ParamWrite) -> Void) async throws {
                var w = Leyline_V1_ParamWrite()
                w.tag = tag
                w.targetID = target
                fill(&w)
                let message = w
                let summary = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(message) }
                XCTAssertEqual(summary.writesApplied, 1, "write tag \(tag) applied")
            }

            // Retune 1.5 MHz away: the channel (100.1 MHz) no longer fits ±1.2 MHz.
            try await write(tag: 1, target: capture.captureID) { $0.centerHz = 101_500_000 }
            let out = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.state == .outOfCapture }
                return false
            }
            XCTAssertNotNil(out, "channel event OUT_OF_CAPTURE after the retune")
            XCTAssertEqual(out?.channel.offsetHz, -1_400_000, "offset follows the absolute frequency")

            // Bandwidth then mode while out: both stored, no WriteRejected, state stays OUT_OF_CAPTURE.
            try await write(tag: 2, target: channel.channelID) { $0.bandwidthHz = 8_000 }
            let bw = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.bandwidthHz == 8_000 }
                return false
            }
            XCTAssertNotNil(bw, "channel event with the stored bandwidth")
            XCTAssertEqual(bw?.channel.state, .outOfCapture)
            XCTAssertEqual(bw?.channel.offsetHz, -1_400_000)
            try await write(tag: 3, target: channel.channelID) { $0.mode = .am }
            let mode = await events.waitFor { ev in
                if case .channel(let ch)? = ev.body { return ch.channelID == channel.channelID && ch.mode == .am }
                return false
            }
            XCTAssertNotNil(mode, "channel event with the stored mode")
            XCTAssertEqual(mode?.channel.state, .outOfCapture)
            XCTAssertEqual(mode?.channel.bandwidthHz, 8_000)
            let rejected = await events.events.contains { ev in
                if case .writeRejected? = ev.body { return true }
                return false
            }
            XCTAssertFalse(rejected, "no write was rejected")

            // An offset write while out is still checked against the capture.
            var bad = Leyline_V1_ParamWrite()
            bad.tag = 4
            bad.targetID = channel.channelID
            bad.offsetHz = -2_000_000
            let badMessage = bad
            _ = try await c.control.writeParams(metadata: testMetadata) { writer in try await writer.write(badMessage) }
            let wr = await events.waitFor { ev in
                if case .writeRejected(let r)? = ev.body { return r.tag == 4 }
                return false
            }
            XCTAssertEqual(wr?.writeRejected.error.code, "OFFSET_OUT_OF_CAPTURE")

            // Move the capture back: ACTIVE with the stored bandwidth and mode at 100.1 MHz.
            try await write(tag: 5, target: capture.captureID) { $0.centerHz = 100_000_000 }
            let back = await events.waitFor { ev in
                // The create event was also CHANNEL_ACTIVE at +100 kHz; the one after the retune carries the stored bandwidth.
                if case .channel(let ch)? = ev.body {
                    return ch.channelID == channel.channelID && ch.state == .channelActive && ch.offsetHz == 100_000 && ch.bandwidthHz == 8_000
                }
                return false
            }
            XCTAssertNotNil(back, "channel event CHANNEL_ACTIVE after the capture moves back")
            XCTAssertEqual(back?.channel.bandwidthHz, 8_000)
            XCTAssertEqual(back?.channel.mode, .am)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            let ch = try XCTUnwrap(state.channels.first(where: { $0.channelID == channel.channelID }))
            XCTAssertEqual(ch.state, .channelActive)
            XCTAssertEqual(ch.bandwidthHz, 8_000)
            XCTAssertEqual(ch.mode, .am)
            await events.stop()
        }
    }
}

/// Accumulates telemetry messages from a streaming RPC for polling from the test body.
actor TelemetryCollector {
    private(set) var messages: [Leyline_V1_TelemetryMsg] = []
    func append(_ m: Leyline_V1_TelemetryMsg) { messages.append(m) }
}

/// A latch for tests: `wait()` suspends callers while the gate is closed; `open()` releases them all.
actor TestGate {
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() { closed = true }

    func open() {
        closed = false
        let resumed = waiters
        waiters = []
        for w in resumed { w.resume() }
    }

    func wait() async {
        guard closed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A telemetry response writer that records every message and, while `gate` is closed, holds the
/// service inside `write` — what a client that stopped reading looks like from the server side.
struct StallingTelemetryWriter: RPCWriterProtocol {
    typealias Element = Leyline_V1_TelemetryMsg
    let collector: TelemetryCollector
    let gate: TestGate

    func write(_ element: Element) async throws {
        await gate.wait()
        await collector.append(element)
    }

    func write(contentsOf elements: some Sequence<Element>) async throws {
        for e in elements { try await write(e) }
    }
}

/// A registry-hosted virtual device whose `startStreaming` throws `DEVICE_IO` while `failStartStreaming`
/// is set; used to drive CreateCapture through the engine's start() unwinding.
final class FaultyStreamDevice: VirtualDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var _descriptor = DeviceDescriptor(id: DeviceID(), driver: "test", model: "faulty", serial: "faulty-1",
                                               tuningRanges: [FrequencyRange(minHz: 0, maxHz: 1_000_000_000)],
                                               sampleRates: [2_400_000], nativeFormat: .cf32)
    private var _onStateChange: (@Sendable (DeviceState) -> Void)?
    let failStartStreaming = LockedValue(false)
    let closes = LockedValue(0)
    let streamStarts = LockedValue(0)

    var descriptor: DeviceDescriptor { lock.lock(); defer { lock.unlock() }; return _descriptor }
    var gains: [GainState] { [] }

    func assignID(_ id: DeviceID) { lock.lock(); _descriptor.id = id; lock.unlock() }
    func setState(_ state: DeviceState) {
        lock.lock(); _descriptor.state = state; let hook = _onStateChange; lock.unlock()
        hook?(state)
    }
    func setOnStateChange(_ hook: (@Sendable (DeviceState) -> Void)?) { lock.lock(); _onStateChange = hook; lock.unlock() }

    func open() async throws {}
    func close() async { closes.value += 1 }
    func tune(centerHz: UInt64) async throws {}
    func setSampleRate(_ hz: UInt64) async throws {}
    func setGain(element: String, value: GainValue) async throws { throw EngineError.gainElementUnknown(element, target: "") }
    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws {
        if failStartStreaming.value { throw EngineError.deviceIO("stream refused", target: descriptor.id.string) }
        streamStarts.value += 1
    }
    func stopStreaming() async {}
}

final class CaptureLifecycleDaemonTests: XCTestCase {
    /// A device that fails to stream is released by the failed CreateCapture: the error is DEVICE_IO,
    /// the device is AVAILABLE again, and a retry after the fault clears succeeds.
    func testCreateCaptureUnwindsWhenStreamingFails() async throws {
        try await withDaemon { c in
            let dev = FaultyStreamDevice()
            dev.failStartStreaming.value = true
            let d = try await c.daemon.registry.attachVirtualDevice(dev)
            // The session store mirrors the registry asynchronously; wait for the device to show up.
            var state = Leyline_V1_GetStateResponse()
            for _ in 0..<150 {
                state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                if state.devices.contains(where: { $0.deviceID == d.id.string }) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.id.string])

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            do {
                _ = try await c.control.createCapture(cc, metadata: testMetadata)
                XCTFail("expected DEVICE_IO")
            } catch {
                XCTAssertEqual(errorCode(error).code, "DEVICE_IO")
            }
            XCTAssertEqual(dev.closes.value, 1, "device closed by the failed start")
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(state.captures.isEmpty)
            XCTAssertEqual(testDevices(state.devices).first?.state, .available)
            let registryState = testDevices(await c.daemon.registry.devices).first?.state
            XCTAssertEqual(registryState, .available)

            // Fault cleared: the retry succeeds on the same device.
            dev.failStartStreaming.value = false
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.state, .captureActive)
            XCTAssertEqual(dev.streamStarts.value, 1)
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.map(\.captureID), [capture.captureID])
            XCTAssertEqual(testDevices(state.devices).first?.state, .inUse)

            var dcap = Leyline_V1_DestroyCaptureRequest()
            dcap.captureID = capture.captureID
            _ = try await c.control.destroyCapture(dcap, metadata: testMetadata)
            XCTAssertEqual(dev.closes.value, 2)
        }
    }
}

final class DetachFileDeviceDaemonTests: XCTestCase {
    /// Waits until the session store mirrors `deviceID` from the registry (arrivals are asynchronous).
    private func waitForDevice(_ c: DaemonClients, _ deviceID: String) async throws -> Leyline_V1_GetStateResponse {
        var state = Leyline_V1_GetStateResponse()
        for _ in 0..<150 {
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            if state.devices.contains(where: { $0.deviceID == deviceID }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return state
    }

    /// DetachFileDevice is rejected before mutating anything: a virtual non-file device is
    /// INVALID_ARGUMENT, an unknown id is DEVICE_NOT_FOUND, and a capture on the device survives both.
    func testDetachRejectsNonFileAndUnknownDevicesWithoutTouchingCaptures() async throws {
        try await withDaemon { c in
            let dev = FaultyStreamDevice()
            let d = try await c.daemon.registry.attachVirtualDevice(dev)
            var state = try await self.waitForDevice(c, d.id.string)
            XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.id.string])

            var cc = Leyline_V1_CreateCaptureRequest()
            cc.deviceID = d.id.string
            cc.centerHz = 146_520_000
            let capture = try await c.control.createCapture(cc, metadata: testMetadata)
            XCTAssertEqual(capture.state, .captureActive)

            // Hosted virtual device that is not file playback (driver "test", like rtl_tcp): rejected.
            var detach = Leyline_V1_DetachFileDeviceRequest()
            detach.deviceID = d.id.string
            do {
                _ = try await c.control.detachFileDevice(detach, metadata: testMetadata)
                XCTFail("expected INVALID_ARGUMENT")
            } catch {
                XCTAssertEqual(errorCode(error).code, "INVALID_ARGUMENT")
            }
            let detachable = await c.daemon.registry.isDetachableFileDevice(id: d.id)
            XCTAssertFalse(detachable)

            // Unknown (well-formed) id: DEVICE_NOT_FOUND.
            detach.deviceID = DeviceID().string
            do {
                _ = try await c.control.detachFileDevice(detach, metadata: testMetadata)
                XCTFail("expected DEVICE_NOT_FOUND")
            } catch {
                XCTAssertEqual(errorCode(error).code, "DEVICE_NOT_FOUND")
            }

            // Nothing was mutated: the capture is still active, the device still hosted and in use.
            state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.captures.map(\.captureID), [capture.captureID])
            XCTAssertEqual(state.captures.first?.state, .captureActive)
            XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.id.string])
            XCTAssertEqual(testDevices(state.devices).first?.state, .inUse)
            XCTAssertEqual(dev.closes.value, 0, "device must not be closed by a rejected detach")
            let registryIDs = testDevices(await c.daemon.registry.devices).map(\.id)
            XCTAssertEqual(registryIDs, [d.id])

            var dcap = Leyline_V1_DestroyCaptureRequest()
            dcap.captureID = capture.captureID
            _ = try await c.control.destroyCapture(dcap, metadata: testMetadata)
        }
    }

    /// A genuine file device reports as detachable and DetachFileDevice still works for it.
    func testFileDeviceIsDetachable() async throws {
        try await withDaemon { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            let d = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            let id = try XCTUnwrap(DeviceID(string: d.deviceID))
            let detachable = await c.daemon.registry.isDetachableFileDevice(id: id)
            XCTAssertTrue(detachable)
            var detach = Leyline_V1_DetachFileDeviceRequest()
            detach.deviceID = d.deviceID
            _ = try await c.control.detachFileDevice(detach, metadata: testMetadata)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertTrue(testDevices(state.devices).isEmpty)
        }
    }
}
