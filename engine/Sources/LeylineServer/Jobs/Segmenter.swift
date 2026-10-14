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

    /// The manifest's pre-roll and hang, with 0 read as the defaults.
    static func timings(_ input: Leyline_V1_DecoderInput) -> (preRollMs: UInt32, hangMs: UInt32) {
        (input.preRollMs == 0 ? defaultPreRollMs : input.preRollMs,
         input.hangMs == 0 ? defaultHangMs : input.hangMs)
    }

    // MARK: The stored rule

    /// One segment of a stored part: capture samples `start..<end`, and `over`, the 1-based index
    /// in the part's `squelch_opens` of the first opening it holds.
    struct Span: Equatable, Sendable {
        var start: UInt64
        var end: UInt64
        var over: UInt32
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
    private var lastEnd: UInt64 = 0
    /// Segment starts and their 1-based index since the job began, newest last, so a record can be
    /// matched to its segment by the time the plugin stamped it.
    private var starts: [(start: UInt64, index: UInt32)] = []
    private(set) var segments: UInt32 = 0
    private static let keptStarts = 256

    init(preRollMs: UInt32, hangMs: UInt32, captureRateHz: UInt64, audioRateHz: UInt32,
         heardSlack: UInt64 = UInt64(CaptureDSPCore.blockSize / 2))
    {
        let perMs = Double(captureRateHz) / 1000
        preRollSamples = UInt64(Double(preRollMs) * perMs)
        hangSamples = UInt64(Double(hangMs) * perMs)
        perAudio = Double(captureRateHz) / Double(Swift.max(audioRateHz, 1))
        ringCapacity = Int(Double(preRollMs) / 1000 * Double(audioRateHz))
        self.heardSlack = heardSlack
        maxHoldSamples = UInt64(2 * Double(captureRateHz))
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

    /// The segment a record stamped at `time` belongs to: the newest that started at or before it.
    func over(at time: UInt64) -> UInt32? {
        starts.last { $0.start <= time }?.index
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

    /// Audio covering `from..<to`: into the open segment, or into the pre-roll ring.
    private mutating func take(_ chunk: ArraySlice<Float>, from: UInt64, to: UInt64, into out: inout [Piece]) {
        guard inSegment else {
            ring.append(contentsOf: chunk)
            if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
            ringEnd = to
            return
        }
        guard !chunk.isEmpty else { return }
        if startOwed {
            startOwed = false
            out.append(Piece(time: segmentStart, floats: Array(chunk), mark: .segmentStart, gap: nil))
            return
        }
        out.append(Piece(time: from, floats: Array(chunk), mark: .unspecified, gap: owedGap))
        owedGap = nil
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
        let held = UInt64((Double(ring.count) * perAudio).rounded())
        let ringStart = ringEnd > held ? ringEnd - held : 0
        let start = Swift.max(wanted, ringStart, startSample)
        let skip = Swift.min(ring.count, Int((Double(start - ringStart) / perAudio).rounded()))
        let preRoll = Array(ring[skip...])
        ring.removeAll(keepingCapacity: true)
        segments += 1
        starts.append((start, segments))
        if starts.count > Self.keptStarts { starts.removeFirst(starts.count - Self.keptStarts) }
        state = .open
        segmentStart = preRoll.isEmpty ? cursor : start
        owedGap = nil
        if preRoll.isEmpty {
            starts[starts.count - 1].start = cursor
            startOwed = true
        } else {
            out.append(Piece(time: start, floats: preRoll, mark: .segmentStart, gap: nil))
        }
    }

    private mutating func endSegment(at sample: UInt64, into out: inout [Piece]) {
        // A segment that never got audio was never started on the wire, so it is not ended there.
        if !startOwed { out.append(Piece(time: sample, floats: [], mark: .segmentEnd, gap: nil)) }
        startOwed = false
        owedGap = nil
        state = .closed
        ring.removeAll(keepingCapacity: true)
        ringEnd = sample
    }
}
