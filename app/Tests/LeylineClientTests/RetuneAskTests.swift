// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// The one question before a person moves the radio (`RetuneAsk`, `RetuneDrag`): what it names
/// from the daemon's plan, which moves need the plan at all, and a drag that asks once.
final class RetuneAskTests: XCTestCase {
    func claim(
        _ holder: String, kind: String, _ k: Leyline_V1_ClaimKind = .claimChannel,
        _ p: Leyline_V1_ClaimPriority = .priorityJob, covers hz: UInt64? = nil, bw: UInt32 = 0,
        displaced: Bool = false
    ) -> Leyline_V1_Claim {
        var c = Leyline_V1_Claim()
        c.holder.clientID = holder
        c.holder.kind = kind
        c.kind = k
        c.priority = p
        if let hz {
            c.covers.frequencyHz = hz
            c.covers.bandwidthHz = bw
        }
        c.state = displaced ? .claimDisplaced : .claimSatisfied
        return c
    }

    var jobs: [Leyline_V1_Job] {
        var aprs = Leyline_V1_Job()
        aprs.jobID = "job_aprs"
        aprs.decode.decoder = "aprs"
        var rec = Leyline_V1_Job()
        rec.jobID = "job_rec"
        rec.record = Leyline_V1_RecordConfig()
        var scan = Leyline_V1_Job()
        scan.jobID = "job_scan"
        scan.scan = Leyline_V1_ScanConfig()
        return [aprs, rec, scan]
    }

    func retune(_ displaced: [Leyline_V1_Claim]) -> Leyline_V1_CapturePlan {
        var p = Leyline_V1_CapturePlan()
        p.retune = .with {
            $0.captureID = "cap_a"
            $0.centerHz = 150_000_000
            $0.displaced = displaced
        }
        return p
    }

    func testTheQuestionNamesTheJobsThePlanPauses() {
        let plan = retune([
            claim("job_aprs", kind: "job", covers: 144_390_000, bw: 12_500),
            claim("job_rec", kind: "job", covers: 146_520_000, bw: 12_500),
            claim("cli_1", kind: "cli", .claimChannel, .priorityPerson, covers: 146_550_000),
            claim("app_me", kind: "app", .claimChannel, .priorityPerson, covers: 146_600_000),
        ])
        let asked = RetuneAsk.asked(plan, selfID: "app_me")
        XCTAssertEqual(asked.map(\.holder.clientID), ["job_aprs", "job_rec"])
        XCTAssertEqual(
            RetuneAsk.words(asked, jobs: jobs, titles: ["aprs": "APRS"]),
            "This pauses the APRS decoder on 144.390 MHz and the recording on 146.520 MHz.")
    }

    func testOneJobTwoClaimsIsNamedOnceAndAScanByName() {
        let aprs = claim("job_aprs", kind: "job", covers: 144_390_000)
        XCTAssertEqual(
            RetuneAsk.words([aprs, aprs], jobs: jobs, titles: [:]),
            "This pauses the aprs decoder on 144.390 MHz.")
        var sweep = claim("job_scan", kind: "job", .claimSweep)
        sweep.covers.frequencyHz = 146_000_000
        sweep.covers.bandwidthHz = 4_000_000
        XCTAssertEqual(
            RetuneAsk.words([sweep], jobs: jobs, titles: [:]),
            "This pauses the scan on 146.000 MHz.")
    }

    func testViewsPeopleAndTheWindowsOwnAreNeverAskedAbout() {
        let plan = retune([
            claim("app_1", kind: "app", .claimSpectrum, .priorityView),
            claim("cli_1", kind: "cli", .claimChannel, .priorityPerson, covers: 146_520_000),
            claim("app_me", kind: "app", .claimChannel, .priorityJob, covers: 146_520_000),
        ])
        let asked = RetuneAsk.asked(plan, selfID: "app_me")
        XCTAssertEqual(asked, [])
        XCTAssertNil(RetuneAsk.words(asked, jobs: jobs, titles: [:]), "nothing to ask")
    }

    func testADeclineAsksNothing() {
        var p = Leyline_V1_CapturePlan()
        p.decline = .with {
            $0.code = "FREQ_OUT_OF_RANGE"
            $0.reason = "the radio cannot tune 1.000 GHz"
        }
        XCTAssertEqual(RetuneAsk.asked(p, selfID: "app_me"), [])
    }

    func testWhatTheJobsKeepAndWhatPausesThem() {
        var cap = Leyline_V1_Capture()
        cap.centerHz = 146_000_000
        cap.sampleRate = 2_400_000
        cap.claims = [
            claim("job_aprs", kind: "job", covers: 145_000_000, bw: 20_000),
            claim("app_1", kind: "app", .claimSpectrum, .priorityView),
            claim("cli_1", kind: "cli", .claimChannel, .priorityPerson, covers: 146_900_000),
            claim("job_old", kind: "job", covers: 160_000_000, displaced: true),
        ]
        let held = RetuneAsk.jobClaims(on: cap, selfID: "app_me")
        XCTAssertEqual(held.map(\.holder.clientID), ["job_aprs"], "only a satisfied job's")
        // 145 MHz ± 10 kHz inside ± 1.2 MHz: centres 143.81 to 146.19 MHz.
        XCTAssertEqual(
            RetuneAsk.keep(held, rate: 2_400_000), .within(143_810_000...146_190_000))
        XCTAssertFalse(RetuneAsk.pauses(cap, centre: 146_190_000, rate: 2_400_000, selfID: ""))
        XCTAssertTrue(RetuneAsk.pauses(cap, centre: 146_190_001, rate: 2_400_000, selfID: ""))
        // A narrower width is a move too.
        XCTAssertTrue(RetuneAsk.pauses(cap, centre: 146_000_000, rate: 1_000_000, selfID: ""))
        // The window's own job claim is never asked about.
        XCTAssertFalse(
            RetuneAsk.pauses(cap, centre: 150_000_000, rate: 2_400_000, selfID: "job_aprs"))

        var adsb = claim("job_adsb", kind: "job", .claimIq)
        adsb.centred.frequencyHz = 1_090_000_000
        adsb.centred.toleranceHz = 1_000
        adsb.sampleRateHz = 2_400_000
        XCTAssertEqual(
            RetuneAsk.keep([adsb], rate: 2_400_000), .within(1_089_999_000...1_090_001_000))
        XCTAssertEqual(RetuneAsk.keep([adsb], rate: 2_000_000), .nowhere, "it needs its rate")
        XCTAssertEqual(RetuneAsk.keep([], rate: 2_400_000), .anywhere)
    }

    func testADragAsksOnceAndRemembersTheAnswer() {
        let keep = RetuneAsk.Keep.within(143_810_000...146_190_000)
        var drag = RetuneDrag(keep: keep, start: 146_000_000)
        XCTAssertEqual(drag.step(to: 146_100_000), .move(146_100_000), "inside: no question")
        XCTAssertEqual(
            drag.step(to: 146_300_000), .ask(wanted: 146_300_000, hold: 146_190_000),
            "the first frame outside asks and holds at the edge")
        XCTAssertEqual(drag.step(to: 146_400_000), .hold(146_190_000), "asked once")
        XCTAssertEqual(drag.step(to: 146_500_000), .hold(146_190_000))
        XCTAssertEqual(drag.wanted, 146_500_000)
        drag.answered(moveAnyway: true)
        XCTAssertEqual(drag.step(to: 146_600_000), .move(146_600_000), "Move anyway holds")
        XCTAssertEqual(drag.step(to: 146_100_000), .move(146_100_000))

        var stay = RetuneDrag(keep: keep, start: 146_000_000)
        _ = stay.step(to: 143_000_000)
        stay.answered(moveAnyway: false)
        XCTAssertEqual(stay.step(to: 142_000_000), .hold(143_810_000), "Cancel holds the edge")
        XCTAssertEqual(stay.step(to: 145_000_000), .move(145_000_000), "inside moves again")
        XCTAssertEqual(stay.step(to: 142_000_000), .hold(143_810_000), "and never asks again")

        var free = RetuneDrag(keep: .anywhere, start: 146_000_000)
        XCTAssertEqual(free.step(to: 160_000_000), .move(160_000_000), "no job, no question")

        var stuck = RetuneDrag(keep: .nowhere, start: 146_000_000)
        XCTAssertEqual(
            stuck.step(to: 147_000_000), .ask(wanted: 147_000_000, hold: 146_000_000),
            "nothing keeps them: held where the drag began")
    }

    func testMoveAnywayAsksAgainWhenTheListGrew() {
        let aprs = claim("job_aprs", kind: "job", covers: 144_390_000, bw: 12_500)
        var aprsTwo = claim("job_aprs", kind: "job", .claimIq)
        aprsTwo.claimID = "clm_second"
        let rec = claim("job_rec", kind: "job", covers: 146_520_000, bw: 12_500)
        XCTAssertFalse(RetuneAsk.grew(from: [aprs], to: [aprs]), "the same job: move")
        XCTAssertFalse(RetuneAsk.grew(from: [aprs, rec], to: [aprs]), "fewer: move")
        XCTAssertFalse(RetuneAsk.grew(from: [aprs], to: []), "none left: move")
        XCTAssertFalse(
            RetuneAsk.grew(from: [aprs], to: [aprs, aprsTwo]),
            "a named job's second claim is the job already named")
        XCTAssertTrue(
            RetuneAsk.grew(from: [aprs], to: [aprs, rec]), "a job started while it was open")
        XCTAssertTrue(RetuneAsk.grew(from: [aprs], to: [rec]), "another job in its place")
    }

    func testOneQuestionAtATime() {
        var gate = RetuneGate()
        XCTAssertTrue(gate.open(), "the first click asks")
        XCTAssertFalse(gate.open(), "a second click while it is open is ignored")
        XCTAssertEqual(
            gate.frame(to: 150_000_000, keep: .anywhere, start: 146_000_000), .ignore,
            "and so is a drag")
        gate.close()
        XCTAssertTrue(gate.open(), "answered: the next move asks again")
        gate.close()
        XCTAssertEqual(
            gate.frame(to: 150_000_000, keep: .anywhere, start: 146_000_000), .write(150_000_000))
    }

    func testADragsQuestionHoldsOtherMovesAndItsAnswerEndsWithIt() {
        let keep = RetuneAsk.Keep.within(143_810_000...146_190_000)
        var gate = RetuneGate()
        XCTAssertEqual(
            gate.frame(to: 146_100_000, keep: keep, start: 146_000_000), .write(146_100_000))
        guard
            case .ask(let wanted, let hold, let n) = gate.frame(
                to: 146_300_000, keep: keep, start: 146_000_000)
        else { return XCTFail("the first frame outside asks") }
        XCTAssertEqual([wanted, hold], [146_300_000, 146_190_000])
        XCTAssertTrue(gate.asking)
        XCTAssertEqual(
            gate.frame(to: 146_400_000, keep: keep, start: 146_000_000), .write(146_190_000),
            "the asking drag holds at the edge")
        XCTAssertFalse(gate.open(), "a click while the drag's question is open is ignored")
        XCTAssertNil(gate.answerDrag(n, moveAnyway: true), "the drag is going: it carries on")
        XCTAssertFalse(gate.asking)
        XCTAssertEqual(
            gate.frame(to: 147_000_000, keep: keep, start: 146_000_000), .write(147_000_000),
            "Move anyway for the rest of the drag")

        // The release never arrived. The next drag begins, and asks again.
        gate.endDrag()
        guard
            case .ask(_, _, let next) = gate.frame(to: 147_000_000, keep: keep, start: 146_000_000)
        else { return XCTFail("a new drag asks again") }
        XCTAssertNotEqual(next, n)
        XCTAssertNil(gate.answerDrag(n, moveAnyway: true), "an old drag's answer is dropped")
        XCTAssertTrue(gate.asking, "and does not close the new drag's question")

        // The drag ends while it asks: Move anyway moves where it wanted to go.
        gate.endDrag()
        XCTAssertEqual(
            gate.frame(to: 140_000_000, keep: keep, start: 146_000_000), .ignore,
            "no drag starts while a question is open")
        XCTAssertEqual(gate.answerDrag(next, moveAnyway: true), 147_000_000)
        XCTAssertFalse(gate.asking)

        var cancelled = RetuneGate()
        guard
            case .ask(_, _, let c) = cancelled.frame(
                to: 147_000_000, keep: keep, start: 146_000_000)
        else { return XCTFail("asks") }
        cancelled.endDrag()
        XCTAssertNil(cancelled.answerDrag(c, moveAnyway: false), "Cancel after the drag: stay")
        XCTAssertFalse(cancelled.asking)
    }
}
