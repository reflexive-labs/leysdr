// `leylined` entry point.

import ArgumentParser
import EngineCore
import Foundation
import Logging

/// Default UDS path: `~/Library/Application Support/Leyline/leyline.sock` on macOS, else
/// `$XDG_RUNTIME_DIR/leyline.sock` or `/tmp/leyline-<uid>.sock`. `LEYLINE_SOCKET` overrides.
func defaultSocketPath() -> String {
    if let env = ProcessInfo.processInfo.environment["LEYLINE_SOCKET"], !env.isEmpty { return env }
    #if os(macOS)
    return NSHomeDirectory() + "/Library/Application Support/Leyline/leyline.sock"
    #else
    if let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !dir.isEmpty { return dir + "/leyline.sock" }
    return NSTemporaryDirectory().hasSuffix("/") ? "\(NSTemporaryDirectory())leyline-\(getuid()).sock" : "\(NSTemporaryDirectory())/leyline-\(getuid()).sock"
    #endif
}

@main
struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leylined",
        abstract: "Leyline SDR engine daemon: owns the radios, serves leyline.v1 over a Unix socket.",
        version: leylinedVersion
    )

    @Option(help: "Unix socket path (env LEYLINE_SOCKET; platform default otherwise).")
    var socket: String = defaultSocketPath()

    @Option(help: "Pidfile path (default: leylined.pid beside the socket).")
    var pidfile: String?

    @Option(name: .customLong("log-level"), help: "trace|debug|info|notice|warning|error|critical")
    var logLevel: String = "info"

    @Option(name: .customLong("poll-ms"), help: "Hot-plug enumeration period in milliseconds.")
    var pollMs: Int = 1000

    @Option(name: .customLong("rtltcp"), help: "Remote dongle served by rtl_tcp, as host:port, for foreground runs (repeatable; env LEYLINE_RTLTCP, comma-separated). A radio the daemon should keep is attached over the protocol instead, with `ley devices attach`.")
    var rtltcp: [String] = []

    func run() async throws {
        let level = Logger.Level(rawValue: logLevel) ?? .info
        LoggingSystem.bootstrap { label in
            var h = StreamLogHandler.standardError(label: label)
            h.logLevel = level
            return h
        }
        let pid = pidfile ?? (URL(fileURLWithPath: socket).deletingLastPathComponent().path + "/leylined.pid")
        let remotes = try Daemon.parseRTLTCPEndpoints(rtltcp + rtltcpEndpointsFromEnvironment())
        let daemon = Daemon(config: .init(socketPath: socket, pidfile: pid, pollMs: pollMs, rtltcp: remotes))
        // A write to a socket whose peer vanished (rtl_tcp dying mid-command) must be an error
        // return, never a process-killing SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let signals = SignalWatcher([SIGTERM, SIGINT])
        do {
            try await serveUntilStopped(
                serve: { try await daemon.run() },
                stopRequested: { await signals.wait() },
                teardown: { await daemon.shutdown() }
            )
        } catch let e as EngineError where e.code == EngineError.Code.socketInUse {
            FileHandle.standardError.write(Data("leylined: \(e.message)\n".utf8))
            throw ExitCode(2)
        }
    }
}

/// Serves until `stopRequested` resolves, then tears the daemon down; returns early, propagating the
/// error, if serving stops on its own.
///
/// `teardown` runs here rather than inside the child that waits for the stop, because teardown
/// closes the listener first: `serve` returns within milliseconds while captures, leases and
/// devices are still being handed back, and a task group cancelled at that moment would cut the
/// rest of the teardown short. Split from the command so tests can drive the same shape.
func serveUntilStopped(
    serve: @escaping @Sendable () async throws -> Void,
    stopRequested: @escaping @Sendable () async -> Void,
    teardown: @escaping @Sendable () async -> Void
) async throws {
    enum Stop { case served, stopped }
    try await withThrowingTaskGroup(of: Stop.self) { group in
        group.addTask { try await serve(); return .served }
        group.addTask { await stopRequested(); return .stopped }
        if try await group.next() == .stopped { await teardown() }
        // Whichever watcher is still parked -- the signal wait, or a serve that outlives its
        // listener -- has nothing left to report.
        group.cancelAll()
    }
}

/// `LEYLINE_RTLTCP=host:port[,host:port...]` — appended to the `--rtltcp` flags.
func rtltcpEndpointsFromEnvironment() -> [String] {
    guard let env = ProcessInfo.processInfo.environment["LEYLINE_RTLTCP"], !env.isEmpty else { return [] }
    return env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Resolves once any of the given signals arrives.
final class SignalWatcher: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]
    private let stream: AsyncStream<Void>

    init(_ signals: [Int32]) {
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        sources = signals.map { sig in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { cont.yield(()) }
            src.resume()
            return src
        }
    }

    func wait() async {
        for await _ in stream { return }
    }
}
