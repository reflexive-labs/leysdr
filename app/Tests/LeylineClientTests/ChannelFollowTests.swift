// SPDX-License-Identifier: Apache-2.0

// The follow rule: a channel another client makes on the window's capture becomes the window's
// tuned channel, its own is ended unless a recording runs on it, its audio moves, and when the
// maker ends the channel the window makes its own where it was.

import LeylineProto
import XCTest

@testable import LeylineClient

final class ChannelFollowTests: XCTestCase {
    let app = ChangeNoteTests.client("app_self", kind: "app", label: "Leyline")
    let assistant = ChangeNoteTests.client("cl_worker", kind: "mcp", label: "assistant")
    let terminal = ChangeNoteTests.client("cl_term", kind: "cli", label: "ley")
    let job = ChangeNoteTests.client("job_1", kind: "job", label: "job_1")

    func capture(center: UInt64 = 162_000_000) -> Leyline_V1_Capture {
        .with {
            $0.captureID = "cap_a"
            $0.deviceID = "dev_a"
            $0.centerHz = center
            $0.sampleRate = 2_400_000
            $0.state = .captureActive
        }
    }

    func channel(
        _ id: String, offset: Int64, by owner: Leyline_V1_ClientInfo,
        state: Leyline_V1_ChannelState = .channelActive
    ) -> Leyline_V1_Channel {
        .with {
            $0.channelID = id
            $0.captureID = "cap_a"
            $0.offsetHz = offset
            $0.bandwidthHz = 12_500
            $0.mode = .nfm
            $0.squelchDb = -40
            $0.state = state
            $0.owner = owner
        }
    }

    func sink(_ id: String, on channel: String) -> Leyline_V1_Sink {
        .with {
            $0.sinkID = id
            $0.channelID = channel
            $0.systemAudio = .init()
            $0.state = .sinkActive
        }
    }

    func recording(hz: UInt64, channel: String = "", device: String = "dev_a")
        -> Leyline_V1_Job
    {
        .with {
            $0.jobID = "job_rec"
            $0.state = .running
            $0.record = .with {
                $0.frequencyHz = hz
                $0.mode = .nfm
                $0.bandwidthHz = 12_500
                $0.channelID = channel
                $0.deviceID = device
            }
        }
    }

    func event(
        _ seq: UInt64, _ body: Leyline_V1_Event.OneOf_Body, by: Leyline_V1_ClientInfo? = nil
    ) -> Leyline_V1_Event {
        .with {
            $0.seq = seq
            $0.body = body
            if let by { $0.causedBy = by }
        }
    }

    /// The window on its own channel at 162.550 MHz with its sink playing.
    func windowListening() -> MirrorState {
        var s = MirrorState()
        s.apply(event(1, .capture(capture()), by: app))
        s.apply(event(2, .channel(channel("chan_own", offset: 550_000, by: app)), by: app))
        s.apply(event(3, .sink(sink("sink_own", on: "chan_own")), by: app))
        return s
    }

    func step(
        _ f: inout ChannelFollow, _ s: MirrorState, held: String?, audioHeld: Bool = false
    ) -> ChannelFollow.Step? {
        f.step(
            in: s, captureID: "cap_a", held: held.flatMap { s.channel($0) },
            windowSinkID: "sink_own", audioHeld: audioHeld, selfClientID: "app_self")
    }

    func testTheMirrorKeepsWhoMadeEachChannel() {
        var s = windowListening()
        XCTAssertEqual(s.made["chan_own"]?.causedBy, app)
        XCTAssertEqual(s.made["chan_own"]?.seq, 2)
        // A setting moved later does not replace the creation.
        var moved = channel("chan_own", offset: 550_000, by: app)
        moved.squelchDb = -30
        s.apply(event(4, .channel(moved), by: assistant))
        XCTAssertEqual(s.made["chan_own"]?.seq, 2)
        // The tombstone takes it, and a snapshot starts with none.
        moved.state = .unspecified
        s.apply(event(5, .channel(moved), by: app))
        XCTAssertNil(s.made["chan_own"])
        var snap = Leyline_V1_GetStateResponse()
        snap.channels = [channel("chan_x", offset: 0, by: terminal)]
        XCTAssertTrue(MirrorState(snapshot: snap).made.isEmpty)
    }

    func testAnotherClientsChannelIsFollowedAndTheWindowsOwnEnded() {
        var s = windowListening()
        var f = ChannelFollow()
        XCTAssertNil(step(&f, s, held: "chan_own"), "nothing new: nothing to follow")

        s.apply(
            event(4, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        let st = step(&f, s, held: "chan_own")
        XCTAssertEqual(st?.follow.channelID, "chan_wx")
        XCTAssertEqual(st?.from, "chan_own")
        XCTAssertEqual(st?.endFrom, true)
        XCTAssertEqual(st?.keepFrom, false)
        XCTAssertNil(st?.detachSink, "ending the channel takes its sink with it")
        XCTAssertEqual(st?.attachSink, true, "the window was playing; nothing plays the new one")
        XCTAssertEqual(f.followed?.channelID, "chan_wx")
        XCTAssertEqual(f.floor, 4)
        XCTAssertNil(f.keptWords(in: s))

        // Held now: the same channel is not followed twice.
        XCTAssertNil(step(&f, s, held: "chan_wx"))
    }

    func testTheNewestOfSeveralIsFollowedAndNeverTheWindowsOwnOrAJobs() {
        var s = windowListening()
        var f = ChannelFollow()
        s.apply(event(4, .channel(channel("chan_t", offset: 100_000, by: terminal)), by: terminal))
        s.apply(
            event(5, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        s.apply(event(6, .channel(channel("chan_rec", offset: 200_000, by: job)), by: job))
        s.apply(event(7, .channel(channel("chan_mine", offset: 300_000, by: app)), by: app))
        XCTAssertEqual(step(&f, s, held: "chan_own")?.follow.channelID, "chan_wx")
        // The terminal's older channel is not followed later: it was made before.
        XCTAssertNil(step(&f, s, held: "chan_wx"))
        // A channel on another capture is not the window's radio.
        var other = channel("chan_b", offset: 0, by: terminal)
        other.captureID = "cap_b"
        s.apply(event(8, .channel(other), by: terminal))
        XCTAssertNil(step(&f, s, held: "chan_wx"))
    }

    func testTheWindowsOwnTuneMakesEarlierChannelsOld() {
        var s = windowListening()
        var f = ChannelFollow()
        s.apply(event(4, .channel(channel("chan_t", offset: 100_000, by: terminal)), by: terminal))
        f.tuned(at: 5)
        XCTAssertNil(step(&f, s, held: "chan_own"))
        s.apply(event(6, .channel(channel("chan_t2", offset: 120_000, by: terminal)), by: terminal))
        XCTAssertEqual(step(&f, s, held: "chan_own")?.follow.channelID, "chan_t2")
    }

    func testACaptureMovedWithNoNewChannelIsNotFollowed() {
        var s = windowListening()
        var f = ChannelFollow()
        _ = step(&f, s, held: "chan_own")
        s.apply(event(4, .capture(capture(center: 50_000_000)), by: assistant))
        s.apply(
            event(
                5, .channel(channel("chan_own", offset: 550_000, by: app, state: .outOfCapture))))
        XCTAssertNil(step(&f, s, held: "chan_own"))
    }

    func testARecordingOnTheWindowsChannelKeepsItUntilItStops() {
        var s = windowListening()
        var f = ChannelFollow()
        _ = step(&f, s, held: "chan_own")  // the window's channel at 162.550 MHz, seen in capture
        s.apply(event(4, .job(recording(hz: 162_550_000)), by: app))
        // The assistant's move took the window's channel out of the capture first.
        s.apply(event(5, .capture(capture(center: 160_000_000)), by: assistant))
        s.apply(
            event(
                6, .channel(channel("chan_own", offset: 550_000, by: app, state: .outOfCapture))))
        _ = step(&f, s, held: "chan_own")
        s.apply(
            event(7, .channel(channel("chan_wx", offset: 2_400_000, by: assistant)), by: assistant))
        let st = step(&f, s, held: "chan_own")
        XCTAssertEqual(st?.follow.channelID, "chan_wx")
        XCTAssertEqual(st?.endFrom, false)
        XCTAssertEqual(st?.keepFrom, true)
        XCTAssertEqual(st?.detachSink, "sink_own", "the kept channel stops playing")
        XCTAssertEqual(st?.attachSink, true)
        XCTAssertEqual(
            f.keptWords(in: s), "Your channel on 162.550 MHz stays open while it records.")
        XCTAssertNil(f.keptToEnd(in: s), "still recording")

        var done = recording(hz: 162_550_000)
        done.state = .completed
        s.apply(event(8, .job(done), by: app))
        XCTAssertEqual(f.keptToEnd(in: s), "chan_own")
        XCTAssertNil(f.kept)
        XCTAssertNil(f.keptToEnd(in: s))
    }

    func testARecordingThatBorrowedTheChannelKeepsItToo() {
        var s = windowListening()
        var f = ChannelFollow()
        s.apply(event(4, .job(recording(hz: 0, channel: "chan_own")), by: terminal))
        s.apply(
            event(5, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        XCTAssertEqual(step(&f, s, held: "chan_own")?.keepFrom, true)
    }

    func testTheSinkMove() {
        // Muted (no sink on the window's channel): the followed channel is not made to play.
        var s = windowListening()
        var gone = sink("sink_own", on: "chan_own")
        gone.state = .unspecified
        s.apply(event(4, .sink(gone), by: app))
        s.apply(
            event(5, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        var f = ChannelFollow()
        XCTAssertEqual(step(&f, s, held: "chan_own")?.attachSink, false)

        // A terminal's channel that already plays gets no second sink: the window wants audio,
        // and the check at attach time, after the settle, finds the terminal's sink.
        s = windowListening()
        s.apply(event(4, .channel(channel("chan_t", offset: 100_000, by: terminal)), by: terminal))
        f = ChannelFollow()
        XCTAssertEqual(step(&f, s, held: "chan_own")?.attachSink, true)
        XCTAssertTrue(ChannelFollow.shouldAttach(in: s, channelID: "chan_t", held: "chan_t"))
        s.apply(event(5, .sink(sink("sink_t", on: "chan_t")), by: terminal))
        XCTAssertFalse(ChannelFollow.shouldAttach(in: s, channelID: "chan_t", held: "chan_t"))
        XCTAssertFalse(
            ChannelFollow.shouldAttach(in: s, channelID: "chan_x", held: "chan_t"),
            "the window moved on during the settle")

        // A recorded part holds the audio: none is attached; the part's end attaches it.
        s = windowListening()
        s.apply(
            event(4, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        f = ChannelFollow()
        XCTAssertEqual(step(&f, s, held: "chan_own", audioHeld: true)?.attachSink, false)

        // Following on from another client's channel: the window's sink there is detached, the
        // channel is not the window's to end, and the terminal's own sink is left alone.
        s = windowListening()
        s.apply(event(4, .channel(channel("chan_t", offset: 100_000, by: terminal)), by: terminal))
        f = ChannelFollow()
        _ = step(&f, s, held: "chan_own")
        s.apply(event(5, .sink(sink("sink_own2", on: "chan_t")), by: app))
        s.apply(
            event(6, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        let st = f.step(
            in: s, captureID: "cap_a", held: s.channel("chan_t"), windowSinkID: "sink_own2",
            audioHeld: false, selfClientID: "app_self")
        XCTAssertEqual(st?.from, "chan_t")
        XCTAssertEqual(st?.endFrom, false)
        XCTAssertEqual(st?.keepFrom, false)
        XCTAssertEqual(st?.detachSink, "sink_own2")
        XCTAssertEqual(st?.attachSink, true)
    }

    func testTheMakerEndingTheChannelGivesTheWindowItsLastCopy() {
        var s = windowListening()
        var f = ChannelFollow()
        s.apply(
            event(4, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        _ = step(&f, s, held: "chan_own")
        var moved = channel("chan_wx", offset: 400_000, by: assistant)
        moved.squelchDb = -35
        s.apply(event(5, .channel(moved), by: assistant))
        _ = step(&f, s, held: "chan_wx")
        XCTAssertNil(f.lost("chan_own"), "the window's own channel goes as before")
        XCTAssertEqual(f.lost("chan_wx")?.squelchDb, -35, "the newest copy")
        XCTAssertNil(f.followed)

        // The window tuned elsewhere: the followed channel is forgotten.
        s.apply(event(6, .channel(channel("chan_t", offset: 100_000, by: terminal)), by: terminal))
        _ = step(&f, s, held: "chan_own")
        s.apply(event(7, .channel(channel("chan_new", offset: 0, by: app)), by: app))
        _ = step(&f, s, held: "chan_new")
        XCTAssertNil(f.followed)
        XCTAssertNil(f.lost("chan_t"))
    }

    func testTheNoteNamesWhoTuned() {
        var s = windowListening()
        s.apply(
            event(4, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        XCTAssertEqual(
            ChangeNote.latest(for: s.channel("chan_wx")!, in: s, selfClientID: "app_self")?.text,
            "The assistant tuned to 162.400 MHz NFM.")
        // The same client's squelch right after reads as one sentence.
        var measured = channel("chan_wx", offset: 400_000, by: assistant)
        measured.squelchDb = -42
        s.apply(event(5, .channel(measured), by: assistant))
        XCTAssertEqual(
            ChangeNote.latest(for: s.channel("chan_wx")!, in: s, selfClientID: "app_self")?.text,
            "The assistant tuned to 162.400 MHz NFM and set the squelch to -42 dBFS.")
        // A terminal's.
        s.apply(event(6, .channel(channel("chan_t", offset: 100_000, by: terminal)), by: terminal))
        XCTAssertEqual(
            ChangeNote.latest(for: s.channel("chan_t")!, in: s, selfClientID: "app_self")?.text,
            "Another terminal tuned to 162.100 MHz NFM.")
        // The window's own write takes it away.
        var mine = channel("chan_wx", offset: 400_000, by: assistant)
        mine.squelchDb = -50
        s.apply(event(7, .channel(mine), by: app))
        XCTAssertNil(
            ChangeNote.latest(for: s.channel("chan_wx")!, in: s, selfClientID: "app_self"))
    }

    func testARecordingOnAnotherRadioDoesNotKeepTheChannel() {
        var s = windowListening()
        var f = ChannelFollow()
        _ = step(&f, s, held: "chan_own")
        s.apply(event(4, .job(recording(hz: 162_550_000, device: "dev_b")), by: terminal))
        s.apply(
            event(5, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        let st = step(&f, s, held: "chan_own")
        XCTAssertEqual(st?.keepFrom, false)
        XCTAssertEqual(st?.endFrom, true)
    }

    func testTheWindowsSinkOnlyAndTheWordsWhenAnotherPlays() {
        var s = windowListening()
        XCTAssertEqual(s.sinkAttachedBy["sink_own"], app)
        s.apply(event(4, .sink(sink("sink_t", on: "chan_own")), by: terminal))
        XCTAssertEqual(s.sinkAttachedBy["sink_t"], terminal)
        // Two sinks on the window's channel: the window's goes.
        XCTAssertEqual(
            ChannelFollow.redundantSink(in: s, held: "chan_own", windowSinkID: "sink_own"),
            "sink_own")
        XCTAssertNil(
            ChannelFollow.playsThroughWords(in: s, held: "chan_own", windowSinkID: "sink_own"),
            "the window still has its own")
        var gone = sink("sink_own", on: "chan_own")
        gone.state = .unspecified
        s.apply(event(5, .sink(gone), by: app))
        XCTAssertNil(s.sinkAttachedBy["sink_own"])
        XCTAssertNil(ChannelFollow.redundantSink(in: s, held: "chan_own", windowSinkID: nil))
        XCTAssertEqual(
            ChannelFollow.playsThroughWords(in: s, held: "chan_own", windowSinkID: nil),
            "The audio plays through another terminal.")
        // Following on from a channel that played through the terminal: the window was
        // hearing it, so it wants audio on the next.
        s.apply(
            event(6, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        var f = ChannelFollow()
        let st = f.step(
            in: s, captureID: "cap_a", held: s.channel("chan_own"), windowSinkID: nil,
            audioHeld: false, selfClientID: "app_self")
        XCTAssertEqual(st?.attachSink, true)
        XCTAssertNil(st?.detachSink, "the terminal's sink is never the window's to detach")
    }

    func testARestartedDaemonsChannelsAreFollowed() {
        var s = windowListening()
        var f = ChannelFollow()
        f.tuned(at: 500)
        // The daemon restarted: its seq counts from 0, and the snapshot carries 2.
        var snap = Leyline_V1_GetStateResponse()
        snap.captures = [capture()]
        snap.channels = [channel("chan_own", offset: 550_000, by: app)]
        snap.eventSeq = 2
        s = MirrorState(snapshot: snap)
        f.connected(atSeq: s.seq)
        XCTAssertEqual(f.floor, 2)
        s.apply(
            event(3, .channel(channel("chan_wx", offset: 400_000, by: assistant)), by: assistant))
        XCTAssertEqual(step(&f, s, held: "chan_own")?.follow.channelID, "chan_wx")
    }

    func testOnConnectTheNewestChannelIsTakenWhenTheWindowsIsNotInTheCapture() {
        var snap = Leyline_V1_GetStateResponse()
        snap.captures = [capture(center: 160_000_000)]
        snap.channels = [
            channel("chan_01A", offset: 550_000, by: app, state: .outOfCapture),
            channel("chan_01B", offset: 100_000, by: terminal),
            channel("chan_01C", offset: 400_000, by: assistant),
            channel("chan_01D", offset: 200_000, by: job),
            channel("chan_01E", offset: 300_000, by: terminal, state: .outOfCapture),
        ]
        let s = MirrorState(snapshot: snap)
        XCTAssertEqual(
            ChannelFollow.adoptable(in: s, captureID: "cap_a", except: "chan_01A")?.channelID,
            "chan_01C", "newest by id, active, not a job's")
        var f = ChannelFollow()
        let st = f.stepOnConnect(
            in: s, captureID: "cap_a", held: s.channel("chan_01A"), windowSinkID: nil,
            audioHeld: false, selfClientID: "app_self")
        XCTAssertEqual(st?.follow.channelID, "chan_01C")
        XCTAssertEqual(st?.endFrom, true)
        XCTAssertEqual(f.followed?.channelID, "chan_01C")

        // The window's channel in the capture: nothing is taken.
        var t = snap
        t.channels[0].state = .channelActive
        var g = ChannelFollow()
        XCTAssertNil(
            g.stepOnConnect(
                in: MirrorState(snapshot: t), captureID: "cap_a",
                held: MirrorState(snapshot: t).channel("chan_01A"), windowSinkID: nil,
                audioHeld: false, selfClientID: "app_self"))
        // The window's channel gone with the daemon: nothing to end, the newest is taken.
        var u = snap
        u.channels.removeFirst()
        let gone = channel("chan_01A", offset: 550_000, by: app)
        let su = MirrorState(snapshot: u)
        let st2 = g.stepOnConnect(
            in: su, captureID: "cap_a", held: gone, windowSinkID: nil, audioHeld: false,
            selfClientID: "app_self")
        XCTAssertEqual(st2?.follow.channelID, "chan_01C")
        XCTAssertNil(st2?.from)
        XCTAssertEqual(st2?.endFrom, false)
    }
}
