// SPDX-License-Identifier: Apache-2.0

// The named failure state, so the app names a problem instead of sitting silently broken: the
// radio clipping, read from the daemon's
// `CaptureLevel` and the capture's gains, a measured fact with its number and the thing to try,
// not a detector (AGENTS.md, invariant 12). `ley tune` reports the same state from the same count
// (`go/internal/cli/failure.go`). "Nothing above the noise" is only `ley tune`'s one-time line,
// not a state here: in a window it flagged a quiet band every few seconds and distracted more
// than it helped. The daemon not running, no radio and
// an unplugged radio are the mirror's states and belong to the window's empty-state message.

import Foundation
import LeylineProto

public enum FailureState: Sendable, Equatable {
    /// Samples at the converter's rails in the daemon's newest `CaptureLevel` interval: the
    /// radio is clipping, measured rather than read off a bin. `gainAuto`
    /// and `gainAtMinimum` pick the thing to try: on auto, switch to manual gain and lower it;
    /// at the lowest manual gain the radio cannot be turned down, so the antenna has to change.
    /// `lower` is the stages to turn down on a radio with several (`stagesToLower`), empty on a
    /// radio with one.
    case clipping(
        clipped: UInt64, total: UInt64, gainAuto: Bool, gainAtMinimum: Bool, lower: [String] = [])

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
            gainAtMinimum: gainAtMinimum(gains: gains, elements: elements),
            lower: stagesToLower(gains: gains, elements: elements))
    }

    /// Whether any gain element is on auto: then "lower the gain" means switching to manual first.
    public static func gainAuto(gains: [Leyline_V1_GainState]) -> Bool {
        gains.contains { $0.auto }
    }

    /// Whether a gain element is a two-value switch rather than a gain to set: exactly two table
    /// entries and no step, as a HackRF advertises its AMP (0 or 11 dB). A switch is left out of
    /// "the lowest gain", because counting it told a HackRF at LNA 8, VGA 20 and the AMP off that
    /// it was at its lowest. `ley`'s `switchStage` is the same rule.
    static func isSwitch(_ el: Leyline_V1_GainElement) -> Bool {
        el.validDb.count == 2 && el.stepDb == 0
    }

    /// The lowest level an element offers: the bottom of its table, or its minimum.
    static func lowestDB(_ el: Leyline_V1_GainElement) -> Double {
        el.validDb.min() ?? el.minDb
    }

    /// The continuous and table stages in the device's order, each with the capture's state for
    /// it, nil when the capture reports none.
    static func stages(
        gains: [Leyline_V1_GainState], elements: [Leyline_V1_GainElement]
    ) -> [(element: Leyline_V1_GainElement, state: Leyline_V1_GainState?)] {
        elements.filter { !isSwitch($0) }.map { el in
            (el, gains.first { $0.element == el.name })
        }
    }

    /// Whether every continuous or table stage is set by hand to its lowest level: then the
    /// radio cannot be turned down, and the advice is the antenna. A two-value stage does not
    /// count (`isSwitch`), a stage on auto is never at its lowest whatever level it chose, and a
    /// radio with no stage to count has no gain to be at the bottom of. `ley`'s `gainAtMinimum`
    /// (`go/internal/cli/failure.go`) is the same rule.
    public static func gainAtMinimum(
        gains: [Leyline_V1_GainState], elements: [Leyline_V1_GainElement]
    ) -> Bool {
        let counted = stages(gains: gains, elements: elements)
        return !counted.isEmpty
            && counted.allSatisfy { el, state in
                guard let state, !state.auto else { return false }
                return state.db <= lowestDB(el) + 0.05
            }
    }

    /// The stages to lower on a radio with more than one to set, in the device's order: those set
    /// by hand above their lowest. Empty on a radio with one, where "Lower the gain." is enough.
    public static func stagesToLower(
        gains: [Leyline_V1_GainState], elements: [Leyline_V1_GainElement]
    ) -> [String] {
        let counted = stages(gains: gains, elements: elements)
        guard counted.count >= 2 else { return [] }
        return counted.compactMap { el, state in
            guard let state, !state.auto, state.db > lowestDB(el) + 0.05 else { return nil }
            return el.name
        }
    }

    /// Whether the thing to try is the gain: unless it is already at its lowest.
    public var namesGain: Bool {
        switch self {
        case .clipping(_, _, _, let atMinimum, _): return !atMinimum
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
        case .clipping(let clipped, let total, let auto, let atMinimum, let lower):
            let percent = total > 0 ? 100 * Double(clipped) / Double(total) : 0
            let reads = String(
                format: "%llu of %llu samples (%@) hit the converter's rails", clipped, total,
                percent < 0.1
                    ? String(format: "%.2f %%", percent) : String(format: "%.1f %%", percent))
            if atMinimum {
                return reads
                    + " at the lowest gain. Move the antenna away from the transmitter, or add attenuation."
            }
            if auto { return reads + " with the gain on auto. Take the gain by hand and lower it." }
            return reads + ". " + Self.lowerWords(lower) + "."
        }
    }

    /// "Lower the gain", or on a radio with several stages the ones to lower: "Lower the VGA
    /// gain", "Lower the LNA or VGA gain". `ley`'s `lowerGainWords` builds the same words.
    static func lowerWords(_ stages: [String]) -> String {
        switch stages.count {
        case 0: return "Lower the gain"
        case 1: return "Lower the \(stages[0]) gain"
        default:
            return "Lower the " + stages.dropLast().joined(separator: ", ") + " or "
                + stages[stages.count - 1] + " gain"
        }
    }
}

/// The failure state as the window shows it: `FailureState.name` folded over the capture's
/// `CaptureLevel` readings with a hold on the capture's clock, so a state is shown only once it
/// has lasted. Clipping is raised after the fraction has been at or over
/// `FailureState.clippingFloor` for `raiseSeconds` and cleared after it has been under
/// `FailureState.clippingExitFraction` for `clearSeconds`; the exit fraction still applies while
/// the state is shown. Clipping comes in bursts of half a second to two seconds (a keyed HT, an
/// FM peak), and without the hold each burst showed and cleared the words. The time is the
/// readings' `SampleTime` and the capture's rate, never the wall clock (AGENTS.md, invariant 5).
public struct FailureHold: Sendable, Equatable {
    /// How long the fraction must stay over the floor before clipping is shown.
    public static let raiseSeconds: Double = 1
    /// How long it must stay under the exit fraction before the shown state clears: longer than
    /// the raise, so a pause between two bursts does not clear and raise the words again.
    public static let clearSeconds: Double = 2

    /// The state to show, or nil.
    public private(set) var state: FailureState?
    /// The capture the readings came from; a reading on another capture starts again.
    private var captureID: String?
    /// The first sample of the run of readings that would change `state` (over the floor while
    /// nothing is shown, under the exit fraction while clipping is), or nil when the newest
    /// reading agrees with `state`.
    private var runStart: UInt64?

    public init() {}

    /// Folds one reading in and returns the state to show. `time` is the reading's `SampleTime`
    /// (the end of its interval, as the daemon sends it) and `sampleRate` the capture's rate. An
    /// empty interval or an unknown rate changes nothing: neither can be timed. Folding the same
    /// reading twice, as the window does when only the gains changed, changes only the words.
    public mutating func fold(
        level: Leyline_V1_CaptureLevel, at time: Leyline_V1_SampleTime, sampleRate: UInt64,
        gains: [Leyline_V1_GainState], elements: [Leyline_V1_GainElement]
    ) -> FailureState? {
        guard sampleRate > 0, level.totalSamples > 0 else { return state }
        if time.captureID != captureID {
            reset()
            captureID = time.captureID
        }
        let named = FailureState.name(
            level: level, gains: gains, elements: elements, previous: state)
        guard (named == nil) != (state == nil) else {
            runStart = nil
            if named != nil { state = named }
            return state
        }
        let end = time.sampleIndex
        let start = end - min(end, level.totalSamples)
        // The run is timed from the first interval's first sample, so four quarter-second
        // readings are one second; a reading from before the run's start begins it again.
        let from = runStart.flatMap { $0 <= end ? $0 : nil } ?? start
        let needed = state == nil ? Self.raiseSeconds : Self.clearSeconds
        if Double(end - from) >= needed * Double(sampleRate) {
            state = named
            runStart = nil
        } else {
            runStart = from
        }
        return state
    }

    /// Forgets the state and any run: the capture went away, or its readings stopped.
    public mutating func reset() {
        state = nil
        captureID = nil
        runStart = nil
    }
}
