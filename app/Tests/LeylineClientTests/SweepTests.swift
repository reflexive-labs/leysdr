// SPDX-License-Identifier: Apache-2.0

// Scan band without a daemon (docs/design/channels.md, "Scan the band"): the scan the band row
// asks for, the row's words from a job's status detail, the hits kept from a Scan and their
// names, the coverage note when the sweep looked at less than the band, and the outcome each
// job state maps to.

import LeylineProto
import XCTest

@testable import LeylineClient

final class SweepTests: XCTestCase {
    private func band(_ alias: String) throws -> Band {
        try XCTUnwrap(Bands.resolve(alias), "\(alias) is not in bands.json")
    }

    private func detection(_ hz: UInt64, snr: Double) -> Leyline_V1_Detection {
        var d = Leyline_V1_Detection()
        d.centerHz = hz
        d.snrDb = snr
        d.bandwidthHz = 12_500
        d.looks = 8
        d.looksPossible = 8
        return d
    }

    private func scan(_ detections: [Leyline_V1_Detection], covered: ClosedRange<UInt64>? = nil)
        -> Leyline_V1_Scan
    {
        var s = Leyline_V1_Scan()
        s.scanID = "scan_01"
        s.detections = detections
        if let covered {
            s.covered.minHz = covered.lowerBound
            s.covered.maxHz = covered.upperBound
        }
        return s
    }

    private func job(_ state: Leyline_V1_JobState, detail: String = "", code: String = "")
        -> Leyline_V1_Job
    {
        var j = Leyline_V1_Job()
        j.jobID = "job_01"
        j.state = state
        j.statusDetail = detail
        j.resultUris = ["ley://scans/scan_01"]
        if !code.isEmpty {
            j.error.code = code
            j.error.message = "the allocator said no"
        }
        return j
    }

    // MARK: The request

    func testTheGroupsConfigSpansBothHalvesOnceWithTakeOverOnTheDevice() throws {
        let gmrs = try band("gmrs")
        let config = Sweep.config(for: gmrs, in: Bands.builtIn, deviceID: "dev_01")
        XCTAssertEqual(config.range.minHz, 462_537_500)
        XCTAssertEqual(config.range.maxHz, 467_737_500)
        XCTAssertTrue(config.once)
        XCTAssertTrue(config.takeOver)
        XCTAssertEqual(config.deviceID, "dev_01")
        let request = Sweep.request(for: gmrs, in: Bands.builtIn, deviceID: "dev_01")
        guard case .scan(let sent)? = request.config else {
            return XCTFail("the request carries no scan config")
        }
        XCTAssertEqual(sent, config)
    }

    func testAPlainBandsConfigIsItsOwnEdges() throws {
        let noaa = try band("noaa")
        let config = Sweep.config(for: noaa, in: Bands.builtIn, deviceID: "dev_01")
        XCTAssertEqual(config.range.minHz, noaa.minHz)
        XCTAssertEqual(config.range.maxHz, noaa.maxHz)
        XCTAssertEqual(config.range.minHz, 162_400_000)
        XCTAssertEqual(config.range.maxHz, 162_550_000)
    }

    // MARK: Progress

    func testTheRowReadsTheStepCountFromEitherDetailShape() throws {
        let twoM = try band("2m")
        let before = SweepProgress(statusDetail: "sweeping 7 steps")
        XCTAssertEqual(before.steps, 7)
        XCTAssertNil(before.step)
        XCTAssertNil(before.found)
        XCTAssertEqual(before.words(band: twoM), "Sweeping 2 m amateur, 7 steps…")

        let during = SweepProgress(statusDetail: "step 3/7, 1 found")
        XCTAssertEqual(during.step, 3)
        XCTAssertEqual(during.steps, 7)
        XCTAssertEqual(during.found, 1)
        XCTAssertEqual(during.words(band: twoM), "Sweeping 2 m amateur, 7 steps…")
    }

    func testAnUnknownDetailPrintsVerbatim() throws {
        let twoM = try band("2m")
        let settling = SweepProgress(statusDetail: "settling")
        XCTAssertNil(settling.steps)
        XCTAssertEqual(settling.words(band: twoM), "settling")
    }

    // MARK: Hits

    func testAGroupKeepsHitsInItsHalvesStrongestFirstAndDropsTheGap() throws {
        let gmrs = try band("gmrs")
        let s = scan([
            detection(462_662_500, snr: 20), detection(465_000_000, snr: 30),
            detection(467_600_000, snr: 10),
        ])
        let result = SweepResult(scan: s, band: gmrs, in: Bands.builtIn)
        XCTAssertEqual(result.hits.map(\.hz), [462_662_500, 467_600_000])
        XCTAssertEqual(result.hits.map(\.snrDb), [20, 10])
        XCTAssertEqual(result.hits.first?.name, "ch5")
        XCTAssertEqual(result.hits.first?.label, "ch5")
        XCTAssertNil(result.hits.last?.name, "467.6 MHz is on no GMRS channel")
        XCTAssertEqual(result.hits.last?.label, "467.600 MHz")
        XCTAssertEqual(result.hits.first?.id, 462_662_500)
        XCTAssertNil(result.covered)

        let half = try band("gmrs-462")
        let one = SweepResult(scan: s, band: half, in: Bands.builtIn)
        XCTAssertEqual(one.hits.map(\.hz), [462_662_500])
    }

    func testHitsWithEqualSNRKeepTheDetectionsOrder() throws {
        let twoM = try band("2m")
        let s = scan([
            detection(146_800_000, snr: 12), detection(145_200_000, snr: 12),
            detection(146_400_000, snr: 12),
        ])
        let result = SweepResult(scan: s, band: twoM, in: Bands.builtIn)
        XCTAssertEqual(result.hits.map(\.hz), [146_800_000, 145_200_000, 146_400_000])
    }

    // MARK: Coverage

    func testACoveredRangeNarrowerThanTheBandNamesBothRanges() throws {
        let twoM = try band("2m")
        let s = scan([], covered: 144_900_000...147_100_000)
        let result = SweepResult(scan: s, band: twoM, in: Bands.builtIn)
        XCTAssertEqual(result.covered, 144_900_000...147_100_000)
        let words = try XCTUnwrap(result.coverageWords(band: twoM))
        for part in ["144.900 MHz", "147.100 MHz", "144.000 MHz", "148.000 MHz"] {
            XCTAssertTrue(words.contains(part), "\(words) does not name \(part)")
        }
        XCTAssertTrue(words.hasPrefix("covered "), words)
    }

    func testACoveredRangeEqualToTheBandSaysNothing() throws {
        let twoM = try band("2m")
        let whole = SweepResult(
            scan: scan([], covered: 144_000_000...148_000_000), band: twoM, in: Bands.builtIn)
        XCTAssertNil(whole.coverageWords(band: twoM))
        let none = SweepResult(scan: scan([]), band: twoM, in: Bands.builtIn)
        XCTAssertNil(none.coverageWords(band: twoM))
    }

    func testTheEmptyWordsAreTheDesigns() {
        XCTAssertEqual(
            SweepResult.emptyWords,
            "Nothing on the air right now; repeaters and towers key up briefly")
    }

    // MARK: Outcome

    func testEachJobStateMapsToItsOutcome() throws {
        let twoM = try band("2m")
        let bands = Bands.builtIn
        let hit = scan([detection(146_520_000, snr: 15)])
        let quiet = scan([])

        XCTAssertEqual(
            SweepOutcome.from(
                job: job(.running, detail: "sweeping 7 steps"), scan: nil,
                band: twoM, in: bands),
            .running(SweepProgress(statusDetail: "sweeping 7 steps")))
        XCTAssertEqual(
            SweepOutcome.from(
                job: job(.degraded, detail: "step 2/7, 0 found"), scan: nil,
                band: twoM, in: bands),
            .running(SweepProgress(statusDetail: "step 2/7, 0 found")))
        XCTAssertEqual(
            SweepOutcome.from(
                job: job(.completed, detail: "1 found in 7 steps"), scan: hit,
                band: twoM, in: bands),
            .found(SweepResult(scan: hit, band: twoM, in: bands)))
        XCTAssertEqual(
            SweepOutcome.from(
                job: job(.completed, detail: "0 found in 7 steps"), scan: quiet,
                band: twoM, in: bands),
            .empty(SweepResult(scan: quiet, band: twoM, in: bands)))
        XCTAssertNil(
            SweepOutcome.from(
                job: job(.completed, detail: "1 found"), scan: nil, band: twoM,
                in: bands),
            "a finished job without its scan yet is not decided")
        XCTAssertEqual(
            SweepOutcome.from(
                job: job(
                    .failed, detail: "the app is listening on 146.100 MHz",
                    code: "DEVICE_BUSY"), scan: nil, band: twoM, in: bands),
            .failed(detail: "the app is listening on 146.100 MHz"))
        XCTAssertEqual(
            SweepOutcome.from(
                job: job(.failed, code: "DEVICE_BUSY"), scan: nil, band: twoM,
                in: bands),
            .failed(detail: "the allocator said no"), "no detail: the error's message")
        XCTAssertEqual(
            SweepOutcome.from(
                job: job(.cancelled, detail: "stopped in step 2 of 7, 0 found"),
                scan: nil, band: twoM, in: bands),
            .cancelled)
    }

    func testTheScanIDIsReadFromTheScansURIOnly() {
        var j = Leyline_V1_Job()
        j.resultUris = ["ley://recordings/job_01", "ley://scans/scan_01HZX"]
        XCTAssertEqual(Sweep.scanID(of: j), "scan_01HZX")
        j.resultUris = ["ley://recordings/job_01"]
        XCTAssertNil(Sweep.scanID(of: j))
        j.resultUris = ["ley://scans/"]
        XCTAssertNil(Sweep.scanID(of: j), "an empty id is no id")
        j.resultUris = []
        XCTAssertNil(Sweep.scanID(of: j))
    }
}
