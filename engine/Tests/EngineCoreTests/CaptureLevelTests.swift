// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import EngineCore

/// The capture's level is counted at the rails, on the native block, and published per interval.
final class CaptureLevelTests: XCTestCase {
    /// A block of `count` samples in `format` at a quiet level, with `rails` samples pushed to a
    /// rail: I on the even ones, Q on the odd ones, both on every fourth, so a count of components
    /// would disagree with a count of samples.
    private func block(_ format: SampleFormat, count: Int, rails: Int) -> SampleStorage {
        let storage = SampleStorage(capacity: count, format: format)
        switch format {
        case .cu8:
            let p = storage.base.assumingMemoryBound(to: UInt8.self)
            for i in 0 ..< count * 2 { p[i] = 128 + UInt8(i % 7) }  // a little above the mid-point
            for r in 0 ..< rails {
                let s = r * 3  // spread out; never past the block for the counts used here
                if r % 2 == 0 { p[2 * s] = 255 } else { p[2 * s + 1] = 0 }
                if r % 4 == 0 { p[2 * s + 1] = 0 }
            }
        case .cs8:
            let p = storage.base.assumingMemoryBound(to: Int8.self)
            for i in 0 ..< count * 2 { p[i] = Int8(i % 7) - 3 }
            for r in 0 ..< rails {
                let s = r * 3
                if r % 2 == 0 { p[2 * s] = 127 } else { p[2 * s + 1] = -128 }
                if r % 4 == 0 { p[2 * s + 1] = -128 }
            }
        case .cs16:
            let p = storage.base.assumingMemoryBound(to: Int16.self)
            for i in 0 ..< count * 2 { p[i] = Int16(i % 7) * 100 - 300 }
            for r in 0 ..< rails {
                let s = r * 3
                if r % 2 == 0 { p[2 * s] = 32767 } else { p[2 * s + 1] = -32768 }
                if r % 4 == 0 { p[2 * s + 1] = -32768 }
            }
        case .cf32:
            let p = storage.base.assumingMemoryBound(to: Float.self)
            for i in 0 ..< count * 2 { p[i] = Float(i % 7) * 0.01 - 0.03 }
            for r in 0 ..< rails {
                let s = r * 3
                if r % 2 == 0 { p[2 * s] = 1.0 } else { p[2 * s + 1] = -1.25 }
                if r % 4 == 0 { p[2 * s + 1] = -1.0 }
            }
        case .f32:
            preconditionFailure("not a capture format")
        }
        return storage
    }

    /// One interval per block: the rate is four blocks' worth of samples a second.
    private func core() -> CaptureDSPCore {
        CaptureDSPCore(captureID: CaptureID(), sampleRate: UInt64(CaptureDSPCore.blockSize) * CaptureLevelMeter.readingsPerSecond, centerHz: 0)
    }

    func testEveryNativeFormatCountsSamplesAtTheRailsExactly() {
        for format in [SampleFormat.cu8, .cs8, .cs16, .cf32] {
            let core = core()
            let n = CaptureDSPCore.blockSize
            XCTAssertNil(core.level.read(), "\(format): a reading before any block")
            let storage = block(format, count: n, rails: 37)
            core.deliver(storage.view(), at: SampleTime(captureID: core.captureID, sampleIndex: 0))
            guard let (reading, generation) = core.level.read() else {
                XCTFail("\(format): no reading after a full interval"); continue
            }
            XCTAssertEqual(generation, 1, "\(format)")
            // 37 samples were pushed to a rail; 10 of them on both I and Q, which is still 37
            // samples (components would read 47).
            XCTAssertEqual(reading.clippedSamples, 37, "\(format)")
            XCTAssertEqual(reading.totalSamples, UInt64(n), "\(format)")
            XCTAssertEqual(reading.sampleIndex, UInt64(n), "\(format): one past the interval's last sample")
            // A rail is full scale by each conversion's own scaling: 0 dBFS for the integer
            // formats, and the cf32 block carries a component past it.
            if format == .cf32 {
                XCTAssertEqual(reading.peak, 1.25, accuracy: 1e-6, "\(format)")
            } else {
                XCTAssertEqual(reading.peak, 1, accuracy: 1e-6, "\(format)")
                XCTAssertEqual(reading.peakDBFS, 0, accuracy: 1e-5, "\(format)")
            }
            // The next block has no rail in it: a new interval, a new generation, zero clipped.
            let quiet = block(format, count: n, rails: 0)
            core.deliver(quiet.view(), at: SampleTime(captureID: core.captureID, sampleIndex: UInt64(n)))
            guard let (second, gen2) = core.level.read() else { XCTFail("\(format): no second reading"); continue }
            XCTAssertEqual(gen2, 2, "\(format)")
            XCTAssertEqual(second.clippedSamples, 0, "\(format)")
            XCTAssertEqual(second.totalSamples, UInt64(n), "\(format)")
            XCTAssertLessThan(second.peakDBFS, -20, "\(format): a quiet block reads well under full scale, got \(second.peakDBFS)")
            XCTAssertEqual(second.sampleIndex, UInt64(2 * n), "\(format)")
        }
    }

    /// Blocks smaller than the interval accumulate into one reading; the reading covers them all.
    func testAnIntervalSpansBlocks() throws {
        let core = core()
        let n = CaptureDSPCore.blockSize
        let quarter = block(.cu8, count: n / 4, rails: 5)
        for i in 0 ..< 3 {
            core.deliver(quarter.view(), at: SampleTime(captureID: core.captureID, sampleIndex: UInt64(i * n / 4)))
            XCTAssertNil(core.level.read(), "published before the interval was full (block \(i))")
        }
        core.deliver(quarter.view(), at: SampleTime(captureID: core.captureID, sampleIndex: UInt64(3 * n / 4)))
        let (reading, _) = try XCTUnwrap(core.level.read())
        XCTAssertEqual(reading.clippedSamples, 20)
        XCTAssertEqual(reading.totalSamples, UInt64(n))
        XCTAssertEqual(reading.sampleIndex, UInt64(n))
    }

    /// A stream restart drops the interval in progress, so a reading never spans two streams.
    func testARestartDropsTheIntervalInProgress() throws {
        let core = core()
        let n = CaptureDSPCore.blockSize
        let half = block(.cu8, count: n / 2, rails: 9)
        core.deliver(half.view(), at: SampleTime(captureID: core.captureID, sampleIndex: 0))
        core.expectNewAnchor()
        let quiet = block(.cu8, count: n, rails: 0)
        core.deliver(quiet.view(), at: SampleTime(captureID: core.captureID, sampleIndex: 0))
        let (reading, _) = try XCTUnwrap(core.level.read())
        XCTAssertEqual(reading.clippedSamples, 0, "the old stream's rails leaked into the new stream's reading")
        XCTAssertEqual(reading.totalSamples, UInt64(n))
    }

    /// The kernels on their own: the count is of samples, the peak is the furthest component
    /// from the mid-point in full-scale units, and an empty block reads as nothing.
    func testRailKernels() {
        let u8: [UInt8] = [255, 128, 0, 0, 100, 128, 128, 200]
        let r = PortableKernels.countAtRailsCU8(u8, count: 8)
        XCTAssertEqual(r.clipped, 2)
        XCTAssertEqual(r.peak, 1, accuracy: 1e-6)
        let quiet: [UInt8] = [100, 128, 128, 200]
        let q = PortableKernels.countAtRailsCU8(quiet, count: 4)
        XCTAssertEqual(q.clipped, 0)
        XCTAssertEqual(q.peak, (200 - 127.5) / 127.5, accuracy: 1e-6)
        XCTAssertEqual(PortableKernels.countAtRailsCU8(quiet, count: 0).clipped, 0)
        XCTAssertEqual(PortableKernels.countAtRailsCU8(quiet, count: 0).peak, 0)
        let s8: [Int8] = [-128, 0, 5, -5, 0, 127]
        let r8 = PortableKernels.countAtRailsCS8(s8, count: 6)
        XCTAssertEqual(r8.clipped, 2)
        XCTAssertEqual(r8.peak, 1, accuracy: 1e-6)
        let s16: [Int16] = [-32768, 0, 16384, -16384, 0, 32767]
        let r16 = PortableKernels.countAtRailsCS16(s16, count: 6)
        XCTAssertEqual(r16.clipped, 2)
        XCTAssertEqual(r16.peak, 1, accuracy: 1e-6)
        XCTAssertEqual(PortableKernels.countAtRailsCS16([Int16](s16[2 ..< 4]), count: 2).peak, 0.5, accuracy: 1e-6)
        let f: [Float] = [0.5, -0.5, 1.0, 0, -0.999, 0.999, 0, -1.5]
        let rf = PortableKernels.countAtRailsCF32(f, count: 8)
        XCTAssertEqual(rf.clipped, 2)
        XCTAssertEqual(rf.peak, 1.5, accuracy: 1e-6)
    }
}
