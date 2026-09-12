// SPDX-License-Identifier: GPL-3.0-or-later

// A decoder plugin that decodes nothing, for the daemon's own tests.
//
// It keeps the contract of docs/design/decoders.md, "Decisions" ("Transport: stdio") and nothing
// else: read the varint-delimited StreamDescriptor, then one DecodeRecord per Frame. A frame with
// an empty payload makes it exit(3), which is how the restart path is tested; FAKE_DECODER_SLEEP_MS
// delays its start, which is how a slow plugin is.
//
// Framing is coded here rather than through `BinaryDelimited` because that API takes Foundation
// `InputStream`/`OutputStream`, which cannot be built from the process's own pipes; the bytes are
// protobuf's delimited convention either way.

import Foundation
import LeylineProto
import SwiftProtobuf

func readExactly(_ n: Int) -> [UInt8]? {
    var out = [UInt8]()
    out.reserveCapacity(n)
    var chunk = [UInt8](repeating: 0, count: n)
    while out.count < n {
        let got = chunk.withUnsafeMutableBytes { read(0, $0.baseAddress, n - out.count) }
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { return nil }
        out.append(contentsOf: chunk[0..<got])
    }
    return out
}

func readDelimited() -> [UInt8]? {
    var length: UInt64 = 0
    var shift: UInt64 = 0
    while true {
        guard let b = readExactly(1)?.first else { return nil }
        length |= UInt64(b & 0x7F) << shift
        if b & 0x80 == 0 { break }
        shift += 7
        if shift > 63 { return nil }
    }
    if length == 0 { return [] }
    return readExactly(Int(length))
}

func writeDelimited(_ message: any Message) {
    guard let body = try? message.serializedBytes() as [UInt8] else { return }
    var out = [UInt8]()
    var n = UInt64(body.count)
    repeat {
        var b = UInt8(n & 0x7F)
        n >>= 7
        if n != 0 { b |= 0x80 }
        out.append(b)
    } while n != 0
    out.append(contentsOf: body)
    var offset = 0
    while offset < out.count {
        let written = out.withUnsafeBytes { write(1, $0.baseAddress!.advanced(by: offset), out.count - offset) }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { exit(4) }
        offset += written
    }
}

if let ms = ProcessInfo.processInfo.environment["FAKE_DECODER_SLEEP_MS"], let n = UInt32(ms) {
    usleep(n * 1000)
}

guard let head = readDelimited(), let descriptor = try? Leyline_V1_StreamDescriptor(serializedBytes: head) else {
    exit(1)
}
FileHandle.standardError.write(Data("fake decoder up on \(descriptor.streamID)\n".utf8))

/// `--die-after=N` exits after N frames, the way a decoder with a bug in it would. A decode job's
/// restart path has no other way to be provoked: every frame the daemon sends is a real one. It
/// dies once: a marker file in the working directory (the plugin's own directory, per test) records
/// that it has already died, so the respawned process runs for good and a test can see the job
/// back in RUNNING rather than racing a second exit through a 170 ms window.
let dieAfter: UInt64 = {
    for arg in CommandLine.arguments.dropFirst() where arg.hasPrefix("--die-after=") {
        let n = UInt64(arg.dropFirst("--die-after=".count)) ?? 0
        let marker = FileManager.default.currentDirectoryPath + "/.died-once"
        if FileManager.default.fileExists(atPath: marker) { return 0 }
        FileManager.default.createFile(atPath: marker, contents: nil)
        return n
    }
    return 0
}()

var seq: UInt64 = 0
while let bytes = readDelimited() {
    guard let frame = try? Leyline_V1_Frame(serializedBytes: bytes) else { exit(2) }
    // The restart path: a frame with nothing in it is the test's way of killing the plugin.
    if frame.payload.isEmpty { exit(3) }
    seq += 1
    var rec = Leyline_V1_DecodeRecord()
    rec.protocol = "fake"
    rec.deviceID = "FAKE-\(seq)"
    rec.kind = "position"
    rec.position.latitude = 1.0
    rec.position.longitude = 2.0
    rec.time = frame.time
    rec.raw = frame.payload.prefix(4)
    writeDelimited(rec)
    if dieAfter > 0, seq >= dieAfter { exit(3) }
}
