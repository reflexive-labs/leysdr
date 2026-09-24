// SPDX-License-Identifier: GPL-3.0-or-later

// Playing a recording back through the daemon's own audio device (docs/design/recording.md,
// "Playing a recording back"). The daemon owns the speakers -- a channel's audio already comes out
// of them -- so a recording plays where the radio is, a client on another machine hears it, and
// `ley play` can hold the terminal and stop what it started.
//
// There is no DSP thread in this path at all: a task reads the file, paces itself against the
// file's own rate and pushes blocks into the same `CoreAudioSink` a channel's audio goes to, whose
// ring absorbs the jitter.

import EngineCore
import Foundation
import Logging

/// PCM S16 mono WAV, which is the only shape `PartWriter` writes. Accepting any other format would
/// add a code path nothing tests.
struct WAVReader {
    let sampleRate: UInt32
    let channels: UInt16
    /// Frames in the data chunk.
    let frames: UInt64
    /// Byte offset of the first sample.
    let dataOffset: UInt64

    private let handle: FileHandle

    /// Opens and validates the header. Throws INVALID_ARGUMENT with what is wrong, because every
    /// case here is a file somebody named rather than a fault the daemon caused.
    init(path: String) throws {
        guard let h = FileHandle(forReadingAtPath: path) else {
            throw EngineError.invalidArgument("cannot open \(path)", target: path)
        }
        handle = h
        guard let head = try h.read(upToCount: 12), head.count == 12,
              head.prefix(4).elementsEqual("RIFF".utf8), head.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8)
        else {
            try? h.close()
            throw EngineError.invalidArgument("\(path) is not a WAV file", target: path)
        }
        // Walk the chunks rather than assuming the canonical layout: a file another tool wrote may
        // carry a LIST or a fact chunk before the data.
        var rate: UInt32 = 0
        var chans: UInt16 = 0
        var bits: UInt16 = 0
        var format: UInt16 = 0
        var dataBytes: UInt64 = 0
        var offset: UInt64 = 0
        while true {
            guard let header = try h.read(upToCount: 8), header.count == 8 else { break }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let size = UInt64(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
            let body = try h.offset()
            if id == "fmt " {
                guard let fmt = try h.read(upToCount: Int(min(size, 16))), fmt.count >= 16 else { break }
                format = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self).littleEndian }
                chans = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self).littleEndian }
                rate = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
                bits = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt16.self).littleEndian }
            } else if id == "data" {
                offset = body
                // A part the daemon was still writing when it died carries a zero length; the
                // file's own size is what it really holds, and that is what plays.
                let end = try h.seekToEnd()
                dataBytes = size == 0 ? end - body : min(size, end - body)
                break
            }
            try h.seek(toOffset: body + size + (size % 2))
        }
        guard format == 1, bits == 16, chans == 1, rate > 0, dataBytes > 0 else {
            try? h.close()
            throw EngineError.invalidArgument(
                "\(path) is not the mono 16-bit PCM WAV a recording writes (format \(format), \(bits)-bit, \(chans) channel)",
                target: path)
        }
        sampleRate = rate
        channels = chans
        frames = dataBytes / 2
        dataOffset = offset
        try h.seek(toOffset: offset)
    }

    /// Reads up to `frames` frames as f32 in -1...1, the shape every `AudioSink` takes. Empty at
    /// the end of the file.
    func read(frames wanted: Int) -> [Float] {
        guard let data = try? handle.read(upToCount: wanted * 2), !data.isEmpty else { return [] }
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian
                out[i] = Float(v) / 32768
            }
        }
        return out
    }

    func close() { try? handle.close() }
}

/// Opens a playback's audio output: the sink's id, the file's rate, the volume and the output
/// device's UID (nil for the default).
typealias PlaybackSinkFactory = @Sendable (SinkID, UInt32, Double, String?) throws -> any AudioSink

/// The daemon's own audio device, which is where a playback goes outside a test.
let systemPlaybackSink: PlaybackSinkFactory = { id, rate, volume, deviceUID in
    try makeSystemAudioSink(id: id, rate: rate, volume: volume, deviceUID: deviceUID)
}

/// One playing recording: the file, the sink it is going to, and where it has reached.
actor PlaybackEngine {
    /// Frames pushed per tick. 20 ms at 48 kHz: short enough that stopping is prompt, long enough
    /// that the pacing loop wakes fifty times a second rather than thousands.
    static let blockFrames = 960

    nonisolated let id: PlaybackID
    nonisolated let path: String
    nonisolated let resourceURI: String
    nonisolated let sampleRate: UInt32
    nonisolated let frames: UInt64
    nonisolated let volume: Double

    private let reader: WAVReader
    private let sink: any AudioSink
    private let onEnd: @Sendable (PlaybackID) async -> Void
    private let log = Logger(label: "leyline.playback")
    private var task: Task<Void, Never>?
    private var played: UInt64 = 0
    private var stopped = false

    /// `makeSink` opens the audio output: the daemon's audio device in the daemon, a sink that
    /// discards the audio in a test on a host with none (`SessionStore.setPlaybackSinkFactory`).
    init(id: PlaybackID, path: String, resourceURI: String, volume: Double, deviceUID: String?,
         makeSink: PlaybackSinkFactory = systemPlaybackSink,
         onEnd: @escaping @Sendable (PlaybackID) async -> Void) throws
    {
        self.id = id
        self.path = path
        self.resourceURI = resourceURI
        self.volume = volume
        self.onEnd = onEnd
        reader = try WAVReader(path: path)
        sampleRate = reader.sampleRate
        frames = reader.frames
        do {
            sink = try makeSink(SinkID(), reader.sampleRate, volume, deviceUID)
        } catch {
            reader.close()
            throw error
        }
    }

    /// Where the playback has reached, in frames.
    var position: UInt64 { played }

    func start() {
        task = Task { [weak self] in await self?.play() }
    }

    func stop() async {
        task?.cancel()
        await finish()
    }

    private func finish() async {
        guard !stopped else { return }
        stopped = true
        reader.close()
        await sink.closeSink()
    }

    /// Reads and pushes at the file's own rate. The sink's ring is the buffer, so a late tick is
    /// absorbed without a dropout; a tick that would overfill it simply waits, which is what keeps
    /// a two-hour recording from being read into memory.
    private func play() async {
        let started = ContinuousClock.now
        var pushed: UInt64 = 0
        while !Task.isCancelled, !stopped {
            let block = reader.read(frames: Self.blockFrames)
            if block.isEmpty { break }
            block.withUnsafeBufferPointer { buf in
                buf.withMemoryRebound(to: Float.self) { floats in
                    let buffer = SampleBuffer(base: UnsafeMutableRawPointer(mutating: floats.baseAddress!),
                                              count: floats.count, format: .f32)
                    sink.write(buffer, at: SampleTime(captureID: CaptureID(), sampleIndex: pushed))
                }
            }
            pushed += UInt64(block.count)
            played = pushed
            // Pace against the start rather than sleeping a fixed block, so jitter never
            // accumulates -- the same rule FilePlaybackDevice's I/O thread follows.
            let due = Duration.seconds(Double(pushed) / Double(sampleRate))
            let elapsed = started.duration(to: ContinuousClock.now)
            if due > elapsed {
                try? await Task.sleep(for: due - elapsed)
            }
        }
        // Let the sink's ring drain before the device goes, or the last fifth of a second is cut.
        if !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await finish()
        await onEnd(id)
    }
}
