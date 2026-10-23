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
