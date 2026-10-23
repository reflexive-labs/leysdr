// SPDX-License-Identifier: GPL-3.0-or-later

// One running `ley worker assistant`: the child the daemon spawns for a conversation and talks to
// over its stdio for the conversation's whole life (docs/dev/engine-internals.md, "Assistant").
// The check worker answers once and exits; this one is long-lived, so both directions are
// varint-delimited protobuf, framed as a decoder plugin's are (`PluginProcess`): the key and
// `WorkerEvent`s in, `WorkerMessage`s out.
//
// Nothing here runs on the DSP thread (invariant 4). Writes go through a serial queue of the
// worker's own, so the conversation store never waits on a pipe: one worker that stops reading
// costs its own conversation, after a deadline, and no other. A reader thread parks in `read(2)`
// on the worker's stdout.

import EngineCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import LeylineProto
import Logging
import SwiftProtobuf
import Synchronization

/// Unchecked Sendable: the child and its pipes are set up in init and only read afterwards; the
/// write descriptor is behind a Mutex and the flags are atomic.
final class AssistantWorker: @unchecked Sendable {
    /// How long a write may wait for the worker to make room before it counts as not reading.
    static let writeDeadlineSeconds: Double = 2
    /// How long a worker whose stdin has closed gets to exit before it is asked, then made, to go.
    static let exitGraceSeconds: Double = 2

    private let child: ChildProcess
    /// The write end of stdin as a raw descriptor, nil once closed: cached for the reason
    /// `PluginProcess.writeFD` gives (NSFileHandle raises on a closed handle).
    private let writeFD = Mutex<Int32?>(nil)
    /// Set by `stop` before it takes the lock, so a write waiting for room gives up at once.
    private let closing = Atomic<Bool>(false)
    /// Set by the first write that fails; every write after it is dropped.
    private let failed = Atomic<Bool>(false)
    /// Writes in the order `send` was called, off the caller's thread.
    private let writes = DispatchQueue(label: "leyline.assistant.writes")
    private let onWriteFailure: @Sendable (EngineError) -> Void
    private let messagesContinuation: AsyncStream<Leyline_V1_WorkerMessage>.Continuation

    /// What the worker wrote, in order. Finishes when its stdout closes.
    let messages: AsyncStream<Leyline_V1_WorkerMessage>
    /// The worker's exit status, once.
    var exits: AsyncStream<Int32> { child.exits }

    /// `onWriteFailure` hears, once, that a write did not reach the worker: its stdin closed, or it
    /// took nothing for `writeDeadlineSeconds`. It is called on the write queue.
    init(executable: String, args: [String], environment: [String: String],
         onWriteFailure: @escaping @Sendable (EngineError) -> Void)
    {
        self.onWriteFailure = onWriteFailure
        child = ChildProcess(executable: executable, args: args, environment: environment)
        (messages, messagesContinuation) = AsyncStream<Leyline_V1_WorkerMessage>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts the child, logging its stderr through `log` with `secret` replaced, and starts the
    /// reader. Throws what `Process.run` throws.
    func run(log: Logger, secret: String) throws {
        do {
            try child.run { log.info("\(WorkerProcess.redacting(secret, in: $0))") }
        } catch {
            messagesContinuation.finish()
            throw error
        }
        let wfd = child.input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(wfd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(wfd, F_SETFL, flags | O_NONBLOCK) }
        writeFD.withLock { $0 = wfd }
        startReader()
    }

    /// Queues one message for the worker and returns at once. Messages reach the worker in the
    /// order they were sent; a write that fails is reported through `onWriteFailure` and the
    /// messages after it are dropped.
    func send(_ message: any Message) {
        let bytes: [UInt8]
        do {
            bytes = try delimitedBytes(message)
        } catch {
            fail(.internalError("a message for the assistant could not be encoded (\(error))"))
            return
        }
        writes.async { [self] in
            guard !failed.load(ordering: .acquiring) else { return }
            do {
                try write(bytes)
            } catch let error as EngineError {
                fail(error)
            } catch {
                fail(Self.notReading("\(error)"))
            }
        }
    }

    /// Closes stdin, which tells the worker the conversation is over, gives it
    /// `exitGraceSeconds` to go, then `SIGTERM` and `SIGKILL` (`ChildProcess.terminate`).
    func stop() async {
        closing.store(true, ordering: .releasing)
        let open = writeFD.withLock { fd -> Bool in
            defer { fd = nil }
            return fd != nil
        }
        if open { try? child.input.fileHandleForWriting.close() }
        if await child.waitForExit(seconds: Self.exitGraceSeconds) { return }
        await child.terminate()
    }

    private func fail(_ error: EngineError) {
        guard !failed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        // A write cut short by `stop` is the end of the conversation, not a fault to report.
        guard !closing.load(ordering: .acquiring) else { return }
        onWriteFailure(error)
    }

    /// Writes `bytes` whole, waiting up to `writeDeadlineSeconds` for room. The lock covers one
    /// non-blocking write at a time and never the wait between them, so `stop` is never held up.
    private func write(_ bytes: [UInt8]) throws {
        var offset = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.writeDeadlineSeconds))
        while offset < bytes.count {
            let attempt = writeFD.withLock { fd -> (fd: Int32, written: Int, error: Int32)? in
                guard let fd, !closing.load(ordering: .acquiring) else { return nil }
                let n = bytes.withUnsafeBytes { raw in rawWrite(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
                return (fd, n, n < 0 ? errno : 0)
            }
            guard let attempt else { throw Self.notReading("its input is closed") }
            if attempt.written > 0 { offset += attempt.written; continue }
            if attempt.error == EINTR { continue }
            guard attempt.error == EAGAIN || attempt.error == EWOULDBLOCK else {
                throw Self.notReading(String(cString: strerror(attempt.error)))
            }
            guard ContinuousClock.now < deadline else {
                throw Self.notReading("it took nothing for \(Int(Self.writeDeadlineSeconds)) s")
            }
            // The descriptor may be closed under the poll; that only ends the wait early.
            var pfd = pollfd(fd: attempt.fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 50)
        }
    }

    var isRunning: Bool { child.process.isRunning }
    var processIdentifier: Int32 { child.process.processIdentifier }

    private func startReader() {
        let outFD = child.output.fileHandleForReading.fileDescriptor
        let continuation = messagesContinuation
        Thread.detachNewThread {
            let reader = DelimitedReader(fd: outFD)
            while let bytes = reader.next() {
                guard let message = try? Leyline_V1_WorkerMessage(serializedBytes: bytes) else { continue }
                continuation.yield(message)
            }
            continuation.finish()
        }
    }

    private static func notReading(_ why: String) -> EngineError {
        .internalError("the assistant is not reading its input (\(why))")
    }
}

/// `write(2)`, under a name `AssistantWorker` does not shadow with its own `write(_:)`.
private func rawWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, bytes, count)
}

extension WorkerProcess {
    /// Spawns `ley worker assistant --conversation <id>` with `LEYLINE_SOCKET` and
    /// `LEYLINE_KEY_ON_STDIN=1`, and queues the key then `WorkerStart`, in that order, before
    /// anything else. Throws `PROVIDER_UNAVAILABLE` when there is no `ley` or it cannot be started;
    /// a worker that does not read what it is sent is reported through `onWriteFailure`.
    func startAssistant(credential: Leyline_V1_SetCredentialRequest, start: Leyline_V1_WorkerStart,
                        onWriteFailure: @escaping @Sendable (EngineError) -> Void) throws -> AssistantWorker
    {
        let provider = credential.provider
        guard let ley = locator.find("ley", explicit: leyPath) else {
            if let leyPath, !leyPath.isEmpty {
                throw Self.cannotStart(provider, "the ley named by --ley or LEYLINE_LEY (\(leyPath)) is not an executable file, so the assistant cannot start")
            }
            throw Self.cannotStart(provider, "no ley executable was found beside leylined, on PATH or by --ley, so the assistant cannot start")
        }
        var environment = PluginProcess.environment(sendingKey: true)
        environment["LEYLINE_SOCKET"] = socketPath
        let worker = AssistantWorker(executable: ley, args: ["worker", "assistant", "--conversation", start.conversationID],
                                     environment: environment, onWriteFailure: onWriteFailure)
        do {
            try worker.run(log: Logger(label: "leyline.assistant.\(start.conversationID)"), secret: credential.secret)
        } catch {
            throw Self.cannotStart(provider, "\(ley) could not be started (\(error))")
        }
        var event = Leyline_V1_WorkerEvent()
        event.start = start
        worker.send(credential)
        worker.send(event)
        return worker
    }

    /// `PROVIDER_UNAVAILABLE` in words about the worker: the provider was never asked.
    private static func cannotStart(_ provider: String, _ why: String) -> EngineError {
        EngineError(code: EngineError.Code.providerUnavailable, message: why, target: provider)
    }
}
