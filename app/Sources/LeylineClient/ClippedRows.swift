// SPDX-License-Identifier: Apache-2.0

// Which of the waterfall's rows were captured while the radio clipped (plans/app.md, M2-8): the
// app's `WaterfallBuffer` keeps one of these beside its ring of levels, and the shader paints a
// `recording` mark at the left edge of every flagged row. Here rather than in the app so the
// ring arithmetic runs in the Linux tests. A `CaptureLevel` arrives after the rows it covers, so
// marking is retroactive: each row's sample index is kept, and a reading flags the held rows
// whose index lies in its interval. The raw per-interval fraction decides, not `FailureHold`'s
// state, because the mark records when the radio clipped and the hold only keeps the chip steady.

import Foundation
import LeylineProto

public struct ClippedRows: Sendable, Equatable {
    /// Rows held, the ring's size; the waterfall's texture height.
    public let capacity: Int
    /// Each slot's row's first sample on the capture's clock (`FFTRow.time.sampleIndex`).
    public private(set) var sampleIndex: [UInt64]
    /// One byte a slot, 1 when the row was captured while the radio clipped: the shader's column.
    public private(set) var flags: [UInt8]
    /// Rows appended since the last reset; the slot of the newest is `(count - 1) % capacity`,
    /// as in the levels' ring, so a slot here is the same row there.
    public private(set) var count = 0

    public init(capacity: Int) {
        self.capacity = capacity
        sampleIndex = [UInt64](repeating: 0, count: capacity)
        flags = [UInt8](repeating: 0, count: capacity)
    }

    public mutating func reset() {
        sampleIndex = [UInt64](repeating: 0, count: capacity)
        flags = [UInt8](repeating: 0, count: capacity)
        count = 0
    }

    /// A new row in the next slot, unflagged: the slot's old flag belonged to the row it replaces.
    public mutating func append(sampleIndex index: UInt64) {
        let slot = count % capacity
        sampleIndex[slot] = index
        flags[slot] = 0
        count += 1
    }

    /// Flags every held row whose sample index lies in `from...to` and returns how many it
    /// flagged. Every held row is compared, 2048 at four readings a second, rather than stopping
    /// at the first older row, because after a change of capture the ring still holds the old
    /// capture's rows on another clock.
    @discardableResult
    public mutating func markClipped(from: UInt64, to: UInt64) -> Int {
        guard from <= to else { return 0 }
        var marked = 0
        for row in max(0, count - capacity)..<count {
            let slot = row % capacity
            if (from...to).contains(sampleIndex[slot]) {
                flags[slot] = 1
                marked += 1
            }
        }
        return marked
    }

    /// Flags the rows one `CaptureLevel` reading covers when its clipped fraction is at or over
    /// `FailureState.clippingFloor`. `time` is the reading's, the end of its interval, and
    /// `totalSamples` the interval's length, so the interval is `time - total ... time`.
    @discardableResult
    public mutating func mark(
        _ level: Leyline_V1_CaptureLevel, at time: Leyline_V1_SampleTime
    ) -> Int {
        guard level.totalSamples > 0,
            Double(level.clippedSamples) / Double(level.totalSamples)
                >= FailureState.clippingFloor
        else { return 0 }
        let end = time.sampleIndex
        let start = end >= level.totalSamples ? end - level.totalSamples : 0
        return markClipped(from: start, to: end)
    }
}
