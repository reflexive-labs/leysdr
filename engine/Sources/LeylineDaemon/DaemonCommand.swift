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

    func run() async throws {
        let level = Logger.Level(rawValue: logLevel) ?? .info
        LoggingSystem.bootstrap { label in
            var h = StreamLogHandler.standardError(label: label)
            h.logLevel = level
            return h
        }
        let pid = pidfile ?? (URL(fileURLWithPath: socket).deletingLastPathComponent().path + "/leylined.pid")
        let daemon = Daemon(config: .init(socketPath: socket, pidfile: pid, pollMs: pollMs))
        let signals = SignalWatcher([SIGTERM, SIGINT])
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await daemon.run() }
                group.addTask {
                    await signals.wait()
                    await daemon.shutdown()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch let e as EngineError where e.code == "SOCKET_IN_USE" {
            FileHandle.standardError.write(Data("leylined: \(e.message)\n".utf8))
            throw ExitCode(2)
        }
    }
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
