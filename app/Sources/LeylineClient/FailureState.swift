// SPDX-License-Identifier: Apache-2.0

// The named failure state (docs/plans/user-stories.md, V1a: the app "detects and names failure
// states instead of sitting silently broken"): the radio clipping, read from the daemon's
// `CaptureLevel` and the capture's gains, a measured fact with its number and the thing to try,
// not a detector (CLAUDE.md, invariant 12). `ley tune` reports the same state from the same count
// (`go/internal/cli/failure.go`). "Nothing above the noise" was a state here until 2026-09-21
// and is now only `ley tune`'s one-time line: in a window it flagged a quiet band every few
// seconds and distracted more than it helped (the owner). The daemon not running, no radio and
// an unplugged radio are the mirror's states and belong to the window's empty-state message.

import Foundation
import LeylineProto

public enum FailureState: Sendable, Equatable {
    /// Samples at the converter's rails in the daemon's newest `CaptureLevel` interval: the
    /// radio is clipping, measured rather than read off a bin (plans/app.md, M2-5). `gainAuto`
    /// and `gainAtMinimum` pick the thing to try: on auto, switch to manual gain and lower it;
    /// at the lowest manual gain the radio cannot be turned down, so the antenna has to change.
    case clipping(clipped: UInt64, total: UInt64, gainAuto: Bool, gainAtMinimum: Bool)

    /// The clipped fraction of an interval that triggers the state: one sample in ten thousand,
    /// `ley tune`'s floor too (`go/internal/cli/failure.go`, `clippingFloor`). Not zero, because
    /// one rail hit in six hundred thousand samples is a stray, not an overload.
    public static let clippingFloor: Double = 1e-4
    /// Once raised, the state holds until the fraction has fallen to half the floor, so a radio
    /// hovering at the edge does not raise and clear it four times a second.
    public static let clippingExitFraction: Double = clippingFloor / 2

    /// The state the numbers show, or nil. `level` is the capture's newest `CaptureLevel`, nil
    /// before the first; `previous` is the state last reported, which the exit threshold holds on
    /// to.
    public static func name(
        level: Leyline_V1_CaptureLevel?, gains: [Leyline_V1_GainState],
        elements: [Leyline_V1_GainElement], previous: FailureState? = nil
    ) -> FailureState? {
        guard let level, level.totalSamples > 0 else { return nil }
        let fraction = Double(level.clippedSamples) / Double(level.totalSamples)
        let floor: Double
        if case .clipping = previous { floor = clippingExitFraction } else { floor = clippingFloor }
        guard fraction >= floor else { return nil }
        return .clipping(
            clipped: level.clippedSamples, total: level.totalSamples,
            gainAuto: gainAuto(gains: gains),
            gainAtMinimum: gainAtMinimum(gains: gains, elements: elements))
    }

    /// Whether any gain element is on auto: then "lower the gain" means switching to manual first.
    public static func gainAuto(gains: [Leyline_V1_GainState]) -> Bool {
        gains.contains { $0.auto }
    }

    /// Whether any gain element is set manually to the lowest level it offers: the bottom of its
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

    /// Whether the thing to try is the gain: unless it is already at its lowest.
    public var namesGain: Bool {
        switch self {
        case .clipping(_, _, _, let atMinimum): return !atMinimum
        }
    }

    public var headline: String {
        switch self {
        case .clipping: return "The radio is clipping"
        }
    }

    /// The number it was read from and the thing to try.
    public var detail: String {
        switch self {
        case .clipping(let clipped, let total, let auto, let atMinimum):
            let percent = total > 0 ? 100 * Double(clipped) / Double(total) : 0
            let reads = String(
                format: "%llu of %llu samples (%@) hit the converter's rails", clipped, total,
                percent < 0.1
                    ? String(format: "%.2f %%", percent) : String(format: "%.1f %%", percent))
            if atMinimum {
                return reads
                    + " at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
            }
            return auto
                ? reads + " with the gain on auto. Take the gain by hand and lower it."
                : reads + ". Lower the gain."
        }
    }
}
