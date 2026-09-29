// SPDX-License-Identifier: Apache-2.0

// A bookmark's tone as the file spells it (docs/design/channels.md, "Bookmarks gain three
// fields"): a CTCSS tone or a DCS code with its polarity, in CHIRP's spelling and only that
// one. The file is shared with `ley bookmarks`, so this is `go/pkg/leyline/tone.go` in Swift,
// case for case: both clients accept the same strings and refuse the rest with one sentence,
// because a tone written two ways would be two tones. What the daemon hears on the air is
// `SubAudibleTone` (Transmissions.swift), which carries a measurement; this is what a person
// wrote down.

import Foundation

/// The one refusal `Tone.parse` makes, carrying the sentence both clients print.
public struct ToneError: Error, Equatable, Sendable {
    public static let sentence =
        "tone must be a CTCSS tone such as 100.0 or a DCS code such as D023N"
    public let message: String
}

public enum Tone: Sendable, Hashable {
    /// A CTCSS tone, one of `ctcssTable`.
    case ctcss(hz: Double)
    /// A DCS code as the number itself, `0o023` for `D023N`, the way `go/pkg/dcs` and
    /// `EngineCore`'s `DCS.standardCodes` hold one. `SubAudibleTone.dcs` carries the wire's
    /// form instead, the octal digits read as decimal, because that is what `dcs_code` sends.
    case dcs(code: Int, inverted: Bool)

    /// The table a bookmark's tone must be on: the 38 EIA tones and the twelve extras (69.3,
    /// 159.8, 165.5, 171.3, 177.3, 183.5, 189.9, 196.6, 199.5, 206.5, 229.1, 254.1) every
    /// current radio menu offers. It is CHIRP's TONES list, so an exported memory's tone is
    /// always on it, and `go/pkg/leyline`'s `CTCSSTones` value for value. Ascending, in hertz.
    public static let ctcssTable: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
        94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
        171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
        203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,
    ]

    /// The 104 standard DCS codes radio menus offer, ascending, octal. A copy of
    /// `engine/Sources/EngineCore/DSP/DCS.swift`'s `standardCodes` (checked there on 2026-09-24
    /// against the RadioReference chart) and of `go/pkg/dcs.Codes`, because the app never links
    /// `EngineCore` (`app/Package.swift`, the licence boundary).
    public static let dcsCodes: [Int] = [
        0o023, 0o025, 0o026, 0o031, 0o032, 0o036, 0o043, 0o047, 0o051, 0o053, 0o054, 0o065,
        0o071, 0o072, 0o073, 0o074, 0o114, 0o115, 0o116, 0o122, 0o125, 0o131, 0o132, 0o134,
        0o143, 0o145, 0o152, 0o155, 0o156, 0o162, 0o165, 0o172, 0o174, 0o205, 0o212, 0o223,
        0o225, 0o226, 0o243, 0o244, 0o245, 0o246, 0o251, 0o252, 0o255, 0o261, 0o263, 0o265,
        0o266, 0o271, 0o274, 0o306, 0o311, 0o315, 0o325, 0o331, 0o332, 0o343, 0o346, 0o351,
        0o356, 0o364, 0o365, 0o371, 0o411, 0o412, 0o413, 0o423, 0o431, 0o432, 0o445, 0o446,
        0o452, 0o454, 0o455, 0o462, 0o464, 0o465, 0o466, 0o503, 0o506, 0o516, 0o523, 0o526,
        0o532, 0o546, 0o565, 0o606, 0o612, 0o624, 0o627, 0o631, 0o632, 0o654, 0o662, 0o664,
        0o703, 0o712, 0o723, 0o731, 0o732, 0o734, 0o743, 0o754,
    ]

    /// Reads a tone the way CHIRP spells one, and only that way: a tone on `ctcssTable` with
    /// one decimal (`100.0`, never `100` or `100.00`), or `D` + three octal digits + `N` or `I`
    /// for a standard DCS code and its polarity (`D023N`, `D754I`). No trimming and no case
    /// folding, so the string a bookmark holds is exactly one `ley bookmarks` would have
    /// accepted. Anything else is `ToneError`, in `go/pkg/leyline.ParseTone`'s words.
    public static func parse(_ s: String) throws(ToneError) -> Tone {
        let bytes = Array(s.utf8)
        if bytes.count == 5, bytes[0] == UInt8(ascii: "D"),
            bytes[4] == UInt8(ascii: "N") || bytes[4] == UInt8(ascii: "I")
        {
            // Digit by digit rather than `Int(_:radix:)`, which would take a sign in front.
            var code = 0
            for b in bytes[1..<4] {
                guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "7") else {
                    throw ToneError(message: ToneError.sentence)
                }
                code = code * 8 + Int(b - UInt8(ascii: "0"))
            }
            guard dcsCodes.contains(code) else { throw ToneError(message: ToneError.sentence) }
            return .dcs(code: code, inverted: bytes[4] == UInt8(ascii: "I"))
        }
        for hz in ctcssTable where s == Self.formatCTCSS(hz) {
            return .ctcss(hz: hz)
        }
        throw ToneError(message: ToneError.sentence)
    }

    /// The spelling `parse` reads and the file stores: `100.0`, `D023N`, `D023I`.
    public var spelling: String {
        switch self {
        case .ctcss(let hz):
            return Self.formatCTCSS(hz)
        case .dcs(let code, let inverted):
            return String(format: "D%03o", code) + (inverted ? "I" : "N")
        }
    }

    /// The tone as a label shows it, the words the transmissions log uses for a heard one
    /// (`SubAudibleTone.words`): `PL 100.0`, `DCS 023`, `DCS 023 inverted`.
    public var words: String {
        switch self {
        case .ctcss(let hz):
            return "PL " + Self.formatCTCSS(hz)
        case .dcs(let code, let inverted):
            return String(format: "DCS %03o", code) + (inverted ? " inverted" : "")
        }
    }

    /// One decimal, Go's `%.1f`.
    private static func formatCTCSS(_ hz: Double) -> String { String(format: "%.1f", hz) }
}
