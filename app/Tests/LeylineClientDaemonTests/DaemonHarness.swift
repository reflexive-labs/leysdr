// SPDX-License-Identifier: Apache-2.0

// A real `leylined --no-hardware` on a temp socket, an IQ fixture attached as its radio. This is
// the harness the app's tests are written against: the
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
    /// The test's deadline (`Harness.testDeadline`), cancelled by `Harness.stop`.
    let watchdog: Watchdog

    /// Reads the daemon's stderr so a failure can print it.
    func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
}

/// A test's deadline: after `Harness.testDeadline` it says so with the daemon's log and kills
/// the daemon, and 10 s later ends the test process if `Harness.stop` has still not been called,
/// so `make app-e2e` fails naming the test (the last `started` line) instead of hanging.
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    init(pid: Int32, log: URL, after seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            guard !isStopped else { return }
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let said = "the test did not finish in \(Int(seconds)) s; its daemon's log:\n\(text)"
            FileHandle.standardError.write(Data("DaemonHarness: \(said)\n".utf8))
            kill(pid, SIGKILL)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
                guard !isStopped else { return }
                let said = "DaemonHarness: the test is still stuck; exiting\n"
                FileHandle.standardError.write(Data(said.utf8))
                exit(1)
            }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    func stop() { lock.withLock { stopped = true } }
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

    /// Starts a daemon and waits until it answers `GetState`, with `arguments` after the
    /// harness's own (`--data` and `--ley` for the AI tests). `XCTSkip`s without LEYLINED_BIN or
    /// the fixture (`make fixtures` generates it).
    static func start(fixture name: String = "nfm_tone.cf32", arguments: [String] = [])
        async throws -> DaemonUnderTest
    {
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
        // Keys in a file under the daemon's own --data, never the login keychain or the
        // person's data directory, whatever this process's environment says; and --no-audio, so
        // a system-audio sink a test attaches is accepted and plays nothing through the Mac.
        let data = arguments.firstIndex(of: "--data").map { arguments[$0 + 1] } ?? dir + "/data"
        p.arguments =
            [
                "--socket", socket, "--no-hardware", "--log-level", "debug",
                "--pidfile", dir + "/leylined.pid", "--store", dir + "/store", "--recordings",
                dir + "/recordings", "--secrets", "file", "--no-audio",
            ] + (arguments.contains("--data") ? [] : ["--data", data]) + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LEYLINE_SECRETS"] = "file"
        p.environment = environment
        let handle = try FileHandle(forWritingTo: log)
        p.standardError = handle
        p.standardOutput = handle
        try p.run()
        let d = DaemonUnderTest(
            socketPath: socket, process: p, log: log, fixture: fixture,
            watchdog: Watchdog(pid: p.processIdentifier, log: log, after: testDeadline))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socket) {
                let probe: DaemonConnection
                do {
                    probe = try DaemonConnection(
                        socketPath: socket, identity: .fresh(kind: "cli", label: "probe"))
                } catch {
                    stop(d)
                    throw error
                }
                defer { probe.close() }
                if (try? await probe.state()) != nil {
                    try refuseKeychain(d, data: data)
                    return d
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        stop(d)
        throw XCTSkip("leylined did not come up on \(socket):\n\(d.logText())")
    }

    /// Stops the daemon and fails unless its last `AI keys in …` line, logged before it
    /// listens, names a file under `data`: a test daemon must never keep a key in the login
    /// keychain, where it would replace the person's own.
    static func refuseKeychain(_ d: DaemonUnderTest, data: String) throws {
        let log = d.logText()
        let line = log.range(of: "AI keys in ", options: .backwards).map {
            log[$0.upperBound...].prefix { $0 != "\n" }
        }
        guard let line, line.hasPrefix(data + "/") else {
            stop(d)
            throw HarnessError(
                "leylined keeps AI keys in \(line.map(String.init) ?? "a place it never named"), not under \(data):\n\(log)"
            )
        }
    }

    /// How long one test may hold its daemon. The longest takes about 7 s; a test still running
    /// at this point is waiting on something that will not come.
    static let testDeadline: TimeInterval = 120

    /// Stops the daemon: SIGTERM, then SIGKILL if it has not exited 10 s later.
    static func stop(_ d: DaemonUnderTest) {
        d.watchdog.stop()
        if d.process.isRunning {
            d.process.terminate()
            let end = Date().addingTimeInterval(10)
            while d.process.isRunning && Date() < end { usleep(20_000) }
            if d.process.isRunning {
                kill(d.process.processIdentifier, SIGKILL)
                d.process.waitUntilExit()
            }
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
    /// confirm it, the way every write is confirmed (invariant 7). NaN turns the squelch off;
    /// `auto` writes the level as one measured from the noise floor.
    @MainActor
    static func setSquelch(
        _ db: Double, auto: Bool = false, channel: String, via c: DaemonConnection,
        mirror: DaemonMirror
    ) async throws {
        let writes = WriteCoalescer(connection: c, tick: .milliseconds(50))
        if auto {
            writes.squelchAutoDb(db, channel: channel)
        } else {
            writes.squelchDb(db, channel: channel)
        }
        await writes.stop()
        let landed = await eventually(.seconds(5)) {
            let ch = mirror.state.channel(channel)
            let got = ch?.squelchDb ?? .nan
            guard db.isNaN ? got.isNaN : got == db else { return false }
            return !auto || ch?.squelchSource == .squelchAuto
        }
        if !landed {
            throw HarnessError(
                "the squelch write never reached the mirror: \(String(describing: writes.lastError))"
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
