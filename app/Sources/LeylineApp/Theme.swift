// SPDX-License-Identifier: Apache-2.0

// The app's colour tokens. Seeded from what the design system has already fixed for the terminal
// (docs/dev/cli-style.md, "3a. The level ramp": hue order teal, green, amber, orange, salmon red,
// cold at the noise line and hot at full scale); the app's own ramp runs from near-black to cream
// and assumes the dark ground it owns, and its stops arrive with the design handoff. Every colour
// a view uses is named here, so the handoff is one file's worth of edits.

import SwiftUI

enum Theme {
    /// The window's ground. Dark by decision: a waterfall is read against black.
    static let ground = Color(red: 0.08, green: 0.08, blue: 0.09)

    /// The level ramp's stops, cold to hot, the terminal's values until the handoff replaces them.
    /// `level(_:)` interpolates; a chart names its own cold end (the noise line) and hot end.
    static let levelStops: [Color] = [
        Color(red: 88 / 255, green: 176 / 255, blue: 160 / 255),  // teal
        Color(red: 104 / 255, green: 160 / 255, blue: 96 / 255),  // green
        Color(red: 168 / 255, green: 136 / 255, blue: 64 / 255),  // amber
        Color(red: 216 / 255, green: 128 / 255, blue: 80 / 255),  // orange
        Color(red: 192 / 255, green: 96 / 255, blue: 80 / 255),   // salmon red
    ]

    /// The ramp at `frac` in [0, 1]: the nearest stop. A waterfall shader does its own
    /// interpolation from `levelStops` on the GPU (APP-2); this is for SwiftUI-drawn meters.
    static func level(_ frac: Double) -> Color {
        let i = Int((frac.clamped(to: 0...1) * Double(levelStops.count - 1)).rounded())
        return levelStops[i]
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
