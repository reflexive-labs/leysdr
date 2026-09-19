// SPDX-License-Identifier: Apache-2.0

// Every place a frequency becomes text: the transport field's digits, a band's range, a width
// a person says out loud. One spelling for each shape so two views never disagree about the
// same hertz (docs/writing-guide.md names the units; this is where the code honours them).

import Foundation

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
