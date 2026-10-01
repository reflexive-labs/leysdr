// SPDX-License-Identifier: Apache-2.0

// The mark: a ring and a dot, `docs/design/brand/leyline-mark.svg` drawn in code rather than
// loaded, so it takes any size and `Theme`'s colours. The toolbar
// draws it at 13 pt beside `Leyline`, the splash at 26 pt, and `scripts/render-icon.swift` draws
// the same proportions in CoreGraphics for the app's icon. The ring's outer edge touches the
// box, as in both SVGs, so a thicker line eats inward and the box stays the mark's size.

import SwiftUI

struct BrandMark: View {
    /// The side of the mark's box.
    var size: CGFloat = Theme.Layout.brandMarkSize
    /// The ring's line; by default the SVG's 1.2 in 13, scaled with `size`. The splash passes
    /// its SVG's own 1.5 at 26.
    var lineWidth: CGFloat?
    var colour: Color = Theme.accent

    var body: some View {
        let line = lineWidth ?? size * Theme.Layout.brandMarkLine / Theme.Layout.brandMarkSize
        let dot = size * Theme.Layout.brandMarkDot / Theme.Layout.brandMarkSize
        ZStack {
            Ring(radius: (size - line) / 2, lineWidth: line).fill(colour)
            Circle().fill(colour).frame(width: dot * 2, height: dot * 2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A circle's outline about the centre of its frame, with its radius and line as animatable
/// data, so the splash can grow and thin one (the ripple) and thicken the flying mark's line as
/// it shrinks. A stroked `Circle` is not used because whether a stroke's width animates is not
/// documented; a shape's `animatableData` is. The ring may be larger than its frame and is drawn
/// outside it.
struct Ring: Shape {
    var radius: CGFloat
    var lineWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, lineWidth) }
        set {
            radius = newValue.first
            lineWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(radius, 0)
        let circle = CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2)
        return Path(ellipseIn: circle).strokedPath(StrokeStyle(lineWidth: max(lineWidth, 0)))
    }
}
