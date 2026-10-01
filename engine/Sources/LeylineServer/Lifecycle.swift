// SPDX-License-Identifier: GPL-3.0-or-later

// What `leylined`'s entry point needs from the server library: default paths, the environment
// lists, the signal wait and the serve-then-teardown shape. Kept here, not in the executable, so
// the tests drive the same code.

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
