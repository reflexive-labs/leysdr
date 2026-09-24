// SPDX-License-Identifier: Apache-2.0

// Two flags per waterfall row: captured while the radio clipped (plans/app.md, M2-8), and kept by
// a recording (docs/design/app-design-handoff-m3.md, 8b). The app's `WaterfallBuffer` keeps one
// of these beside its ring of levels, and the shader paints a `recording` mark at the left edge
// of every clipped row and an `accentRec` bar at the right edge of every kept one. Here rather
// than in the app so the ring arithmetic runs in the Linux tests. Both flags are set after the
// rows they cover arrive, so marking is retroactive: each row's sample index and capture are
// kept. A `CaptureLevel` flags the held rows whose index lies in its interval; the raw
// per-interval fraction decides, not `FailureHold`'s state, because the mark records when the
// radio clipped and the hold only keeps the chip steady. A manifest's parts flag the held rows on
// their capture inside their span each time the manifest is read, since a part joins the
// manifest only when it closes.

import Foundation
import LeylineProto

public struct ClippedRows: Sendable, Equatable {
    /// Rows held, the ring's size; the waterfall's texture height.
    public let capacity: Int
    /// Each slot's row's first sample on the capture's clock (`FFTRow.time.sampleIndex`).
    public private(set) var sampleIndex: [UInt64]
    /// Each slot's row's capture (`FFTRow.time.captureID`): after a change of capture the ring
    /// still holds the old capture's rows, on another timeline.
    public private(set) var captureID: [String]
    /// One byte a slot, 1 when the row was captured while the radio clipped: the shader's column.
    public private(set) var flags: [UInt8]
    /// One byte a slot, 1 when a recorded part holds the row: the shader's second column.
    public private(set) var kept: [UInt8]
    /// Rows appended since the last reset; the slot of the newest is `(count - 1) % capacity`,
    /// as in the levels' ring, so a slot here is the same row there.
    public private(set) var count = 0

    public init(capacity: Int) {
        self.capacity = capacity
        sampleIndex = [UInt64](repeating: 0, count: capacity)
        captureID = [String](repeating: "", count: capacity)
        flags = [UInt8](repeating: 0, count: capacity)
        kept = [UInt8](repeating: 0, count: capacity)
    }

    public mutating func reset() {
        sampleIndex = [UInt64](repeating: 0, count: capacity)
        captureID = [String](repeating: "", count: capacity)
        flags = [UInt8](repeating: 0, count: capacity)
        kept = [UInt8](repeating: 0, count: capacity)
        count = 0
    }

    /// A new row in the next slot, unflagged: the slot's old flags belonged to the row it
    /// replaces.
    public mutating func append(sampleIndex index: UInt64, captureID capture: String = "") {
        let slot = count % capacity
        sampleIndex[slot] = index
        captureID[slot] = capture
        flags[slot] = 0
        kept[slot] = 0
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

    /// Sets the kept flag on exactly the held rows that lie in one of `parts`: the part's
    /// capture, its start sample at or before the row's, the row's at or before its end. Every
    /// other row's kept flag is cleared, so a manifest read again leaves the bars what it says,
    /// and an empty list clears them. A part whose capture is unknown flags nothing.
    /// Returns how many rows are flagged.
    @discardableResult
    public mutating func markKept(_ parts: [RecordingPart]) -> Int {
        var marked = 0
        kept = [UInt8](repeating: 0, count: capacity)
        let spans = parts.compactMap { p -> (String, ClosedRange<UInt64>)? in
            guard let c = p.captureID, !c.isEmpty, p.startSample <= p.endSample else { return nil }
            return (c, p.startSample...p.endSample)
        }
        guard !spans.isEmpty else { return 0 }
        for row in max(0, count - capacity)..<count {
            let slot = row % capacity
            let capture = captureID[slot]
            let index = sampleIndex[slot]
            if spans.contains(where: { $0.0 == capture && $0.1.contains(index) }) {
                kept[slot] = 1
                marked += 1
            }
        }
        return marked
    }
}
