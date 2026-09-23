// SPDX-License-Identifier: Apache-2.0

// Every place a frequency becomes text: the transport field's digits, a band's range, a width
// a person says out loud. One spelling for each shape so two views never disagree about the
// same hertz (docs/writing-guide.md names the units; this is where the code honours them).

import Foundation
import LeylineClient

enum Frequency {
    /// `146.520 MHz`, `88.5 MHz`, `462.6125 MHz`, `1.766 GHz`: the guide's spelling, a space
    /// before the unit.
    static func format(_ hz: UInt64) -> String {
        if hz >= 1_000_000_000 { return String(format: "%.3f GHz", Double(hz) / 1e9) }
        // A fourth decimal for a frequency on an exact half-kilohertz: every 12.5 kHz channel
        // plan has them (GMRS channel 3 is 462.6125 MHz, and three decimals would round it to a
        // channel it is not), and no measurement lands on one by chance, so a measured centre
        // keeps the three decimals its bin width can honestly carry. `ley`'s rule.
        if hz >= 1_000_000 {
            return String(format: hz % 1_000 == 500 ? "%.4f MHz" : "%.3f MHz", Double(hz) / 1e6)
        }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }

    /// `146.5200` and `000`: the MHz digits the field shows in ink and the sub-hundred-hertz ones
    /// it dims. Four fractional digits are always visible so `.6120` cannot masquerade as the
    /// `.6125` centre of a 12.5 kHz channel plan.
    static func fieldParts(_ hz: UInt64) -> (major: String, minor: String) {
        FrequencyEntry.fieldParts(hz)
    }

    /// A width as a person says it: `12.5 kHz`, `200 kHz`, `500 Hz`.
    static func width(_ hz: UInt32) -> String {
        if hz >= 1_000_000 { return String(format: "%g MHz", Double(hz) / 1e6) }
        if hz >= 1_000 { return String(format: "%g kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }

    /// `144`, `87.5`, `462.5375`: MHz to four decimals with the zeros a person would not say
    /// trimmed off. The sidebar's band list and the band rail's caps both want this shape and
    /// used to keep their own copies, which drifted (`docs/dev/swift-style.md`, section 13).
    static func mhz(_ hz: UInt64) -> String {
        var s = String(format: "%.4f", Double(hz) / 1e6)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
