// SPDX-License-Identifier: Apache-2.0

// Word labels the inspector shows for the meter's numbers (docs/design/app-design-handoff-m2.md,
// Region 3 "the reading" and Region 4's relative time form). Each word is a band of a number the
// façade already holds — `AppSession.overNoiseDB`, `Meter.freq_error_hz`, `Meter.deviation_hz`
// — and the number stays one click away, so a word is presentation and never a detector
// (AGENTS.md, invariant 12). A word for a measurement nobody made is not shown: NaN and nil
// come back as nil here and the view prints `—` or hides the row. The band edges are the
// handoff's tables verbatim; a value on an edge belongs to the band above it, so 3 dB is already
// "Very weak" and a tenth of the bandwidth is still "Centred".

import Foundation
import LeylineProto

/// The five words for a channel's power over the band's floor (handoff M2, Region 3 "Signal").
public enum SignalWord: String, Sendable, CaseIterable, Equatable {
    case notAudible = "Not audible"
    case veryWeak = "Very weak"
    case weak = "Weak"
    case fair = "Fair"
    case strong = "Strong"

    /// The lower edges of the four upper bands, in dB over noise: 3, 8, 14, 22. Asserted from the
    /// design's copy ("Voice is fully readable above about 12 dB"), not measured; the handoff's
    /// "Open for the owner" says captures should set this table, not the other way round.
    public static let thresholdsDB: [Double] = [3, 8, 14, 22]

    /// nil when the number is NaN or nil: a word for a measurement nobody made is not shown.
    public init?(overNoiseDB: Double?) {
        guard let db = overNoiseDB, !db.isNaN else { return nil }
        let above = Self.thresholdsDB.filter { db >= $0 }.count
        self = Self.allCases[above]
    }

    /// The word as the panel prints it.
    public var word: String { rawValue }
}

/// Where the transmitter sits against the channel (Region 3 "Tuning"): within a tenth of the
/// bandwidth of centre, or off tune low or high. Positive `freqErrorHz` is a transmitter ABOVE
/// the channel (M2-2's sign).
public enum TuningWord: Sendable, Equatable {
    case centred, offTuneLow, offTuneHigh

    /// How far from centre, as a fraction of the channel's bandwidth, the transmitter may sit
    /// before it is off tune: the terminal's rule (`docs/design/signal-views.md`, "off tune is
    /// `Warn` and appears only above 10% of channel bandwidth"), so both clients warn together.
    public static let offTuneFraction: Double = 0.1

    /// nil for NaN (not FM, or the squelch closed: the row is hidden) or a bandwidth of 0.
    public init?(freqErrorHz: Double, bandwidthHz: UInt32) {
        // Exactly 0 is a field nobody set: a double on the wire carries no absence, an older
        // daemon sends none, and a measured error is never 0.0 to the last bit. Nil, not
        // "Centred", or a daemon built before the field would read centred for ever.
        guard !freqErrorHz.isNaN, freqErrorHz != 0, bandwidthHz > 0 else { return nil }
        if abs(freqErrorHz) <= Self.offTuneFraction * Double(bandwidthHz) {
            self = .centred
        } else {
            self = freqErrorHz > 0 ? .offTuneHigh : .offTuneLow
        }
    }

    /// The word as the panel prints it.
    public var word: String {
        switch self {
        case .centred: return "Centred"
        case .offTuneLow: return "Off tune · low"
        case .offTuneHigh: return "Off tune · high"
        }
    }

    public var isOffTune: Bool { self != .centred }
}

/// The deviation against the mode's nominal (Region 3 "Deviation").
public enum DeviationWord: Sendable, Equatable {
    case quiet, normal, overdeviating

    /// Under 0.4 of nominal is quiet, over 1.3 is overdeviating: the handoff's 40–130% band.
    public static let quietFraction: Double = 0.4
    public static let overFraction: Double = 1.3

    /// The nominal peak deviation for a mode at a bandwidth: NFM a fifth of the bandwidth
    /// (2.5 kHz at 12.5 kHz, 5 kHz at 25 kHz, the handoff's two examples as one rule), WFM
    /// 75 kHz (`Demodulators.swift`, `fullScaleDeviationHz`), nil for every other mode, which
    /// has no deviation to read.
    public static func nominalHz(mode: Leyline_V1_DemodMode, bandwidthHz: UInt32) -> Double? {
        switch mode {
        case .nfm: return bandwidthHz > 0 ? Double(bandwidthHz) / 5 : nil
        case .wfm: return 75_000
        default: return nil
        }
    }

    /// nil for NaN, no nominal, or a bandwidth of 0.
    public init?(deviationHz: Double, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32) {
        // Exactly 0 is a field nobody set (see `TuningWord`): even silence deviates by noise.
        guard !deviationHz.isNaN, deviationHz != 0, bandwidthHz > 0,
            let nominal = Self.nominalHz(mode: mode, bandwidthHz: bandwidthHz)
        else { return nil }
        let fraction = deviationHz / nominal
        if fraction < Self.quietFraction {
            self = .quiet
        } else if fraction > Self.overFraction {
            self = .overdeviating
        } else {
            self = .normal
        }
    }

    /// The word as the panel prints it.
    public var word: String {
        switch self {
        case .quiet: return "Quiet"
        case .normal: return "Normal"
        case .overdeviating: return "Overdeviating"
        }
    }
}

public enum Reading {
    /// What the panel prints for a number it does not have.
    public static let absent = "—"

    /// A duration as the panel prints it: "4.2 s" under a minute, "1:04.2" from a minute (tenths
    /// kept), "—" for NaN, infinite or negative. Rounded to tenths before the minute is split off,
    /// so 59.96 s is "1:00.0" and never "60.0 s".
    public static func seconds(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return absent }
        let tenths = Int((s * 10).rounded())
        if tenths < 600 { return "\(tenths / 10).\(tenths % 10) s" }
        let rest = tenths % 600
        return "\(tenths / 600):" + String(format: "%02d.%d", rest / 10, rest % 10)
    }

    /// A time before now as the log prints it when no anchor dates it: "−2:14" (a real minus sign
    /// U+2212, minutes:seconds), "−1:02:14" past an hour; "—" for NaN/negative. A wall-clock time
    /// the daemon never anchored is not printed; this relative form is used instead (Region 4,
    /// "relative when it does not").
    public static func relative(secondsAgo s: Double) -> String {
        guard s.isFinite, s >= 0 else { return absent }
        let whole = Int(s.rounded())
        let (hours, rest) = whole.quotientAndRemainder(dividingBy: 3600)
        let (minutes, seconds) = rest.quotientAndRemainder(dividingBy: 60)
        if hours > 0 {
            return "\u{2212}\(hours):" + String(format: "%02d:%02d", minutes, seconds)
        }
        return "\u{2212}\(minutes):" + String(format: "%02d", seconds)
    }
}
