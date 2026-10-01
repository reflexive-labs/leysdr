// SPDX-License-Identifier: GPL-3.0-or-later

// The capture's raw level: samples at the converter's rails and the peak, counted on the device
// thread where every block is already converted. The daemon uses it to report whether the radio
// is clipping. The loudest FFT bin is not used because it reads near full scale on a
// strong steady carrier at auto gain when nothing is wrong. Owned by
// `CaptureDSPCore`, published a quarter of a second at a time, read by `TelemetryService` as
// `CaptureLevel`.

import Foundation
import Synchronization

/// One interval of the capture's level: a quarter of a second of samples, by the capture's rate.
package struct CaptureLevelReading: Hashable, Sendable {
    /// Capture-timeline index one past the interval's last sample.
    package var sampleIndex: UInt64
    /// Complex samples with I or Q at the converter's rails. Samples, not components: a sample
    /// with both at a rail is one clipped sample, and the fraction against `totalSamples` is then
    /// a fraction of time.
    package var clippedSamples: UInt64
    /// Samples in the interval. A little over a quarter second's worth, since a block is never
    /// split to end an interval on the boundary.
    package var totalSamples: UInt64
    /// The largest component magnitude in the interval, 1 at full scale.
    package var peak: Float

    package init(sampleIndex: UInt64, clippedSamples: UInt64, totalSamples: UInt64, peak: Float) {
        self.sampleIndex = sampleIndex
        self.clippedSamples = clippedSamples
        self.totalSamples = totalSamples
        self.peak = peak
    }

    /// `peak` against full scale; -inf when the interval was digitally silent.
    package var peakDBFS: Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }
}

/// Accumulates one capture's rail counts and peak on the device thread and publishes a reading
/// per interval in a seqlock: a reader from any thread copies four words and retries if a write
/// overlapped. Allocation-free and lock-free on both sides (invariant 4).
/// Unchecked Sendable: the accumulators belong to the device thread; the published reading is a seqlock of atomics.
package final class CaptureLevelMeter: @unchecked Sendable {
    /// Readings per second, the `BandFloor` cadence: fast enough to follow a gain change within
    /// a meter or two, slow enough that the fraction is measured over hundreds of thousands of
    /// samples rather than a block.
    package static let readingsPerSecond: UInt64 = 4

    // Device thread only.
    private var clipped: UInt64 = 0
    private var total: UInt64 = 0
    private var peak: Float = 0
    /// Set by the control plane at a stream restart; the device thread drops the interval in
    /// progress so a reading never spans two streams.
    private let restart = Atomic<Bool>(true)

    // The published reading. `seq` is odd while a write is in progress; a reader that loaded an
    // odd value, or a different one after its copy, goes again. Every access is sequentially
    // consistent so the fields are ordered against the counter on both sides.
    private let seq = Atomic<UInt64>(0)
    private let outIndex = Atomic<UInt64>(0)
    private let outClipped = Atomic<UInt64>(0)
    private let outTotal = Atomic<UInt64>(0)
    private let outPeakBits = Atomic<UInt32>(0)

    package init() {}

    /// Hot path (device thread): fold one block's count and peak in, and publish once the
    /// interval holds `sampleRate / readingsPerSecond` samples. `end` is the capture-timeline
    /// index one past the block's last sample.
    package func observe(clipped n: Int, peak p: Float, count: Int, endingAt end: UInt64, sampleRate: UInt64) {
        if restart.exchange(false, ordering: .relaxed) {
            clipped = 0; total = 0; peak = 0
        }
        clipped &+= UInt64(n)
        total &+= UInt64(count)
        if p > peak { peak = p }
        let interval = Swift.max(1 as UInt64, sampleRate / Self.readingsPerSecond)
        guard total >= interval else { return }
        seq.wrappingAdd(1, ordering: .sequentiallyConsistent)
        outIndex.store(end, ordering: .sequentiallyConsistent)
        outClipped.store(clipped, ordering: .sequentiallyConsistent)
        outTotal.store(total, ordering: .sequentiallyConsistent)
        outPeakBits.store(peak.bitPattern, ordering: .sequentiallyConsistent)
        seq.wrappingAdd(1, ordering: .sequentiallyConsistent)
        clipped = 0; total = 0; peak = 0
    }

    /// Forget the interval in progress. Control plane, at a stream restart, for the reason
    /// `BandFloor.reset` gives: the samples either side of a gap are not the same air.
    package func reset() {
        restart.store(true, ordering: .relaxed)
    }

    /// The latest reading and its generation (1 for the first reading published), or nil before
    /// any. Safe from any thread; a caller sending readings on keeps the last generation it sent
    /// so a reading goes out once and never twice.
    package func read() -> (reading: CaptureLevelReading, generation: UInt64)? {
        while true {
            let before = seq.load(ordering: .sequentiallyConsistent)
            guard before != 0 else { return nil }
            guard before & 1 == 0 else { continue }
            let reading = CaptureLevelReading(
                sampleIndex: outIndex.load(ordering: .sequentiallyConsistent),
                clippedSamples: outClipped.load(ordering: .sequentiallyConsistent),
                totalSamples: outTotal.load(ordering: .sequentiallyConsistent),
                peak: Float(bitPattern: outPeakBits.load(ordering: .sequentiallyConsistent)))
            guard seq.load(ordering: .sequentiallyConsistent) == before else { continue }
            return (reading, before / 2)
        }
    }
}
