// SPDX-License-Identifier: GPL-3.0-or-later

// The SEGMENTED cut on synthetic edges and audio: where a segment starts and ends, what it holds,
// and that nothing is released while the squelch is shut (docs/dev/engine-internals.md, "Decoders").
//
// The numbers are small on purpose: a capture at 10 kHz and audio at 1 kHz, so ten capture samples
// per audio sample, 100 ms of pre-roll and hang (1000 capture samples, 100 audio samples), and each
// audio sample's value is its own index on the audio timeline, so a piece shows what it carries.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class SegmenterTests: XCTestCase {
    private func segmenter() -> Segmenter {
        Segmenter(preRollMs: 100, hangMs: 100, captureRateHz: 10_000, audioRateHz: 1_000, heardSlack: 0)
    }

    /// Frames of 1000 capture samples from `from` to `to`, each sample's value its audio index.
    private func push(_ s: inout Segmenter, from: UInt64, to: UInt64) {
        var at = from
        while at < to {
            let floats = (0..<100).map { Float(at / 10 + UInt64($0)) }
            s.push(Segmenter.Frame(start: at, count: 1000, floats: floats, dropped: 0))
            at += 1000
        }
    }

    /// The segments in `pieces`, as (START time, END time, audio samples between), and any audio
    /// that arrived outside a segment.
    private func segments(_ pieces: [Segmenter.Piece]) -> (spans: [(start: UInt64, end: UInt64, samples: [Float])], outside: Int) {
        var out: [(UInt64, UInt64, [Float])] = []
        var open: (UInt64, [Float])?
        var outside = 0
        for p in pieces {
            switch p.mark {
            case .segmentStart:
                XCTAssertNil(open, "a START inside a segment")
                XCTAssertFalse(p.floats.isEmpty, "a START carries audio")
                open = (p.time, p.floats)
            case .segmentEnd:
                XCTAssertTrue(p.floats.isEmpty, "an END carries no audio")
                if let o = open { out.append((o.0, p.time, o.1)) }
                open = nil
            default:
                if open == nil { outside += 1 } else { open!.1.append(contentsOf: p.floats) }
            }
        }
        return (out, outside)
    }

    func testASegmentRunsFromThePreRollToTheHang() {
        var s = segmenter()
        s.hear(.meter(open: false, at: 0))
        s.hear(.squelch(open: true, at: 5000))
        s.hear(.squelch(open: false, at: 8000))
        s.hear(.meter(open: false, at: 20_000))
        push(&s, from: 0, to: 20_000)
        let got = segments(s.release())
        XCTAssertEqual(got.outside, 0, "nothing is sent while the squelch is shut")
        XCTAssertEqual(got.spans.count, 1)
        XCTAssertEqual(got.spans.first?.start, 4000, "the pre-roll reaches 100 ms back from the open")
        XCTAssertEqual(got.spans.first?.end, 9000, "the hang runs 100 ms on from the close")
        XCTAssertEqual(got.spans.first?.samples, (400..<900).map(Float.init),
                       "exactly the audio from the pre-roll to the end of the hang, in order")
        XCTAssertEqual(s.over(at: 4000), 1)
        XCTAssertNil(s.over(at: 3989), "more than 1 ms before the first segment is none")
    }

    func testAReopeningInsideTheHangContinuesTheSegment() {
        var s = segmenter()
        s.hear(.meter(open: false, at: 0))
        s.hear(.squelch(open: true, at: 5000))
        s.hear(.squelch(open: false, at: 6000))
        s.hear(.squelch(open: true, at: 6500))
        s.hear(.squelch(open: false, at: 7000))
        s.hear(.meter(open: false, at: 20_000))
        push(&s, from: 0, to: 20_000)
        let got = segments(s.release())
        XCTAssertEqual(got.spans.map(\.start), [4000])
        XCTAssertEqual(got.spans.map(\.end), [8000])
    }

    func testAReopeningAfterTheHangIsANewSegmentThatStartsNoEarlierThanTheLastEnded() {
        var s = segmenter()
        s.hear(.meter(open: false, at: 0))
        s.hear(.squelch(open: true, at: 5000))
        s.hear(.squelch(open: false, at: 6000))
        // The hang ends at 7000; this opening's pre-roll would reach back to 6500.
        s.hear(.squelch(open: true, at: 7500))
        s.hear(.squelch(open: false, at: 8000))
        s.hear(.meter(open: false, at: 20_000))
        push(&s, from: 0, to: 20_000)
        let got = segments(s.release())
        XCTAssertEqual(got.spans.map(\.start), [4000, 7000])
        XCTAssertEqual(got.spans.map(\.end), [7000, 9000])
        XCTAssertEqual(got.spans.last?.samples, (700..<900).map(Float.init))
        XCTAssertEqual(s.over(at: 7000), 2)
    }

    func testNothingIsReleasedBeforeTheTelemetryAboutItHasBeenHeard() {
        var s = segmenter()
        push(&s, from: 0, to: 4000)
        XCTAssertTrue(s.release().isEmpty, "the squelch's state at these samples is not known yet")
        s.hear(.meter(open: false, at: 0))
        s.hear(.squelch(open: true, at: 2500))
        s.hear(.meter(open: true, at: 4000))
        let got = s.release()
        XCTAssertEqual(got.first?.mark, .segmentStart)
        XCTAssertEqual(got.first?.time, 1500, "the edge applies at its own sample, not when it arrived")
    }

    func testASquelchOpenWhenTheJobStartedOpensASegmentAtOnce() {
        var s = segmenter()
        s.hear(.meter(open: true, at: 0))
        s.hear(.squelch(open: false, at: 3000))
        s.hear(.meter(open: false, at: 10_000))
        push(&s, from: 0, to: 10_000)
        let got = segments(s.release())
        XCTAssertEqual(got.spans.map(\.start), [0])
        XCTAssertEqual(got.spans.map(\.end), [4000])
    }

    func testTheStoredCutAgreesWithTheLiveOne() {
        let opens = [RecordingSquelchOpen(openSample: 5000, closeSample: 6000),
                     RecordingSquelchOpen(openSample: 6500, closeSample: 7000),
                     RecordingSquelchOpen(openSample: 9500, closeSample: 10_000),
                     RecordingSquelchOpen(openSample: 19_800, closeSample: 19_900)]
        let spans = Segmenter.cut(opens, partStart: 4200, partEnd: 20_000, preRoll: 1000, hang: 1000)
        XCTAssertEqual(spans, [
            // The pre-roll is clamped to the part's start, and the reopening at 6500 continues.
            .init(start: 4200, end: 8000, over: 1),
            .init(start: 8500, end: 11_000, over: 3),
            // The hang is clamped to the part's end.
            .init(start: 18_800, end: 20_000, over: 4),
        ])

        var s = segmenter()
        s.hear(.meter(open: false, at: 0))
        for o in opens {
            s.hear(.squelch(open: true, at: o.openSample))
            s.hear(.squelch(open: false, at: o.closeSample))
        }
        s.hear(.meter(open: false, at: 30_000))
        push(&s, from: 0, to: 30_000)
        let live = segments(s.release())
        XCTAssertEqual(live.spans.map(\.start), [4000, 8500, 18_800])
        XCTAssertEqual(live.spans.map(\.end), [8000, 11_000, 20_900])
    }

    func testARecordDatedJustBeforeItsSegmentStillBelongsToIt() {
        var s = segmenter()
        s.hear(.meter(open: false, at: 0))
        s.hear(.squelch(open: true, at: 5000))
        s.hear(.squelch(open: false, at: 6000))
        s.hear(.squelch(open: true, at: 9000))
        s.hear(.meter(open: false, at: 20_000))
        push(&s, from: 0, to: 20_000)
        _ = s.release()
        // Starts at 4000 and 8000; 10 samples is 1 ms at this capture rate.
        XCTAssertEqual(s.over(at: 7990), 2, "10 samples early is still the second segment")
        XCTAssertEqual(s.over(at: 7900), 1)

        var manifest = RecordingManifest(
            jobID: "job_x", kind: "audio", frequencyHz: 0, mode: "NFM", bandwidthHz: 0, sampleRate: 48_000,
            format: "wav-s16", device: nil, gains: [], squelchDbfs: .nan, gate: nil, partMs: 0, startedAtNs: 0,
            createdBy: RecordingClient(clientID: "", kind: "", label: ""), anchors: [])
        manifest.parts = []
        let part = RecordingSource.Part(number: 1, path: "", startSample: 0, endSample: 480_000, frames: 48_000,
                                        captureID: "cap_x", captureRate: 480_000)
        let source = RecordingSource(
            recordingID: "job_x", manifest: manifest, parts: [part],
            items: [.init(part: 0, span: .init(start: 1000, end: 2000, over: 1)),
                    .init(part: 0, span: .init(start: 5000, end: 9000, over: 2))],
            segmented: true)
        var time = Leyline_V1_SampleTime()
        time.captureID = "cap_x"
        time.sampleIndex = 4990
        XCTAssertEqual(source.locate(time)?.over, 2, "10 samples before a span takes the span")
        time.sampleIndex = 990
        XCTAssertEqual(source.locate(time)?.over, 1, "and before the first span too")
        time.sampleIndex = 3000
        XCTAssertEqual(source.locate(time)?.over, 1, "between spans, the one that started before")
    }

    func testAPreRollLongerThanAFrameIsSentInFrames() {
        var s = Segmenter(preRollMs: 500, hangMs: 100, captureRateHz: 480_000, audioRateHz: 48_000, heardSlack: 0)
        s.hear(.meter(open: false, at: 0))
        s.hear(.squelch(open: true, at: 480_000))
        s.hear(.meter(open: true, at: 500_000))
        var at: UInt64 = 0
        while at < 500_000 {
            s.push(Segmenter.Frame(start: at, count: 10_000, floats: [Float](repeating: 0, count: 1000), dropped: 0))
            at += 10_000
        }
        let pieces = s.release()
        let preRoll = pieces.prefix { $0.time < 480_000 }
        XCTAssertEqual(preRoll.reduce(0) { $0 + $1.floats.count }, 24_000, "half a second at 48 kHz")
        XCTAssertTrue(preRoll.allSatisfy { $0.floats.count <= AudioFrameSource.maxFrame })
        XCTAssertEqual(preRoll.first?.mark, .segmentStart)
        XCTAssertEqual(preRoll.first?.time, 240_000)
        XCTAssertEqual(preRoll.dropFirst().filter { $0.mark != .unspecified }.count, 0, "only the first is marked")
    }

    // MARK: A squelch that never closes

    /// Frames of 1000 capture samples from `from` to `to`, each audio sample `value(i)` for its
    /// audio index `i`.
    private func push(_ s: inout Segmenter, from: UInt64, to: UInt64, value: (UInt64) -> Float) {
        var at = from
        while at < to {
            let floats = (0..<UInt64(100)).map { value(at / 10 + $0) }
            s.push(Segmenter.Frame(start: at, count: 1000, floats: floats, dropped: 0))
            at += 1000
        }
    }

    /// 30 s of audio at full scale with 200 ms of silence at 6.5 s: audio sample `i` is `i + 1`
    /// except in the silence, so the samples show their order and none is zero by accident.
    private func loudWithOneDip(_ i: UInt64) -> Float {
        (6500..<6700).contains(i) ? 0 : Float(i + 1)
    }

    /// Checks that `spans` follow each other with no gap and no overlap, that each is at most
    /// `max` capture samples, and that their audio is exactly `expected` in order.
    private func assertContiguous(_ spans: [(start: UInt64, end: UInt64, samples: [Float])], max: UInt64,
                                  expected: [Float], file: StaticString = #filePath, line: UInt = #line)
    {
        for (a, b) in zip(spans, spans.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "the next segment starts on the sample the last one ended", file: file, line: line)
        }
        for s in spans {
            XCTAssertLessThanOrEqual(s.end - s.start, max, "no segment is longer than the limit", file: file, line: line)
            XCTAssertEqual(UInt64(s.samples.count) * 10, s.end - s.start, "a segment holds exactly its span", file: file, line: line)
        }
        XCTAssertEqual(spans.flatMap(\.samples), expected, "every sample once, in order", file: file, line: line)
    }

    /// The defect `max_segment_ms` fixes: without a limit, a squelch that never closes is one
    /// segment that never ends, which the plugin SDK drops after ten minutes.
    func testWithoutALimitASquelchThatNeverClosesIsOneSegmentThatNeverEnds() {
        var s = segmenter()
        s.hear(.meter(open: true, at: 0))
        s.hear(.meter(open: true, at: 300_000))
        push(&s, from: 0, to: 300_000)
        let pieces = s.release()
        XCTAssertEqual(pieces.filter { $0.mark == .segmentStart }.count, 1)
        XCTAssertEqual(pieces.filter { $0.mark == .segmentEnd }.count, 0, "nothing ever ends it")
    }

    func testASquelchThatNeverClosesIsCutAtTheLimitAtAQuietPointWithNothingLost() {
        // 8 s limit, so the quiet point is looked for in the 5 s before each limit.
        var s = Segmenter(preRollMs: 100, hangMs: 100, captureRateHz: 10_000, audioRateHz: 1_000, maxSegmentMs: 8000,
                          heardSlack: 0)
        s.hear(.meter(open: true, at: 0))
        s.hear(.meter(open: true, at: 300_000))
        push(&s, from: 0, to: 300_000, value: loudWithOneDip)
        let got = segments(s.release())
        XCTAssertEqual(got.outside, 0)
        // The last segment is still open when the audio stops.
        let expected = (0..<UInt64(got.spans.last?.end ?? 0) / 10).map(loudWithOneDip)
        assertContiguous(got.spans, max: 80_000, expected: expected)
        XCTAssertEqual(got.spans.first?.start, 0)
        XCTAssertEqual(got.spans.first?.end, 66_000, "the first cut is the middle of the silence, 6.6 s")
        // From 6.6 s the audio only gets louder, so the quietest 200 ms in the 5 s before the
        // limit at 14.6 s is the first of them, 9.6 to 9.8 s.
        XCTAssertEqual(got.spans.dropFirst().first?.end, 97_000)
        XCTAssertGreaterThanOrEqual(got.spans.count, 4)
        XCTAssertEqual(s.segment(at: 0)?.continues, false, "the first piece starts the transmission")
        XCTAssertEqual(s.segment(at: 66_000)?.continues, true, "every piece after it continues it")
        XCTAssertEqual(s.segment(at: 97_000)?.continues, true)
    }

    /// `value` in frames of 1000 capture samples, with `hole` missing: the frame after it
    /// says it follows a drop when `flagged`, and arrives without saying so otherwise (the ring
    /// counts a drop on the frame read after it, and the time it took can show on a later one).
    /// Returns what the segmenter released, a frame at a time, as the drain hands it frames.
    private func cutAcross(hole: Range<UInt64>, flagged: Bool = true,
                           value: (UInt64) -> Float = { (6500..<6700).contains($0) ? 0 : Float($0 + 1) }) -> [Segmenter.Piece]
    {
        var s = Segmenter(preRollMs: 100, hangMs: 100, captureRateHz: 10_000, audioRateHz: 1_000, maxSegmentMs: 8000,
                          heardSlack: 0)
        s.hear(.meter(open: true, at: 0))
        s.hear(.meter(open: true, at: 300_000))
        var pieces: [Segmenter.Piece] = []
        var at: UInt64 = 0
        while at < 300_000 {
            if hole.contains(at) {
                at += 1000
                continue
            }
            let floats = (0..<UInt64(100)).map { value(at / 10 + $0) }
            let dropped = flagged && at == hole.upperBound ? UInt64(hole.count) : 0
            s.push(Segmenter.Frame(start: at, count: 1000, floats: floats, dropped: dropped))
            pieces += s.release()
            at += 1000
        }
        return pieces
    }

    /// Checks that every piece's audio is where its time says (each sample is its audio index
    /// plus one, or 0 in the dip), and that from one piece to the next the timeline is covered by
    /// audio or by a gap the later piece reports: nothing goes missing that the plugin is not
    /// told of, at a cut or anywhere else. Returns the capture samples reported dropped.
    @discardableResult
    private func assertTiled(_ pieces: [Segmenter.Piece], file: StaticString = #filePath, line: UInt = #line) -> UInt64 {
        var end: UInt64?
        var reported: UInt64 = 0
        for p in pieces where !p.floats.isEmpty {
            let gap = UInt64(p.gap?.count ?? 0)
            reported += gap
            if let end {
                XCTAssertEqual(p.time, end + gap, "a piece follows the audio before it, or the gap it reports (\(p.mark))",
                               file: file, line: line)
            }
            if let i = p.floats.indices.first(where: { p.floats[$0] != 0 }) {
                XCTAssertEqual(p.floats[i], Float(p.time / 10 + UInt64(i) + 1), "a piece's audio is placed by its time",
                               file: file, line: line)
            }
            end = p.time + UInt64(p.floats.count) * 10
        }
        return reported
    }

    /// The CI failure of 2026-11-12: a drop whose next frame ran past the open segment's limit. The
    /// cut came before that frame's audio went in, and it forgot the gap, so the plugin was never
    /// told and the audio after the hole sat where the hole should have been.
    func testADropThatRunsPastTheLimitIsReportedAfterTheCut() {
        let pieces = cutAcross(hole: 77_000..<83_000)
        XCTAssertEqual(segments(pieces).spans.first?.end, 66_000, "the cut is still the middle of the silence")
        XCTAssertEqual(assertTiled(pieces), 6000, "the whole hole is reported, once")
    }

    func testADropJustBeforeTheCutIsReportedOnTheNextSegmentsStart() {
        // 400 ms of silence from 6.4 s with 100 ms of it dropped: the latest quiet 200 ms that is
        // left runs from 6.5 s across the hole, so the cut, its middle, is the first sample after it.
        let pieces = cutAcross(hole: 66_000..<67_000) { (6400..<6800).contains($0) ? 0 : Float($0 + 1) }
        let start = pieces.first { $0.mark == .segmentStart && $0.time > 0 }
        XCTAssertEqual(start?.time, 67_000)
        XCTAssertEqual(start?.gap, 66_000..<67_000, "the START says what was lost before it")
        XCTAssertEqual(assertTiled(pieces), 1000)
    }

    func testADropLongerThanTheLimitStartsTheNextSegmentWhereItsAudioDoes() {
        let pieces = cutAcross(hole: 75_000..<180_000)
        XCTAssertEqual(assertTiled(pieces), 105_000)
        XCTAssertTrue(pieces.contains { $0.mark == .segmentStart && $0.time == 180_000 && $0.gap != nil },
                      "the segment after the hole starts on its first audio, and says what came before was lost")
        XCTAssertEqual(segments(pieces).outside, 0)
    }

    func testAHoleTheRingDidNotFlagIsReportedToo() {
        let pieces = cutAcross(hole: 30_000..<33_000, flagged: false)
        XCTAssertEqual(assertTiled(pieces), 3000)
    }

    func testAnOverThatClosesBeforeTheLimitIsSentAsBefore() {
        var s = Segmenter(preRollMs: 100, hangMs: 100, captureRateHz: 10_000, audioRateHz: 1_000, maxSegmentMs: 8000,
                          heardSlack: 0)
        s.hear(.meter(open: false, at: 0))
        s.hear(.squelch(open: true, at: 5000))
        s.hear(.squelch(open: false, at: 70_000))
        s.hear(.meter(open: false, at: 100_000))
        push(&s, from: 0, to: 100_000)
        let got = segments(s.release())
        XCTAssertEqual(got.spans.map(\.start), [4000])
        XCTAssertEqual(got.spans.map(\.end), [71_000], "7 s is under the limit: one segment, held back and sent whole")
        XCTAssertEqual(got.spans.first?.samples, (400..<7100).map(Float.init))
    }

    func testTheStoredCutSplitsALongSpanAtItsQuietPoints() {
        let spans = [Segmenter.Span(start: 0, end: 200_000, over: 2), Segmenter.Span(start: 210_000, end: 220_000, over: 3)]
        var asked: [Range<UInt64>] = []
        let cut = Segmenter.limit(spans, maxSamples: 80_000, lookback: 50_000) { range in
            asked.append(range)
            return range.lowerBound + 10_000
        }
        XCTAssertEqual(asked.first, 30_000..<80_000, "the 5 s before the first limit")
        XCTAssertEqual(cut, [
            .init(start: 0, end: 40_000, over: 2),
            .init(start: 40_000, end: 80_000, over: 2, continues: true),
            .init(start: 80_000, end: 120_000, over: 2, continues: true),
            // Exactly the limit is not over it.
            .init(start: 120_000, end: 200_000, over: 2, continues: true),
            .init(start: 210_000, end: 220_000, over: 3),
        ])
        let noQuiet = Segmenter.limit([spans[0]], maxSamples: 80_000, lookback: 50_000) { _ in nil }
        XCTAssertEqual(noQuiet.map(\.end), [80_000, 160_000, 200_000], "with no quiet point, the cut is at the limit")
        XCTAssertEqual(Segmenter.limit(spans, maxSamples: 0, lookback: 0) { _ in nil }, spans, "0 is no limit")
    }

    func testTheQuietestWindowIsItsMiddleAndTheLatestOfATie() {
        let audio: [Float] = [5, 5, 0, 0, 5, 5, 0, 0, 5]
        XCTAssertEqual(Segmenter.quietest(audio[...], window: 2), 7, "the later of two silences, at its middle")
        XCTAssertEqual(Segmenter.quietest([Float](repeating: 1, count: 10)[...], window: 4), 8,
                       "all alike: as late as it can be")
        XCTAssertNil(Segmenter.quietest([1, 2][...], window: 3), "shorter than the window")
    }

    func testTheDefaultsApplyWhenTheManifestLeavesThemZero() {
        var input = Leyline_V1_DecoderInput()
        XCTAssertEqual(Segmenter.timings(input).preRollMs, 500)
        XCTAssertEqual(Segmenter.timings(input).hangMs, 500)
        input.preRollMs = 250
        input.hangMs = 1500
        XCTAssertEqual(Segmenter.timings(input).preRollMs, 250)
        XCTAssertEqual(Segmenter.timings(input).hangMs, 1500)
    }
}
