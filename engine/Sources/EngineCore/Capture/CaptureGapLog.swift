// SPDX-License-Identifier: GPL-3.0-or-later

// The capture's dropped samples, by where they were on its timeline. `CaptureDSPCore.deliver`
// drops a block when the block ring is full (the DSP thread has fallen behind the radio), and that
// is the one place the samples are known to be gone; this log is where it says so. A recording
// reads it to list the gaps in what it wrote (docs/design/recording.md, "Gaps"), so a part never
// claims audio it does not hold.

import Synchronization

/// One stretch of capture samples the block ring dropped: `samples` of them from `fromSample`, on
/// the capture's timeline (invariant 5).
package struct CaptureGap: Hashable, Sendable {
    package var fromSample: UInt64
    package var samples: UInt64

    package init(fromSample: UInt64, samples: UInt64) {
        self.fromSample = fromSample
        self.samples = samples
    }

    package var toSample: UInt64 { fromSample &+ samples }
}

/// A fixed ring of the capture's last `capacity` gaps. The device thread is the one writer: drops
/// that follow one another are one gap, held open until a block is committed again, and published
/// then into a preallocated slot behind a per-slot seqlock. Readers on any thread keep a cursor
/// and read what was published past it. No allocation and no lock on the writer side
/// (invariant 4); a reader more than `capacity` gaps behind is told how many it missed.
/// Unchecked Sendable: the open gap belongs to the device thread; every published field is an atomic.
package final class CaptureGapLog: @unchecked Sendable {
    package static let capacity = 64

    /// One published gap. `seq` is odd while the writer is in it; `number` says which gap the slot
    /// holds, so a reader that lapped the ring can tell its gap was overwritten.
    private final class Slot: Sendable {
        let seq = Atomic<UInt64>(0)
        let number = Atomic<UInt64>(0)
        let from = Atomic<UInt64>(0)
        let samples = Atomic<UInt64>(0)
    }

    private let slots: [Slot]
    /// Gaps published so far; gap `n` (counted from 0) is in slot `n % capacity`.
    private let published = Atomic<UInt64>(0)

    // Device thread only.
    private var openFrom: UInt64 = 0
    private var openSamples: UInt64 = 0

    package init() {
        slots = (0..<Self.capacity).map { _ in Slot() }
    }

    /// Gaps published since the capture started. A reader starting now passes this as its cursor
    /// and sees only gaps that come after it.
    package var count: UInt64 { published.load(ordering: .acquiring) }

    // MARK: Device thread

    /// Hot path (device thread): `samples` samples from `from` were dropped. Contiguous with the
    /// gap already open they extend it; otherwise the open one is published and a new one begins.
    @inline(__always)
    package func dropped(from: UInt64, samples: UInt64) {
        guard samples > 0 else { return }
        if openSamples > 0 {
            if openFrom &+ openSamples == from {
                openSamples &+= samples
                return
            }
            publish()
        }
        openFrom = from
        openSamples = samples
    }

    /// Hot path (device thread): a block was committed, so the gap open before it, if any, has
    /// ended. One compare when nothing was dropped.
    @inline(__always)
    package func delivered() {
        guard openSamples > 0 else { return }
        publish()
    }

    private func publish() {
        let n = published.load(ordering: .relaxed)
        let slot = slots[Int(n % UInt64(Self.capacity))]
        slot.seq.wrappingAdd(1, ordering: .sequentiallyConsistent)
        slot.number.store(n, ordering: .sequentiallyConsistent)
        slot.from.store(openFrom, ordering: .sequentiallyConsistent)
        slot.samples.store(openSamples, ordering: .sequentiallyConsistent)
        slot.seq.wrappingAdd(1, ordering: .sequentiallyConsistent)
        published.store(n &+ 1, ordering: .releasing)
        openSamples = 0
    }

    // MARK: Readers

    /// The gaps published from `cursor` on, oldest first, and the cursor to pass next time.
    /// `missed` counts gaps that were overwritten before this read reached them. Any thread;
    /// allocates, so never from the sample path.
    package func read(from cursor: UInt64) -> (gaps: [CaptureGap], next: UInt64, missed: UInt64) {
        let end = count
        guard end > cursor else { return ([], end, 0) }
        var first = cursor
        var missed: UInt64 = 0
        if end - cursor > UInt64(Self.capacity) {
            first = end - UInt64(Self.capacity)
            missed = first - cursor
        }
        var gaps: [CaptureGap] = []
        gaps.reserveCapacity(Int(end - first))
        for n in first..<end {
            let slot = slots[Int(n % UInt64(Self.capacity))]
            var got: CaptureGap?
            while true {
                let before = slot.seq.load(ordering: .sequentiallyConsistent)
                guard before & 1 == 0 else { continue }
                let number = slot.number.load(ordering: .sequentiallyConsistent)
                let gap = CaptureGap(fromSample: slot.from.load(ordering: .sequentiallyConsistent),
                                     samples: slot.samples.load(ordering: .sequentiallyConsistent))
                guard slot.seq.load(ordering: .sequentiallyConsistent) == before else { continue }
                if number == n { got = gap }
                break
            }
            if let got { gaps.append(got) } else { missed += 1 }
        }
        return (gaps, end, missed)
    }
}
