// SPDX-License-Identifier: GPL-3.0-or-later

// `leylined` entry point: argument parsing and logging setup. Everything it runs is in the
// LeylineServer library.

import ArgumentParser
import EngineCore
import Foundation
import LeylineServer
import Logging

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

    @Flag(name: .customLong("no-hardware"), help: "Never look for USB dongles: the daemon hosts only what is attached to it (file devices, rtl_tcp). For a daemon that must see nothing but its test radios, such as an eval's.")
    var noHardware = false

    @Option(name: .customLong("rtltcp"), help: "Remote dongle served by rtl_tcp, as host:port, for foreground runs (repeatable; env LEYLINE_RTLTCP, comma-separated). A radio the daemon should keep is attached over the protocol instead, with `ley devices attach`.")
    var rtltcp: [String] = []

    @Option(help: "Directory of decoder plugins (repeatable; env LEYLINE_DECODERS, colon-separated). The platform default is searched next, then a decoders directory beside leylined.")
    var decoders: [String] = []

    @Option(help: "Where kept decode records are written (platform default otherwise).")
    var store: String = defaultStorePath()

    @Option(name: .customLong("store-cap"), help: "Record store size cap in bytes; the oldest jobs go when it is exceeded.")
    var storeCap: UInt64 = 2 << 30

    @Option(name: .customLong("store-age"), help: "Days a kept job's records are held before they are dropped.")
    var storeAge: UInt32 = 90

    @Option(help: "Where recordings are written (platform default otherwise).")
    var recordings: String = defaultRecordingsPath()

    @Option(name: .customLong("recordings-cap"), help: "Recordings store size cap in bytes; the oldest finished recordings go when it is exceeded, and a running one is never dropped.")
    var recordingsCap: UInt64 = 20 << 30

    @Option(name: .customLong("recordings-age"), help: "Days a recording is held before it is dropped; 0 keeps them until the cap does.")
    var recordingsAge: UInt32 = 0

    @Option(name: .customLong("log-file"), help: "Append standard output and error to this file, creating it and its directory; a leading ~/ is the home directory. For a launch agent that cannot redirect them itself.")
    var logFile: String?

    @Option(name: .customLong("wall-clock"), help: "Development: shift the wall clock captures, recordings and records are dated from so the daemon starts at HH:MM local time today, for staged screenshots. Retention still runs on the real clock.")
    var wallClock: String?

    func run() async throws {
        if let logFile {
            do {
                try appendOutput(toLogFile: logFile)
            } catch {
                FileHandle.standardError.write(Data("leylined: \(error).\n".utf8))
                throw ExitCode(2)
            }
            // A file is fully buffered by default; a log line must reach it when it is written.
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        if let wallClock {
            do {
                let (hour, minute) = try WallClock.parseClockTime(wallClock)
                WallClock.setOffsetNs(WallClock.offsetNs(toHour: hour, minute: minute, now: Date()))
            } catch let e as EngineError {
                FileHandle.standardError.write(Data("leylined: \(e.message).\n".utf8))
                throw ExitCode(2)
            }
        }
        let level = Logger.Level(rawValue: logLevel) ?? .info
        LoggingSystem.bootstrap { label in
            var h = StreamLogHandler.standardError(label: label)
            h.logLevel = level
            return h
        }
        if let wallClock {
            Logger(label: "leyline.daemon").notice("wall clock set to \(wallClock) today: dates are shifted by \(WallClock.offsetNs / 1_000_000_000) s; retention uses the real clock")
        }
        let pid = pidfile ?? (URL(fileURLWithPath: socket).deletingLastPathComponent().path + "/leylined.pid")
        let remotes = try Daemon.parseRTLTCPEndpoints(rtltcp + rtltcpEndpointsFromEnvironment())
        let searchPath = decoderSearchPath(configured: decoders)
        let daemon = Daemon(config: .init(socketPath: socket, pidfile: pid, pollMs: pollMs, enumerateHardware: !noHardware, rtltcp: remotes,
                                          decoderSearchPath: searchPath, storePath: store,
                                          storeCapBytes: storeCap, storeAgeDays: storeAge,
                                          recordingsPath: recordings, recordingsCapBytes: recordingsCap,
                                          recordingsAgeDays: recordingsAge, version: leylinedVersion))
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
