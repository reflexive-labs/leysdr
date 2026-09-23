// SPDX-License-Identifier: Apache-2.0

// The exact decimal digits the app's frequency entry renders. Kept here as a pure rule so the
// field's precision is testable without SwiftUI: four fractional MHz digits expose the hundreds
// of hertz that 12.5 kHz channel plans use instead of silently making 462.612 look like CH3.

import Foundation

public enum FrequencyEntry {
    /// MHz digits through hundreds of hertz, plus any remaining tens and units of hertz.
    /// `462_612_500` becomes (`462.6125`, ``), while `462_612_000` remains visibly
    /// (`462.6120`, ``) rather than looking like the half-kilohertz channel centre.
    public static func fieldParts(_ hz: UInt64) -> (major: String, minor: String) {
        let mhz = hz / 1_000_000
        let khz = (hz % 1_000_000) / 1_000
        let hundreds = (hz % 1_000) / 100
        let sub = hz % 100
        return (
            String(format: "%d.%03d%d", mhz, khz, hundreds),
            sub == 0 ? "" : String(format: "%02d", sub)
        )
    }
}
