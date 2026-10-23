// SPDX-License-Identifier: GPL-3.0-or-later

// One running decoder plugin: a child process the daemon writes bulk frames to and reads
// DecodeRecords from (docs/design/decoders.md, "Decisions": "Transport: stdio").
//
// The framing is protobuf's own "delimited" convention -- a varint length then the message -- so a
// plugin reads exactly what a Bulk.Stream client reads and no client library has to know a framing
// of ours. It is coded here rather than through `BinaryDelimited` because that API takes Foundation
// `InputStream`/`OutputStream`, which cannot be built from a pipe's file descriptor on either
// platform; the bytes on the wire are the same.
//
// Nothing here runs on the DSP thread (invariant 4): the runner's drain task calls `write`, and a
// reader thread parks in `read(2)` on the plugin's stdout.

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

/// Reads varint-delimited messages from a file descriptor, blocking. Owned by one thread.
final class DelimitedReader {
    private let fd: Int32
    private var pending: [UInt8] = []
    private var pos = 0

    init(fd: Int32) { self.fd = fd }

    /// The next message's bytes, or nil at end of stream (or on a malformed length).
    func next() -> [UInt8]? {
        var length: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard let b = byte() else { return nil }
            length |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { return nil }
        }
        guard length <= 0x7FFF_FFFF else { return nil }
        guard fill(Int(length)) else { return nil }
        let out = Array(pending[pos..<(pos + Int(length))])
        pos += Int(length)
        return out
    }

    private func byte() -> UInt8? {
        guard fill(1) else { return nil }
        let b = pending[pos]
        pos += 1
        return b
    }

    /// Blocks until `n` bytes are buffered; false at end of stream.
    private func fill(_ n: Int) -> Bool {
        while pending.count - pos < n {
            if pos > 0 {
                pending.removeFirst(pos)
                pos = 0
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let got = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, 65536)
            }
            if got < 0 && errno == EINTR { continue }
            if got <= 0 { return false }
            pending.append(contentsOf: chunk[0..<got])
        }
        return true
    }
}

/// One message in delimited form: a varint length then the encoded message.
func delimitedBytes(_ message: any Message) throws -> [UInt8] {
    let body: [UInt8] = try message.serializedBytes()
    var out: [UInt8] = []
    out.reserveCapacity(body.count + 5)
    var n = UInt64(body.count)
    repeat {
        var b = UInt8(n & 0x7F)
        n >>= 7
        if n != 0 { b |= 0x80 }
        out.append(b)
    } while n != 0
    out.append(contentsOf: body)
    return out
}

/// The result of trying to hand one frame to a plugin over a non-blocking pipe.
enum PluginWrite {
    /// Every byte reached the plugin.
    case written
    /// The pipe was full at the first byte -- the plugin has stopped reading -- so nothing was
    /// written and the frame is dropped. The next frame that lands carries the gap (invariant 3).
    case droppedFull
}

/// A plugin whose pipe stalled with a frame half-written. The stream cannot be resynchronised, so
/// the runner tears the plugin down and the restart loop spawns a fresh one.
struct PluginStalled: Error {}

/// Writes a varint-delimited message to a non-blocking file descriptor, giving up rather than
/// blocking the caller for ever on a plugin that has wedged.
///
/// The frame is atomic on the wire or it is dropped: if the pipe cannot take its first byte the
/// whole frame is dropped and reported (`droppedFull`); once a byte has gone the frame must finish
/// or the length prefix no longer matches the bytes that follow, so a stall past `deadlineSeconds`
/// mid-frame throws `PluginStalled` and the plugin is replaced rather than fed a torn stream.
@discardableResult
func writeDelimited(_ message: any Message, to fd: Int32, deadlineSeconds: Double = 2.0) throws -> PluginWrite {
    let out = try delimitedBytes(message)
    var offset = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(deadlineSeconds))
    while offset < out.count {
        let written = out.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress!.advanced(by: offset), out.count - offset)
        }
        if written > 0 { offset += written; continue }
        if written < 0 && errno == EINTR { continue }
        if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            if offset == 0 { return .droppedFull }
            // Mid-frame: wait for the reader to make room, but not for ever.
            if ContinuousClock.now >= deadline { throw PluginStalled() }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 50)
            continue
        }
        throw EngineError(code: EngineError.Code.decoderFailed,
                          message: "the plugin is not reading its input (\(String(cString: strerror(errno))))", target: "")
    }
    return .written
}

/// `write(2)`, under a name `PluginProcess` does not shadow with its own `write(_:)`.
private func writeRaw(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, bytes, count)
}

/// The key a plugin's manifest names a provider for, read from the store now, for
/// `PluginProcess.start`. Nil when the manifest names none; `CREDENTIAL_MISSING` when it names one
/// and no key is set, or there is no store to hold one.
func pluginCredential(for manifest: Leyline_V1_DecoderManifest,
                      from store: CredentialStore?) async throws -> Leyline_V1_SetCredentialRequest?
{
    let provider = manifest.credentialProvider
    guard !provider.isEmpty else { return nil }
    guard let store else { throw EngineError.credentialMissing(provider) }
    return try await store.pluginCredential(provider)
}

/// The arguments a plugin is spawned with: the manifest's, then `--model <model>` when the user
/// has chosen a speech model on the provider the plugin calls (`ley ai use speech <provider>
/// <model>`). Read at every spawn, so a restart takes the choice as it now stands.
func pluginArguments(for manifest: Leyline_V1_DecoderManifest, from store: CredentialStore?) async -> [String] {
    let provider = manifest.credentialProvider
    guard !provider.isEmpty, let store else { return manifest.args }
    let chosen = await store.snapshot().features.first { $0.feature == "speech" && $0.provider == provider }
    guard let model = chosen?.model, !model.isEmpty else { return manifest.args }
    return manifest.args + ["--model", model]
}

/// A spawned decoder. One instance runs one child; a restart makes a new one.
/// Unchecked Sendable: the child and its pipes are set up in init and only read afterwards; the write descriptor is behind a Mutex.
final class PluginProcess: @unchecked Sendable {
    let name: String
    private let child: ChildProcess
    private let log: Logger
    private let recordsContinuation: AsyncStream<Leyline_V1_DecodeRecord>.Continuation
    /// The write end of the plugin's stdin as a raw descriptor: nil before `start` and after
    /// `stop`. A write holds the lock for its duration, so `stop` cannot close the descriptor under
    /// a frame in flight, and `stop` empties it first, so a frame that arrives afterwards is a drop
    /// rather than a call on the closed handle. The descriptor is cached because NSFileHandle
    /// raises an Objective-C exception for `fileDescriptor` once it is closed, which Swift cannot
    /// catch: the runner's drain asking for it a moment after cancel closed the pipe would take the
    /// whole daemon down.
    private let writeFD = Mutex<Int32?>(nil)
    /// Set by `closeInput` before it takes the lock, so a patient write waiting for room gives up.
    private let closing = Atomic<Bool>(false)
    /// A patient write is parked waiting for the plugin to read.
    private let waitingForRoom = Atomic<Bool>(false)
    /// The input was closed while a patient write waited for room: the plugin had stopped reading.
    private let notReadingAtClose = Atomic<Bool>(false)
    static let stuckGraceSeconds: Double = 0.5

    /// Records the plugin wrote, in order. Finishes when its stdout closes.
    let records: AsyncStream<Leyline_V1_DecodeRecord>
    /// The child's exit status, once.
    var exits: AsyncStream<Int32> { child.exits }

    init(name: String, executable: String, args: [String], directory: String) {
        self.name = name
        child = ChildProcess(executable: executable, args: args, directory: directory)
        log = Logger(label: "leyline.decoder.\(name)")
        (records, recordsContinuation) = AsyncStream<Leyline_V1_DecodeRecord>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Spawns the child and writes the descriptor, which is the first thing every plugin reads. A
    /// plugin whose manifest names a provider reads one `SetCredentialRequest` before it: the key,
    /// read from the store by the caller at this moment, so a restart takes the key as it now
    /// stands. The key never reaches a log line: what the plugin writes on stderr is logged with it
    /// replaced.
    func start(descriptor: Leyline_V1_StreamDescriptor, credential: Leyline_V1_SetCredentialRequest? = nil) throws {
        let logger = log
        let secret = credential?.secret ?? ""
        child.process.environment = Self.environment(sendingKey: credential != nil)
        do {
            try child.run { logger.info("\(WorkerProcess.redacting(secret, in: $0))") }
        } catch {
            recordsContinuation.finish()
            throw EngineError(code: EngineError.Code.decoderFailed,
                              message: "\(name) could not be started: \(error)", target: name)
        }
        startReader()
        // The write end is non-blocking so a plugin that stops reading cannot wedge the runner's
        // drain task. The descriptor is small and read at once, so a drop there means the plugin is
        // not reading its input -- treat it as a failure to start.
        let wfd = child.input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(wfd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(wfd, F_SETFL, flags | O_NONBLOCK) }
        writeFD.withLock { $0 = wfd }
        if let credential, try writeDelimited(credential, to: wfd, deadlineSeconds: 5) == .droppedFull {
            throw EngineError(code: EngineError.Code.decoderFailed,
                              message: "\(name) did not read its key", target: name)
        }
        if try writeDelimited(descriptor, to: wfd, deadlineSeconds: 5) == .droppedFull {
            throw EngineError(code: EngineError.Code.decoderFailed,
                              message: "\(name) did not read its stream descriptor", target: name)
        }
    }

    /// The variable that tells a plugin a key comes before its descriptor. A plugin cannot learn
    /// it from its own built-in manifest, because the installed one is what the daemon goes by and
    /// may name a provider the binary's does not.
    static let keyOnStdinVariable = "LEYLINE_KEY_ON_STDIN"

    /// The daemon's environment, with `LEYLINE_KEY_ON_STDIN=1` when the key is sent and without
    /// the variable when it is not, so a daemon started with it set cannot mislead a plugin.
    static func environment(sendingKey: Bool,
                            inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String]
    {
        var env = base
        env[keyOnStdinVariable] = sendingKey ? "1" : nil
        return env
    }

    /// One frame to the plugin, without blocking the caller. Returns whether the frame reached the
    /// plugin or was dropped because the plugin has stopped reading, or because `stop` has already
    /// closed its input; throws `PluginStalled` if a frame stalled half-written, which the runner
    /// answers by replacing the plugin.
    @discardableResult
    func write(_ frame: Leyline_V1_Frame) throws -> PluginWrite {
        try writeFD.withLock { fd in
            guard let fd else { return .droppedFull }
            return try writeDelimited(frame, to: fd)
        }
    }

    /// One frame of a stored recording, written whole however long the plugin takes to read it:
    /// nothing here is live, so a full pipe is waited out rather than dropped. The lock covers one
    /// non-blocking write at a time and never the wait between them, so `closeInput` and `stop`
    /// never queue behind a plugin that has stopped reading; the wait sees `closing` within 20 ms.
    /// Throws when the plugin has gone or its input is being closed, and `CancellationError` when
    /// the calling task is cancelled.
    func writeWaiting(_ frame: Leyline_V1_Frame) throws {
        let out = try delimitedBytes(frame)
        var offset = 0
        while offset < out.count {
            let attempt = writeFD.withLock { fd -> (fd: Int32, written: Int, error: Int32)? in
                guard let fd, !closing.load(ordering: .acquiring) else { return nil }
                let n = out.withUnsafeBytes { raw in writeRaw(fd, raw.baseAddress!.advanced(by: offset), out.count - offset) }
                return (fd, n, n < 0 ? errno : 0)
            }
            guard let attempt else { throw inputClosed }
            if attempt.written > 0 {
                offset += attempt.written
                waitingForRoom.store(false, ordering: .releasing)
                continue
            }
            if attempt.error == EINTR { continue }
            guard attempt.error == EAGAIN || attempt.error == EWOULDBLOCK else {
                throw EngineError(code: EngineError.Code.decoderFailed,
                                  message: "\(name) is not reading its input (\(String(cString: strerror(attempt.error))))",
                                  target: name)
            }
            if Task.isCancelled { throw CancellationError() }
            // The descriptor may be closed under the poll; that only ends the wait early, and the
            // next attempt finds it gone.
            waitingForRoom.store(true, ordering: .releasing)
            var pfd = pollfd(fd: attempt.fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 20)
        }
    }

    private var inputClosed: EngineError {
        EngineError(code: EngineError.Code.decoderFailed, message: "\(name)'s input is closed", target: name)
    }

    /// Closes the plugin's input without waiting for it to exit: the end of a stored recording,
    /// after which the plugin writes what it has left and exits on its own. A patient write in
    /// progress sees `closing` and gives up; if it was waiting for room, the plugin had stopped
    /// reading, which `stop` takes into account.
    func closeInput() {
        closing.store(true, ordering: .releasing)
        if waitingForRoom.load(ordering: .acquiring) { notReadingAtClose.store(true, ordering: .releasing) }
        let open = writeFD.withLock { fd -> Bool in
            let was = fd != nil
            fd = nil
            return was
        }
        if open { try? child.input.fileHandleForWriting.close() }
    }

    /// The last line the plugin wrote on stderr before it exited, which is where a plugin says why
    /// (`DecodeRunner.refusedExitStatus`).
    func lastErrorLine() async -> String? {
        await child.lastErrorLine()
    }

    private func startReader() {
        let outFD = child.output.fileHandleForReading.fileDescriptor
        let cont = recordsContinuation
        Thread.detachNewThread {
            let reader = DelimitedReader(fd: outFD)
            while let bytes = reader.next() {
                guard let rec = try? Leyline_V1_DecodeRecord(serializedBytes: bytes) else { continue }
                cont.yield(rec)
            }
            cont.finish()
        }
    }

    /// Closes stdin and waits, then escalates. A decoder with buffered state gets the chance to
    /// flush what it has before it is killed. Idempotent: the drain stops a stalled plugin and
    /// the runner's teardown stops it again, and the input is closed once.
    func stop() async {
        closeInput()
        // A plugin that was not reading its input when it was closed is not flushing anything
        // either, so it gets half a second rather than two, and is then killed outright: asking it
        // to go would only add the second `terminate` allows for a polite exit.
        if notReadingAtClose.load(ordering: .acquiring) {
            if await child.waitForExit(seconds: Self.stuckGraceSeconds) { return }
            await child.kill()
            return
        }
        if await child.waitForExit(seconds: 2) { return }
        await child.terminate()
    }
}
