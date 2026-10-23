// SPDX-License-Identifier: Apache-2.0

// The tuning field's digits as pure rules, so they are testable without SwiftUI. The field shows
// four fractional MHz digits, truncated and never rounded: the fourth is the hundreds of hertz
// that 12.5 kHz channel plans use, so 462.612 cannot look like GMRS CH3's 462.6125, and a radio
// on 146.940186 MHz reads `146.9401`, under the hertz it is on. The exact hertz is in the
// tooltip and the inspector (`exactWords`), and a typed frequency may carry all six digits.
// Return with nothing typed keeps that exact hertz (`commit`).

import Foundation

public enum FrequencyEntry {
    /// The most fractional MHz digits the field takes: down to the hertz.
    public static let maxFractionDigits = 6

    /// What the field tunes. Nothing below 500 kHz (AM broadcast starts at 530) or above 6 GHz
    /// is a frequency a radio here tunes, and the keypad makes both easy to type: a `.` into an
    /// empty MHz part followed by three digits reads as 0.500.
    public static let tunableHz: ClosedRange<UInt64> = 500_000...6_000_000_000

    /// MHz digits through hundreds of hertz, plus any remaining tens and units of hertz.
    /// `462_612_500` becomes (`462.6125`, ``), while `462_612_000` remains visibly
    /// (`462.6120`, ``) rather than looking like the half-kilohertz channel centre. Both parts
    /// are cut from the hertz, never rounded: `146_940_186` is (`146.9401`, `86`).
    public static func fieldParts(_ hz: UInt64) -> (major: String, minor: String) {
        let sub = hz % 100
        let major = "\(hz / 1_000_000).\(padded((hz % 1_000_000) / 100, 4))"
        return (major, sub == 0 ? "" : padded(sub, 2))
    }

    /// The field's text: `146.9401` for 146.940186 MHz, four decimals, truncated.
    public static func fieldText(_ hz: UInt64) -> String { fieldParts(hz).major }

    /// The exact hertz in MHz, as the field's tooltip and the inspector give it:
    /// `146.940186 MHz`, `462.6125 MHz`, and at least three decimals, `146.520 MHz`.
    public static func exactWords(_ hz: UInt64) -> String {
        var fraction = padded(hz % 1_000_000, 6)
        while fraction.count > 3, fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(hz / 1_000_000).\(fraction) MHz"
    }

    /// The hertz of a typed frequency: the MHz digits and up to `maxFractionDigits` after the
    /// point, read exactly (`146` and `940186` are 146_940_186 Hz). nil for anything else: a
    /// sign, a character that is not a digit, more than six fractional digits, no digit at all,
    /// or a number past `UInt64`. The range is `tunableHz`'s to check.
    public static func hz(whole: String, fraction: String) -> UInt64? {
        let digits = Set("0123456789")
        guard whole.allSatisfy(digits.contains), fraction.allSatisfy(digits.contains),
            fraction.count <= maxFractionDigits, !(whole.isEmpty && fraction.isEmpty)
        else { return nil }
        let mhz = whole.isEmpty ? 0 : UInt64(whole)
        let sub = UInt64(fraction.padding(toLength: maxFractionDigits, withPad: "0", startingAt: 0))
        guard let mhz, let sub else { return nil }
        let (scaled, over) = mhz.multipliedReportingOverflow(by: 1_000_000)
        guard !over else { return nil }
        let (total, past) = scaled.addingReportingOverflow(sub)
        return past ? nil : total
    }

    /// What Return in the field does.
    public enum Commit: Equatable, Sendable {
        /// Nothing was typed, or what was typed is where the radio is: no tune at all.
        case keep
        /// Tune to the typed hertz.
        case tune(UInt64)
        /// Not a frequency `tunableHz` holds; the field keeps its focus.
        case refused
    }

    /// Return with the field holding `whole` and `fraction`, opened on `loadedHz` (the radio's
    /// frequency when the edit began). Unchanged digits keep the radio on its exact hertz:
    /// the field shows four decimals, and tuning what it shows would drop the hertz past them,
    /// taking 146.940186 to 146.9401 (MC-3). Any edit tunes exactly what was typed.
    public static func commit(whole: String, fraction: String, loadedHz: UInt64?) -> Commit {
        if let loadedHz, "\(whole).\(fraction)" == fieldText(loadedHz) { return .keep }
        guard let hz = hz(whole: whole, fraction: fraction), tunableHz.contains(hz) else {
            return .refused
        }
        return hz == loadedHz ? .keep : .tune(hz)
    }

    private static func padded(_ v: UInt64, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
