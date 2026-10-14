// SPDX-License-Identifier: GPL-3.0-or-later

// In-process daemon on a temp UDS, driven by the generated Swift client.

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import LeylineServer
import LeylineProto
import Logging
import Synchronization
import XCTest

/// Identity the tests send on every RPC.
let testClientID = "cli_" + ULID().string
let testMetadata: Metadata = [
    "leyline-client-id": .string(testClientID),
    "leyline-client-kind": .string("cli"),
    "leyline-client-label": .string("xctest"),
]

/// Path to a generated fixture (`leyfix generate` if absent).
func fixturePath(_ name: String) -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent("fixtures/\(name)").path
}

struct DaemonClients {
    let control: Leyline_V1_Control.Client<HTTP2ClientTransport.Posix>
    let decoders: Leyline_V1_Decoders.Client<HTTP2ClientTransport.Posix>
    let telemetry: Leyline_V1_Telemetry.Client<HTTP2ClientTransport.Posix>
    let bulk: Leyline_V1_Bulk.Client<HTTP2ClientTransport.Posix>
    let jobs: Leyline_V1_Jobs.Client<HTTP2ClientTransport.Posix>
    let resources: Leyline_V1_Resources.Client<HTTP2ClientTransport.Posix>
    let credentials: Leyline_V1_Credentials.Client<HTTP2ClientTransport.Posix>
    let daemon: Daemon
    /// The daemon's data directory: `ai.json`, and `credentials.json` for the test's file store.
    let dataPath: String
    let socketPath: String
}

/// The version every test daemon reports in `DaemonInfo`.
let testDaemonVersion = "0.0.0-test"

/// Boots a daemon on a temp socket, runs `body` with connected clients, then shuts down.
/// `shutdownDeadlineNs` puts a watchdog on the teardown: tests about handlers ending on cancellation
/// need shutdown to be prompt, and a hung handler shows up here rather than as a stalled suite.
/// `dir` runs the daemon in a directory the caller owns and keeps -- what a daemon leaves beside
/// its socket (the remembered device list) is then still there for the next one. `rtltcp` is the
/// daemon's own `--rtltcp` command line.
func withDaemon(dir: String? = nil, presenceGraceNs: UInt64 = 5_000_000_000, shutdownDeadlineNs: UInt64? = nil,
                rtltcp: [Daemon.RTLTCPEndpoint] = [],
                decoderSearchPath: [String]? = nil, storePath: String? = nil,
                recordingsPath: String? = nil, recordingsCapBytes: UInt64 = 20 << 30,
                leyPath: String? = nil,
                _ body: @escaping @Sendable (DaemonClients) async throws -> Void) async throws {
    // Every logger the daemon makes goes through the capture's handler, so a test can read the log.
    _ = LogCapture.shared
    let caller = dir
    let dir = caller ?? (NSTemporaryDirectory() + "leyline-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { if caller == nil { try? FileManager.default.removeItem(atPath: dir) } }
    let socket = dir + "/d.sock"
    // A test never looks at the host's own plugin directory or writes to its store: both
    // default to somewhere inside the temp directory the daemon is running in.
    // Keys go to a file in the test's own data directory, never the Mac's keychain.
    var config = Daemon.Config(socketPath: socket, pidfile: dir + "/leylined.pid", pollMs: 100_000,
                               presenceGraceNs: presenceGraceNs, rtltcp: rtltcp,
                               decoderSearchPath: decoderSearchPath ?? [dir + "/decoders"],
                               storePath: storePath ?? (dir + "/store"),
                               recordingsPath: recordingsPath ?? (dir + "/recordings"),
                               recordingsCapBytes: recordingsCapBytes, dataPath: dir + "/data",
                               version: testDaemonVersion)
    config.secretStore = FileSecrets(path: dir + "/data/credentials.json")
    // `ley` is whatever the test names and nothing else: never one on the machine's PATH.
    config.leyPath = leyPath
    config.programLocator = ProgramLocator(directories: [], searchPath: [])
    let daemon = Daemon(config: config)
    let serverTask = Task { try await daemon.run() }
    let listening = await daemon.waitUntilListening()
    XCTAssertTrue(listening, "daemon did not start listening")
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/leylined.pid"))
    var bodyError: (any Error)?
    do {
        try await withGRPCClient(
            transport: try .http2NIOPosix(target: .unixDomainSocket(path: socket), transportSecurity: .plaintext)
        ) { client in
            let clients = DaemonClients(
                control: .init(wrapping: client), decoders: .init(wrapping: client), telemetry: .init(wrapping: client),
                bulk: .init(wrapping: client), jobs: .init(wrapping: client), resources: .init(wrapping: client),
                credentials: .init(wrapping: client), daemon: daemon, dataPath: dir + "/data", socketPath: socket
            )
            do { try await body(clients) } catch { bodyError = error }
        }
    } catch {
        if bodyError == nil { bodyError = error }
    }
    let teardownStart = DispatchTime.now().uptimeNanoseconds
    if let deadline = shutdownDeadlineNs {
        // The shutdown runs unstructured and reports through a stream. A task group would wait for
        // every child at scope exit, and `shutdown()` does not answer cancellation, so a watchdog
        // child inside the group could never outrun the hang it is here to catch.
        let (finished, finishedContinuation) = AsyncStream<Void>.makeStream()
        Task {
            await daemon.shutdown()
            _ = try? await serverTask.value
            finishedContinuation.finish()
        }
        let stopped = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in finished {}; return !Task.isCancelled }
            group.addTask { try? await Task.sleep(nanoseconds: deadline); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard stopped else {
            XCTFail("daemon.shutdown() did not finish within \(Double(deadline) / 1e9) s (a handler is still alive)")
            if let e = bodyError { throw e }
            return
        }
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - teardownStart, deadline)
    } else {
        await daemon.shutdown()
        _ = try? await serverTask.value
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "socket not unlinked on shutdown")
    if let e = bodyError { throw e }
}

/// Collects WatchEvents into an array; `stop()` cancels the RPC.
actor EventCollector {
    private(set) var events: [Leyline_V1_Event] = []
    private var task: Task<Void, Never>?

    func append(_ e: Leyline_V1_Event) { events.append(e) }
    func setTask(_ t: Task<Void, Never>) { task = t }

    func stop() { task?.cancel() }

    /// Starts watching and returns once the daemon holds the subscription, so anything a test changes
    /// afterwards is guaranteed to reach this collector. Response headers only say the client reached
    /// the service, which is a weaker guarantee than the store having the subscriber.
    static func start(_ control: Leyline_V1_Control.Client<HTTP2ClientTransport.Posix>, daemon: Daemon) async -> EventCollector {
        let before = await daemon.store.subscriberCount
        let c = EventCollector()
        let t = Task {
            var scope = Leyline_V1_EventScope()
            scope.daemon = true
            try? await control.watchEvents(scope, metadata: testMetadata) { response in
                for try await ev in response.messages { await c.append(ev) }
            }
        }
        await c.setTask(t)
        for _ in 0..<1000 {
            if await daemon.store.subscriberCount > before { return c }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("watch subscription never registered with the store")
        return c
    }

    /// Polls until an event matching `pred` arrives (timeout in ms).
    func waitFor(timeoutMs: Int = 3000, _ pred: (Leyline_V1_Event) -> Bool) async -> Leyline_V1_Event? {
        for _ in 0..<(timeoutMs / 20) {
            if let e = events.first(where: pred) { return e }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return events.first(where: pred)
    }
}

/// The stable engine code from a failed RPC (status message "CODE: ..." plus the trailer).
func errorCode(_ error: any Error) -> (code: String, trailer: Leyline_V1_ErrorDetail?) {
    guard let rpc = error as? RPCError else { return ("", nil) }
    let code = rpc.message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    var detail: Leyline_V1_ErrorDetail?
    for bytes in rpc.metadata[binaryValues: "leyline-error-bin"] {
        detail = try? Leyline_V1_ErrorDetail(serializedBytes: bytes)
    }
    return (code, detail)
}

/// The devices a test created. A developer's Mac may have a real dongle plugged in while the suite
/// runs; every registry poll enumerates it, so assertions about "the" device list must ignore it.
func testDevices(_ devices: [Leyline_V1_DeviceDescriptor]) -> [Leyline_V1_DeviceDescriptor] {
    devices.filter { $0.driver != "rtlsdr" }
}

func testDevices(_ devices: [DeviceDescriptor]) -> [DeviceDescriptor] {
    devices.filter { $0.driver != "rtlsdr" }
}

// MARK: Decoders

/// Where SwiftPM put the test bundle, which is also where it puts the package's executables.
var productsDirectory: URL {
    #if os(macOS)
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
    }
    #endif
    return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
}

/// The fake decoder SwiftPM builds from the `leyline-fake-decoder` executable target.
func fakeDecoderPath() -> String {
    productsDirectory.appendingPathComponent("leyline-fake-decoder").path
}

/// Writes a plugin directory: `<dir>/<name>/manifest.json` naming the fake decoder by absolute
/// path, so the registry resolves it without a PATH of our own.
@discardableResult
func writeFakePlugin(in dir: String, name: String = "fake", executable: String? = nil,
                     recipe: (frequencyHz: UInt64, bandwidthHz: UInt32)? = (146_000_000, 15_000),
                     signal: Leyline_V1_DecoderSignal = .signalAudio,
                     args: [String] = [], credentialProvider: String = "", json: String? = nil) throws -> String
{
    let pluginDir = dir + "/" + name
    try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
    let body: String
    if let json {
        body = json
    } else {
        let freq = recipe?.frequencyHz ?? 146_000_000
        let bw = recipe?.bandwidthHz ?? 15_000
        // SIGNAL_IQ makes the daemon stream the capture's raw cf32 rather than a channel's audio
        // (docs/design/decoders.md, "Multiplexing"). The fake decoder is signal-agnostic: it emits
        // one record per frame either way.
        let signalName = signal == .signalIq ? "SIGNAL_IQ" : "SIGNAL_AUDIO"
        body = """
        {
          "name": "\(name)",
          "version": "0.1.0",
          "description": "decodes nothing, for tests",
          "recipe": {"frequenciesHz": ["\(freq)"], "bandwidthHz": \(bw), "mode": "NFM", "gain": "GAIN_LEAVE"},
          "input": {"mode": "CONTINUOUS", "tap": "TAP_AUDIO", "signal": "\(signalName)"},
          "outputs": ["SHAPE_RECORDS"],
          "entitySilenceS": 1800,
          "credentialProvider": "\(credentialProvider)",
          "executable": "\(executable ?? fakeDecoderPath())",
          "args": [\(args.map { "\"\($0)\"" }.joined(separator: ", "))]
        }
        """
    }
    try body.write(toFile: pluginDir + "/manifest.json", atomically: true, encoding: .utf8)
    return pluginDir
}

/// A temp directory the caller owns for the length of one test.
func makeTempDir(_ tag: String) throws -> String {
    let dir = NSTemporaryDirectory() + "leyline-\(tag)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: Workers

/// Writes `<dir>/ley`, a shell script standing in for `ley worker check`: `body` runs with the
/// worker's arguments and its stdin, and whatever it prints is the worker's answer. The arguments
/// and the environment's socket are written to `<dir>/ley.args` so a test can see what the daemon
/// passed.
@discardableResult
func writeScriptedLey(in dir: String, _ body: String) throws -> String {
    let path = dir + "/ley"
    let script = """
    #!/bin/sh
    echo "$@" > "\(dir)/ley.args"
    echo "$LEYLINE_SOCKET" > "\(dir)/ley.socket"
    \(body)

    """
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

/// A worker that answers every check with `outcome` and the message `message`.
@discardableResult
func writeScriptedLey(in dir: String, outcome: String, message: String) throws -> String {
    try writeScriptedLey(in: dir, """
    read key
    printf '%s\\n' '{"outcome": "\(outcome)", "message": "\(message)"}'
    """)
}

// MARK: The daemon's log

/// Every line any `Logger` writes while `capture` runs, for tests that must show something never
/// reaches the log. swift-log takes one bootstrap per process, so the handler is installed on first
/// use and tees to standard output, which is where the default handler writes, so the suite's own
/// output is unchanged.
final class LogCapture: Sendable {
    private let state = Mutex<(on: Bool, lines: [String])>((false, []))

    static let shared: LogCapture = {
        let capture = LogCapture()
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([StreamLogHandler.standardOutput(label: label), CapturingLogHandler(label: label, capture: capture)])
        }
        return capture
    }()

    /// Runs `body` with capture on and returns what was logged meanwhile, as one text.
    func capture(_ body: () async throws -> Void) async rethrows -> String {
        state.withLock { $0 = (true, []) }
        defer { state.withLock { $0.on = false } }
        try await body()
        return state.withLock { $0.lines.joined(separator: "\n") }
    }

    fileprivate func append(_ line: String) {
        state.withLock { if $0.on { $0.lines.append(line) } }
    }
}

private struct CapturingLogHandler: LogHandler {
    let label: String
    let capture: LogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source _: String,
             file _: String, function _: String, line _: UInt)
    {
        capture.append("\(label) \(level) \(message) \(metadata ?? [:])")
    }
}
