// SPDX-License-Identifier: Apache-2.0

// The app's colour and type tokens: every value in docs/design/app-design-handoff.md ("Palette",
// "Type") and the inspector's few from docs/design/app-design-handoff-m2.md ("Decided
// 2026-09-20"), and nothing a view invents. The names are the handoffs', so the design and the
// code use the same names. The level ramp shares hue order with the terminal's
// (docs/dev/cli-style.md, "3a. The level ramp") and nothing else: this one runs from near-black
// to cream and assumes the app's own dark ground.

import SwiftUI

enum Theme {
    // Grounds and chrome.
    static let ground = Color(hex: 0x0B0D0F)
    static let chrome = Color(hex: 0x17191C)
    static let panel = Color(hex: 0x101315)
    static let panelHeader = Color(hex: 0x0E1113)
    static let raised = Color(hex: 0x14181B)
    static let selected = Color(hex: 0x1A1E21)

    // Lines.
    static let hairline = Color(hex: 0x1C2125)
    static let border = Color(hex: 0x23282C)
    static let borderStrong = Color(hex: 0x2A3034)
    static let borderFocus = Color(hex: 0x3A4044)

    // Inks, brightest first.
    static let ink = Color(hex: 0xE7E9EA)
    static let inkSecondary = Color(hex: 0xC5CACD)
    static let inkTertiary = Color(hex: 0x9BA1A6)
    static let inkMuted = Color(hex: 0x7A8185)
    static let inkFaint = Color(hex: 0x6B7276)
    static let inkFaintest = Color(hex: 0x5F656A)
    static let inkDisabled = Color(hex: 0x4A5054)

    /// The tuned channel, and nothing else: the ramp's fifth stop is the same orange, so a second
    /// use of it would make the tuned channel unfindable.
    static let accent = Color(hex: 0xE8814A)
    /// Squelch open, a connected device, a bookmarked frequency.
    static let good = Color(hex: 0x2FB6A3)
    /// Reserved; unused in M1.
    static let recording = Color(hex: 0xB8483C)
    /// A reading that needs attention but is not an alarm: off tune, overdeviating. The ramp's
    /// fourth stop, so it never competes with `accent` for the tuned channel.
    static let caution = Color(hex: 0xC9C06A)
    /// The failure strip's ground in the inspector (M2 handoff, Region 2): warm, one step off
    /// the panel, so the failure message reads as a block and not a row.
    static let warnGround = Color(hex: 0x1F1714)
    /// The failure strip's edge, the only border in the window that is not grey.
    static let warnBorder = Color(hex: 0x6B3A28)

    /// The level ramp's stops, cold to hot: floor to full scale. `level(_:)` interpolates for
    /// SwiftUI-drawn meters; the waterfall shader gets the same stops as floats.
    static let levelStopsHex: [UInt32] = [
        0x10262B, 0x14555A, 0x2FB6A3, 0xC9C06A, 0xE8814A, 0xF6E6DA,
    ]
    static let levelStops: [Color] = levelStopsHex.map { Color(hex: $0) }

    /// The ramp as RGB triples in [0, 1], for the shader's uniforms.
    static var levelStopsRGB: [SIMD3<Float>] {
        levelStopsHex.map {
            SIMD3(
                Float(($0 >> 16) & 0xFF) / 255, Float(($0 >> 8) & 0xFF) / 255,
                Float($0 & 0xFF) / 255)
        }
    }

    /// The ramp at `frac` in [0, 1], interpolated between stops. A chart sets its own cold end
    /// (the noise line) and hot end.
    static func level(_ frac: Double) -> Color {
        // A meter with nothing measured yet hands over NaN, which clamps to itself and traps in
        // `Int(_:)`; a missing reading is drawn at the cold end.
        guard frac.isFinite else { return levelStops[0] }
        let stops = levelStopsRGB
        let x = frac.clamped(to: 0...1) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let t = Float(x - Double(i))
        let c = stops[i] + (stops[i + 1] - stops[i]) * t
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    // Type. SF for the interface, SF Mono for anything compared digit by digit; every number
    // that changes while you watch it is tabular.
    enum Font {
        /// The tuned frequency in the transport field.
        static let frequency = SwiftUI.Font.system(size: 29, weight: .medium, design: .monospaced)
            .monospacedDigit()
        /// The channel's name at the top of the inspector: the only text in the window that is
        /// a name rather than a number, tracked by `Theme.nameTracking`. The M2 design set it
        /// in Space Grotesk; no font is bundled (M1 handoff, "Type"), so it is SF at the same
        /// size and weight.
        static let name = SwiftUI.Font.system(size: 21, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13)
        static let label = SwiftUI.Font.system(size: 12.5)
        /// A view's own headline: the band rail's band name, the empty-state headline.
        static let title = SwiftUI.Font.system(size: 15, weight: .medium)
        /// A popover's header: the device menu's, smaller than `title` because it sits over a
        /// control rather than the window.
        static let menuTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        /// A value beside a label.
        static let value = SwiftUI.Font.system(size: 11, design: .monospaced).monospacedDigit()
        static let valueSmall = SwiftUI.Font.system(size: 10.5, design: .monospaced)
            .monospacedDigit()
        /// A section header: uppercase, tracked (`Theme.sectionTracking`).
        static let section = SwiftUI.Font.system(size: 9.5, weight: .medium, design: .monospaced)
        /// A table's column head over mono rows: the inspector's log.
        static let columnHead = SwiftUI.Font.system(
            size: 8.5, weight: .medium, design: .monospaced)
        static let footnote = SwiftUI.Font.system(size: 10.5)
        /// A clause under a sentence: the failure strip's thing to try.
        static let aside = SwiftUI.Font.system(size: 11.5)
    }

    /// `0.14em` at 9.5 pt; was `0.16em`, brought down a step on 2026-09-19.
    static let sectionTracking: CGFloat = 9.5 * 0.14
    /// `-0.02em` at 29 pt.
    static let frequencyTracking: CGFloat = 29 * -0.02
    /// `-0.015em` at 21 pt, the channel's name.
    static let nameTracking: CGFloat = 21 * -0.015

    // Layout, from the handoff's window: ratios of a 1360×820 design, fixed where it says so.
    enum Layout {
        static let sidebarWidth: CGFloat = 236
        static let bandRailHeight: CGFloat = 40
        static let spectrumHeight: CGFloat = 150
        static let transportHeight: CGFloat = 88
        /// The inspector, fixed on the right (M2 handoff, "The panel"); the window works
        /// without it.
        static let inspectorWidth: CGFloat = 312
        static let inspectorHeaderHeight: CGFloat = 36
        /// The inspector's reading rows are four fixed columns (label, meter, word, number), so
        /// no meter or number moves when a word beside it changes. The handoff's 74 pt label
        /// column came down to 62 on 2026-09-23 to make room for the number; `Deviation`, the
        /// longest label, is about 54 pt at `Font.label`.
        static let readingLabelWidth: CGFloat = 62
        static let readingMeterWidth: CGFloat = 72
        /// The gap between a reading's meter and its word.
        static let readingWordGap: CGFloat = 10
        /// Wide enough for `+1.2 kHz` in `Font.value`, the longest number a reading prints.
        static let readingNumberWidth: CGFloat = 54
        /// A meter's track (`MeterTrack`), and the height of its ticks and needle, which is the
        /// meter's own height.
        static let meterTrackHeight: CGFloat = 6
        static let meterMarkHeight: CGFloat = 10
        /// The log's fixed columns; signal fills the rest.
        static let logTimeWidth: CGFloat = 52
        static let logLengthWidth: CGFloat = 40
        /// One log row, fixed so the log can count how many fit in the height it is given.
        static let logRowHeight: CGFloat = 19
        /// The inspector's audio ladder (M2 handoff, "Region 3b: audio"): a 64 pt plot beside a
        /// 22 pt dB gutter, eleven 14 pt bars in 22 pt slots with a gap before rms and peak,
        /// 272 pt in all inside the panel's 280. The rows under the plot are the labels and the
        /// meter's two numbers.
        static let audioPlotHeight: CGFloat = 64
        static let audioGutterWidth: CGFloat = 22
        static let audioBarWidth: CGFloat = 14
        static let audioSlotWidth: CGFloat = 22
        static let audioPairGap: CGFloat = 8
        static let audioCapHeight: CGFloat = 1.5
        static let audioLabelHeight: CGFloat = 14
        static let audioNumberHeight: CGFloat = 13
        static let defaultWindow = CGSize(width: 1360, height: 820)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// A section header in the handoff's style: uppercase, small, tracked, faint.
struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.section)
            .tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.inkFaint)
    }
}
