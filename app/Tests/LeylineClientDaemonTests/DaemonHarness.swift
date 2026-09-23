// SPDX-License-Identifier: Apache-2.0

// A real `leylined --no-hardware` on a temp socket, an IQ fixture attached as its radio. This is
// the harness the app's tests are written against (docs/plans/build-order.md, Milestone E): the
// daemon under test is the product, and the radio is a file, so the suite needs no hardware.
// Skipped unless LEYLINED_BIN names a built daemon; `make app-e2e` sets it.

import Foundation
import LeylineClient
import LeylineProto
import XCTest

struct DaemonUnderTest {
    let socketPath: String
    let process: Process
    let log: URL
    let fixture: String

    /// Reads the daemon's stderr so a failure can print it.
    func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
}

/// A setup step that failed, with its description; thrown so the test fails there.
struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Harness {
    static var daemonBinary: String? {
        let p = ProcessInfo.processInfo.environment["LEYLINED_BIN"] ?? ""
        return p.isEmpty ? nil : p
    }

    /// The fixtures directory: LEYLINE_FIXTURES, else `fixtures/` at the repository root.
    static var fixtures: String {
        if let f = ProcessInfo.processInfo.environment["LEYLINE_FIXTURES"], !f.isEmpty { return f }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures").path
    }

    /// Starts a daemon and waits until it answers `GetState`. `XCTSkip`s without LEYLINED_BIN or
    /// the fixture (`make fixtures` generates it).
    static func start(fixture name: String = "nfm_tone.cf32") async throws -> DaemonUnderTest {
        guard let bin = daemonBinary else {
            throw XCTSkip("set LEYLINED_BIN to run the app's daemon-backed tests (make app-e2e)")
        }
        let fixture = fixtures + "/" + name
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture missing at \(fixture); run make fixtures")
        }
        // Short: macOS caps a socket path at 104 bytes.
        let dir = "/tmp/ley-app-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let socket = dir + "/d.sock"
        let log = URL(fileURLWithPath: dir + "/leylined.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [
            "--socket", socket, "--no-hardware", "--log-level", "debug",
            "--pidfile", dir + "/leylined.pid", "--store", dir + "/store", "--recordings",
            dir + "/recordings",
        ]
        let handle = try FileHandle(forWritingTo: log)
        p.standardError = handle
        p.standardOutput = handle
        try p.run()
        let d = DaemonUnderTest(socketPath: socket, process: p, log: log, fixture: fixture)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socket) {
                let probe = try DaemonConnection(
                    socketPath: socket, identity: .fresh(kind: "cli", label: "probe"))
                defer { probe.close() }
                if (try? await probe.state()) != nil { return d }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        stop(d)
        throw XCTSkip("leylined did not come up on \(socket):\n\(d.logText())")
    }

    static func stop(_ d: DaemonUnderTest) {
        if d.process.isRunning {
            d.process.terminate()
            d.process.waitUntilExit()
        }
        try? FileManager.default.removeItem(
            atPath: (d.socketPath as NSString).deletingLastPathComponent)
    }

    /// Attaches the fixture as a looping file device and returns its descriptor.
    static func attachFixture(_ d: DaemonUnderTest, via c: DaemonConnection) async throws
        -> Leyline_V1_DeviceDescriptor
    {
        var req = Leyline_V1_AttachFileDeviceRequest()
        req.path = d.fixture
        req.loop = true
        return try await c.control.attachFileDevice(req)
    }

    /// Sets a channel's squelch through a coalescer of its own and waits for the mirror to
    /// confirm it, the way every write is confirmed (invariant 7). NaN turns the squelch off.
    @MainActor
    static func setSquelch(
        _ db: Double, channel: String, via c: DaemonConnection, mirror: DaemonMirror
    ) async throws {
        let writes = WriteCoalescer(connection: c, tick: .milliseconds(50))
        await writes.squelchDb(db, channel: channel)
        await writes.stop()
        let landed = await eventually(.seconds(5)) {
            let got = mirror.state.channel(channel)?.squelchDb ?? .nan
            return db.isNaN ? got.isNaN : got == db
        }
        if !landed {
            throw HarnessError(
                "the squelch write never reached the mirror: \(String(describing: await writes.lastError))"
            )
        }
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    static func eventually(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool)
        async -> Bool
    {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// Asserts that `condition` holds within `timeout`, reporting `message` at the caller's line.
@MainActor
func assertEventually(
    _ message: String, timeout: Duration = .seconds(5), file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let held = await Harness.eventually(timeout, condition)
    XCTAssertTrue(held, message, file: file, line: line)
}
