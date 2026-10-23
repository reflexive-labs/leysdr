// SPDX-License-Identifier: GPL-3.0-or-later

// A stored audio recording as a decode job's input (decode.proto, `DecodeConfig.source_uri`;
// docs/dev/engine-internals.md, "Decoders"). The job reads the recording's parts in order and feeds
// the plugin as fast as it reads, with no capture, channel or lease: a recording needs no radio.
//
// Under SEGMENTED input each part is cut by `Segmenter.cut` from its sidecar's `squelch_opens`,
// with the pre-roll and hang the live job uses, so a recording decoded later yields the segments a
// live job would have sent. Under any other input every part is sent whole, and the time between
// two parts is a gap. Times stay on the capture's timeline: a part's `start_sample` is a capture
// sample, and its WAV holds audio at the recording's rate, so a capture sample is placed in the file
// by the two rates the sidecar gives.

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

    var uri: String { "ley://recordings/\(recordingID)" }
    var audioRate: UInt32 { UInt32(truncatingIfNeeded: manifest.sampleRate) }
    /// The capture rate the recording was made at, for the descriptor's span.
    var captureRate: UInt64 { UInt64(parts.first?.captureRate ?? 0) }

    /// Reads the recording `uri` names and plans what the plugin will get. The refusals are the
    /// caller's to see: a URI that is not a recording, a recording that does not exist
    /// (JOB_NOT_FOUND, as ResolveLocalPath says it), and an IQ recording, which needs an offline
    /// demodulator first (UNIMPLEMENTED).
    static func open(uri: String, store: RecordingStore, input: Leyline_V1_DecoderInput) async throws -> RecordingSource {
        guard case .recording(let id, let part) = ResourceURI(uri) else {
            throw EngineError.invalidArgument("\(uri) is not a recording; a decoder reads ley://recordings/<id>", target: uri)
        }
        guard part == nil else {
            throw EngineError.invalidArgument("\(uri) names one part; a decoder reads the whole recording, ley://recordings/\(id)",
                                              target: uri)
        }
        guard let manifest = await store.manifest(jobID: id) else { throw EngineError.jobNotFound(id) }
        guard manifest.kind == "audio" else { throw EngineError.unimplemented("decoding an IQ recording") }
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
        return RecordingSource(recordingID: id, manifest: manifest, parts: parts, items: items, segmented: segmented)
    }

    private static func sidecar(of part: RecordingPart, in directory: String) -> PartSidecar? {
        let base = (part.file as NSString).deletingPathExtension
        guard let data = FileManager.default.contents(atPath: directory + "/" + base + ".json") else { return nil }
        return try? JSONDecoder().decode(PartSidecar.self, from: data)
    }

    /// Where capture sample `sample` falls in `part`'s WAV, clamped to the file.
    func frame(at sample: UInt64, in part: Part) -> UInt64 {
        guard part.captureRate > 0, sample > part.startSample else { return 0 }
        let f = (Double(sample - part.startSample) * Double(manifest.sampleRate) / part.captureRate).rounded()
        return Swift.min(part.frames, UInt64(f))
    }

    /// The capture sample WAV frame `frame` of `part` sits at.
    func sample(at frame: UInt64, in part: Part) -> UInt64 {
        guard manifest.sampleRate > 0 else { return part.startSample }
        return part.startSample + UInt64((Double(frame) * part.captureRate / Double(manifest.sampleRate)).rounded())
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

    /// Reads one item's audio a frame at a time, so a long part is never held in memory whole.
    struct FrameReader {
        private let source: RecordingSource
        private let item: Item
        private let part: Part
        private let reader: WAVReader
        private var at: UInt64
        private let end: UInt64
        private var gapFrom: UInt64?
        private var first = true
        private var ended = false

        init(source: RecordingSource, item: Item, gapFrom: UInt64?) throws {
            self.source = source
            self.item = item
            part = source.parts[item.part]
            reader = try WAVReader(path: part.path)
            at = source.frame(at: item.span.start, in: part)
            end = Swift.min(source.frame(at: item.span.end, in: part), reader.frames)
            self.gapFrom = gapFrom
            reader.seek(toFrame: at)
        }

        /// The next frame, nil after the last. Closes the file when it is done.
        mutating func next() -> Leyline_V1_Frame? {
            if at < end {
                let floats = reader.read(frames: Int(Swift.min(UInt64(RecordingSource.frameSamples), end - at)))
                if !floats.isEmpty {
                    var frame = Leyline_V1_Frame()
                    frame.time.captureID = part.captureID
                    // The START is dated by the segment's own first sample, exactly, so a record
                    // the plugin stamps from it lands where the cut was made.
                    frame.time.sampleIndex = first ? item.span.start : source.sample(at: at, in: part)
                    frame.payload = floats.withUnsafeBytes { Data($0) }
                    if first, source.segmented { frame.segment = .segmentStart }
                    if first, let from = gapFrom, from < frame.time.sampleIndex {
                        frame.gap.fromSample = from
                        frame.gap.toSample = frame.time.sampleIndex
                    }
                    first = false
                    at += UInt64(floats.count)
                    return frame
                }
                at = end
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
}
