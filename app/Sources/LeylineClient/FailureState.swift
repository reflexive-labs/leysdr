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
    /// limit, and the next dB of signal clips.
    case nearFullScale(peakDB: Float)
    /// Nothing `SpectrumFold.peakAboveFloorDB` above the floor for `quietSeconds`. Deaf, or a
    /// quiet band; when the gain is manual at its minimum, that is the first thing to try.
    case nothingAboveFloor(floorDB: Float, gainAtMinimum: Bool)

    /// How close to full scale the loudest bin may come before the state is named. A full-scale
    /// tone reads 0 dBFS at its bin (`engine/Sources/EngineCore/DSP/FFT.swift`); 3 dB is one
    /// gain step on an RTL-SDR's table, so the words arrive before the clip does.
    public static let fullScaleMarginDB: Float = 3
    /// How long the band must show nothing above the floor before it is said. A held peak that
    /// lets go at 1 dB a second means a burst a few seconds old still counts as something heard.
    public static let quietSeconds: Double = 3

    /// The state the numbers show, or nil. `floorDB` and `peakDB` are the feed's held floor
    /// and peak; `rows` is how many rows they were folded from, at `rowsPerSecond`.
    public static func name(
        floorDB: Float, peakDB: Float, rows: Int, rowsPerSecond: Double,
        gains: [Leyline_V1_GainState], elements: [Leyline_V1_GainElement]
    ) -> FailureState? {
        guard peakDB.isFinite else { return nil }
        if peakDB >= -fullScaleMarginDB { return .nearFullScale(peakDB: peakDB) }
        guard floorDB.isFinite, Double(rows) >= quietSeconds * rowsPerSecond else { return nil }
        if peakDB - floorDB < SpectrumFold.peakAboveFloorDB {
            return .nothingAboveFloor(
                floorDB: floorDB, gainAtMinimum: gainAtMinimum(gains: gains, elements: elements))
        }
        return nil
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
        case .nearFullScale(let peak):
            return String(
                format:
                    "The loudest bin reads %.0f dBFS. Lower the gain, or set it to auto, before the radio clips.",
                peak)
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
