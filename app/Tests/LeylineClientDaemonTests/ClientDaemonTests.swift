// SPDX-License-Identifier: Apache-2.0

// The façade against the real daemon. Each test covers one behaviour the app relies on:
//   - another client's change reaches the mirror (the CLI changes the tuning, the UI reflects it),
//     and its tombstone leaves it;
//   - a burst of coalesced writes lands as one confirmed value, and a refused one comes back as
//     a WriteRejected with its tag;
//   - an FFT subscription answers a descriptor and rows decode against it;
//   - a channel's audio spectrum on the demod tap sums into octave bands where the fixture's
//     tones are;
//   - a keyed carrier's squelch edges fold into transmissions as long as the fixture keyed them,
//     and the capture's anchor gives one a wall clock;
//   - the window's record job writes a manifest the façade reads, whose parts hold the
//     transmissions heard live, and a finished recording deletes;
//   - the daemon's error code survives the trip.

import Foundation
import LeylineClient
import LeylineProto
import XCTest

final class ClientDaemonTests: XCTestCase {
    var daemon: DaemonUnderTest!

    override func setUp() async throws {
        daemon = try await Harness.start()
    }

    override func tearDown() async throws {
        if let daemon { Harness.stop(daemon) }
    }

    /// A capture on the fixture plus one NFM channel at +100 kHz, made by `c`. Free of `self` so
    /// a main-actor test can call it without sending the test case across actors.
    nonisolated static func tuneFixture(_ c: DaemonConnection, on daemon: DaemonUnderTest)
        async throws -> (Leyline_V1_Capture, Leyline_V1_Channel)
    {
        let dev = try await Harness.attachFixture(daemon, via: c)
        var cap = Leyline_V1_CreateCaptureRequest()
        cap.deviceID = dev.deviceID
        // A file device tunes only where it was recorded: its one tuning range is that centre.
        cap.centerHz = dev.tuningRanges.first?.minHz ?? 0
        let capture = try await c.control.createCapture(cap)
        var ch = Leyline_V1_CreateChannelRequest()
        ch.captureID = capture.captureID
        ch.offsetHz = 100_000
        ch.mode = .nfm
        let channel = try await c.control.createChannel(ch)
        return (capture, channel)
    }

    @MainActor
    func testMirrorReflectsAnotherClientsChanges() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        XCTAssertEqual(mirror.snapshots, 1)
        XCTAssertFalse(mirror.state.daemon.version.isEmpty)

        // "The CLI": a second identity, holding its own event stream so its channel stays alive.
        let cli = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "cli", label: "test-cli"))
        defer { cli.close() }
        let presence = Task { for try await _ in cli.events() {} }
        defer { presence.cancel() }
        let (capture, channel) = try await Self.tuneFixture(cli, on: daemon)

        await assertEventually("the channel never reached the mirror") {
            mirror.state.channel(channel.channelID) != nil
        }
        XCTAssertEqual(
            mirror.state.capture(capture.captureID)?.centerHz, 146_520_000, "the fixture's centre")
        XCTAssertEqual(
            mirror.state.frequencyHz(of: mirror.state.channel(channel.channelID)!), 146_620_000)
        XCTAssertEqual(mirror.state.devices.first?.driver, "file")
        XCTAssertEqual(
            mirror.state.channel(channel.channelID)?.owner.kind, "cli", "events carry attribution")

        var destroy = Leyline_V1_DestroyChannelRequest()
        destroy.channelID = channel.channelID
        _ = try await cli.control.destroyChannel(destroy)
        await assertEventually("the tombstone never removed the channel") {
            mirror.state.channel(channel.channelID) == nil
        }
        XCTAssertEqual(mirror.snapshots, 1, "no seq gap: the stream carried everything")
    }

    @MainActor
    func testCoalescedWritesLandAsTheLastValueAndRefusalsCarryTheirTag() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("condition never held") { mirror.connection == .live }
        let (capture, channel) = try await Self.tuneFixture(app, on: daemon)

        // 50 ms is wide enough that a loaded runner cannot split the burst.
        let writes = WriteCoalescer(connection: app, tick: .milliseconds(50))
        // A drag: a burst of offsets inside one tick. Only the last should be applied.
        for hz: Int64 in [110_000, 120_000, 130_000, 140_000, 150_000] {
            await writes.offsetHz(hz, channel: channel.channelID)
        }
        await assertEventually("the last offset never arrived") {
            mirror.state.channel(channel.channelID)?.offsetHz == 150_000
        }
        XCTAssertEqual(
            mirror.state.frequencyHz(of: mirror.state.channel(channel.channelID)!), 146_670_000)

        // Out of the capture (2.4 MSPS spans ±1.2 MHz): refused, and the refusal carries the tag.
        let tag = await writes.offsetHz(5_000_000, channel: channel.channelID)
        await assertEventually("no WriteRejected for the bad offset") {
            mirror.state.rejections.contains { $0.tag == tag }
        }
        let rejection = mirror.state.rejections.first { $0.tag == tag }!
        XCTAssertEqual(rejection.error.code, "OFFSET_OUT_OF_CAPTURE")
        XCTAssertEqual(
            mirror.state.channel(channel.channelID)?.offsetHz, 150_000,
            "the refused write changed nothing")

        await writes.stop()
        let summary = await writes.lastSummary
        let streamError = await writes.lastError
        XCTAssertNotNil(
            summary, "the stream ends with the daemon's summary: \(String(describing: streamError))"
        )
        XCTAssertEqual(
            summary?.writesReceived, 2, "five offsets in a tick are one write, plus the refused one"
        )
        _ = capture
    }

    func testFFTRowsDecodeAgainstTheAnsweredDescriptor() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let presence = Task { for try await _ in app.events() {} }
        defer { presence.cancel() }
        let (capture, _) = try await Self.tuneFixture(app, on: daemon)

        let (descriptor, rows) = try await app.fft(
            capture: capture.captureID, bins: 256, rowsPerSecond: 10)
        XCTAssertEqual(descriptor.kind, .fft)
        XCTAssertEqual(descriptor.centerHz, 146_520_000)
        XCTAssertEqual(descriptor.spanHz, 2_400_000)
        XCTAssertEqual(descriptor.fft.binFormat, .dbU8)
        XCTAssertTrue(descriptor.grpc, "v0 answers every subscription with gRPC")

        var seen = 0
        for try await row in rows {
            XCTAssertEqual(row.levelsDB.count, Int(descriptor.fft.bins))
            XCTAssertEqual(
                row.time.captureID, capture.captureID, "every row carries the sample timebase")
            XCTAssertTrue(row.levelsDB.allSatisfy { $0 >= -120 && $0 <= 7.5 })
            // The fixture's tone at +100 kHz sits about 40 dB over its floor; the loudest bin is
            // in the upper half of the row.
            let peak = row.levelsDB.indices.max { row.levelsDB[$0] < row.levelsDB[$1] }!
            XCTAssertGreaterThan(peak, row.levelsDB.count / 2)
            seen += 1
            if seen == 3 { break }
        }
        XCTAssertEqual(seen, 3)
    }

    /// The inspector's audio ladder off the real daemon (docs/plans/app.md, M2-7):
    /// `nfm_pl.cf32` is a 1 kHz tone over a 100.0 Hz PL (`go/cmd/leyfix/catalog.go`), and on
    /// the demod tap, before the high-pass takes the PL out, both are there: 100 Hz in the 125 Hz
    /// band (88 to 177 Hz) and the tone in the 1 kHz band, each well over the 8 and 16 kHz bands,
    /// which hold only the discriminator's noise. Measured 2026-09-23 against the Linux-built
    /// daemon, the same on three runs: 125 Hz −11.3, 1 kHz 0.0, 8 kHz −49.6 and 16 kHz
    /// −95.6 dBFS, the first two as `go/internal/e2e/meters_test.go` reads them from `ley
    /// levels`. 20 dB over the louder of 8 and 16 kHz leaves 18 dB of that 38 dB to spare.
    @MainActor
    func testAudioSpectrumBandsReadTheFixturesTones() async throws {
        // This test's radio is the PL fixture, not the tone `setUp` starts on.
        Harness.stop(daemon)
        daemon = try await Harness.start(fixture: "nfm_pl.cf32")
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let presence = Task { for try await _ in app.events() {} }
        defer { presence.cancel() }
        let (_, channel) = try await Self.tuneFixture(app, on: daemon)

        let (descriptor, rows) = try await app.fft(
            channel: channel.channelID, tap: .tapDemod, bins: 1024, rowsPerSecond: 20)
        XCTAssertEqual(descriptor.kind, .fft)
        XCTAssertEqual(descriptor.fft.tap, .tapDemod)
        XCTAssertEqual(descriptor.fft.bins, 1024)
        XCTAssertEqual(descriptor.fft.binFormat, .dbF32)
        XCTAssertEqual(descriptor.spanHz, 2 * descriptor.centerHz, "rate/2 over rate/4")
        let binHz = Double(descriptor.spanHz) / Double(descriptor.fft.bins)

        let seen = BandsSeen()
        let folder = Task { @MainActor in
            for try await row in rows {
                seen.levels.measure(row.levelsDB, binHz: binHz)
                seen.rows += 1
            }
        }
        defer { folder.cancel() }
        // Bands in `BandLevels.octaveCentresHz` order: 125 Hz is 1, 1 kHz 4, 8 kHz 7, 16 kHz 8.
        let margin = 20.0
        func noise() -> Double { max(seen.levels.levelsDB[7], seen.levels.levelsDB[8]) }
        await assertEventually(
            "the 125 Hz and 1 kHz bands never stood 20 dB over the 8 and 16 kHz bands",
            timeout: .seconds(10)
        ) {
            seen.rows > 0 && seen.levels.levelsDB[1] - noise() >= margin
                && seen.levels.levelsDB[4] - noise() >= margin
        }
        let db = seen.levels.levelsDB
        XCTAssertGreaterThanOrEqual(db[1] - noise(), margin, "125 Hz over the noise; bands \(db)")
        XCTAssertGreaterThanOrEqual(db[4] - noise(), margin, "1 kHz over the noise; bands \(db)")
    }

    /// The keyed fixture's transmissions (`fixtures/nfm_keyed.json`: keyed for 1.0 s, 0.5 s and
    /// 2.0 s with 3 s of floor between, looping) as the log folds them from the daemon's own
    /// edges, at the -40 dBFS gate the sidecar specifies and `go/internal/e2e/record_test.go`
    /// records with. The squelch has 2 dB of hysteresis and no hang, so a close edge's duration
    /// is the key-down time to within a block; 0.25 s leaves room for the fixture's edges
    /// landing inside one.
    @MainActor
    func testKeyedCarrierFoldsIntoTransmissionsWithAWallClock() async throws {
        // This test's radio is the keyed fixture, not the tone `setUp` starts on.
        Harness.stop(daemon)
        daemon = try await Harness.start(fixture: "nfm_keyed.cf32")
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        let (capture, channel) = try await Self.tuneFixture(app, on: daemon)
        try await Harness.setSquelch(-40, channel: channel.channelID, via: app, mirror: mirror)
        await assertEventually("the capture never carried a dated anchor") {
            (mirror.state.capture(capture.captureID)?.anchor.hostTimeNs ?? 0) != 0
        }

        let keyedSeconds: [Double] = [1.0, 0.5, 2.0]
        let tolerance = 0.25
        func keyed(_ t: Transmission) -> Bool {
            keyedSeconds.contains { abs(t.seconds - $0) <= tolerance }
        }
        var sub = Leyline_V1_TelemetrySubscription()
        sub.channelID = channel.channelID
        sub.types = [.squelchTransition, .subAudible]
        let edges = app.telemetry(sub)
        let rate = capture.sampleRate
        let channelID = channel.channelID
        // The file loops, so the next key-down is at most a file's length away; the deadline
        // ends the fold with whatever it holds rather than hanging the suite.
        let folder = Task { () -> (TransmissionLog, Leyline_V1_SampleTime?) in
            var log = TransmissionLog(channelID: channelID)
            var last: Leyline_V1_SampleTime?
            for try await msg in edges {
                log.fold(msg, captureRate: rate)
                last = msg.time
                if log.closed.contains(where: keyed) { break }
            }
            return (log, last)
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(25))
            folder.cancel()
        }
        let (log, last) = try await folder.value
        deadline.cancel()

        let durations = log.closed.map { String(format: "%.2f", $0.seconds) }
        XCTAssertTrue(
            log.closed.contains(where: keyed),
            "no transmission as long as the fixture keyed one; saw \(durations) s")
        let transmission = try XCTUnwrap(log.closed.first(where: keyed))
        XCTAssertEqual(transmission.start.captureID, capture.captureID)
        XCTAssertGreaterThan(transmission.peakAudioDBFS, -40, "the tone is over the gate")
        XCTAssertEqual(log.captureRate, 2_400_000)
        let newest = try XCTUnwrap(last)
        XCTAssertNil(log.timeOnAir(at: newest), "the fold ended on a close edge")

        let anchor = try XCTUnwrap(mirror.state.capture(capture.captureID)).anchor
        let started = try XCTUnwrap(
            SampleClock.wallTime(of: transmission.start, anchor: anchor),
            "the capture's anchor covers its own transmission")
        XCTAssertLessThan(
            abs(started.timeIntervalSinceNow), 120, "on the daemon's clock, minutes ago at most")
        var elsewhere = transmission.start
        elsewhere.captureID = "cap_00000000000000000000000000"
        XCTAssertNil(SampleClock.wallTime(of: elsewhere, anchor: anchor))
    }

    @MainActor
    func testTheWindowsRecordingHoldsTheTransmissionsHeardLive() async throws {
        Harness.stop(daemon)
        daemon = try await Harness.start(fixture: "nfm_keyed.cf32")
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        let (capture, channel) = try await Self.tuneFixture(app, on: daemon)
        try await Harness.setSquelch(-40, channel: channel.channelID, via: app, mirror: mirror)
        let hz = UInt64(Int64(capture.centerHz) + channel.offsetHz)

        // The job the Record transmissions switch starts: the channel copied, gated by the
        // squelch. The switch's state is that job, found in the mirror by frequency and mode.
        var start = Leyline_V1_StartJobRequest()
        start.record = Recordings.config(
            frequencyHz: hz, mode: .nfm, bandwidthHz: channel.bandwidthHz, squelchDBFS: -40)
        let job = try await app.jobs.startJob(start)
        await assertEventually("the record job never ran on the tuned frequency") {
            Recordings.activeJob(in: mirror.state.jobs, frequencyHz: hz, mode: .nfm)?.jobID
                == job.jobID
        }
        // The job rides the window's capture, so moving the capture off its frequency asks
        // first, and moving it a little does not.
        await assertEventually("the job's channel never reached the mirror") {
            Recordings.jobs(riding: capture.captureID, in: mirror.state).map(\.jobID)
                == [job.jobID]
        }
        let far = capture.centerHz + 10 * capture.sampleRate
        XCTAssertEqual(
            Recordings.leftOut(
                capture: capture.captureID,
                movingTo: (far - capture.sampleRate / 2)...(far + capture.sampleRate / 2),
                in: mirror.state
            ).map(\.jobID), [job.jobID])
        XCTAssertEqual(
            Recordings.leftOut(
                capture: capture.captureID,
                movingTo: (hz - capture.sampleRate / 4)...(hz + capture.sampleRate / 4),
                in: mirror.state), [])

        // Two transmissions heard after the job started: the first the fold sees may have
        // begun before the job did, and its start is then outside every part.
        var sub = Leyline_V1_TelemetrySubscription()
        sub.channelID = channel.channelID
        sub.types = [.squelchTransition]
        let edges = app.telemetry(sub)
        let rate = capture.sampleRate
        let channelID = channel.channelID
        let folder = Task { () -> TransmissionLog in
            var log = TransmissionLog(channelID: channelID)
            for try await msg in edges {
                log.fold(msg, captureRate: rate)
                if log.closed.count >= 2 { break }
            }
            return log
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(25))
            folder.cancel()
        }
        let log = try await folder.value
        deadline.cancel()
        let heard = try XCTUnwrap(log.closed.first, "nothing heard on the keyed fixture")

        var ref = Leyline_V1_JobRef()
        ref.jobID = job.jobID
        let cancelled = try await app.jobs.cancelJob(ref)
        XCTAssertEqual(cancelled.jobID, job.jobID)
        await assertEventually("the job never ended") {
            mirror.state.jobs.first { $0.jobID == job.jobID }?.state == .cancelled
        }

        var list = Leyline_V1_ListResourcesRequest()
        list.kind = .recording
        let listed = try await app.resources.listResources(list)
        let summary = try XCTUnwrap(
            listed.resources.map(RecordingSummary.init).first { $0.jobID == job.jobID },
            "the recording is not listed")
        XCTAssertEqual(summary.frequencyHz, hz)
        XCTAssertEqual(summary.mode, .nfm)
        XCTAssertEqual(
            summary.bandwidthHz, channel.bandwidthHz, "the listing carries the width recorded")
        XCTAssertGreaterThan(summary.parts, 0)

        var resource = Leyline_V1_ResourceRef()
        resource.uri = summary.uri
        let local: Leyline_V1_LocalPath = try await app.resources.resolveLocalPath(resource)
        let manifest = try RecordingManifest.read(at: URL(fileURLWithPath: local.path))
        XCTAssertEqual(manifest.jobID, job.jobID)
        XCTAssertEqual(manifest.frequencyHz, hz)
        XCTAssertEqual(manifest.demodMode, .nfm)
        XCTAssertEqual(manifest.gate?.kind, "squelch")
        XCTAssertEqual(manifest.parts.count, summary.parts)
        XCTAssertTrue(
            manifest.parts.allSatisfy { $0.captureID == capture.captureID },
            "the job rode the window's capture, so its parts are on that timeline")
        let part = try XCTUnwrap(
            RecordingParts.match(transmission: heard, in: manifest.parts),
            "the newest transmission \(heard.start.sampleIndex)–\(heard.end.sampleIndex) lies in no part of \(manifest.parts.map { ($0.startSample, $0.endSample) })"
        )
        XCTAssertTrue(
            manifest.uri(of: part).hasPrefix(summary.uri + "/"), "the kept row plays its part")
        // The waterfall's kept bars: rows on the capture's timeline inside the part are flagged.
        var rows = ClippedRows(capacity: 8)
        rows.append(sampleIndex: part.startSample, captureID: capture.captureID)
        let last = manifest.parts.map(\.endSample).max() ?? part.endSample
        rows.append(sampleIndex: last + 1, captureID: capture.captureID)
        XCTAssertEqual(rows.markKept(manifest.parts), 1)

        let gone = try await app.resources.deleteResource(resource)
        XCTAssertEqual(gone.uri, summary.uri)
        XCTAssertGreaterThan(gone.freedBytes, 0)
        let after = try await app.resources.listResources(list)
        XCTAssertFalse(after.resources.contains { $0.uri == summary.uri }, "deleted, still listed")
    }

    func testErrorCodesSurviveTheTrip() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        var req = Leyline_V1_CreateCaptureRequest()
        req.deviceID = "dev_00000000000000000000000000"
        do {
            _ = try await app.control.createCapture(req)
            XCTFail("a capture on no device was created")
        } catch {
            let e = LeylineError(error)
            XCTAssertEqual(e.code, "DEVICE_NOT_FOUND")
            XCTAssertFalse(e.message.isEmpty)
        }
    }

    func testNoDaemonIsUnavailableAndTheMirrorKeepsTrying() async throws {
        let app = try DaemonConnection(
            socketPath: "/tmp/ley-app-nobody-\(getpid()).sock",
            identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        do {
            _ = try await app.state()
            XCTFail("a socket with no listener answered")
        } catch {
            XCTAssertTrue(LeylineError(error).daemonUnreachable, "\(error)")
        }
        let mirror = await DaemonMirror(connection: app, backoff: [.milliseconds(50)])
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("the mirror never named the missing daemon") {
            if case .unavailable(let e, _) = mirror.connection { return e.daemonUnreachable }
            return false
        }
    }
}

/// The newest bands a test's row fold has read, on the main actor where the assertion polls.
@MainActor
private final class BandsSeen {
    var levels = BandLevels()
    var rows = 0
}
