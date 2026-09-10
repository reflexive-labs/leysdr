import XCTest
@testable import EngineCore

final class SweepPlanTests: XCTestCase {
    private let rtl = [FrequencyRange(minHz: 24_000_000, maxHz: 1_766_000_000)]

    /// The story's own example: 144-148 MHz on a 2.4 MSPS radio.
    func testTwoMetreSweep() throws {
        let p = try XCTUnwrap(SweepPlan.plan(minHz: 144_000_000, maxHz: 148_000_000,
                                             sampleRateHz: 2_400_000, tuningRanges: rtl))
        XCTAssertFalse(p.clipped)
        XCTAssertEqual(p.covered.lowHz, 144_000_000)
        XCTAssertEqual(p.covered.highHz, 148_000_000)
        // advance = (0.45 - 0.05) * 2.4 MHz = 960 kHz, plus the two end steps.
        XCTAssertEqual(p.steps.count, 7)
        XCTAssertEqual(p.steps.first?.centerHz, 143_880_000)   // 144.0 - 0.05 * 2.4
        XCTAssertEqual(p.steps[2].centerHz - p.steps[1].centerHz, 960_000)
    }

    /// The property the geometry exists for: no gap anywhere, because a step's own DC hole is
    /// covered by its neighbour's lower quarter.
    func testEveryFrequencyInRangeIsLookedAt() throws {
        for (lo, hi, rate) in [(144_000_000 as UInt64, 148_000_000 as UInt64, 2_400_000 as UInt64),
                               (88_000_000, 108_000_000, 2_048_000),
                               (162_400_000, 162_550_000, 250_000),
                               (902_000_000, 928_000_000, 3_200_000)]
        {
            let p = try XCTUnwrap(SweepPlan.plan(minHz: lo, maxHz: hi, sampleRateHz: rate, tuningRanges: rtl))
            var gaps: [UInt64] = []
            var single = 0
            let stride = Swift.max(1, (hi - lo) / 4000)
            var hz = lo
            while hz < hi {
                switch p.looks(at: hz) {
                case 0: gaps.append(hz)
                case 1: single += 1
                default: break
                }
                hz += stride
            }
            XCTAssertTrue(gaps.isEmpty, "\(lo)-\(hi) at \(rate): \(gaps.count) uncovered points, first \(gaps.first ?? 0)")
            // Most of the range is seen at two tuner settings, which is the cross-check the
            // geometry buys. The exception is each step's DC hole: it is covered by exactly one
            // neighbour, and covering it twice would mean halving the advance and doubling the
            // sweep. A detection carries how many steps saw it, so this is reported, not hidden.
            let sampled = Int((hi - lo) / stride)
            XCTAssertLessThanOrEqual(single, sampled / 2, "\(lo)-\(hi): \(single)/\(sampled) points seen only once")
        }
    }

    /// No analysis window may sit on the capture centre: that is where the uncorrected DC spike is.
    func testNoWindowTouchesTheCaptureCentre() throws {
        let p = try XCTUnwrap(SweepPlan.plan(minHz: 144_000_000, maxHz: 148_000_000,
                                             sampleRateHz: 2_400_000, tuningRanges: rtl))
        for s in p.steps {
            XCTAssertFalse(s.low.contains(s.centerHz))
            XCTAssertFalse(s.high.contains(s.centerHz))
            XCTAssertEqual(s.high.lowHz - s.centerHz, 120_000)   // 0.05 * 2.4 MHz
            XCTAssertEqual(s.centerHz - s.low.highHz, 120_000)
        }
    }

    /// A range narrower than one span still needs two steps, because one step cannot cover its
    /// own hole.
    func testANarrowRangeStillGetsTwoSteps() throws {
        let p = try XCTUnwrap(SweepPlan.plan(minHz: 162_400_000, maxHz: 162_550_000,
                                             sampleRateHz: 2_400_000, tuningRanges: rtl))
        XCTAssertEqual(p.steps.count, 2)
        // And it gets both looks: once in a step's lower window, once in another's upper.
        var hz: UInt64 = 162_400_000
        while hz < 162_550_000 {
            XCTAssertEqual(p.looks(at: hz), 2, "\(hz)")
            hz += 1000
        }
        XCTAssertNotEqual(p.steps[0].centerHz, p.steps[1].centerHz)
    }

    /// Asking for more than the radio can hear returns what it can, and says so.
    func testAskingBelowTheTunerClipsAndSaysSo() throws {
        let p = try XCTUnwrap(SweepPlan.plan(minHz: 1_000_000, maxHz: 30_000_000,
                                             sampleRateHz: 2_400_000, tuningRanges: rtl))
        XCTAssertTrue(p.clipped)
        XCTAssertGreaterThanOrEqual(p.covered.lowHz, 22_000_000)   // 24 MHz - half a span
        XCTAssertEqual(p.covered.highHz, 30_000_000)
        for s in p.steps {
            XCTAssertGreaterThanOrEqual(s.centerHz, 24_000_000)
            XCTAssertLessThanOrEqual(s.centerHz, 1_766_000_000)
        }
    }

    /// A file device tunes to exactly one frequency -- the one its recording was made at -- and a
    /// sweep over it is the single-step fixture run the detector is tested with.
    func testAPointTuningRangeGivesOneStep() throws {
        let file = [FrequencyRange(minHz: 146_520_000, maxHz: 146_520_000)]
        let p = try XCTUnwrap(SweepPlan.plan(minHz: 145_400_000, maxHz: 147_600_000,
                                             sampleRateHz: 2_400_000, tuningRanges: file))
        XCTAssertEqual(p.steps.count, 1)
        XCTAssertEqual(p.steps[0].centerHz, 146_520_000)
        XCTAssertTrue(p.clipped, "the request was wider than the one frequency this radio has")
        XCTAssertEqual(p.looks(at: 146_220_000), 1, "300 kHz below centre is inside the lower window")
        XCTAssertEqual(p.looks(at: 147_400_000), 1, "880 kHz above centre is inside the upper window")
        // With one step the DC hole has no neighbour to cover it, so the guard band -- 5% of the
        // span, 120 kHz here -- is simply not looked at. A fixture meant for the detector must put
        // its carriers outside it.
        XCTAssertEqual(p.looks(at: 146_520_000), 0, "the capture centre is where the DC spike is")
        XCTAssertEqual(p.looks(at: 146_620_000), 0, "100 kHz off centre is inside the guard band")
    }

    func testImpossibleRequestsReturnNil() {
        XCTAssertNil(SweepPlan.plan(minHz: 148_000_000, maxHz: 144_000_000, sampleRateHz: 2_400_000, tuningRanges: rtl))
        XCTAssertNil(SweepPlan.plan(minHz: 144_000_000, maxHz: 148_000_000, sampleRateHz: 0, tuningRanges: rtl))
        XCTAssertNil(SweepPlan.plan(minHz: 144_000_000, maxHz: 148_000_000, sampleRateHz: 2_400_000, tuningRanges: []))
        // Entirely below the tuner.
        XCTAssertNil(SweepPlan.plan(minHz: 1_000_000, maxHz: 2_000_000, sampleRateHz: 2_400_000, tuningRanges: rtl))
    }

    /// A clamped run must not sweep the same point twice.
    func testCentresAreNeverRepeated() throws {
        let p = try XCTUnwrap(SweepPlan.plan(minHz: 1_700_000_000, maxHz: 1_800_000_000,
                                             sampleRateHz: 2_400_000, tuningRanges: rtl))
        XCTAssertEqual(Set(p.steps.map(\.centerHz)).count, p.steps.count)
    }
}
