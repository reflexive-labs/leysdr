// SPDX-License-Identifier: Apache-2.0

// The clock's arithmetic, held to `go/pkg/leyline/decoders.go`: `AnchorWallTime` has no
// numeric test of its own there, so the numbers here are chosen to be checked by hand (one
// second of samples is one second; 100 ppm over a second is 100 µs), and to say what a missing
// anchor gives, which is nothing.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class SampleClockTests: XCTestCase {
    /// 2023-11-14T22:13:20Z, at the nanosecond precision Go keeps.
    private let hostNs: Int64 = 1_700_000_000_000_000_000

    private func anchor(rate: UInt64 = 2_400_000, drift: Double = 0, hostNs: Int64? = nil)
        -> Leyline_V1_CaptureAnchor
    {
        .with {
            $0.captureID = "cap_a"
            $0.hostTimeNs = hostNs ?? self.hostNs
            $0.sampleRate = rate
            $0.driftPpm = drift
        }
    }

    private func at(_ index: UInt64, capture: String = "cap_a") -> Leyline_V1_SampleTime {
        .with {
            $0.captureID = capture
            $0.sampleIndex = index
        }
    }

    func testSampleZeroIsTheAnchorAndASecondOfSamplesIsASecond() throws {
        let zero = try XCTUnwrap(SampleClock.wallTime(anchor: anchor(), sampleIndex: 0))
        XCTAssertEqual(zero.timeIntervalSince1970, 1_700_000_000, accuracy: 1e-6)
        let one = try XCTUnwrap(SampleClock.wallTime(anchor: anchor(), sampleIndex: 2_400_000))
        XCTAssertEqual(one.timeIntervalSince(zero), 1, accuracy: 1e-6)
        let ten = try XCTUnwrap(SampleClock.wallTime(anchor: anchor(), sampleIndex: 24_000_000))
        XCTAssertEqual(ten.timeIntervalSince(zero), 10, accuracy: 1e-6)
    }

    func testDriftScalesTheElapsedTimeAsTheAnchorStatesIt() throws {
        let fast = try XCTUnwrap(
            SampleClock.wallTime(anchor: anchor(drift: 100), sampleIndex: 2_400_000))
        XCTAssertEqual(fast.timeIntervalSince1970 - 1_700_000_000, 1.0001, accuracy: 1e-6)
        let slow = try XCTUnwrap(
            SampleClock.wallTime(anchor: anchor(drift: -50), sampleIndex: 24_000_000))
        XCTAssertEqual(slow.timeIntervalSince1970 - 1_700_000_000, 9.9995, accuracy: 1e-6)
    }

    func testAnAnchorWithoutARateGivesNothing() {
        XCTAssertNil(SampleClock.wallTime(anchor: anchor(rate: 0), sampleIndex: 1))
        XCTAssertNil(SampleClock.wallTime(of: at(1), anchor: anchor(rate: 0)))
    }

    func testAnAnchorCoversOnlyItsOwnCaptureFromTheSampleItAppliesFrom() throws {
        let t = try XCTUnwrap(SampleClock.wallTime(of: at(2_400_000), anchor: anchor()))
        XCTAssertEqual(t.timeIntervalSince1970, 1_700_000_001, accuracy: 1e-6)
        XCTAssertNil(SampleClock.wallTime(of: at(2_400_000, capture: "cap_b"), anchor: anchor()))
        XCTAssertNil(SampleClock.wallTime(of: at(2_400_000, capture: ""), anchor: anchor()))
        XCTAssertNil(
            SampleClock.wallTime(of: at(2_400_000), anchor: anchor(), fromSample: 2_400_001),
            "a record anchor applies from its from_sample on, not before")
        XCTAssertNotNil(
            SampleClock.wallTime(of: at(2_400_000), anchor: anchor(), fromSample: 2_400_000))
        XCTAssertNil(
            SampleClock.wallTime(of: at(2_400_000), anchor: anchor(hostNs: 0)),
            "a capture's anchor is undated until its first block, and 1970 is not a clock")
    }
}
