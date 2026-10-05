// SPDX-License-Identifier: GPL-3.0-or-later

// What `leylined`'s entry point needs from the server library: default paths, the environment
// lists, the log file, the signal wait and the serve-then-teardown shape. Kept here, not in the
// executable, so the tests drive the same code.

import Foundation

/// Default UDS path: `~/Library/Application Support/Leyline/leyline.sock` on macOS, else
/// `$XDG_RUNTIME_DIR/leyline.sock` or `/tmp/leyline-<uid>.sock`. `LEYLINE_SOCKET` overrides.
package func defaultSocketPath() -> String {
    if let env = ProcessInfo.processInfo.environment["LEYLINE_SOCKET"], !env.isEmpty { return env }
    #if os(macOS)
    return NSHomeDirectory() + "/Library/Application Support/Leyline/leyline.sock"
    #else
    if let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !dir.isEmpty { return dir + "/leyline.sock" }
    return NSTemporaryDirectory().hasSuffix("/") ? "\(NSTemporaryDirectory())leyline-\(getuid()).sock" : "\(NSTemporaryDirectory())/leyline-\(getuid()).sock"
    #endif
}

/// Where decoder plugins live when nothing says otherwise: `~/Library/Application
/// Support/Leyline/decoders` on macOS, `$XDG_DATA_HOME/leyline/decoders` (or
/// `~/.local/share/leyline/decoders`) elsewhere (docs/design/decoders.md, "Decisions").
package func defaultDecodersPath() -> String { defaultDataPath("decoders") }

/// Where the daemon looks for decoder plugins, in order: the `--decoders` flags, `LEYLINE_DECODERS`,
/// the platform default, then the `decoders` directory beside the executable. The last is how
/// the plugins a distributed build carries in `Contents/Helpers/decoders` work without being
/// copied out; it comes after the default so a plugin the user installed shadows the bundled one
/// (docs/design/decoders.md, "Decisions").
package func decoderSearchPath(configured: [String], executablePath: String? = currentExecutablePath()) -> [String] {
    var path = configured + decoderPathsFromEnvironment() + [defaultDecodersPath()]
    if let executablePath {
        path.append(URL(fileURLWithPath: executablePath).deletingLastPathComponent().appendingPathComponent("decoders").path)
    }
    return path
}

/// The running executable's path with every symlink resolved, so a `leylined` reached through a
/// link still finds what sits beside the real file. `argv[0]` is no help: launchd passes the
/// plist's first `ProgramArguments` entry, a bare name.
package func currentExecutablePath() -> String? {
    #if canImport(Darwin)
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    let raw = String(cString: buffer)
    #else
    let raw = "/proc/self/exe"
    #endif
    guard let resolved = realpath(raw, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A leading `~/` replaced by the home directory. launchd does not expand `~` in
/// `ProgramArguments`, and the launch agent the app registers passes `--log-file
/// ~/Library/Logs/Leyline/leylined.log`, so the daemon expands it itself.
package func expandingTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
    guard path.hasPrefix("~/") else { return path }
    return (home.hasSuffix("/") ? String(home.dropLast()) : home) + path.dropFirst()
}

/// Why `--log-file` could not be opened.
package struct LogFileError: Error, CustomStringConvertible {
    package let path: String
    package let reason: String
    package var description: String { "cannot write the log file \(path): \(reason)" }
}

/// Points `descriptors` (standard output and error, unless a test passes its own) at `path`,
/// opened for appending and created with its parent directory if absent, so a daemon launchd
/// starts without `StandardOutPath` still logs where `ley daemon logs` looks. Appending keeps
/// what earlier runs wrote, as launchd's own redirection does.
package func appendOutput(toLogFile path: String, descriptors: [Int32] = [STDOUT_FILENO, STDERR_FILENO]) throws {
    let expanded = expandingTilde(path)
    let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
        throw LogFileError(path: expanded, reason: "cannot create \(parent.path)")
    }
    let fd = open(expanded, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw LogFileError(path: expanded, reason: String(cString: strerror(errno))) }
    defer { close(fd) }
    for target in descriptors where dup2(fd, target) < 0 {
        throw LogFileError(path: expanded, reason: String(cString: strerror(errno)))
    }
}

/// Where kept records live when nothing says otherwise, by the same rule.
package func defaultStorePath() -> String { defaultDataPath("store") }

/// Where recordings live when nothing says otherwise: a plain directory Finder can open and
/// Spotlight can index, beside the kept-records store (docs/design/recording.md, "Files").
package func defaultRecordingsPath() -> String { defaultDataPath("recordings") }

private func defaultDataPath(_ leaf: String) -> String {
    #if os(macOS)
    return NSHomeDirectory() + "/Library/Application Support/Leyline/" + leaf
    #else
    if let dir = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !dir.isEmpty {
        return dir + "/leyline/" + leaf
    }
    return NSHomeDirectory() + "/.local/share/leyline/" + leaf
    #endif
}

/// `LEYLINE_DECODERS=dir[:dir...]` — appended to the `--decoders` flags, ahead of the default.
package func decoderPathsFromEnvironment() -> [String] {
    guard let env = ProcessInfo.processInfo.environment["LEYLINE_DECODERS"], !env.isEmpty else { return [] }
    return env.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Serves until `stopRequested` resolves, then tears the daemon down; returns early, propagating the
/// error, if serving stops on its own.
///
/// `teardown` runs here rather than inside the child that waits for the stop, because teardown
/// closes the listener first: `serve` returns within milliseconds while captures, leases and
/// devices are still being handed back, and a task group cancelled at that moment would cut the
/// rest of the teardown short. Split from the command so tests can drive the same shape.
package func serveUntilStopped(
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
package func rtltcpEndpointsFromEnvironment() -> [String] {
    guard let env = ProcessInfo.processInfo.environment["LEYLINE_RTLTCP"], !env.isEmpty else { return [] }
    return env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Resolves once any of the given signals arrives.
/// Unchecked Sendable: `sources` only keeps the signal handlers alive and is never touched after init.
package final class SignalWatcher: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]
    private let stream: AsyncStream<Void>

    package init(_ signals: [Int32]) {
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

    package func wait() async {
        for await _ in stream { return }
    }
}
