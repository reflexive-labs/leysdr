// SPDX-License-Identifier: Apache-2.0

// The Library row's LEVEL column (docs/design/app-design-handoff-m3.md, "10a · The Library,
// revised"): one pass over a part's WAV, client side, into a few dozen columns of RMS level. The
// window is local, as `ley recordings show` is, so the file is read through the path
// `Resources.ResolveLocalPath` returns for the part's URI; a remote daemon's path does not exist
// here and the column stays empty. The file is the one shape `PartWriter` writes, PCM S16 mono;
// the chunk walk is the engine's `WAVReader` (engine/Sources/LeylineDaemon/Recording/
// PlaybackEngine.swift), reimplemented because the app never links the engine (AGENTS.md,
// Conventions).

import Foundation

public enum LevelGraph {
    /// The most columns a part draws: 10a's "about 40".
    public static let maxColumns = 40
    /// Columns a second, so a bar is the same width on every row and a longer part draws a
    /// longer graph, as the screen does (a 4 s part about 7 bars, a 25 s part about 40). Read
    /// off `tmp/library.png`; a guess until the Mac.
    public static let columnsPerSecond = 1.6
    /// The dBFS the graph's floor stands for; 0 dBFS is the top.
    public static let floorDBFS: Float = -60

    /// How many columns a part of `seconds` draws: `columnsPerSecond` of them, at least 4 and at
    /// most `maxColumns`.
    public static func columnCount(seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 4 }
        return min(maxColumns, max(4, Int((seconds * columnsPerSecond).rounded())))
    }

    public enum ReadError: Error, Equatable {
        case unreadable(String)
        /// Anything but the mono 16-bit PCM a recording writes, or no samples.
        case notARecordingWAV(String)
    }

    /// The WAV at `wav` as `columns` levels, 0 to 1, left to right: each column the RMS of its
    /// share of the frames in dBFS, mapped from `floorDBFS`…0 onto 0…1 and clamped. A file with
    /// fewer frames than columns gets one column a frame. Reads in blocks, so a long continuous
    /// part costs one pass and no more memory than a block.
    public static func columns(wav: URL, columns: Int) throws -> [Float] {
        guard columns > 0 else { return [] }
        guard let h = FileHandle(forReadingAtPath: wav.path) else {
            throw ReadError.unreadable(wav.path)
        }
        defer { try? h.close() }
        let (offset, bytes) = try dataChunk(h, path: wav.path)
        let frames = Int(bytes / 2)
        let n = min(columns, frames)
        guard n > 0 else { return [] }
        try h.seek(toOffset: offset)
        var sums = [Double](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: n)
        var frame = 0
        let block = 65_536
        while frame < frames {
            let want = min(block, frames - frame)
            guard let data = try h.read(upToCount: want * 2), !data.isEmpty else { break }
            let count = data.count / 2
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    let v =
                        Double(
                            raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian)
                        / 32768
                    // Column of this frame: its share of the file, so the columns split the
                    // frames as evenly as integers allow.
                    let c = min(n - 1, (frame + i) * n / frames)
                    sums[c] += v * v
                    counts[c] += 1
                }
            }
            frame += count
        }
        return (0..<n).map { c in
            guard counts[c] > 0 else { return 0 }
            return level(meanSquare: sums[c] / Double(counts[c]))
        }
    }

    /// A mean square of full-scale samples as the graph's 0…1: its dBFS against `floorDBFS`.
    /// Silence and anything at or below the floor is 0; full scale is 1.
    public static func level(meanSquare: Double) -> Float {
        guard meanSquare > 0, meanSquare.isFinite else { return 0 }
        let db = Float(10 * log10(meanSquare))
        return min(1, max(0, (db - floorDBFS) / -floorDBFS))
    }

    /// Walks the RIFF chunks to `data`, checking `fmt ` on the way: the data's byte offset and
    /// length. A part the daemon was still writing when it died carries a zero length, and what
    /// the file holds is read instead, as the engine's reader does.
    private static func dataChunk(_ h: FileHandle, path: String) throws -> (UInt64, UInt64) {
        guard let head = try h.read(upToCount: 12), head.count == 12,
            head.prefix(4).elementsEqual("RIFF".utf8),
            head.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8)
        else { throw ReadError.notARecordingWAV(path) }
        var format: UInt16 = 0
        var channels: UInt16 = 0
        var bits: UInt16 = 0
        while true {
            guard let header = try h.read(upToCount: 8), header.count == 8 else { break }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let size = UInt64(u32(header, 4))
            let body = try h.offset()
            if id == "fmt " {
                guard let fmt = try h.read(upToCount: Int(min(size, 16))), fmt.count >= 16 else {
                    break
                }
                format = u16(fmt, 0)
                channels = u16(fmt, 2)
                bits = u16(fmt, 14)
            } else if id == "data" {
                guard format == 1, channels == 1, bits == 16 else { break }
                let end = try h.seekToEnd()
                let bytes = size == 0 ? end - body : min(size, end - body)
                return (body, bytes)
            }
            try h.seek(toOffset: body + size + (size % 2))
        }
        throw ReadError.notARecordingWAV(path)
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian }
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian }
    }
}
