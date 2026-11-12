// SPDX-License-Identifier: GPL-3.0-or-later

// SEGMENTED decoder input: a channel's audio cut into overs at the squelch's own edges
// (docs/dev/engine-internals.md, "Decoders"; decode.proto, InputMode). A segment starts
// `pre_roll_ms` before the squelch opened and ends `hang_ms` after it closed, a squelch that reopens
// inside the hang continues the same segment, and nothing is sent while the squelch is shut.
//
// Two paths cut by the one rule. The live path is `Segmenter`, which follows the squelch records
// the way the gated recorder does (`RecordRunner.followSquelch`): edges are applied in sample order
// against the audio, never in arrival order, and a pre-roll ring holds audio while the squelch is
// shut. The stored path is `Segmenter.cut`, which reads the same edges back from a part sidecar's
// `squelch_opens`, so a recording transcribed later yields the segments the live job would have.
//
// A segment that reaches the manifest's `max_segment_ms` is cut there and the next one starts on
// the same sample, so a squelch that never closes (squelch off, a broadcast carrier, a mode with no
// gate) still yields segments a speech engine takes, and no audio falls between them. The cut is the
// middle of the quietest `quietWindowMs` in the last `quietLookbackMs` before the limit, so a word
// is rarely split; both paths find it with `quietest(_:window:)`.
//
// Everything is on the capture's timeline and in capture samples; the audio is placed on it by
// each frame's own span. Nothing here runs on the DSP thread (invariant 4): the decode runner's
// drain task owns the live segmenter, and the squelch follower only hands it records.

import EngineCore
import Foundation
import LeylineProto

struct Segmenter: Sendable {
    /// What `pre_roll_ms` and `hang_ms` mean when the manifest leaves them 0.
    static let defaultPreRollMs: UInt32 = 500
    static let defaultHangMs: UInt32 = 500

    /// How far before a segment's first sample a record may be dated and still belong to it, in
    /// seconds: a plugin that rounds its own arithmetic should not move its record into the over
    /// before.
    static let overTolerance = 0.001

    /// The manifest's pre-roll and hang, with 0 read as the defaults.
    static func timings(_ input: Leyline_V1_DecoderInput) -> (preRollMs: UInt32, hangMs: UInt32) {
        (input.preRollMs == 0 ? defaultPreRollMs : input.preRollMs,
         input.hangMs == 0 ? defaultHangMs : input.hangMs)
    }

    /// How long the window is that a cut at `max_segment_ms` looks for the quietest of, and how far
    /// back from the limit it looks.
    static let quietWindowMs: UInt32 = 200
    static let quietLookbackMs: UInt32 = 5000

    /// The FLAG field the daemon sets on a record from a segment that continues the one before it,
    /// cut at `max_segment_ms` out of one transmission.
    static let continuesField = "continues"

    /// Where to cut `audio`: the middle of its quietest stretch of `window` samples, by the sum of
    /// squares, the latest of equally quiet ones so a piece is as long as it can be. Nil when the
    /// audio is shorter than the window, or the window is empty.
    static func quietest(_ audio: ArraySlice<Float>, window: Int) -> Int? {
        guard window > 0, audio.count >= window else { return nil }
        let base = audio.startIndex
        var sum: Double = 0
        for i in 0..<window {
            let v = Double(audio[base + i])
            sum += v * v
        }
        var best = sum
        var bestStart = 0
        var start = 1
        while start + window <= audio.count {
            let leaving = Double(audio[base + start - 1])
            let entering = Double(audio[base + start + window - 1])
            sum = Swift.max(0, sum + entering * entering - leaving * leaving)
            // The running sum drifts by rounding; a relative slack keeps a run of silence from
            // losing to an earlier window of it.
            if sum <= best + 1e-9 * Swift.max(best, 1e-12) {
                best = Swift.min(best, sum)
                bestStart = start
            }
            start += 1
        }
        return bestStart + window / 2
    }

    /// Cuts every span longer than `maxSamples` into pieces of at most that, each cut where
    /// `quietest` says in the `lookback` before the limit, or at the limit when it says nothing.
    /// Every piece keeps its span's `over`; the ones after the first are marked `continues`.
    static func limit(_ spans: [Span], maxSamples: UInt64, lookback: UInt64,
                      quietest: (Range<UInt64>) -> UInt64?) -> [Span]
    {
        guard maxSamples > 0 else { return spans }
        var out: [Span] = []
        for span in spans {
            var start = span.start
            var continues = span.continues
            while span.end - start > maxSamples {
                let limit = start + maxSamples
                var cut = quietest((limit - Swift.min(lookback, maxSamples))..<limit) ?? limit
                if cut <= start || cut > limit { cut = limit }
                out.append(Span(start: start, end: cut, over: span.over, continues: continues))
                start = cut
                continues = true
            }
            out.append(Span(start: start, end: span.end, over: span.over, continues: continues))
        }
        return out
    }

    // MARK: The stored rule

    /// One segment of a stored part: capture samples `start..<end`, and `over`, the 1-based index
    /// in the part's `squelch_opens` of the first opening it holds (in a part with none, the
    /// piece's own number). `continues` is a piece after the first of one transmission cut at
    /// `max_segment_ms`.
    struct Span: Equatable, Sendable {
        var start: UInt64
        var end: UInt64
        var over: UInt32
        var continues = false
    }

    /// The segments of one part, from its squelch intervals. The live rule, applied to edges that
    /// are already known: each segment reaches `preRoll` back from its first opening and `hang` on
    /// from its last close, an opening less than `hang` after the previous close continues the
    /// segment, and a segment never reaches before the part's start or the previous segment's end,
    /// nor past the part's end. Intervals are taken in the order the sidecar lists them, which is
    /// the order they happened.
    static func cut(_ opens: [RecordingSquelchOpen], partStart: UInt64, partEnd: UInt64,
                    preRoll: UInt64, hang: UInt64) -> [Span]
    {
        var out: [Span] = []
        var current: Span?
        for (i, interval) in opens.enumerated() {
            let close = Swift.max(interval.closeSample, interval.openSample)
            if var open = current, interval.openSample < open.end {
                // Reopened inside the hang: the same over goes on.
                open.end = Swift.max(open.end, close + hang)
                current = open
                continue
            }
            if let done = current { out.append(done) }
            let floor = Swift.max(partStart, out.last?.end ?? partStart)
            let wanted = interval.openSample > preRoll ? interval.openSample - preRoll : 0
            current = Span(start: Swift.max(wanted, floor), end: close + hang, over: UInt32(i + 1))
        }
        if let done = current { out.append(done) }
        return out.compactMap { span in
            var s = span
            s.end = Swift.min(s.end, partEnd)
            return s.end > s.start ? s : nil
        }
    }

    // MARK: The live segmenter

    /// One frame for the plugin: audio from `time` on, or for an END the sample after the
    /// segment's last. `gap` is audio inside the segment that never reached the segmenter.
    struct Piece: Equatable, Sendable {
        var time: UInt64
        var floats: [Float]
        var mark: Leyline_V1_SegmentMark
        var gap: Range<UInt64>?
    }

    /// A drained audio frame: `floats` cover capture samples `start..<start + count`.
    struct Frame: Sendable {
        var start: UInt64
        var count: UInt64
        var floats: [Float]
        var dropped: UInt64
        var end: UInt64 { start + count }
    }

    /// What the channel's telemetry said, applied when the audio reaches its sample.
    enum Heard: Sendable {
        case squelch(open: Bool, at: UInt64)
        case meter(open: Bool, at: UInt64)

        var sample: UInt64 {
            switch self {
            case .squelch(_, let at), .meter(_, let at): return at
            }
        }
    }

    private enum State: Equatable {
        case closed
        case open
        case hanging(closedAt: UInt64)
    }

    let preRollSamples: UInt64
    let hangSamples: UInt64
    /// Capture samples per audio sample.
    let perAudio: Double
    /// The pre-roll ring's size, in audio samples.
    let ringCapacity: Int
    /// How far short of a frame's end a squelch record may be and still cover it: a record is
    /// stamped with its block's first sample, so half a block.
    let heardSlack: UInt64
    /// A frame older than this, behind the newest audio, goes on without waiting for telemetry
    /// that has stopped coming.
    let maxHoldSamples: UInt64
    /// `overTolerance` in capture samples.
    let toleranceSamples: UInt64
    /// `max_segment_ms` in capture samples, 0 for no limit, and how far back from the limit the
    /// quiet point is looked for, also in capture samples.
    let maxSegmentSamples: UInt64
    let lookbackSamples: UInt64
    /// `quietWindowMs` in audio samples.
    let quietWindow: Int

    private var state = State.closed
    private var waiting: [Frame] = []
    private var heard: [Heard] = []
    private var heardThrough: UInt64?
    private var squelchKnown = false
    private var started = false
    private var startSample: UInt64 = 0
    /// Audio while no segment is open, ending at `ringEnd`.
    private var ring: [Float] = []
    private var ringEnd: UInt64 = 0
    /// The open segment's first sample, and whether its START has still to go out because the
    /// pre-roll held no audio.
    private var segmentStart: UInt64 = 0
    private var startOwed = false
    /// Audio inside the open segment that a drop took, for the next piece.
    private var owedGap: Range<UInt64>?
    /// The open segment's newest pieces, from `holdFrom` on, kept back so the cut at the limit can
    /// be made at a quiet point inside them. Every piece passes through here, in order.
    private var held: [Piece] = []
    private var lastEnd: UInt64 = 0
    /// Segment starts and their 1-based index since the job began, newest last, so a record can be
    /// matched to its segment by the time the plugin stamped it.
    private var starts: [SegmentStart] = []
    private(set) var segments: UInt32 = 0
    private static let keptStarts = 256

    /// Where a segment starts, its count since the job began, and whether it continues the one
    /// before it, cut at the limit out of one transmission.
    struct SegmentStart: Equatable, Sendable {
        var start: UInt64
        var index: UInt32
        var continues: Bool
    }

    init(preRollMs: UInt32, hangMs: UInt32, captureRateHz: UInt64, audioRateHz: UInt32,
         maxSegmentMs: UInt32 = 0,
         heardSlack: UInt64 = UInt64(CaptureDSPCore.blockSize / 2))
    {
        let perMs = Double(captureRateHz) / 1000
        maxSegmentSamples = UInt64(Double(maxSegmentMs) * perMs)
        lookbackSamples = Swift.min(UInt64(Double(Self.quietLookbackMs) * perMs), maxSegmentSamples)
        quietWindow = Int(Double(Self.quietWindowMs) / 1000 * Double(audioRateHz))
        preRollSamples = UInt64(Double(preRollMs) * perMs)
        hangSamples = UInt64(Double(hangMs) * perMs)
        perAudio = Double(captureRateHz) / Double(Swift.max(audioRateHz, 1))
        ringCapacity = Int(Double(preRollMs) / 1000 * Double(audioRateHz))
        self.heardSlack = heardSlack
        maxHoldSamples = UInt64(2 * Double(captureRateHz))
        toleranceSamples = UInt64(Self.overTolerance * Double(captureRateHz))
        ring.reserveCapacity(ringCapacity + AudioFrameSource.maxFrame)
    }

    /// A squelch record or meter, in the channel's own order.
    mutating func hear(_ record: Heard) {
        heard.append(record)
        heardThrough = Swift.max(heardThrough ?? 0, record.sample)
    }

    mutating func push(_ frame: Frame) {
        waiting.append(frame)
    }

    /// The segment a record stamped at `time` belongs to: the newest that started at or before it,
    /// or less than `overTolerance` after it.
    func over(at time: UInt64) -> UInt32? {
        segment(at: time)?.index
    }

    /// The first sample of the segment a record stamped at `time` belongs to, by the same rule as
    /// `over(at:)`, with its count since the job began and whether it continues the one before.
    func segment(at time: UInt64) -> SegmentStart? {
        starts.last { $0.start <= time + toleranceSamples }
    }

    /// The waiting frames whose telemetry has been heard, cut into pieces for the plugin.
    mutating func release() -> [Piece] {
        var out: [Piece] = []
        let newest = waiting.last?.end ?? 0
        while let frame = waiting.first, isHeard(frame) || (newest > frame.start && newest - frame.start > maxHoldSamples) {
            waiting.removeFirst()
            process(frame, into: &out)
        }
        return out
    }

    private func isHeard(_ frame: Frame) -> Bool {
        guard let heardThrough else { return false }
        return heardThrough + heardSlack >= frame.end
    }

    /// One frame, walked in sample order: the audio up to each event goes where the state before
    /// it says, then the event applies. The events are the squelch records inside the frame and a
    /// hang that runs out inside it; on a tie the hang ends first, so a reopening exactly at the end
    /// of the hang starts a new segment.
    private mutating func process(_ frame: Frame, into out: inout [Piece]) {
        if !started {
            started = true
            startSample = frame.start
            ringEnd = frame.start
            lastEnd = frame.start
        }
        if frame.dropped > 0 {
            let hole = lastEnd..<Swift.max(lastEnd, frame.start)
            if inSegment {
                if !hole.isEmpty { owedGap = (owedGap?.lowerBound ?? hole.lowerBound)..<hole.upperBound }
            } else {
                // The pre-roll must not span a hole: what it holds is contiguous up to now.
                ring.removeAll(keepingCapacity: true)
                ringEnd = frame.start
            }
        }
        var cursor = frame.start
        var index = 0
        while let event = nextEvent(before: frame.end, cursor: cursor) {
            let to = audioIndex(event.at, in: frame, from: index)
            take(frame.floats[index..<to], from: cursor, to: event.at, into: &out)
            index = to
            cursor = event.at
            if event.hangEnds {
                endSegment(at: cursor, into: &out)
            } else {
                apply(heard.removeFirst(), at: cursor, into: &out)
            }
        }
        take(frame.floats[index...], from: cursor, to: frame.end, into: &out)
        lastEnd = frame.end
    }

    private var inSegment: Bool { state != .closed }

    private func nextEvent(before end: UInt64, cursor: UInt64) -> (at: UInt64, hangEnds: Bool)? {
        var next: (at: UInt64, hangEnds: Bool)?
        if case .hanging(let closedAt) = state, closedAt + hangSamples < end {
            next = (Swift.max(closedAt + hangSamples, cursor), true)
        }
        if let record = heard.first, record.sample < end {
            let at = Swift.max(record.sample, cursor)
            if next == nil || at < next!.at { next = (at, false) }
        }
        return next
    }

    /// Where capture sample `x` falls in the frame's audio, never behind what was already taken.
    private func audioIndex(_ x: UInt64, in frame: Frame, from taken: Int) -> Int {
        guard frame.count > 0 else { return frame.floats.count }
        let i = Int((Double(x - frame.start) / Double(frame.count) * Double(frame.floats.count)).rounded())
        return Swift.min(frame.floats.count, Swift.max(taken, i))
    }

    /// Audio covering `from..<to`: into the open segment, or into the pre-roll ring. A segment the
    /// audio carries past its limit is cut, and the rest of the audio goes into the next one.
    private mutating func take(_ chunk: ArraySlice<Float>, from: UInt64, to: UInt64, into out: inout [Piece]) {
        guard inSegment else {
            ring.append(contentsOf: chunk)
            if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
            ringEnd = to
            return
        }
        guard !chunk.isEmpty else { return }
        var rest = chunk
        var at = from
        while maxSegmentSamples > 0, to > limit, !rest.isEmpty {
            let limit = self.limit
            let k = limit > at
                ? Swift.min(rest.count, Int((Double(limit - at) / Double(to - at) * Double(rest.count)).rounded()))
                : 0
            if k > 0 { put(rest.prefix(k), from: at) }
            cut(at: limit, into: &out)
            rest = rest.dropFirst(k)
            at = Swift.max(at, limit)
        }
        if !rest.isEmpty { put(rest, from: at) }
        flushUnheld(into: &out)
    }

    /// The open segment's limit, and where its pieces start being held for the cut there.
    private var limit: UInt64 { segmentStart + maxSegmentSamples }
    private var holdFrom: UInt64 { limit - lookbackSamples }

    /// Audio into the open segment: the START when one is owed, else a piece carrying any gap.
    /// It goes into `held`; `flushUnheld` lets go of what lies before `holdFrom`.
    private mutating func put(_ chunk: ArraySlice<Float>, from: UInt64) {
        if startOwed {
            startOwed = false
            held.append(Piece(time: segmentStart, floats: Array(chunk), mark: .segmentStart, gap: nil))
            return
        }
        held.append(Piece(time: from, floats: Array(chunk), mark: .unspecified, gap: owedGap))
        owedGap = nil
    }

    /// The capture sample after a piece's last.
    private func end(of piece: Piece) -> UInt64 {
        piece.time + UInt64((Double(piece.floats.count) * perAudio).rounded())
    }

    /// Sends the held pieces that end before the stretch the cut looks in; with no limit, all.
    private mutating func flushUnheld(into out: inout [Piece]) {
        var n = 0
        while n < held.count, maxSegmentSamples == 0 || end(of: held[n]) <= holdFrom { n += 1 }
        guard n > 0 else { return }
        out.append(contentsOf: held.prefix(n))
        held.removeFirst(n)
    }

    /// Ends the open segment at the quiet point in the held audio, or at `limit` when it holds too
    /// little to look in, and starts the next one on the same sample with the audio after it, so
    /// nothing is lost or sent twice.
    private mutating func cut(at limit: UInt64, into out: inout [Piece]) {
        flushUnheld(into: &out)
        if startOwed {
            // The segment never got audio (a drop took it), so it was never started on the wire:
            // it starts again from here.
            segmentStart = limit
            if !starts.isEmpty { starts[starts.count - 1].start = limit }
            return
        }
        // The held audio from the lookback on, end to end, and the quietest window's middle in it.
        let audio = held.flatMap(\.floats)
        let skip = Swift.max(0, audio.count - Int((Double(lookbackSamples) / perAudio).rounded()))
        var boundary = limit
        var piece = held.count
        var offset = 0
        if var index = Self.quietest(audio[skip...], window: quietWindow).map({ skip + $0 }) {
            for (i, p) in held.enumerated() {
                if index < p.floats.count {
                    piece = i
                    offset = index
                    break
                }
                index -= p.floats.count
            }
            if piece < held.count {
                boundary = held[piece].time + UInt64((Double(offset) * perAudio).rounded())
            }
        }
        var after: [Piece] = []
        if piece < held.count {
            let split = held[piece]
            out.append(contentsOf: held[..<piece])
            if offset > 0 {
                out.append(Piece(time: split.time, floats: Array(split.floats[..<offset]), mark: split.mark, gap: split.gap))
            }
            after.append(Piece(time: boundary, floats: Array(split.floats[offset...]), mark: .unspecified, gap: nil))
            after.append(contentsOf: held[(piece + 1)...])
        } else {
            out.append(contentsOf: held)
        }
        held = []
        out.append(Piece(time: boundary, floats: [], mark: .segmentEnd, gap: nil))
        segments += 1
        starts.append(SegmentStart(start: boundary, index: segments, continues: true))
        if starts.count > Self.keptStarts { starts.removeFirst(starts.count - Self.keptStarts) }
        segmentStart = boundary
        startOwed = true
        owedGap = nil
        for var p in after where !p.floats.isEmpty {
            if startOwed {
                startOwed = false
                p.mark = .segmentStart
                p.time = boundary
                p.gap = nil
            }
            held.append(p)
        }
        flushUnheld(into: &out)
    }

    private mutating func apply(_ record: Heard, at cursor: UInt64, into out: inout [Piece]) {
        switch record {
        case .squelch(let open, let at):
            squelchKnown = true
            edge(open: open, at: at, cursor: cursor, into: &out)
        case .meter(let open, let at):
            // The first meter tells a segmenter that started under an open squelch -- a carrier
            // that was already on the air -- that it is open, since no edge will come. After that,
            // a meter that disagrees is an edge the follower missed.
            guard squelchKnown else {
                squelchKnown = true
                if open { openSegment(wanted: 0, cursor: cursor, into: &out) }
                return
            }
            if open != (state == .open) { edge(open: open, at: at, cursor: cursor, into: &out) }
        }
    }

    private mutating func edge(open: Bool, at sample: UInt64, cursor: UInt64, into out: inout [Piece]) {
        switch (open, state) {
        case (true, .closed):
            openSegment(wanted: sample > preRollSamples ? sample - preRollSamples : 0, cursor: cursor, into: &out)
        case (true, .hanging):
            state = .open
        case (false, .open):
            state = .hanging(closedAt: sample)
        default:
            break
        }
    }

    /// Opens a segment reaching back to `wanted`, or to the oldest audio the ring holds if that is
    /// later, and sends the ring from there as the START.
    private mutating func openSegment(wanted: UInt64, cursor: UInt64, into out: inout [Piece]) {
        let inRing = UInt64((Double(ring.count) * perAudio).rounded())
        let ringStart = ringEnd > inRing ? ringEnd - inRing : 0
        let start = Swift.max(wanted, ringStart, startSample)
        let skip = Swift.min(ring.count, Int((Double(start - ringStart) / perAudio).rounded()))
        let preRoll = Array(ring[skip...])
        ring.removeAll(keepingCapacity: true)
        segments += 1
        starts.append(SegmentStart(start: start, index: segments, continues: false))
        if starts.count > Self.keptStarts { starts.removeFirst(starts.count - Self.keptStarts) }
        state = .open
        segmentStart = preRoll.isEmpty ? cursor : start
        owedGap = nil
        held = []
        if preRoll.isEmpty {
            starts[starts.count - 1].start = cursor
            startOwed = true
            return
        }
        // The pre-roll goes out in frames no longer than the drain's own, the first marked START,
        // so no single frame is big enough for one slow read to trip the plugin's stall limit.
        var offset = 0
        while offset < preRoll.count {
            let end = Swift.min(preRoll.count, offset + AudioFrameSource.maxFrame)
            let at = start + UInt64((Double(offset) * perAudio).rounded())
            held.append(Piece(time: at, floats: Array(preRoll[offset..<end]),
                              mark: offset == 0 ? .segmentStart : .unspecified, gap: nil))
            offset = end
        }
        flushUnheld(into: &out)
    }

    private mutating func endSegment(at sample: UInt64, into out: inout [Piece]) {
        out.append(contentsOf: held)
        held = []
        // A segment that never got audio was never started on the wire, so it is not ended there.
        if !startOwed { out.append(Piece(time: sample, floats: [], mark: .segmentEnd, gap: nil)) }
        startOwed = false
        owedGap = nil
        state = .closed
        ring.removeAll(keepingCapacity: true)
        ringEnd = sample
    }
}
