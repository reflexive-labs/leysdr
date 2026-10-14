// SPDX-License-Identifier: GPL-3.0-or-later

// A program the daemon spawns with its three standard streams on pipes: the half a decoder plugin
// (`PluginProcess`) and a `ley` worker (`WorkerProcess`) share (docs/dev/engine-internals.md,
// "Decoders" and "Credentials and usage"). What goes over the pipes is the caller's; this file
// starts the child, reads its stderr a line at a time and stops it.
//
// Nothing here runs on the DSP thread (invariant 4): the stderr reader is a thread of its own that
// parks in `read(2)`.

import EngineCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Synchronization

/// One spawned child. Unchecked Sendable: the process and its pipes are set up in init and only
/// read afterwards, and the one mutable field is behind a Mutex.
final class ChildProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    /// The child's exit status, once.
    let exits: AsyncStream<Int32>
    private let exitContinuation: AsyncStream<Int32>.Continuation
    /// The last line the child wrote on stderr, and whether stderr has closed.
    private let stderrState = Mutex<(last: String?, closed: Bool)>((nil, false))

    /// `environment` nil inherits the daemon's.
    init(executable: String, args: [String], directory: String? = nil, environment: [String: String]? = nil) {
        (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    /// Starts the child. `onErrorLine` sees each line it writes on stderr, on the reader's thread.
    /// Throws what `Process.run` throws when the program cannot be started.
    func run(onErrorLine: @escaping @Sendable (String) -> Void) throws {
        // A write to a pipe whose reader died must be an error return, never a process-killing
        // signal. The daemon's main does this too; a test hosting the daemon in-process does not.
        signal(SIGPIPE, SIG_IGN)
        let continuation = exitContinuation
        process.terminationHandler = { p in
            continuation.yield(p.terminationStatus)
            continuation.finish()
        }
        do {
            try process.run()
        } catch {
            exitContinuation.finish()
            throw error
        }
        readErrorLines(onErrorLine)
    }

    /// The last line the child wrote on stderr, after waiting up to `seconds` for stderr to close:
    /// the exit status can arrive before the reader has seen the line written just before it.
    func lastErrorLine(waitingSeconds seconds: Double = 1) async -> String? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline, !stderrState.withLock({ $0.closed }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return stderrState.withLock { $0.last }
    }

    private func readErrorLines(_ onLine: @escaping @Sendable (String) -> Void) {
        let errFD = errors.fileHandleForReading.fileDescriptor
        // The thread holds the child until its stderr closes, which is no longer than the child.
        Thread.detachNewThread { [self] in
            var line = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            func finishLine() {
                guard !line.isEmpty else { return }
                let text = String(decoding: line, as: UTF8.self)
                stderrState.withLock { $0.last = text }
                onLine(text)
                line.removeAll(keepingCapacity: true)
            }
            while true {
                let got = chunk.withUnsafeMutableBytes { read(errFD, $0.baseAddress, 4096) }
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { break }
                for b in chunk[0..<got] {
                    if b == UInt8(ascii: "\n") { finishLine() } else { line.append(b) }
                }
            }
            finishLine()
            stderrState.withLock { $0.closed = true }
        }
    }

    /// Asks the child to go and then makes it: `SIGTERM`, a second to exit, then `SIGKILL`. The
    /// caller closes stdin and gives the child its own grace first, when it has one to give.
    func terminate() async {
        if process.isRunning { process.terminate() }
        if await waitForExit(seconds: 1) { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        _ = await waitForExit(seconds: 1)
    }

    /// True once the child has exited, false if it is still running after `seconds`.
    func waitForExit(seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !process.isRunning
    }
}
