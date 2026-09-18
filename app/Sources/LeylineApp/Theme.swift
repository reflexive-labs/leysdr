// SPDX-License-Identifier: Apache-2.0

// The app's colour and type tokens: every value in docs/design/app-design-handoff.md ("Palette",
// "Type") and nothing a view invents. The names are the handoff's, so a designer and a reader
// of the code point at the same word. The level ramp shares hue order with the terminal's
// (docs/dev/cli-style.md, "3a. The level ramp") and nothing else: this one runs from near-black
// to cream and assumes the dark ground it owns.

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

    /// The level ramp's stops, cold to hot: floor to full scale. `level(_:)` interpolates for
    /// SwiftUI-drawn meters; the waterfall shader gets the same stops as floats.
    static let levelStopsHex: [UInt32] = [0x10262B, 0x14555A, 0x2FB6A3, 0xC9C06A, 0xE8814A, 0xF6E6DA]
    static let levelStops: [Color] = levelStopsHex.map { Color(hex: $0) }

    /// The ramp as RGB triples in [0, 1], for the shader's uniforms.
    static var levelStopsRGB: [SIMD3<Float>] {
        levelStopsHex.map { SIMD3(Float(($0 >> 16) & 0xFF) / 255, Float(($0 >> 8) & 0xFF) / 255, Float($0 & 0xFF) / 255) }
    }

    /// The ramp at `frac` in [0, 1], interpolated between stops. A chart names its own cold end
    /// (the noise line) and hot end.
    static func level(_ frac: Double) -> Color {
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
        static let frequency = SwiftUI.Font.system(size: 29, weight: .medium, design: .monospaced).monospacedDigit()
        /// The signal readout.
        static let readout = SwiftUI.Font.system(size: 21, weight: .medium, design: .monospaced).monospacedDigit()
        static let body = SwiftUI.Font.system(size: 13)
        static let label = SwiftUI.Font.system(size: 12.5)
        /// A value beside a label.
        static let value = SwiftUI.Font.system(size: 11, design: .monospaced).monospacedDigit()
        static let valueSmall = SwiftUI.Font.system(size: 10.5, design: .monospaced).monospacedDigit()
        /// A section header: uppercase, tracked (`Theme.sectionTracking`).
        static let section = SwiftUI.Font.system(size: 9.5, weight: .medium, design: .monospaced)
        static let footnote = SwiftUI.Font.system(size: 10.5)
    }

    /// `0.16em` at 9.5 pt.
    static let sectionTracking: CGFloat = 9.5 * 0.16
    /// `-0.02em` at 29 pt.
    static let frequencyTracking: CGFloat = 29 * -0.02

    // Layout, from the handoff's window: ratios of a 1360×820 design, fixed where it says so.
    enum Layout {
        static let sidebarWidth: CGFloat = 236
        static let bandHeaderHeight: CGFloat = 36
        static let spectrumHeight: CGFloat = 150
        static let transportHeight: CGFloat = 88
        static let defaultWindow = CGSize(width: 1360, height: 820)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

/// A section header in the handoff's voice: uppercase, small, tracked, faint.
struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.section)
            .tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.inkFaint)
    }
}

enum Frequency {
    /// `146.520 MHz`, `88.5 MHz`, `1.766 GHz`: the guide's spelling, a space before the unit.
    static func format(_ hz: UInt64) -> String {
        if hz >= 1_000_000_000 { return String(format: "%.3f GHz", Double(hz) / 1e9) }
        if hz >= 1_000_000 { return String(format: "%.3f MHz", Double(hz) / 1e6) }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }

    /// `146.520` and `000`: the MHz digits the field shows in ink and the sub-kHz ones it dims.
    static func fieldParts(_ hz: UInt64) -> (major: String, minor: String) {
        let mhz = hz / 1_000_000
        let khz = (hz % 1_000_000) / 1_000
        let sub = hz % 1_000
        return (String(format: "%d.%03d", mhz, khz), String(format: "%03d", sub))
    }

    /// A width as a person says it: `12.5 kHz`, `200 kHz`, `500 Hz`.
    static func width(_ hz: UInt32) -> String {
        if hz >= 1_000_000 { return String(format: "%g MHz", Double(hz) / 1e6) }
        if hz >= 1_000 { return String(format: "%g kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }

    /// Parses what a person types into the frequency field: `146.52`, `146.52M`, `162550k`,
    /// `1090MHz`, `7.2 MHz`. A bare number is MHz unless it is too large to be one.
    static func parse(_ text: String) -> UInt64? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        var digits = s
        var scale = 1e6
        if s.hasSuffix("ghz") || s.hasSuffix("g") { scale = 1e9; digits = String(s.dropLast(s.hasSuffix("ghz") ? 3 : 1)) }
        else if s.hasSuffix("mhz") || s.hasSuffix("m") { scale = 1e6; digits = String(s.dropLast(s.hasSuffix("mhz") ? 3 : 1)) }
        else if s.hasSuffix("khz") || s.hasSuffix("k") { scale = 1e3; digits = String(s.dropLast(s.hasSuffix("khz") ? 3 : 1)) }
        else if s.hasSuffix("hz") { scale = 1; digits = String(s.dropLast(2)) }
        guard let v = Double(digits), v > 0 else { return nil }
        if scale == 1e6, v >= 30_000 { scale = 1 }  // nobody means 146 520 000 MHz
        let hz = v * scale
        guard hz.isFinite, hz < 1e12 else { return nil }
        return UInt64(hz.rounded())
    }
}
