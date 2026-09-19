// SPDX-License-Identifier: Apache-2.0

// A value's place across a pixel width, and the inverse, both clamped: the squelch marker and
// the gain slider each drag a `Double` along a track, and both used to keep their own copy of
// this pair (docs/dev/swift-style.md, section 13). `Comparable.clamped(to:)` lives here too,
// because clamping is what both directions of the map are for.

import CoreGraphics

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

enum Scale {
    /// Where `value` falls across `width` if `range` is stretched to fill it, clamped to the
    /// track when `value` runs past either end.
    static func x(of value: Double, in range: ClosedRange<Double>, width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(((value - range.lowerBound) / span).clamped(to: 0...1)) * width
    }

    /// The inverse of `x(of:in:width:)`: the value at `x` across `width`, clamped to `range`.
    static func value(atX x: CGFloat, in range: ClosedRange<Double>, width: CGFloat) -> Double {
        range.lowerBound
            + Double((x / max(width, 1)).clamped(to: 0...1)) * (range.upperBound - range.lowerBound)
    }
}
