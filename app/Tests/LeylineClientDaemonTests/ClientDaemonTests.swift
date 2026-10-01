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
//   - a recording switched on and off over a continuous carrier cuts the log there, and the
//     piece between the cuts lies in the recording's part;
//   - The band scan borrows the window's capture, hands it back at its centre, and its
//     Scan holds the fixture's carriers; the same sweep without take-over is declined;
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

        // Delete is refused while the job runs, in the sentence the part inspector's disabled
        // Delete shows as its tooltip.
        var runningRef = Leyline_V1_ResourceRef()
        runningRef.uri = "ley://recordings/\(job.jobID)"
        do {
            _ = try await app.resources.deleteResource(runningRef)
            XCTFail("a running recording was deleted")
        } catch {
            XCTAssertEqual(
                LeylineError(error).message, Recordings.deleteRefusalWords(jobID: job.jobID))
        }

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
        XCTAssertEqual(
            manifest.gate?.hangMs, Recordings.windowHangMs,
            "the window's hang, not the daemon's 5 s")
        XCTAssertEqual(manifest.gate?.preRollMs, Recordings.windowPreRollMs)

        // The switch turned on again: a second recording on the channel, its manifest empty or
        // not yet written. The row the first one kept is still kept.
        let again = try await app.jobs.startJob(start)
        await assertEventually("the second record job never ran") {
            Recordings.activeJob(in: mirror.state.jobs, frequencyHz: hz, mode: .nfm)?.jobID
                == again.jobID
        }
        let relisted = try await app.resources.listResources(list).resources.map(
            RecordingSummary.init)
        let ids = Recordings.recordingIDs(
            onFrequencyHz: hz, mode: .nfm, in: relisted, running: again.jobID)
        XCTAssertEqual(ids.first, again.jobID, "the running recording first")
        XCTAssertTrue(ids.contains(job.jobID), "the earlier recording is the channel's too")
        var manifests: [RecordingManifest] = []
        for id in ids {
            var r = Leyline_V1_ResourceRef()
            r.uri = "ley://recordings/\(id)"
            guard let path = try? await app.resources.resolveLocalPath(r).path,
                let m = try? RecordingManifest.read(at: URL(fileURLWithPath: path))
            else { continue }
            manifests.append(m)
        }
        XCTAssertEqual(
            RecordingParts.keptPartURI(of: heard, in: manifests), manifest.uri(of: part),
            "the new recording's manifest does not hide the old one's parts")
        var againRef = Leyline_V1_JobRef()
        againRef.jobID = again.jobID
        _ = try await app.jobs.cancelJob(againRef)
        await assertEventually("the second job never ended") {
            mirror.state.jobs.first { $0.jobID == again.jobID }?.isActive == false
        }
        // The Library's rows and the inspector on that part, from the daemon's own files.
        // The fixture never reaches the rails, so no part carries `clipped_ms`.
        XCTAssertTrue(
            manifest.parts.allSatisfy { $0.clippedMs == nil },
            "clipped_ms is absent on a clean part: \(manifest.parts.map(\.clippedMs))")
        let card = RecordingGroup(summary: summary, manifest: manifest, running: false)
        XCTAssertEqual(card.chips.map(\.uri), manifest.parts.map { manifest.uri(of: $0) })
        XCTAssertNotNil(card.startedAt, "the anchor dates the first part")
        XCTAssertEqual(Recordings.endedWords(manifest.endedBy, running: false), "Switched off")
        var queue = PlayQueue()
        XCTAssertEqual(queue.start(card), card.chips.first?.uri, "Play all starts at part 1")
        let days = Recordings.dayRows([card], now: Date())
        XCTAssertEqual(
            days.flatMap(\.rows).map(\.uri).sorted(),
            manifest.parts.map { manifest.uri(of: $0) }.sorted(), "every part is a row")
        XCTAssertEqual(days.first?.title, "today")
        XCTAssertEqual(
            days.first?.marks.count, days.first?.rows.count, "each part dated on the strip")
        XCTAssertEqual(
            days.first?.rows.first?.bracket,
            manifest.parts.count > 1 ? .first : PartRow.Bracket.none)
        XCTAssertFalse(days.flatMap(\.rows).contains { $0.clipped })
        let inspector = Recordings.partInspectorWords(part: part, of: manifest, running: false)
        XCTAssertTrue(inspector.heading.hasPrefix("PART "), inspector.heading)
        XCTAssertFalse(inspector.clipped)
        XCTAssertNil(inspector.clippedSentence)
        XCTAssertEqual(inspector.recording.first { $0.label == "Ended" }?.value, "Switched off")
        XCTAssertEqual(inspector.deleteLine, Recordings.deleteWords(parts: manifest.parts.count))
        // The level graph, read from the part's WAV through the path the daemon resolves.
        var partRef = Leyline_V1_ResourceRef()
        partRef.uri = manifest.uri(of: part)
        let partPath = try await app.resources.resolveLocalPath(partRef).path
        let graph = try LevelGraph.columns(
            wav: URL(fileURLWithPath: partPath),
            columns: LevelGraph.columnCount(seconds: manifest.seconds(of: part)))
        XCTAssertFalse(graph.isEmpty)
        XCTAssertTrue(graph.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(graph)")
        XCTAssertTrue(graph.contains { $0 > 0 }, "a kept transmission has a level: \(graph)")
        // The Library's player on the same part: its words, and ⏮ and ⏭ within the recording.
        let player = Recordings.playerWords(
            channelTitle: "GMRS CH3", part: part, of: manifest, positionFrames: nil,
            positionRate: 0, now: Date())
        XCTAssertEqual(player.title, "GMRS CH3 · Today")
        XCTAssertTrue(
            player.time.hasSuffix("part \(part.part) of \(manifest.parts.count)"), player.time)
        XCTAssertEqual(player.played, "0:00.0")
        let uri = manifest.uri(of: part)
        let ordered = manifest.parts.sorted { $0.part < $1.part }
        XCTAssertEqual(
            Recordings.neighbourPart(of: uri, in: manifest, step: -1) == nil,
            ordered.first?.part == part.part, "⏮ is disabled only at the first part")
        XCTAssertEqual(
            Recordings.neighbourPart(of: uri, in: manifest, step: 1) == nil,
            ordered.last?.part == part.part, "⏭ is disabled only at the last part")
        // The gutter's kept bars: a row on the capture's timeline inside the part is held, the
        // newer one after every part is not.
        var rows = ClippedRows(capacity: 8)
        rows.append(sampleIndex: part.startSample, captureID: capture.captureID)
        let last = manifest.parts.map(\.endSample).max() ?? part.endSample
        rows.append(sampleIndex: last + 1, captureID: capture.captureID)
        XCTAssertEqual(rows.keptRuns(manifest.parts), [1..<2])
        // The Library's channel rows and its store footer, from the same listing and the cap the
        // daemon reports.
        let summaries = listed.resources.map(RecordingSummary.init)
        let channels = Recordings.channels(summaries, bookmarks: [], jobs: mirror.state.jobs)
        XCTAssertTrue(
            channels.contains { $0.frequencyHz == hz && $0.recordings.contains(summary) },
            "the recording has no channel row")
        XCTAssertGreaterThan(Recordings.storeUsedBytes(summaries), 0)
        XCTAssertGreaterThan(
            mirror.state.daemon.recordingsCapBytes, 0, "the daemon reports its recordings cap")

        try await Self.pauseHoldsThePosition(
            of: manifest.uri(of: manifest.parts.max { $0.samples < $1.samples } ?? part),
            app: app, mirror: mirror)

        let gone = try await app.resources.deleteResource(resource)
        XCTAssertEqual(gone.uri, summary.uri)
        XCTAssertGreaterThan(gone.freedBytes, 0)
        let after = try await app.resources.listResources(list)
        XCTAssertFalse(after.resources.contains { $0.uri == summary.uri }, "deleted, still listed")
    }

    /// The player's ⏸: `SetPlaybackPaused` holds the position and the mirror's playback carries
    /// `paused`, which the row, the player and the space key read; a resume moves on. A daemon on a
    /// host with no audio output (the Linux container) refuses `StartPlayback` with
    /// `PLATFORM_UNSUPPORTED`, and the check is then left to the Mac.
    @MainActor
    private static func pauseHoldsThePosition(
        of uri: String, app: DaemonConnection, mirror: DaemonMirror
    ) async throws {
        var start = Leyline_V1_StartPlaybackRequest()
        start.resourceUri = uri
        let pb: Leyline_V1_Playback
        do {
            pb = try await app.control.startPlayback(start)
        } catch {
            let e = LeylineError(error)
            guard e.code == "PLATFORM_UNSUPPORTED" else { throw error }
            print("pause not checked on this host: \(e.message)")
            return
        }
        var pause = Leyline_V1_SetPlaybackPausedRequest()
        pause.playbackID = pb.playbackID
        pause.paused = true
        let paused = try await app.control.setPlaybackPaused(pause)
        XCTAssertTrue(paused.paused)
        await assertEventually("the mirror never showed the playback paused") {
            mirror.state.playbacks.first { $0.playbackID == pb.playbackID }?.paused == true
        }
        let held = mirror.state.playbacks.first { $0.playbackID == pb.playbackID }?.position
        try await Task.sleep(for: .milliseconds(500))
        let state = try await app.state()
        let after = state.playbacks.first { $0.playbackID == pb.playbackID }
        XCTAssertEqual(after?.paused, true)
        XCTAssertEqual(after?.position, held, "a paused playback holds its position")
        pause.paused = false
        let resumed = try await app.control.setPlaybackPaused(pause)
        XCTAssertFalse(resumed.paused)
        var stop = Leyline_V1_StopPlaybackRequest()
        stop.playbackID = pb.playbackID
        _ = try? await app.control.stopPlayback(stop)
    }

    /// The channel page's Record transmissions switch, by the page's own path: the channel is a
    /// row of the store's listing, with no manifest read and no channel of the window's to copy,
    /// so the request carries the listing's frequency, mode and width and no squelch. The job it
    /// starts must run and be the one the page's switch finds (plans/app.md, APP-5, "Fixed
    /// 2026-09-25").
    /// The owner, 2026-09-25: "make sure that toggling a recording on and off creates a
    /// transmission. treat it as a manual marker." The tone fixture is a continuous carrier, so
    /// its squelch is open from the channel's creation and sends no edge at all; the meters say
    /// it is open, the recording's gate is seeded open and its part starts at once. The log is cut the way `AppSession` cuts it: at the newest telemetry time
    /// when the mirror first shows the job running, and again when it shows it ended.
    @MainActor
    func testARecordingOverACarrierCutsTheLogAtItsToggles() async throws {
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
        let rate = capture.sampleRate

        // `ChannelTelemetryFeed`'s subscription and fold, on the main actor.
        final class Folded {
            var log: TransmissionLog
            var newest: Leyline_V1_SampleTime?
            var meterOpen = false
            init(_ id: String) { log = TransmissionLog(channelID: id) }
        }
        let folded = Folded(channel.channelID)
        var sub = Leyline_V1_TelemetrySubscription()
        sub.channelID = channel.channelID
        sub.types = [.meter, .squelchTransition, .subAudible]
        let stream = app.telemetry(sub)
        let folder = Task { @MainActor in
            for try await msg in stream {
                folded.newest = msg.time
                if case .meter(let m)? = msg.body { folded.meterOpen = m.squelchOpen }
                folded.log.fold(msg, captureRate: rate)
            }
        }
        defer { folder.cancel() }
        await assertEventually("the meters never said the carrier held the squelch open") {
            folded.meterOpen
        }

        var start = Leyline_V1_StartJobRequest()
        start.record = Recordings.config(
            frequencyHz: hz, mode: .nfm, bandwidthHz: channel.bandwidthHz, squelchDBFS: -40)
        let job = try await app.jobs.startJob(start)
        var onAt: Leyline_V1_SampleTime?
        await assertEventually("the record job never ran on the tuned frequency") {
            guard
                Recordings.activeJob(in: mirror.state.jobs, frequencyHz: hz, mode: .nfm)?.jobID
                    == job.jobID
            else { return false }
            onAt = folded.newest
            return true
        }
        let on = try XCTUnwrap(onAt, "no telemetry time when the job ran")
        XCTAssertTrue(folded.log.mark(.recordingOn, at: on, captureRate: rate), "nothing on air")

        try await Task.sleep(for: .seconds(2))
        var ref = Leyline_V1_JobRef()
        ref.jobID = job.jobID
        _ = try await app.jobs.cancelJob(ref)
        var offAt: Leyline_V1_SampleTime?
        await assertEventually("the job never ended") {
            guard
                Recordings.activeJob(in: mirror.state.jobs, frequencyHz: hz, mode: .nfm) == nil
            else { return false }
            offAt = folded.newest
            return true
        }
        let off = try XCTUnwrap(offAt)
        XCTAssertTrue(folded.log.mark(.recordingOff, at: off, captureRate: rate), "nothing on air")
        XCTAssertEqual(folded.log.onAir?.startMarker, .recordingOff, "the carrier is still on air")

        let piece = try XCTUnwrap(
            folded.log.closed.first { $0.startMarker == .recordingOn },
            "no row starts at the cut: \(folded.log.closed.map { ($0.start.sampleIndex, $0.end.sampleIndex) })"
        )
        XCTAssertEqual(piece.start, on)
        XCTAssertEqual(piece.end, off)
        XCTAssertEqual(piece.endMarker, .recordingOff)
        XCTAssertEqual(piece.seconds, 2, accuracy: 0.5)
        XCTAssertGreaterThan(piece.peakSNRDB, 20, "the piece's own meters measured the carrier")

        await assertEventually("the job never reached a terminal state") {
            mirror.state.jobs.first { $0.jobID == job.jobID }?.state == .cancelled
        }
        var resource = Leyline_V1_ResourceRef()
        resource.uri = "ley://recordings/\(job.jobID)"
        let local = try await app.resources.resolveLocalPath(resource)
        let manifest = try RecordingManifest.read(at: URL(fileURLWithPath: local.path))
        XCTAssertNotNil(
            RecordingParts.match(transmission: piece, in: manifest.parts),
            "the piece \(piece.start.sampleIndex)–\(piece.end.sampleIndex) lies in no part of \(manifest.parts.map { ($0.startSample, $0.endSample) })"
        )
    }

    @MainActor
    func testTheChannelPagesSwitchStartsARecordingThatRuns() async throws {
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        let (capture, channel) = try await Self.tuneFixture(app, on: daemon)
        let hz = UInt64(Int64(capture.centerHz) + channel.offsetHz)

        // A recording already in the store, which is what gives the page its channel.
        var first = Leyline_V1_StartJobRequest()
        first.record = Recordings.config(
            frequencyHz: hz, mode: .nfm, bandwidthHz: channel.bandwidthHz, squelchDBFS: -40)
        first.record.durationMs = 500
        let earlier = try await app.jobs.startJob(first)
        await assertEventually("the first recording never finished", timeout: .seconds(10)) {
            mirror.state.jobs.first { $0.jobID == earlier.jobID }?.isActive == false
        }

        var list = Leyline_V1_ListResourcesRequest()
        list.kind = .recording
        let summaries = try await app.resources.listResources(list).resources.map(
            RecordingSummary.init)
        let channels = Recordings.channels(summaries, bookmarks: [], jobs: mirror.state.jobs)
        let page = try XCTUnwrap(
            channels.first { $0.frequencyHz == hz }, "the recording has no channel row")
        XCTAssertNil(
            Recordings.activeJob(
                in: mirror.state.jobs, frequencyHz: page.frequencyHz, mode: page.mode),
            "the switch starts off")

        // `AppSession.setRecording(_:channel:)`, with no manifest loaded.
        var req = Leyline_V1_StartJobRequest()
        req.record = Recordings.pageConfig(page, groups: [])
        let job = try await app.jobs.startJob(req)
        XCTAssertEqual(job.state, .running, job.statusDetail)
        await assertEventually(
            "the page's switch never found its job running", timeout: .seconds(10)
        ) {
            Recordings.activeJob(
                in: mirror.state.jobs, frequencyHz: page.frequencyHz, mode: page.mode)?
                .jobID == job.jobID
        }
        // Still running once the squelch is measured and the gate has had time to act: a job
        // that failed after starting leaves the switch off as surely as a refusal does.
        try await Task.sleep(for: .seconds(1.5))
        let now = try XCTUnwrap(mirror.state.jobs.first { $0.jobID == job.jobID })
        XCTAssertEqual(now.state, .running, now.statusDetail)

        var ref = Leyline_V1_JobRef()
        ref.jobID = job.jobID
        _ = try await app.jobs.cancelJob(ref)
        await assertEventually("the job never ended") {
            mirror.state.jobs.first { $0.jobID == job.jobID }?.state == .cancelled
        }
        let after = try await app.resources.listResources(list).resources.map(
            RecordingSummary.init)
        let summary = try XCTUnwrap(
            after.first { $0.jobID == job.jobID }, "the page's recording is not listed")
        XCTAssertGreaterThan(summary.parts, 0, "the carrier holds the squelch open: one part")
    }

    /// The scan job Scan band starts (docs/design/channels.md, "Scan the band"): 2 m with
    /// take-over on the window's own device. The file device tunes only at its one centre, so
    /// the sweep is clipped to that one step and `covered` is narrower than the band by design;
    /// the test asserts the carriers, the borrowed capture's id and its restored centre, not
    /// full coverage. Then the same request without take-over, while the window's channel is
    /// on the capture, is declined by the allocator's don't-disturb rule with `DEVICE_BUSY`.
    @MainActor
    func testScanBandSweepsTheFixtureAndGivesTheCaptureBack() async throws {
        Harness.stop(daemon)
        daemon = try await Harness.start(fixture: "scan_band.cf32")
        let app = try DaemonConnection(
            socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        let (capture, channel) = try await Self.tuneFixture(app, on: daemon)
        let centreHz = capture.centerHz
        XCTAssertEqual(centreHz, 146_000_000, "scan_band.cf32 was recorded at 146.0 MHz")
        await assertEventually("the capture never reached the mirror") {
            mirror.state.capture(capture.captureID) != nil
        }
        let twoM = try XCTUnwrap(Bands.resolve("2m"))

        // `AppSession.scanBand(row:)` after its pause: the request on the capture's device.
        let job = try await app.jobs.startJob(
            Sweep.request(for: twoM, in: Bands.builtIn, deviceID: capture.deviceID))
        XCTAssertEqual(job.state, .running, job.statusDetail)
        let scanID = try XCTUnwrap(Sweep.scanID(of: job), "the job names no scan")
        await assertEventually("the sweep never ended", timeout: .seconds(60)) {
            mirror.state.jobs.first { $0.jobID == job.jobID }?.isActive == false
        }
        let ended = try XCTUnwrap(mirror.state.jobs.first { $0.jobID == job.jobID })
        XCTAssertEqual(ended.state, .completed, "\(ended.statusDetail) [\(ended.error.code)]")

        var ref = Leyline_V1_ScanRef()
        ref.scanID = scanID
        let scan = try await app.jobs.getScan(ref)
        let result = SweepResult(scan: scan, band: twoM, in: Bands.builtIn)
        let outcome = SweepOutcome.from(job: ended, scan: scan, band: twoM, in: Bands.builtIn)
        XCTAssertEqual(outcome, .found(result))
        let carriers: [UInt64] = [145_200_000, 145_600_000, 146_400_000, 146_800_000]
        let heard = carriers.filter { c in
            result.hits.contains { h in
                (h.hz > c ? h.hz - c : c - h.hz) <= 15_000
            }
        }
        XCTAssertGreaterThanOrEqual(
            heard.count, 3, "hits at \(result.hits.map(\.hz)), carriers heard \(heard)")
        for (a, b) in zip(result.hits, result.hits.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.snrDb, b.snrDb, "strongest first")
        }
        XCTAssertNotNil(
            result.coverageWords(band: twoM),
            "one centre cannot cover 2 m: covered \(String(describing: result.covered))")

        // The borrowed capture keeps its id and is back at its centre once the job has ended.
        XCTAssertNotNil(mirror.state.capture(capture.captureID), "the capture was replaced")
        await assertEventually("the centre never came back to \(centreHz)") {
            mirror.state.capture(capture.captureID)?.centerHz == centreHz
        }
        XCTAssertEqual(mirror.state.captures.count, 1, "the sweep opened a capture of its own")
        XCTAssertNotNil(mirror.state.channel(channel.channelID), "the channel is still there")

        // Without take-over the window's own channel is what makes the radio busy, and the
        // allocator says so on the job's event: `StartJob` answers before it allocates.
        var polite = Sweep.request(for: twoM, in: Bands.builtIn, deviceID: capture.deviceID)
        polite.scan.takeOver = false
        let refused = try await app.jobs.startJob(polite)
        await assertEventually("the polite sweep never ended", timeout: .seconds(20)) {
            mirror.state.jobs.first { $0.jobID == refused.jobID }?.isActive == false
        }
        let declined = try XCTUnwrap(mirror.state.jobs.first { $0.jobID == refused.jobID })
        XCTAssertEqual(declined.state, .failed, declined.statusDetail)
        XCTAssertEqual(declined.error.code, "DEVICE_BUSY", declined.statusDetail)
        XCTAssertEqual(
            SweepOutcome.from(job: declined, scan: nil, band: twoM, in: Bands.builtIn),
            .failed(detail: declined.statusDetail))
        XCTAssertFalse(declined.statusDetail.isEmpty, "the reason names what is using the radio")
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
