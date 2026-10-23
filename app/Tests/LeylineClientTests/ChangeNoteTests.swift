// SPDX-License-Identifier: Apache-2.0

// Attribution: the mirror keeps who caused each object's newest event, and the newest change that
// moved a setting, and the inspector's note words the tuned channel's change when another client
// made it ("The assistant set the squelch to -45 dBFS.").

import LeylineProto
import XCTest

@testable import LeylineClient

final class ChangeNoteTests: XCTestCase {
    let app = ChangeNoteTests.client("app_self", kind: "app", label: "Leyline")
    let assistant = ChangeNoteTests.client("cl_worker", kind: "mcp", label: "assistant")

    static func client(_ id: String, kind: String, label: String) -> Leyline_V1_ClientInfo {
        var c = Leyline_V1_ClientInfo()
        c.clientID = id
        c.kind = kind
        c.label = label
        return c
    }

    func capture(center: UInt64 = 146_000_000, activityNs: Int64 = 0) -> Leyline_V1_Capture {
        var c = Leyline_V1_Capture()
        c.captureID = "cap_a"
        c.centerHz = center
        c.sampleRate = 2_400_000
        c.state = .captureActive
        c.activity.lastInteractiveWriteNs = activityNs
        return c
    }

    func channel(squelch: Double = -60, mode: Leyline_V1_DemodMode = .nfm, offset: Int64 = 520_000)
        -> Leyline_V1_Channel
    {
        var ch = Leyline_V1_Channel()
        ch.channelID = "chan_1"
        ch.captureID = "cap_a"
        ch.offsetHz = offset
        ch.bandwidthHz = 12_500
        ch.mode = mode
        ch.squelchDb = squelch
        ch.state = .channelActive
        return ch
    }

    func event(
        _ seq: UInt64, _ body: Leyline_V1_Event.OneOf_Body, by: Leyline_V1_ClientInfo? = nil
    ) -> Leyline_V1_Event {
        var e = Leyline_V1_Event()
        e.seq = seq
        e.body = body
        if let by { e.causedBy = by }
        return e
    }

    func tuned() -> MirrorState {
        var s = MirrorState()
        s.apply(event(1, .capture(capture()), by: app))
        s.apply(event(2, .channel(channel()), by: app))
        return s
    }

    func testTheFoldKeepsTheNewestAttributedChangeThatMovedASetting() {
        var s = tuned()
        // A first sight has nothing to diff against.
        XCTAssertNil(s.changes["chan_1"])

        s.apply(event(3, .channel(channel(squelch: -45)), by: assistant))
        XCTAssertEqual(s.changes["chan_1"]?.causedBy, assistant)
        XCTAssertEqual(s.changes["chan_1"]?.seq, 3)
        // The daemon's own event names nobody and moves no setting: the change stays.
        var outside = channel(squelch: -45)
        outside.state = .outOfCapture
        s.apply(event(4, .channel(outside)))
        XCTAssertEqual(s.changes["chan_1"]?.seq, 3)

        // The tombstone takes the entry with the object.
        var gone = channel()
        gone.state = .unspecified
        s.apply(event(5, .channel(gone), by: app))
        XCTAssertNil(s.changes["chan_1"])
    }

    func testANoteNeverNamesAValueSinceChanged() {
        var s = tuned()
        s.apply(event(3, .channel(channel(squelch: -45)), by: assistant))
        // An event with no author moves the squelch: it is not kept as a change, and the
        // assistant's -45 is no longer what the channel holds, so nothing is said.
        s.apply(event(4, .channel(channel(squelch: -30))))
        XCTAssertEqual(s.changes["chan_1"]?.seq, 3)
        XCTAssertNil(ChangeNote.latest(for: s.channel("chan_1")!, in: s, selfClientID: "app_self"))
        // Back to the assistant's value, the note is true again.
        s.apply(event(5, .channel(channel(squelch: -45))))
        XCTAssertEqual(
            ChangeNote.latest(for: s.channel("chan_1")!, in: s, selfClientID: "app_self")?.text,
            "The assistant set the squelch to -45 dBFS.")
    }

    func testTheAssistantsSquelchChangeIsWordedForTheInspector() {
        var s = tuned()
        s.apply(event(3, .channel(channel(squelch: -45)), by: assistant))
        // The same write stamps the capture's activity clock; that moves no setting and must not
        // hide the squelch change.
        s.apply(event(4, .capture(capture(activityNs: 99)), by: assistant))
        let note = ChangeNote.latest(
            for: s.channel("chan_1")!, in: s, selfClientID: "app_self")
        XCTAssertEqual(note?.text, "The assistant set the squelch to -45 dBFS.")
        XCTAssertEqual(note?.author, "the assistant")
    }

    func testOwnChangesAndUnmovedSettingsSayNothing() {
        var s = tuned()
        s.apply(event(3, .channel(channel(squelch: -45)), by: assistant))
        // This app sets it back: the newest change is its own, so the note goes.
        s.apply(event(4, .channel(channel(squelch: -50)), by: app))
        XCTAssertNil(ChangeNote.latest(for: s.channel("chan_1")!, in: s, selfClientID: "app_self"))
        // NaN is off on both sides: not a change.
        var t = tuned()
        t.apply(event(3, .channel(channel(squelch: .nan)), by: app))
        t.apply(event(4, .channel(channel(squelch: .nan)), by: assistant))
        XCTAssertEqual(t.changes["chan_1"]?.causedBy, app)
    }

    func testSeveralFieldsReadAsOneSentence() {
        var s = tuned()
        var ch = channel(squelch: .nan, mode: .am)
        ch.bandwidthHz = 25_000
        s.apply(event(3, .channel(ch), by: Self.client("cl_t", kind: "cli", label: "ley")))
        XCTAssertEqual(
            ChangeNote.latest(for: s.channel("chan_1")!, in: s, selfClientID: "app_self")?.text,
            "Another terminal set the mode to AM and the width to 25.0 kHz and turned the squelch off."
        )
    }

    func testARetuneOfTheRadioIsTheNewerChange() {
        var s = tuned()
        s.apply(event(3, .channel(channel(squelch: -45)), by: assistant))
        s.apply(event(4, .capture(capture(center: 146_500_000)), by: assistant))
        XCTAssertEqual(
            ChangeNote.latest(for: s.channel("chan_1")!, in: s, selfClientID: "app_self")?.text,
            "The assistant retuned the radio to 146.500 MHz.")
        s.apply(event(5, .channel(channel(squelch: -45, offset: 20_000)), by: assistant))
        XCTAssertEqual(
            ChangeNote.latest(for: s.channel("chan_1")!, in: s, selfClientID: "app_self")?.text,
            "The assistant moved this channel to 146.520 MHz.")
    }

    func testAuthorsAreNamedAsLeyNamesThem() {
        XCTAssertEqual(ChangeNote.author(assistant), "the assistant")
        // Only the MCP client labelled assistant is the assistant.
        XCTAssertEqual(
            ChangeNote.author(Self.client("x", kind: "cli", label: "assistant")),
            "another terminal")
        XCTAssertEqual(
            ChangeNote.author(Self.client("x", kind: "app", label: "Leyline")), "the app")
        XCTAssertEqual(
            ChangeNote.author(Self.client("x", kind: "mcp", label: "claude")), "an agent")
        XCTAssertEqual(ChangeNote.author(Self.client("x", kind: "job", label: "")), "a job")
        XCTAssertEqual(ChangeNote.author(Self.client("x", kind: "", label: "")), "another client")
        XCTAssertEqual(ChangeNote.author(Self.client("x", kind: "other", label: "pi")), "pi")
    }
}
