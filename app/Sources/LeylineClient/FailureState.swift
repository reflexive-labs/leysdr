// SPDX-License-Identifier: Apache-2.0

// The named failure states (docs/plans/user-stories.md, V1a: the app "detects and names failure
// states instead of sitting silently broken"), read from what the window already holds: the
// feed's floor and peak, the capture's gains and the device's gain elements. Each is a measured
// fact with its number and the thing to try; none is a detector (CLAUDE.md, invariant 12). The
// rule is `ley tune`'s (`go/internal/cli/failure.go`), so both clients say the same thing about
// the same band. The daemon not running, no radio and an unplugged radio are the mirror's states
// and belong to the window's empty words, not here.

import Foundation
import LeylineProto

public enum FailureState: Sendable, Equatable {
    /// The loudest bin is within `fullScaleMarginDB` of full scale: the front end is at its
    /// limit, and the next dB of signal clips. `gainAuto` and `gainAtMinimum` pick the thing to
    /// try: on auto, take the gain by hand; at the lowest manual gain, the radio cannot be
    /// turned down and the antenna is what moves.
    case nearFullScale(peakDB: Float, gainAuto: Bool, gainAtMinimum: Bool)
    /// Nothing `SpectrumFold.peakAboveFloorDB` above the floor for `quietSeconds`. Deaf, or a
    /// quiet band; when the gain is manual at its minimum, that is the first thing to try.
    case nothingAboveFloor(floorDB: Float, gainAtMinimum: Bool)

    /// How close to full scale the loudest bin may come before the state is named. A full-scale
    /// tone reads 0 dBFS at its bin (`engine/Sources/EngineCore/DSP/FFT.swift`); 3 dB is one
    /// gain step on an RTL-SDR's table, so the words arrive before the clip does.
    public static let fullScaleMarginDB: Float = 3
    /// Once named, the state holds until the peak has fallen this far below full scale, so a
    /// signal hovering at the margin does not name and clear it once a second.
    public static let fullScaleExitDB: Float = 6
    /// How long the band must show nothing above the floor before it is said. A held peak that
    /// lets go at 1 dB a second means a burst a few seconds old still counts as something heard.
    public static let quietSeconds: Double = 3
    /// Once named, the quiet state holds until a peak this far above the floor: the peak rule's
    /// edge plus 3 dB, for the same reason as `fullScaleExitDB`.
    public static let quietExitAboveFloorDB: Float = SpectrumFold.peakAboveFloorDB + 3

    /// The state the numbers show, or nil. `floorDB` and `peakDB` are the feed's held floor
    /// and peak; `rows` is how many rows they were folded from, at `rowsPerSecond`; `previous`
    /// is the state last named, which the exit thresholds hold on to.
    public static func name(
        floorDB: Float, peakDB: Float, rows: Int, rowsPerSecond: Double,
        gains: [Leyline_V1_GainState], elements: [Leyline_V1_GainElement],
        previous: FailureState? = nil
    ) -> FailureState? {
        guard peakDB.isFinite else { return nil }
        let atMinimum = gainAtMinimum(gains: gains, elements: elements)
        let hot: Float
        if case .nearFullScale = previous {
            hot = -fullScaleExitDB
        } else {
            hot = -fullScaleMarginDB
        }
        if peakDB >= hot {
            return .nearFullScale(
                peakDB: peakDB, gainAuto: gainAuto(gains: gains), gainAtMinimum: atMinimum)
        }
        guard floorDB.isFinite, Double(rows) >= quietSeconds * rowsPerSecond else { return nil }
        let quiet: Float
        if case .nothingAboveFloor = previous {
            quiet = quietExitAboveFloorDB
        } else {
            quiet = SpectrumFold.peakAboveFloorDB
        }
        if peakDB - floorDB < quiet {
            return .nothingAboveFloor(floorDB: floorDB, gainAtMinimum: atMinimum)
        }
        return nil
    }

    /// Whether any gain element is on auto: then "lower the gain" means taking it by hand first.
    public static func gainAuto(gains: [Leyline_V1_GainState]) -> Bool {
        gains.contains { $0.auto }
    }

    /// Whether any gain element is set by hand to the lowest level it offers: the bottom of its
    /// table, or its minimum. Auto is never at the minimum, whatever level it chose.
    public static func gainAtMinimum(
        gains: [Leyline_V1_GainState], elements: [Leyline_V1_GainElement]
    ) -> Bool {
        gains.contains { g in
            guard !g.auto, let el = elements.first(where: { $0.name == g.element }) else {
                return false
            }
            let lowest = el.validDb.min() ?? el.minDb
            return g.db <= lowest + 0.05
        }
    }

    /// Whether the thing to try is the gain: near full scale unless the gain is already at its
    /// lowest, and nothing above the floor only when it is.
    public var namesGain: Bool {
        switch self {
        case .nearFullScale(_, _, let atMinimum): return !atMinimum
        case .nothingAboveFloor(_, let atMinimum): return atMinimum
        }
    }

    public var headline: String {
        switch self {
        case .nearFullScale:
            return "A signal is within \(Int(Self.fullScaleMarginDB)) dB of full scale"
        case .nothingAboveFloor:
            return "Nothing is above the noise"
        }
    }

    /// The number it was read from and the thing to try.
    public var detail: String {
        switch self {
        case .nearFullScale(let peak, let auto, let atMinimum):
            let reads = String(format: "The loudest bin reads %.0f dBFS", peak)
            if atMinimum {
                return reads
                    + " at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
            }
            return auto
                ? reads
                    + " with the gain on auto. Take the gain by hand and lower it before the radio clips."
                : reads + ". Lower the gain before the radio clips."
        case .nothingAboveFloor(let floor, let gainAtMinimum):
            let measured = String(
                format: "No bin has been %d dB above the floor (%.0f dBFS) for %d s",
                Int(SpectrumFold.peakAboveFloorDB), floor, Int(Self.quietSeconds))
            return gainAtMinimum
                ? measured + ", and the gain is at its lowest. Turn it up, or set it to auto."
                : measured + ". Check the antenna; FM broadcast is the band most antennas hear."
        }
    }
}
