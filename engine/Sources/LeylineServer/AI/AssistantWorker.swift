// SPDX-License-Identifier: GPL-3.0-or-later

// One running `ley worker assistant`: the child the daemon spawns for a conversation and talks to
// over its stdio for the conversation's whole life (docs/dev/engine-internals.md, "Assistant").
// The check worker answers once and exits; this one is long-lived, so both directions are
// varint-delimited protobuf, framed as a decoder plugin's are (`PluginProcess`): the key and
// `WorkerEvent`s in, `WorkerMessage`s out.
//
// Nothing here runs on the DSP thread (invariant 4): writes come from the conversation store and
// are a few hundred bytes, and a reader thread parks in `read(2)` on the worker's stdout.

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
/// write descriptor is behind a Mutex.
final class AssistantWorker: @unchecked Sendable {
    /// How long a write may wait for the worker to make room before it counts as not reading.
    static let writeDeadlineSeconds: Double = 2
    /// How long a worker whose stdin has closed gets to exit before it is asked, then made, to go.
    static let exitGraceSeconds: Double = 2

    private let child: ChildProcess
    /// The write end of stdin as a raw descriptor, nil once closed: cached for the reason
    /// `PluginProcess.writeFD` gives (NSFileHandle raises on a closed handle).
    private let writeFD = Mutex<Int32?>(nil)
    private let messagesContinuation: AsyncStream<Leyline_V1_WorkerMessage>.Continuation

    /// What the worker wrote, in order. Finishes when its stdout closes.
    let messages: AsyncStream<Leyline_V1_WorkerMessage>
    /// The worker's exit status, once.
    var exits: AsyncStream<Int32> { child.exits }

    init(executable: String, args: [String], environment: [String: String]) {
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

    /// One message to the worker, waiting up to `writeDeadlineSeconds` for room. Throws when the
    /// worker's stdin is closed or the worker is not reading it.
    func write(_ message: any Message) throws {
        let bytes = try delimitedBytes(message)
        try writeFD.withLock { fd in
            guard let fd else { throw Self.notReading("its input is closed") }
            var offset = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(Self.writeDeadlineSeconds))
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { raw in
                    rawWrite(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw Self.notReading(String(cString: strerror(errno)))
                }
                guard ContinuousClock.now < deadline else { throw Self.notReading("it stopped reading") }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 50)
            }
        }
    }

    /// Closes stdin, which tells the worker the conversation is over, gives it
    /// `exitGraceSeconds` to go, then `SIGTERM` and `SIGKILL` (`ChildProcess.terminate`).
    func stop() async {
        let open = writeFD.withLock { fd -> Bool in
            defer { fd = nil }
            return fd != nil
        }
        if open { try? child.input.fileHandleForWriting.close() }
        if await child.waitForExit(seconds: Self.exitGraceSeconds) { return }
        await child.terminate()
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
    /// `LEYLINE_KEY_ON_STDIN=1`, and writes the key then `WorkerStart`, in that order, before
    /// anything else. Throws `PROVIDER_UNAVAILABLE` when there is no `ley` or it cannot be started
    /// or does not read what it is sent.
    func startAssistant(credential: Leyline_V1_SetCredentialRequest, start: Leyline_V1_WorkerStart) throws -> AssistantWorker {
        let provider = credential.provider
        guard let ley = locator.find("ley", explicit: leyPath) else {
            if let leyPath, !leyPath.isEmpty {
                throw Self.cannotStart(provider, "the ley named by --ley or LEYLINE_LEY (\(leyPath)) is not an executable file, so the assistant cannot start")
            }
            throw Self.cannotStart(provider, "no ley executable was found beside leylined or on PATH, so the assistant cannot start")
        }
        var environment = PluginProcess.environment(sendingKey: true)
        environment["LEYLINE_SOCKET"] = socketPath
        let worker = AssistantWorker(executable: ley, args: ["worker", "assistant", "--conversation", start.conversationID],
                                     environment: environment)
        do {
            try worker.run(log: Logger(label: "leyline.assistant.\(start.conversationID)"), secret: credential.secret)
        } catch {
            throw Self.cannotStart(provider, "\(ley) could not be started (\(error))")
        }
        var event = Leyline_V1_WorkerEvent()
        event.start = start
        do {
            try worker.write(credential)
            try worker.write(event)
        } catch {
            Task { await worker.stop() }
            throw Self.cannotStart(provider, "ley worker assistant did not read its key")
        }
        return worker
    }

    /// `PROVIDER_UNAVAILABLE` in words about the worker: the provider was never asked.
    private static func cannotStart(_ provider: String, _ why: String) -> EngineError {
        EngineError(code: EngineError.Code.providerUnavailable, message: why, target: provider)
    }
}
