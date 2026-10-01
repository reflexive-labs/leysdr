// SPDX-License-Identifier: Apache-2.0

// All frequency-to-text formatting: the transport field's digits, a band's range, a width in
// spoken form. One format for each shape so two views never disagree about the same hertz
// (docs/writing-guide.md specifies the units; this file implements them).

import Foundation
import LeylineClient

enum Frequency {
    /// `146.520 MHz`, `88.5 MHz`, `462.6125 MHz`, `1.766 GHz`: the guide's spelling, a space
    /// before the unit.
    static func format(_ hz: UInt64) -> String {
        // The rule lives in the client library, where it names bookmarks and is tested on
        // Linux; the transport bar shows the same hertz the same way by calling it.
        BookmarkNaming.frequencyWords(hz)
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

    /// `144`, `87.5`, `462.5375`: MHz to four decimals with trailing zeros trimmed. The
    /// sidebar's band list and the band rail's caps both use this shape, from here, so the two
    /// cannot drift apart.
    static func mhz(_ hz: UInt64) -> String {
        var s = String(format: "%.4f", Double(hz) / 1e6)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
