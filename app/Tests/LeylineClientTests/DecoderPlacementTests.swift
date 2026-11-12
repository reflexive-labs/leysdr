// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// The Decoders page's words for each kind of plan `Control.Plan` answers, from hand-built
/// `CapturePlan` values: the daemon decides where a decoder goes, the app only says it.
final class DecoderPlacementTests: XCTestCase {
    let me = "app_me"

    func state() -> MirrorState {
        var s = MirrorState()
        var d = Leyline_V1_DeviceDescriptor()
        d.deviceID = "dev_a"
        d.model = "RTL-SDR"
        s.devices = [d]
        var c = Leyline_V1_Capture()
        c.captureID = "cap_1"
        c.deviceID = "dev_a"
        c.centerHz = 146_000_000
        c.sampleRate = 2_400_000
        c.state = .captureActive
        s.captures = [c]
        var j = Leyline_V1_Job()
        j.jobID = "job_rec"
        j.record = Leyline_V1_RecordConfig()
        s.jobs = [j]
        return s
    }

    func channel(owner: String, id: String = "chan_1") -> Leyline_V1_Channel {
        var ch = Leyline_V1_Channel()
        ch.channelID = id
        ch.captureID = "cap_1"
        ch.state = .channelActive
        ch.owner.clientID = owner
        return ch
    }

    func claim(
        _ holder: String, kind: String, _ k: Leyline_V1_ClaimKind = .claimChannel, at hz: UInt64,
        priority: Leyline_V1_ClaimPriority = .priorityPerson
    ) -> Leyline_V1_Claim {
        var c = Leyline_V1_Claim()
        c.holder.clientID = holder
        c.holder.kind = kind
        c.kind = k
        c.covers.frequencyHz = hz
        c.priority = priority
        return c
    }

    func share() -> Leyline_V1_CapturePlan {
        var p = Leyline_V1_CapturePlan()
        p.share.captureID = "cap_1"
        p.share.deviceID = "dev_a"
        p.share.centerHz = 146_000_000
        p.share.sampleRateHz = 2_400_000
        return p
    }

    func retune(_ displaced: [Leyline_V1_Claim], rate: UInt64 = 2_400_000)
        -> Leyline_V1_CapturePlan
    {
        var p = Leyline_V1_CapturePlan()
        p.retune.captureID = "cap_1"
        p.retune.deviceID = "dev_a"
        p.retune.centerHz = 144_390_000
        p.retune.sampleRateHz = rate
        p.retune.displaced = displaced
        return p
    }

    func decline(_ code: String, _ reason: String) -> Leyline_V1_CapturePlan {
        var p = Leyline_V1_CapturePlan()
        p.decline.code = code
        p.decline.reason = reason
        return p
    }

    func words(
        _ p: Leyline_V1_CapturePlan, insisting: Leyline_V1_CapturePlan? = nil,
        _ s: MirrorState? = nil, window: String? = nil
    ) -> DecoderPlacement {
        DecoderPlacement.from(
            p, insisting: insisting, state: s ?? state(), selfID: me, windowChannel: window,
            titles: ["aprs": "APRS"])
    }

    // MARK: Share

    func testAShareOfTheWindowsCaptureRunsAlongside() {
        var s = state()
        s.channels = [channel(owner: me)]
        let p = words(share(), s)
        XCTAssertEqual(p.words, "Runs alongside what you are listening to.")
        XCTAssertTrue(p.canStart)
        XCTAssertFalse(p.needsTakeOver)
        // A channel the window followed is the window's too.
        s.channels = [channel(owner: "cli_x", id: "chan_f")]
        XCTAssertEqual(
            words(share(), s, window: "chan_f").words,
            "Runs alongside what you are listening to.")
    }

    func testAShareOfAnotherCaptureNamesItsRadio() {
        let p = words(share())
        XCTAssertEqual(p.words, "Shares the RTL-SDR's capture at 146.000 MHz; nothing is retuned.")
        XCTAssertTrue(p.canStart)
    }

    // MARK: Open

    func testAnIdleRadioIsOpenedAtTheCentreAndRate() {
        var plan = Leyline_V1_CapturePlan()
        plan.create.deviceID = "dev_a"
        plan.create.centerHz = 1_090_000_000
        plan.create.sampleRateHz = 2_000_000
        let p = words(plan)
        XCTAssertEqual(
            p.words, "Opens the RTL-SDR at 1090.000 MHz, 2 MSPS; nothing else is using it.")
        XCTAssertTrue(p.canStart)
        XCTAssertFalse(p.needsTakeOver)
    }

    // MARK: Retune

    func testARetuneThatPausesNothingStartsWithoutAsking() {
        let p = words(retune([]))
        XCTAssertEqual(p.words, "Retunes the RTL-SDR to 144.390 MHz; nothing on it has to move.")
        XCTAssertTrue(p.canStart)
        XCTAssertFalse(p.needsTakeOver)
        XCTAssertEqual(
            words(retune([], rate: 2_048_000)).words,
            "Retunes the RTL-SDR to 144.390 MHz at 2.048 MSPS; nothing on it has to move.")
    }

    func testARetuneNamesWhatItPausesAndAsksOnlyForAPerson() {
        var jobs = state()
        var j = Leyline_V1_Job()
        j.jobID = "job_aprs"
        j.decode.decoder = "aprs"
        jobs.jobs.append(j)
        let byJobs = words(
            retune([
                claim("job_aprs", kind: "job", at: 144_390_000, priority: .priorityJob),
                claim("job_rec", kind: "job", at: 146_520_000, priority: .priorityJob),
            ]), jobs)
        XCTAssertEqual(
            byJobs.words,
            "Retunes the RTL-SDR to 144.390 MHz, pausing: the APRS decoder on 144.390 MHz and the recording on 146.520 MHz."
        )
        XCTAssertFalse(byJobs.needsTakeOver, "a job's claim is not a person's")

        let byPeople = words(
            retune([
                claim(me, kind: "app", at: 146_520_000),
                claim("cli_x", kind: "cli", at: 146_940_000),
                claim("mcp_x", kind: "mcp", .claimIq, at: 146_000_000),
            ]))
        XCTAssertEqual(
            byPeople.words,
            "Retunes the RTL-SDR to 144.390 MHz, pausing: your channel on 146.520 MHz, a terminal's channel on 146.940 MHz and an agent's IQ reader on 146.000 MHz."
        )
        XCTAssertTrue(byPeople.needsTakeOver)
        XCTAssertTrue(byPeople.canStart)
        XCTAssertNil(byPeople.declineReason)
    }

    // MARK: Decline

    func testADeclineTakeOverWouldRetuneAsksToTakeTheRadio() {
        let reason = "a terminal is listening on 146.520 MHz"
        let p = words(
            decline("DEVICE_BUSY", reason),
            insisting: retune([claim("cli_x", kind: "cli", at: 146_520_000)]))
        XCTAssertEqual(
            p.words,
            "Would not start: a terminal is listening on 146.520 MHz; Start asks to take the radio."
        )
        XCTAssertTrue(p.canStart)
        XCTAssertTrue(p.needsTakeOver)
        XCTAssertEqual(p.declineReason, reason)
        XCTAssertEqual(
            p.takeOver?.clause,
            "retunes the RTL-SDR to 144.390 MHz, pausing: a terminal's channel on 146.520 MHz")
    }

    func testADeclineTakeOverCannotChangeIsNoStart() {
        let reason = "RTL-SDR cannot tune to 1090.000 MHz (a file radio plays what it recorded)"
        let p = words(decline("NO_DEVICE", reason), insisting: decline("NO_DEVICE", reason))
        XCTAssertEqual(
            p.words,
            "Would not start: RTL-SDR cannot tune to 1090.000 MHz (a file radio plays what it recorded)."
        )
        XCTAssertFalse(p.canStart)
        XCTAssertFalse(p.needsTakeOver)
        // A failed job with the daemon's same reason adds no line under it.
        var j = Leyline_V1_Job()
        j.state = .failed
        j.statusDetail = reason
        XCTAssertNil(DecoderPages.failedLine(newest: j, placement: p.declineReason ?? p.words))
    }

    func testNoAnswerYetAndNoFrequencyAreNoStart() {
        XCTAssertFalse(DecoderPlacement.asking.canStart)
        XCTAssertEqual(DecoderPlacement.asking.words, "Asking the daemon where it would run.")
        XCTAssertFalse(DecoderPlacement.needsFrequency.canStart)
        XCTAssertEqual(
            DecoderPlacement.needsFrequency.words,
            "Has no frequency of its own: tune a channel first.")
    }

    // MARK: The frequency

    func testTheFrequencyIsTheFirstRecipeFrequencyInsideTheSpanElseTheFirst() {
        var m = Leyline_V1_DecoderManifest()
        m.recipe.frequenciesHz = [144_390_000, 144_800_000]
        var c = Leyline_V1_Capture()
        c.sampleRate = 2_400_000
        c.centerHz = 145_900_000
        XCTAssertEqual(DecoderPlacement.frequency(for: m, capture: c, tunedHz: nil), 144_800_000)
        c.centerHz = 162_000_000
        XCTAssertEqual(DecoderPlacement.frequency(for: m, capture: c, tunedHz: nil), 144_390_000)
        XCTAssertEqual(DecoderPlacement.frequency(for: m, capture: nil, tunedHz: nil), 144_390_000)
    }

    /// Speech has no frequency of its own: Start borrows the window's channel, so a WFM station
    /// is transcribed through the WFM channel the person hears. A decoder with a recipe makes its
    /// own channel on the frequency, and so does speech with no window channel.
    func testStartPassesTheWindowsChannelForSpeech() {
        var speech = Leyline_V1_DecoderManifest()
        speech.name = "speech"
        speech.input.mode = .segmented
        let borrowed = DecoderPlacement.startConfig(
            speech, frequencyHz: 98_500_000, windowChannel: "chan_window", takeOver: true)
        XCTAssertEqual(borrowed.channelID, "chan_window")
        XCTAssertEqual(borrowed.frequencyHz, 0, "the channel says where")
        XCTAssertFalse(borrowed.takeOver, "a borrowed channel takes no radio")
        XCTAssertTrue(borrowed.keep)
        let none = DecoderPlacement.startConfig(
            speech, frequencyHz: 98_500_000, windowChannel: nil, takeOver: false)
        XCTAssertEqual(none.channelID, "")
        XCTAssertEqual(none.frequencyHz, 98_500_000)
        var aprs = Leyline_V1_DecoderManifest()
        aprs.name = "aprs"
        aprs.recipe.frequenciesHz = [144_390_000]
        let own = DecoderPlacement.startConfig(
            aprs, frequencyHz: 144_390_000, windowChannel: "chan_window", takeOver: true)
        XCTAssertEqual(own.channelID, "", "a decoder with a recipe makes its own channel")
        XCTAssertEqual(own.frequencyHz, 144_390_000)
        XCTAssertTrue(own.takeOver)
    }

    func testADecoderWithNoFrequencyTakesTheTunedOne() {
        let m = Leyline_V1_DecoderManifest()
        XCTAssertEqual(
            DecoderPlacement.frequency(for: m, capture: nil, tunedHz: 146_940_000), 146_940_000)
        XCTAssertNil(DecoderPlacement.frequency(for: m, capture: nil, tunedHz: nil))
    }
}
