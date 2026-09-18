// SPDX-License-Identifier: Apache-2.0

// The façade against the real daemon. Each test is one of the app's promises:
//   - another client's change reaches the mirror (the CLI changes the tuning, the UI reflects it),
//     and its tombstone leaves it;
//   - a burst of coalesced writes lands as one confirmed value, and a refused one comes back as
//     a WriteRejected with its tag;
//   - an FFT subscription answers a descriptor and rows decode against it;
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
    nonisolated static func tuneFixture(_ c: DaemonConnection, on daemon: DaemonUnderTest) async throws -> (Leyline_V1_Capture, Leyline_V1_Channel) {
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
        let app = try DaemonConnection(socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("mirror never went live") { mirror.connection == .live }
        XCTAssertEqual(mirror.snapshots, 1)
        XCTAssertFalse(mirror.state.daemon.version.isEmpty)

        // "The CLI": a second identity, holding its own event stream so its channel stays alive.
        let cli = try DaemonConnection(socketPath: daemon.socketPath, identity: .fresh(kind: "cli", label: "test-cli"))
        defer { cli.close() }
        let presence = Task { for try await _ in cli.events() {} }
        defer { presence.cancel() }
        let (capture, channel) = try await Self.tuneFixture(cli, on: daemon)

        await assertEventually("the channel never reached the mirror") { mirror.state.channel(channel.channelID) != nil }
        XCTAssertEqual(mirror.state.capture(capture.captureID)?.centerHz, 146_520_000, "the fixture's centre")
        XCTAssertEqual(mirror.state.frequencyHz(of: mirror.state.channel(channel.channelID)!), 146_620_000)
        XCTAssertEqual(mirror.state.devices.first?.driver, "file")
        XCTAssertEqual(mirror.state.channel(channel.channelID)?.owner.kind, "cli", "events carry attribution")

        var destroy = Leyline_V1_DestroyChannelRequest()
        destroy.channelID = channel.channelID
        _ = try await cli.control.destroyChannel(destroy)
        await assertEventually("the tombstone never removed the channel") { mirror.state.channel(channel.channelID) == nil }
        XCTAssertEqual(mirror.snapshots, 1, "no seq gap: the stream carried everything")
    }

    @MainActor
    func testCoalescedWritesLandAsTheLastValueAndRefusalsCarryTheirTag() async throws {
        let app = try DaemonConnection(socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let mirror = DaemonMirror(connection: app)
        let running = Task { await mirror.run() }
        defer { running.cancel() }
        await assertEventually("condition never held") { mirror.connection == .live }
        let (capture, channel) = try await Self.tuneFixture(app, on: daemon)

        let writes = WriteCoalescer(connection: app, tick: .milliseconds(50))  // wide enough that a loaded runner cannot split the burst
        // A drag: a burst of offsets inside one tick. Only the last should be applied.
        for hz: Int64 in [110_000, 120_000, 130_000, 140_000, 150_000] { await writes.offsetHz(hz, channel: channel.channelID) }
        await assertEventually("the last offset never arrived") { mirror.state.channel(channel.channelID)?.offsetHz == 150_000 }
        XCTAssertEqual(mirror.state.frequencyHz(of: mirror.state.channel(channel.channelID)!), 146_670_000)

        // Out of the capture (2.4 MSPS spans ±1.2 MHz): refused, and the refusal names the tag.
        let tag = await writes.offsetHz(5_000_000, channel: channel.channelID)
        await assertEventually("no WriteRejected for the bad offset") { mirror.state.rejections.contains { $0.tag == tag } }
        let rejection = mirror.state.rejections.first { $0.tag == tag }!
        XCTAssertEqual(rejection.error.code, "OFFSET_OUT_OF_CAPTURE")
        XCTAssertEqual(mirror.state.channel(channel.channelID)?.offsetHz, 150_000, "the refused write changed nothing")

        await writes.stop()
        let summary = await writes.lastSummary
        let streamError = await writes.lastError
        XCTAssertNotNil(summary, "the stream ends with the daemon's summary: \(String(describing: streamError))")
        XCTAssertEqual(summary?.writesReceived, 2, "five offsets in a tick are one write, plus the refused one")
        _ = capture
    }

    func testFFTRowsDecodeAgainstTheAnsweredDescriptor() async throws {
        let app = try DaemonConnection(socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
        defer { app.close() }
        let presence = Task { for try await _ in app.events() {} }
        defer { presence.cancel() }
        let (capture, _) = try await Self.tuneFixture(app, on: daemon)

        let (descriptor, rows) = try await app.fft(capture: capture.captureID, bins: 256, rowsPerSecond: 10)
        XCTAssertEqual(descriptor.kind, .fft)
        XCTAssertEqual(descriptor.centerHz, 146_520_000)
        XCTAssertEqual(descriptor.spanHz, 2_400_000)
        XCTAssertEqual(descriptor.fft.binFormat, .dbU8)
        XCTAssertTrue(descriptor.grpc, "v0 answers every subscription with gRPC")

        var seen = 0
        for try await row in rows {
            XCTAssertEqual(row.levelsDB.count, Int(descriptor.fft.bins))
            XCTAssertEqual(row.time.captureID, capture.captureID, "every row carries the sample timebase")
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

    func testErrorCodesSurviveTheTrip() async throws {
        let app = try DaemonConnection(socketPath: daemon.socketPath, identity: .fresh(kind: "app", label: "test-app"))
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
        let app = try DaemonConnection(socketPath: "/tmp/ley-app-nobody-\(getpid()).sock", identity: .fresh(kind: "app", label: "test-app"))
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
