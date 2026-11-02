// SPDX-License-Identifier: GPL-3.0-or-later

// A stored recording as a decode job's input (decode.proto, `DecodeConfig.source_uri`;
// docs/dev/engine-internals.md, "Decoders"). The job reads the recording's parts in order and feeds
// the plugin as fast as it reads, with no capture, channel or lease: a recording needs no radio.
// An audio decoder reads an audio recording and an IQ decoder (SIGNAL_IQ) an IQ one, whose cf32
// parts go out a capture block per frame, as the live IQ path frames them.
//
// Under SEGMENTED input each part is cut by `Segmenter.cut` from its sidecar's `squelch_opens`,
// with the pre-roll and hang the live job uses, so a recording decoded later yields the segments a
// live job would have sent. Under any other input every part is sent whole, and the time between
// two parts is a gap. Times stay on the capture's timeline: a part's `start_sample` is a capture
// sample, and its WAV holds audio at the recording's rate, so a capture sample is placed in the file
// by the two rates the sidecar gives. An IQ part holds the capture's own samples, one for one, and
// a part at another centre or rate than the recording's is skipped.

import EngineCore
import Foundation
import LeylineProto

struct RecordingSource: Sendable {
    /// Audio samples per frame written to the plugin: 4096, the drain's own frame size.
    static let frameSamples = AudioFrameSource.maxFrame

    /// One part, as the source reads it.
    struct Part: Sendable {
        var number: Int
        var path: String
        var startSample: UInt64
        var endSample: UInt64
        /// Audio frames in the WAV.
        var frames: UInt64
        /// The capture whose timeline the part's samples are on, and its rate.
        var captureID: String
        var captureRate: Double
    }

    /// One stretch of one part for the plugin: a segment under SEGMENTED input (`over` its first
    /// opening's index in the part), else the whole part (`over` 0).
    struct Item: Sendable {
        var part: Int
        var span: Segmenter.Span
    }

    let recordingID: String
    let manifest: RecordingManifest
    let parts: [Part]
    let items: [Item]
    let segmented: Bool
    /// An IQ recording: cf32 parts at the capture rate, for an IQ decoder.
    var iq = false
    /// IQ parts recorded at a centre or rate other than the recording's, which the plugin is not
    /// given (`open`).
    var skippedParts = 0

    var uri: String { "ley://recordings/\(recordingID)" }
    var audioRate: UInt32 { UInt32(truncatingIfNeeded: manifest.sampleRate) }
    /// The capture rate the recording was made at, for the descriptor's span.
    var captureRate: UInt64 { UInt64(parts.first?.captureRate ?? 0) }
    /// Samples per frame written to the plugin: one capture block of IQ, as `IQFrameTap` frames the
    /// live stream, or `frameSamples` of audio.
    var samplesPerFrame: Int { iq ? CaptureDSPCore.blockSize : Self.frameSamples }

    /// Reads the recording `uri` names and plans what `decoder`, whose manifest asks for `input`,
    /// will get. The refusals are the caller's to see: a URI that is not a recording, a recording
    /// that does not exist (JOB_NOT_FOUND, as ResolveLocalPath says it), an IQ recording for an
    /// audio decoder, which needs an offline demodulator first (UNIMPLEMENTED), and an audio
    /// recording for an IQ decoder, which can never be one (INVALID_ARGUMENT).
    static func open(uri: String, store: RecordingStore, decoder: String,
                     input: Leyline_V1_DecoderInput) async throws -> RecordingSource
    {
        guard case .recording(let id, let part) = ResourceURI(uri) else {
            throw EngineError.invalidArgument("\(uri) is not a recording; a decoder reads ley://recordings/<id>", target: uri)
        }
        guard part == nil else {
            throw EngineError.invalidArgument("\(uri) names one part; a decoder reads the whole recording, ley://recordings/\(id)",
                                              target: uri)
        }
        guard let manifest = await store.manifest(jobID: id) else { throw EngineError.jobNotFound(id) }
        let iq = manifest.kind == "iq"
        let wantsIQ = input.signal == .signalIq
        if iq, !wantsIQ {
            throw EngineError(
                code: EngineError.Code.unimplemented,
                message: "\(decoder) reads demodulated audio and \(uri) holds raw IQ, which the daemon cannot "
                    + "demodulate from a recording yet; record audio for it",
                target: uri)
        }
        if !iq, wantsIQ {
            throw EngineError.invalidArgument(
                "\(uri) holds demodulated audio, and \(decoder) reads raw IQ; record with --iq for it", target: uri)
        }
        // A recording still being made has parts yet to close; it is read once it has ended.
        guard !manifest.endedBy.isEmpty else {
            throw EngineError.failedPrecondition(
                "\(uri) is still recording; decode it once its job has ended", target: uri)
        }
        let directory = store.directory + "/" + id
        let segmented = input.mode == .segmented
        let (preRollMs, hangMs) = Segmenter.timings(input)
        var parts: [Part] = []
        var items: [Item] = []
        var skipped = 0
        for entry in manifest.parts {
            let sidecar = Self.sidecar(of: entry, in: directory)
            let anchor = manifest.anchors.last { ($0.captureID ?? "") == sidecar?.anchor.captureID } ?? manifest.anchors.last
            var captureRate = Double(sidecar?.anchor.sampleRate ?? 0)
            if captureRate == 0 { captureRate = Double(anchor?.sampleRate ?? 0) }
            if captureRate == 0, entry.samples > 0 {
                // No anchor gives the rate: the part's own span over its frames does.
                captureRate = Double(entry.endSample - entry.startSample) / Double(entry.samples) * Double(manifest.sampleRate)
            }
            let part = Part(number: entry.part, path: directory + "/" + entry.file, startSample: entry.startSample,
                            endSample: entry.endSample, frames: entry.samples,
                            captureID: sidecar?.anchor.captureID ?? anchor?.captureID ?? "", captureRate: captureRate)
            parts.append(part)
            if iq, let sidecar, sidecar.centerHz != manifest.frequencyHz
                || (sidecar.anchor.sampleRate != 0 && sidecar.anchor.sampleRate != manifest.sampleRate)
            {
                // The plugin is told one centre and rate, the recording's, and the wire cannot
                // change them mid-stream; a part at another tuning would put every signal in it at
                // the wrong offset. It is skipped, and the time it covers is a gap.
                skipped += 1
                continue
            }
            if segmented {
                let perMs = captureRate / 1000
                let spans = Segmenter.cut(sidecar?.recording.squelchOpens ?? [], partStart: entry.startSample,
                                          partEnd: entry.endSample, preRoll: UInt64(Double(preRollMs) * perMs),
                                          hang: UInt64(Double(hangMs) * perMs))
                items += spans.map { Item(part: parts.count - 1, span: $0) }
            } else if entry.endSample > entry.startSample {
                items.append(Item(part: parts.count - 1,
                                  span: Segmenter.Span(start: entry.startSample, end: entry.endSample, over: 0)))
            }
        }
        return RecordingSource(recordingID: id, manifest: manifest, parts: parts, items: items, segmented: segmented, iq: iq,
                               skippedParts: skipped)
    }

    private static func sidecar(of part: RecordingPart, in directory: String) -> PartSidecar? {
        let base = (part.file as NSString).deletingPathExtension
        guard let data = FileManager.default.contents(atPath: directory + "/" + base + ".json") else { return nil }
        return try? JSONDecoder().decode(PartSidecar.self, from: data)
    }

    /// Where capture sample `sample` falls in `part`'s file, clamped to the file. An IQ part holds
    /// the capture's own samples, one for one; a WAV holds audio at the recording's rate.
    func frame(at sample: UInt64, in part: Part) -> UInt64 {
        guard sample > part.startSample else { return 0 }
        if iq { return Swift.min(part.frames, sample - part.startSample) }
        guard part.captureRate > 0 else { return 0 }
        let f = (Double(sample - part.startSample) * Double(manifest.sampleRate) / part.captureRate).rounded()
        return Swift.min(part.frames, UInt64(f))
    }

    /// The capture sample frame `frame` of `part`'s file sits at.
    func sample(at frame: UInt64, in part: Part) -> UInt64 {
        if iq { return part.startSample + frame }
        guard manifest.sampleRate > 0 else { return part.startSample }
        return part.startSample + UInt64((Double(frame) * part.captureRate / Double(manifest.sampleRate)).rounded())
    }

    /// The capture sample after the last one `item` can send, from what its file holds: the gap
    /// before the next part starts there, not where the manifest says the part ended.
    func readEnd(of item: Item) -> UInt64 {
        guard let reader = try? FrameReader(source: self, item: item, gapFrom: nil) else { return item.span.end }
        defer { reader.close() }
        return reader.endSample
    }

    /// The part and over a record stamped at `time` came from: the item that holds it on its
    /// capture's timeline, else the newest that started before it. Nil before the first.
    ///
    /// A plugin that dates a record a little before the segment's first sample -- a rounding of
    /// its own -- still means that segment: a time less than a millisecond before a span's start
    /// takes the span (`Segmenter.overTolerance`).
    func locate(_ time: Leyline_V1_SampleTime) -> Location? {
        let at = time.sampleIndex
        var hit: Int?
        for (i, item) in items.enumerated() {
            let part = parts[item.part]
            guard time.captureID.isEmpty || part.captureID == time.captureID else { continue }
            let slack = UInt64(part.captureRate * Segmenter.overTolerance)
            if at < item.span.end, at + slack >= item.span.start {
                hit = i
                break
            }
            if item.span.start <= at { hit = i }
        }
        return hit.map { i in
            let item = items[i]
            return Location(item: i, part: parts[item.part].number, over: item.span.over, captureID: parts[item.part].captureID)
        }
    }

    /// Where a record came from: the item's index in `items`, the part's number, the over, and the
    /// capture whose timeline the part is on.
    struct Location: Sendable {
        var item: Int
        var part: Int
        var over: UInt32
        var captureID: String
    }

    /// The frames one item sends, in order, read from its part's WAV as they are asked for. Under
    /// SEGMENTED input the first carries SEGMENT_START and the last is an empty SEGMENT_END at the
    /// sample after the segment's last; otherwise none is marked, and `gapFrom` marks the time
    /// before the part that the recording does not hold.
    func frames(of item: Item, gapFrom: UInt64?) throws -> FrameReader {
        try FrameReader(source: self, item: item, gapFrom: gapFrom)
    }

    /// Reads one item a frame at a time, so a long part is never held in memory whole: f32 audio
    /// from a WAV part, or cf32 as it lies in an IQ part.
    struct FrameReader {
        private let source: RecordingSource
        private let item: Item
        private let part: Part
        private let reader: PartReader
        private var at: UInt64
        /// Where the item ends in the file by the manifest, and where it can end: earlier when the
        /// file holds fewer samples than the manifest says, or a read comes back short.
        private let wanted: UInt64
        private var end: UInt64
        private var gapFrom: UInt64?
        private var first = true
        private var ended = false

        init(source: RecordingSource, item: Item, gapFrom: UInt64?) throws {
            self.source = source
            self.item = item
            part = source.parts[item.part]
            reader = source.iq ? .cf32(try CF32Reader(path: part.path)) : .wav(try WAVReader(path: part.path))
            at = source.frame(at: item.span.start, in: part)
            wanted = source.frame(at: item.span.end, in: part)
            end = Swift.min(wanted, reader.frames)
            self.gapFrom = gapFrom
            reader.seek(toFrame: at)
        }

        /// The capture sample after the last one this item sends: the span's end, or the sample
        /// where the file ran out. The gap before the next part starts here.
        var endSample: UInt64 { end < wanted ? source.sample(at: end, in: part) : item.span.end }

        func close() { reader.close() }

        /// The next frame, nil after the last. Closes the file when it is done.
        mutating func next() -> Leyline_V1_Frame? {
            if at < end {
                let (payload, count) = reader.read(frames: Int(Swift.min(UInt64(source.samplesPerFrame), end - at)))
                if count > 0 {
                    var frame = Leyline_V1_Frame()
                    frame.time.captureID = part.captureID
                    // The START is dated by the segment's own first sample, exactly, so a record
                    // the plugin stamps from it lands where the cut was made.
                    frame.time.sampleIndex = first ? item.span.start : source.sample(at: at, in: part)
                    frame.payload = payload
                    if first, source.segmented { frame.segment = .segmentStart }
                    if first, let from = gapFrom, from < frame.time.sampleIndex {
                        frame.gap.fromSample = from
                        frame.gap.toSample = frame.time.sampleIndex
                    }
                    first = false
                    at += UInt64(count)
                    return frame
                }
                // The file ended before its header or size said it would.
                end = at
            }
            reader.close()
            guard source.segmented, !first, !ended else { return nil }
            ended = true
            var frame = Leyline_V1_Frame()
            frame.time.captureID = part.captureID
            frame.time.sampleIndex = item.span.end
            frame.segment = .segmentEnd
            return frame
        }
    }

    /// One part's samples file, whichever kind the recording holds.
    enum PartReader {
        case wav(WAVReader)
        case cf32(CF32Reader)

        var frames: UInt64 {
            switch self {
            case .wav(let r): r.frames
            case .cf32(let r): r.frames
            }
        }

        func seek(toFrame frame: UInt64) {
            switch self {
            case .wav(let r): r.seek(toFrame: frame)
            case .cf32(let r): r.seek(toFrame: frame)
            }
        }

        /// Up to `frames` frames as the plugin's payload (f32 audio, or cf32), and how many there were.
        func read(frames: Int) -> (Data, Int) {
            switch self {
            case .wav(let r):
                let floats = r.read(frames: frames)
                return (floats.withUnsafeBytes { Data($0) }, floats.count)
            case .cf32(let r):
                let data = r.read(frames: frames)
                return (data, data.count / 8)
            }
        }

        func close() {
            switch self {
            case .wav(let r): r.close()
            case .cf32(let r): r.close()
            }
        }
    }

    /// An IQ part: interleaved little-endian f32 I and Q with no header, as `PartWriter` appends
    /// it. A trailing partial sample, left by a daemon that died mid-write, is not read.
    struct CF32Reader {
        static let bytesPerFrame: UInt64 = 8
        let frames: UInt64
        private let handle: FileHandle

        init(path: String) throws {
            guard let h = FileHandle(forReadingAtPath: path) else {
                throw EngineError.invalidArgument("cannot open \(path)", target: path)
            }
            handle = h
            frames = try h.seekToEnd() / Self.bytesPerFrame
            try h.seek(toOffset: 0)
        }

        /// Up to `frames` whole samples, empty at the end of the file.
        func read(frames wanted: Int) -> Data {
            guard let data = try? handle.read(upToCount: wanted * Int(Self.bytesPerFrame)) else { return Data() }
            return data.prefix(data.count - data.count % Int(Self.bytesPerFrame))
        }

        func seek(toFrame frame: UInt64) {
            try? handle.seek(toOffset: Swift.min(frame, frames) * Self.bytesPerFrame)
        }

        func close() { try? handle.close() }
    }
}
