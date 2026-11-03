// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// The Radio inspector's Claims group: who holds each of the tuned capture's claims and what it
/// needs, in words, everybody else's first.
final class ClaimWordsTests: XCTestCase {
    func claim(
        _ holder: String, kind: String, _ k: Leyline_V1_ClaimKind,
        _ p: Leyline_V1_ClaimPriority, covers hz: UInt64? = nil, bw: UInt32 = 0,
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

    func testEachClaimIsItsHolderAndItsNeedWithTheAppsOwnLast() {
        var aprs = Leyline_V1_Job()
        aprs.jobID = "job_aprs"
        aprs.decode.decoder = "aprs"
        var rec = Leyline_V1_Job()
        rec.jobID = "job_rec"
        rec.record = Leyline_V1_RecordConfig()
        var iq = claim("job_adsb", kind: "job", .claimIq, .priorityJob, displaced: true)
        iq.centred.frequencyHz = 1_090_000_000
        let claims = [
            claim("app_1", kind: "app", .claimListen, .priorityPerson),
            claim("app_1", kind: "app", .claimChannel, .priorityPerson, covers: 144_390_000),
            claim("app_1", kind: "app", .claimSpectrum, .priorityView),
            claim("app_1", kind: "app", .claimSpectrum, .priorityView),
            claim("job_aprs", kind: "job", .claimChannel, .priorityJob, covers: 144_390_000),
            claim("job_rec", kind: "job", .claimChannel, .priorityJob, covers: 144_800_000),
            iq,
            claim("cli_1", kind: "cli", .claimChannel, .priorityPerson, covers: 144_620_000),
            claim("mcp_1", kind: "mcp", .claimListen, .priorityPerson),
        ]
        let rows = ClaimWords.rows(claims, jobs: [aprs, rec], titles: ["aprs": "APRS"])
        XCTAssertEqual(
            rows,
            [
                .init(who: "a terminal", what: "channel on 144.620 MHz"),
                .init(who: "an agent", what: "listening"),
                .init(who: "job: APRS", what: "channel on 144.390 MHz"),
                .init(who: "job: recording", what: "channel on 144.800 MHz"),
                .init(
                    who: "a job", what: "IQ centred on 1.090 GHz", displaced: true,
                    paused: "paused"),
                .init(who: "the app", what: "listening"),
                .init(who: "the app", what: "channel on 144.390 MHz"),
                .init(who: "the app", what: "spectrum view", count: 2),
            ])
    }

    func testADisplacedClaimSaysWhoPausedItAndWhen() {
        var aprs = Leyline_V1_Job()
        aprs.jobID = "job_aprs"
        aprs.decode.decoder = "aprs"
        var scan = Leyline_V1_Job()
        scan.jobID = "job_scan"
        scan.scan = Leyline_V1_ScanConfig()
        let utc = TimeZone(identifier: "UTC")!
        // 2026-11-02 14:05:30 UTC.
        let at: Int64 = 1_793_628_330 * 1_000_000_000
        var byApp = claim(
            "job_aprs", kind: "job", .claimChannel, .priorityJob, covers: 144_390_000,
            displaced: true)
        byApp.displacedBy = .with {
            $0.clientID = "app_1"
            $0.kind = "app"
        }
        byApp.displacedSinceNs = at
        var byScan = claim(
            "cli_1", kind: "cli", .claimChannel, .priorityPerson, covers: 146_520_000,
            displaced: true)
        byScan.displacedBy = .with {
            $0.clientID = "job_scan"
            $0.kind = "job"
        }
        let nobody = claim(
            "job_rec", kind: "job", .claimChannel, .priorityJob, covers: 146_940_000,
            displaced: true)
        let rows = ClaimWords.rows(
            [byApp, byScan, nobody], jobs: [aprs, scan], titles: ["aprs": "APRS"],
            timeZone: utc)
        XCTAssertEqual(
            rows,
            [
                .init(
                    who: "a terminal", what: "channel on 146.520 MHz", displaced: true,
                    paused: "paused by the scan"),
                .init(
                    who: "job: APRS", what: "channel on 144.390 MHz", displaced: true,
                    paused: "paused by the app at 14:05"),
                .init(
                    who: "a job", what: "channel on 146.940 MHz", displaced: true,
                    paused: "paused"),
            ])
        XCTAssertEqual(
            ClaimWords.paused(
                by: byApp, jobs: [aprs], titles: [:],
                timeZone: TimeZone(identifier: "America/Los_Angeles")!),
            "paused by the app at 06:05")
    }

    func testASweepIsItsRange() {
        let c = claim(
            "job_scan", kind: "job", .claimSweep, .priorityJob, covers: 146_000_000,
            bw: 4_000_000)
        XCTAssertEqual(ClaimWords.what(c), "sweep 144.000 MHz to 148.000 MHz")
    }
}
