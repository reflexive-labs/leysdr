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
/// blocking the caller for ever on a plugin that has wedged (docs/plans/decoders.md, DEC-16).
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

/// A spawned decoder. One instance runs one child; a restart makes a new one.
/// Unchecked Sendable: the process and its pipes are set up in init and only read afterwards; the write descriptor is behind a Mutex.
final class PluginProcess: @unchecked Sendable {
    let name: String
    private let executable: String
    private let args: [String]
    private let directory: String
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let log: Logger
    private let recordsContinuation: AsyncStream<Leyline_V1_DecodeRecord>.Continuation
    private let exitContinuation: AsyncStream<Int32>.Continuation
    /// The write end of the plugin's stdin as a raw descriptor: nil before `start` and after
    /// `stop`. A write holds the lock for its duration, so `stop` cannot close the descriptor
    /// under a frame in flight, and `stop` empties it first, so a frame that arrives afterwards
    /// is a drop rather than a call on the closed handle. The descriptor is cached because
    /// NSFileHandle raises an Objective-C exception for `fileDescriptor` once it is closed, which
    /// Swift cannot catch: the runner's drain asking for it a moment after cancel closed the pipe
    /// took the whole daemon down (docs/plans/decoders.md, DEC-22).
    private let writeFD = Mutex<Int32?>(nil)

    /// Records the plugin wrote, in order. Finishes when its stdout closes.
    let records: AsyncStream<Leyline_V1_DecodeRecord>
    /// The child's exit status, once.
    let exits: AsyncStream<Int32>

    init(name: String, executable: String, args: [String], directory: String) {
        self.name = name
        self.executable = executable
        self.args = args
        self.directory = directory
        log = Logger(label: "leyline.decoder.\(name)")
        (records, recordsContinuation) = AsyncStream<Leyline_V1_DecodeRecord>.makeStream(bufferingPolicy: .unbounded)
        (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
    }

    /// Spawns the child and writes the descriptor, which is the first thing every plugin reads.
    func start(descriptor: Leyline_V1_StreamDescriptor) throws {
        // A write to a pipe whose reader died must be an error return, never a process-killing
        // signal. The daemon's main does this too; a test hosting the daemon in-process does not.
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { [weak self] p in
            self?.exitContinuation.yield(p.terminationStatus)
            self?.exitContinuation.finish()
        }
        do {
            try process.run()
        } catch {
            recordsContinuation.finish()
            exitContinuation.finish()
            throw EngineError(code: EngineError.Code.decoderFailed,
                              message: "\(name) could not be started: \(error)", target: name)
        }
        startReaders()
        // The write end is non-blocking so a plugin that stops reading cannot wedge the runner's
        // drain task (DEC-16). The descriptor is small and read at once, so a drop there means the
        // plugin is not reading its input -- treat it as a failure to start.
        let wfd = inPipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(wfd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(wfd, F_SETFL, flags | O_NONBLOCK) }
        writeFD.withLock { $0 = wfd }
        if try writeDelimited(descriptor, to: wfd, deadlineSeconds: 5) == .droppedFull {
            throw EngineError(code: EngineError.Code.decoderFailed,
                              message: "\(name) did not read its stream descriptor", target: name)
        }
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

    private func startReaders() {
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let cont = recordsContinuation
        Thread.detachNewThread {
            let reader = DelimitedReader(fd: outFD)
            while let bytes = reader.next() {
                guard let rec = try? Leyline_V1_DecodeRecord(serializedBytes: bytes) else { continue }
                cont.yield(rec)
            }
            cont.finish()
        }
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let logger = log
        Thread.detachNewThread {
            var line = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let got = chunk.withUnsafeMutableBytes { read(errFD, $0.baseAddress, 4096) }
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { break }
                for b in chunk[0..<got] {
                    if b == UInt8(ascii: "\n") {
                        if !line.isEmpty { logger.info("\(String(decoding: line, as: UTF8.self))") }
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(b)
                    }
                }
            }
            if !line.isEmpty { logger.info("\(String(decoding: line, as: UTF8.self))") }
        }
    }

    /// Closes stdin and waits, then escalates. A decoder with buffered state gets the chance to
    /// flush what it has before it is killed. Idempotent: the drain stops a stalled plugin and
    /// the runner's teardown stops it again, and the input is closed once.
    func stop() async {
        let open = writeFD.withLock { fd -> Bool in
            let was = fd != nil
            fd = nil
            return was
        }
        if open { try? inPipe.fileHandleForWriting.close() }
        if await waitForExit(seconds: 2) { return }
        if process.isRunning { process.terminate() }
        if await waitForExit(seconds: 1) { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        _ = await waitForExit(seconds: 1)
    }

    private func waitForExit(seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !process.isRunning
    }
}
