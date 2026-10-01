// SPDX-License-Identifier: GPL-3.0-or-later

// The capture's noise floor, measured the way every client already measures it: the median bin
// of a spectrum row. Owned by `CaptureDSPCore`, written on the DSP thread, read by each channel
// when it stamps a meter, so `Meter.snr_db` is the number the Mac app's "over noise" and
// `ley tune`'s auto squelch compute for themselves (`docs/dev/engine-internals.md`, "Squelch and
// meters").

import Foundation
import Synchronization

/// One scalar per capture: the band's floor as a density, dBFS per hertz, or NaN until a row has
/// been read. A channel adds `10·log10(bandwidth)` to get the floor at its own width, which is
/// what the median bin of a 2048-bin row plus `10·log10(bandwidth / bin width)` comes to on the
/// clients (`SpectrumFold.channelFloorDB`, `session.measureSquelch`): the bin count cancels, so
/// the daemon can take a smaller transform than they do and land on the same number.
///
/// The floor was the channel's own running minimum until 2026-09-19, and on a carrier that
/// never stops the minimum is the carrier, so a -12 dBFS signal read `0 dB over noise`
/// (`docs/plans/app.md`, APP-3). The band's median is not raised by a steady carrier, because a
/// carrier occupies a few bins of the band and the median ignores them.
/// Unchecked Sendable: the analyzer and row belong to the DSP thread; other threads touch only the atomics.
package final class BandFloor: @unchecked Sendable {
    /// Bins in the transform the floor is read from. The density does not depend on the count
    /// (per-bin noise power scales with bin width, and the density divides it back out), so the
    /// smallest size that leaves a -20 dBFS tone's leakage well short of half the row is enough.
    package static let bins = 1024
    /// Rows per second. A meter is stamped ten times a second; a floor that moves four times a
    /// second follows a gain change within a meter or two, and costs one 1024-point transform and
    /// one selection per row.
    package static let rowsPerSecond: UInt64 = 4

    private let analyzer: SpectrumAnalyzer
    private let row: UnsafeMutableBufferPointer<Float>
    /// Bit pattern of the density, NaN until the first row. One 32-bit atomic, so a reader never
    /// sees half a value.
    private let densityBits = Atomic<UInt32>(Float.nan.bitPattern)
    /// Set by the control plane when the stream restarts; the DSP thread takes the next row at
    /// once instead of waiting out the interval, so no channel is judged against the old stream.
    private let restart = Atomic<Bool>(true)
    /// Sample index at or after which the next row is due. DSP thread only.
    private var nextDue: UInt64 = 0

    package init() {
        analyzer = SpectrumAnalyzer(size: Self.bins)
        row = UnsafeMutableBufferPointer<Float>.allocate(capacity: Self.bins)
        row.initialize(repeating: 0)
    }

    deinit { row.deallocate() }

    /// The band's floor in dBFS per hertz, or NaN until a row has been read. Safe from any
    /// thread: one relaxed load.
    package var densityDBFS: Float {
        Float(bitPattern: densityBits.load(ordering: .relaxed))
    }

    /// The floor at `bandwidthHz`, in dBFS: what a channel that wide holds when nothing is on it.
    /// NaN until a row has been read.
    package func floorDBFS(bandwidthHz: UInt32) -> Float {
        densityDBFS + 10 * log10f(Float(bandwidthHz))
    }

    /// Forget the floor: the next block read is measured at once. Control plane, at a stream
    /// restart, for the reason `ChannelDSPCore.reset` gives: the samples either side of a gap
    /// are not the same air.
    package func reset() {
        densityBits.store(Float.nan.bitPattern, ordering: .relaxed)
        restart.store(true, ordering: .relaxed)
    }

    /// Hot path (DSP thread): read one row from `block` when a row is due. Allocation-free and
    /// lock-free; the transform and the selection run on this thread because they happen four
    /// times a second, not once per block, and the row buffer is this object's own.
    package func observe(_ block: SampleBuffer, at time: SampleTime, spanHz: UInt64) {
        guard spanHz > 0, block.count >= Self.bins else { return }
        let now = time.sampleIndex
        let interval = Swift.max(1 as UInt64, spanHz / Self.rowsPerSecond)
        if restart.exchange(false, ordering: .relaxed) { nextDue = now }
        // A rewound timeline would otherwise park the due point past every block that follows.
        if nextDue > now &+ interval { nextDue = now }
        guard now >= nextDue else { return }
        let scheduled = nextDue &+ interval
        nextDue = scheduled > now ? scheduled : now &+ interval
        analyzer.analyze(block, into: row)
        // The row is rewritten whole on the next read, so the selection may reorder it in place.
        let median = SpectrumDetect.median(row.baseAddress!, count: Self.bins)
        let binWidthHz = Float(spanHz) / Float(Self.bins)
        densityBits.store((median - 10 * log10f(binWidthHz)).bitPattern, ordering: .relaxed)
    }
}
