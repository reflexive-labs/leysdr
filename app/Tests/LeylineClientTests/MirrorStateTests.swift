// SPDX-License-Identifier: Apache-2.0

// The fold, without a daemon: replace by id, tombstones, stale events, rejections.

import LeylineProto
import XCTest

@testable import LeylineClient

final class MirrorStateTests: XCTestCase {
    func capture(
        _ id: String, center: UInt64 = 146_520_000, state: Leyline_V1_CaptureState = .captureActive
    ) -> Leyline_V1_Capture {
        var c = Leyline_V1_Capture()
        c.captureID = id
        c.centerHz = center
        c.sampleRate = 2_400_000
        c.state = state
        return c
    }

    func channel(
        _ id: String, capture: String, offset: Int64 = 100_000,
        state: Leyline_V1_ChannelState = .channelActive
    ) -> Leyline_V1_Channel {
        var ch = Leyline_V1_Channel()
        ch.channelID = id
        ch.captureID = capture
        ch.offsetHz = offset
        ch.state = state
        return ch
    }

    func event(_ seq: UInt64, _ body: Leyline_V1_Event.OneOf_Body) -> Leyline_V1_Event {
        var e = Leyline_V1_Event()
        e.seq = seq
        e.body = body
        return e
    }

    func testSnapshotThenEventsReplaceById() {
        var snap = Leyline_V1_GetStateResponse()
        snap.eventSeq = 10
        snap.captures = [capture("cap_a")]
        var s = MirrorState(snapshot: snap)
        XCTAssertEqual(s.seq, 10)

        XCTAssertTrue(s.apply(event(11, .capture(capture("cap_a", center: 100_000_000)))))
        XCTAssertEqual(s.captures.count, 1)
        XCTAssertEqual(s.captures[0].centerHz, 100_000_000)
        XCTAssertEqual(s.seq, 11)

        XCTAssertTrue(s.apply(event(12, .channel(channel("chan_1", capture: "cap_a")))))
        XCTAssertEqual(s.channels(in: "cap_a").map(\.channelID), ["chan_1"])
        XCTAssertEqual(s.frequencyHz(of: s.channels[0]), 100_100_000)
    }

    func testTombstoneRemovesAndDetachedStays() {
        var s = MirrorState()
        s.apply(event(1, .capture(capture("cap_a"))))
        s.apply(event(2, .channel(channel("chan_1", capture: "cap_a"))))
        s.apply(event(3, .capture(capture("cap_a", state: .captureDetached))))
        XCTAssertEqual(s.captures.count, 1, "a yanked dongle's capture stays, it rebinds on replug")
        s.apply(event(4, .channel(channel("chan_1", capture: "cap_a", state: .unspecified))))
        XCTAssertTrue(s.channels.isEmpty, "state unset is the tombstone")
        s.apply(event(5, .capture(capture("cap_a", state: .unspecified))))
        XCTAssertTrue(s.captures.isEmpty)
    }

    /// The daemon publishes a playing playback four times a second with its position, so the
    /// window's progress line reads the mirror; the tombstone takes the playback out.
    func testAPlaybacksPositionMovesInTheMirror() {
        func playback(_ position: UInt64, state: Leyline_V1_PlaybackState = .playbackPlaying)
            -> Leyline_V1_Playback
        {
            var p = Leyline_V1_Playback()
            p.playbackID = "pb_a"
            p.samples = 48_000
            p.sampleRate = 48_000
            p.position = position
            p.state = state
            return p
        }
        var s = MirrorState()
        s.apply(event(1, .playback(playback(0))))
        s.apply(event(2, .playback(playback(12_000))))
        XCTAssertEqual(s.playbacks.map(\.position), [12_000], "replaced by id, never added twice")
        s.apply(event(3, .playback(playback(24_000))))
        XCTAssertEqual(s.playbacks.first?.position, 24_000)
        s.apply(event(4, .playback(playback(48_000, state: .unspecified))))
        XCTAssertTrue(s.playbacks.isEmpty, "state unset is the tombstone")
    }

    func testStaleEventsAreSkippedButRejectionsNever() {
        var snap = Leyline_V1_GetStateResponse()
        snap.eventSeq = 20
        var s = MirrorState(snapshot: snap)
        XCTAssertFalse(
            s.apply(event(20, .capture(capture("cap_old")))),
            "at the snapshot's seq: already reflected")
        XCTAssertFalse(s.apply(event(3, .capture(capture("cap_old")))))
        XCTAssertTrue(s.captures.isEmpty)
        var r = Leyline_V1_WriteRejected()
        r.tag = 7
        XCTAssertTrue(s.apply(event(5, .writeRejected(r))))
        XCTAssertEqual(s.rejections.map(\.tag), [7])
        XCTAssertEqual(s.seq, 20)
    }

    func testRejectionsAreBounded() {
        var s = MirrorState()
        for i in 0..<(MirrorState.rejectionsKept + 5) {
            var r = Leyline_V1_WriteRejected()
            r.tag = UInt64(i)
            s.apply(event(0, .writeRejected(r)))
        }
        XCTAssertEqual(s.rejections.count, MirrorState.rejectionsKept)
        XCTAssertEqual(s.rejections.last?.tag, UInt64(MirrorState.rejectionsKept + 4))
    }

    func testFrequencyAddsOffsetAndIsAbsentBelowZero() {
        var s = MirrorState()
        s.apply(event(1, .capture(capture("cap_a", center: 146_520_000))))
        s.apply(event(2, .channel(channel("chan_1", capture: "cap_a", offset: 100_000))))
        XCTAssertEqual(s.frequencyHz(of: s.channel("chan_1")!), 146_620_000)

        // Another client retunes the shared capture under the channel's negative offset: the sum
        // is a frequency below 0 Hz, which no channel has, and reading it must not trap.
        s.apply(event(3, .channel(channel("chan_1", capture: "cap_a", offset: -200_000_000))))
        XCTAssertNil(s.frequencyHz(of: s.channel("chan_1")!))
    }

    func testAnchorUpdatesItsCapture() {
        var s = MirrorState()
        s.apply(event(1, .capture(capture("cap_a"))))
        var a = Leyline_V1_CaptureAnchor()
        a.captureID = "cap_a"
        a.hostTimeNs = 123
        s.apply(event(2, .anchor(a)))
        XCTAssertEqual(s.capture("cap_a")?.anchor.hostTimeNs, 123)
    }
}
