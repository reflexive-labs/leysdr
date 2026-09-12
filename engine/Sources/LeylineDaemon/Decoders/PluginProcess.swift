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
import LeylineProto
import Logging
import SwiftProtobuf

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

/// Writes varint-delimited messages to a file descriptor.
func writeDelimited(_ message: any Message, to fd: Int32) throws {
    let out = try delimitedBytes(message)
    var offset = 0
    while offset < out.count {
        let written = out.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress!.advanced(by: offset), out.count - offset)
        }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else {
            throw EngineError(code: EngineError.Code.decoderFailed,
                              message: "the plugin is not reading its input (\(String(cString: strerror(errno))))", target: "")
        }
        offset += written
    }
}

/// A spawned decoder. One instance runs one child; a restart makes a new one.
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
        try writeDelimited(descriptor, to: inPipe.fileHandleForWriting.fileDescriptor)
    }

    /// One frame to the plugin. Called from the runner's drain task.
    func write(_ frame: Leyline_V1_Frame) throws {
        try writeDelimited(frame, to: inPipe.fileHandleForWriting.fileDescriptor)
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
    /// flush what it has before it is killed.
    func stop() async {
        try? inPipe.fileHandleForWriting.close()
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
