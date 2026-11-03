// SPDX-License-Identifier: Apache-2.0

// Where a decoder will land before it starts, as the daemon's `Control.Plan` answers it
// (docs/design/claims.md, "One decision: plan"): share a capture, open an idle radio, retune
// one, or decline. The daemon decides; this file only words the answer for the Decoders page, in
// the shapes `ley --dry-run` prints (`go/internal/cli/plan.go`), and says whether Start must ask
// before it sends `take_over`. The job's own state and detail are the truth once it runs.

import Foundation
import LeylineProto

public enum DecoderPlacement: Sendable, Equatable {
    /// No answer yet for this decoder and frequency.
    case asking
    /// The decoder has no frequency of its own and the window has nothing tuned to give it.
    case needsFrequency
    /// A capture already covers it as it is. `listening` is whether the window's own channel is
    /// on that capture.
    case share(device: String, centerHz: UInt64, listening: Bool)
    /// A radio nothing is using, opened at the centre and rate.
    case open(device: String, centerHz: UInt64, rateHz: UInt64)
    /// A capture moved, and what that pauses.
    case retune(Retune)
    /// Nowhere: the daemon's code and reason. `insist` is what `take_over` would do instead, when
    /// it would retune a radio rather than decline again.
    case decline(code: String, reason: String, insist: Retune?)

    /// A retune as the page words it.
    public struct Retune: Sendable, Equatable {
        public var device: String
        public var centerHz: UInt64
        /// The rate when it changes the capture's, else nil.
        public var rateHz: UInt64?
        /// The claims left unsatisfied, each named (`ClaimWords.paused`).
        public var displaced: [String]
        /// Whether any of them is a person's.
        public var displacesPerson: Bool

        public init(
            device: String, centerHz: UInt64, rateHz: UInt64? = nil, displaced: [String] = [],
            displacesPerson: Bool = false
        ) {
            self.device = device
            self.centerHz = centerHz
            self.rateHz = rateHz
            self.displaced = displaced
            self.displacesPerson = displacesPerson
        }

        /// `retunes the RTL-SDR to 144.390 MHz, pausing: your channel on 146.520 MHz`, or `…;
        /// nothing on it has to move`.
        public var clause: String {
            var head = "retunes the \(device) to \(DecoderPages.frequencyWords(centerHz))"
            if let rateHz { head += " at \(DecoderPlacement.msps(rateHz))" }
            if displaced.isEmpty { return head + "; nothing on it has to move" }
            return head + ", pausing: " + DecoderPlacement.joinAnd(displaced)
        }
    }

    /// The line under Start.
    public var words: String {
        switch self {
        case .asking:
            return "Asking the daemon where it would run."
        case .needsFrequency:
            return "Has no frequency of its own: tune a channel first."
        case .share(let device, let centre, let listening):
            return listening
                ? "Runs alongside what you are listening to."
                : "Shares the \(device)'s capture at \(DecoderPages.frequencyWords(centre)); nothing is retuned."
        case .open(let device, let centre, let rate):
            return
                "Opens the \(device) at \(DecoderPages.frequencyWords(centre)), \(Self.msps(rate)); nothing else is using it."
        case .retune(let r):
            return Self.sentence(r.clause)
        case .decline(_, let reason, let insist):
            let head = "Would not start: \(Self.unstopped(reason))"
            return insist == nil ? head + "." : head + "; Start asks to take the radio."
        }
    }

    /// Why it would not start without the radio, in the daemon's words: a decline's reason, else
    /// nil. A failed job with the same reason adds no line of its own (`DecoderPages.failedLine`).
    public var declineReason: String? {
        if case .decline(_, let reason, _) = self { return reason }
        return nil
    }

    /// What Start's take-over would do, nil when Start does not ask.
    public var takeOver: Retune? {
        switch self {
        case .retune(let r): return r.displacesPerson ? r : nil
        case .decline(_, _, let insist): return insist
        default: return nil
        }
    }

    /// Whether Start must ask and then send `take_over`: the plan moves a radio from a person, or
    /// the daemon declines what `take_over` would turn into a retune.
    public var needsTakeOver: Bool { takeOver != nil }

    /// Whether Start is offered at all.
    public var canStart: Bool {
        switch self {
        case .asking, .needsFrequency: return false
        case .decline(_, _, let insist): return insist != nil
        default: return true
        }
    }

    /// The page's placement from the daemon's plan for the decoder, and, after a decline, its plan
    /// for the same request with `take_over`. `selfID` is the window's client id and
    /// `windowChannel` the channel it plays, which may be another client's it followed; either on
    /// the shared capture reads "you are listening". `titles` names a decode job's decoder by its
    /// manifest name.
    public static func from(
        _ plan: Leyline_V1_CapturePlan, insisting: Leyline_V1_CapturePlan? = nil,
        state: MirrorState, selfID: String, windowChannel: String? = nil,
        titles: [String: String] = [:]
    ) -> DecoderPlacement {
        switch plan.outcome {
        case .share(let s)?:
            let listening = state.channels.contains {
                $0.captureID == s.captureID
                    && ($0.owner.clientID == selfID || $0.channelID == windowChannel)
            }
            return .share(
                device: device(s.deviceID, state), centerHz: s.centerHz, listening: listening)
        case .create(let c)?:
            return .open(
                device: device(c.deviceID, state), centerHz: c.centerHz, rateHz: c.sampleRateHz)
        case .retune(let r)?:
            return .retune(retune(r, state: state, selfID: selfID, titles: titles))
        case .decline(let d)?:
            var insist: Retune?
            if case .retune(let r)? = insisting?.outcome {
                insist = retune(r, state: state, selfID: selfID, titles: titles)
            }
            return .decline(code: d.code, reason: d.reason, insist: insist)
        case nil:
            return .decline(code: "", reason: "the daemon gave no plan", insist: nil)
        }
    }

    static func retune(
        _ r: Leyline_V1_PlanRetune, state: MirrorState, selfID: String, titles: [String: String]
    ) -> Retune {
        // The rate is said only when it changes the capture's, as `ley --dry-run` says it.
        var rate: UInt64?
        if let cap = state.captures.first(where: { $0.captureID == r.captureID }),
            r.sampleRateHz != 0, cap.sampleRate != r.sampleRateHz
        {
            rate = r.sampleRateHz
        }
        return Retune(
            device: device(r.deviceID, state), centerHz: r.centerHz, rateHz: rate,
            displaced: r.displaced.map {
                ClaimWords.paused($0, jobs: state.jobs, selfID: selfID, titles: titles)
            },
            displacesPerson: r.displaced.contains { $0.priority == .priorityPerson })
    }

    /// A radio by its model, as `ley` names one; "radio" when it has none.
    static func device(_ id: String, _ state: MirrorState) -> String {
        let model = state.devices.first { $0.deviceID == id }?.model ?? ""
        return model.isEmpty ? "radio" : model
    }

    /// The frequency a decoder starts on: the first of its recipe's frequencies inside the span
    /// the window's capture covers, else the recipe's first, else the window's tuned frequency
    /// for a decoder with none of its own (speech). Nil when there is none of the three.
    public static func frequency(
        for manifest: Leyline_V1_DecoderManifest, capture: Leyline_V1_Capture?, tunedHz: UInt64?
    ) -> UInt64? {
        let recipe = manifest.recipe.frequenciesHz
        guard let first = recipe.first else { return tunedHz }
        if let cap = capture, cap.sampleRate > 0 {
            let half = cap.sampleRate / 2
            let low = cap.centerHz > half ? cap.centerHz - half : 0
            if let inside = recipe.first(where: { $0 >= low && $0 <= cap.centerHz + half }) {
                return inside
            }
        }
        return first
    }

    /// In MHz, as every sentence of the Decoders place writes a frequency.
    static func mhz(_ hz: UInt64) -> String { DecoderPages.frequencyWords(hz) }

    /// A sample rate as people say it: `2.4 MSPS`.
    static func msps(_ hz: UInt64) -> String {
        var words = String(format: "%.3f", Double(hz) / 1e6)
        while words.hasSuffix("0") { words.removeLast() }
        if words.hasSuffix(".") { words.removeLast() }
        return words + " MSPS"
    }

    /// `a`, `a and b`, `a, b and c`.
    static func joinAnd(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// A clause as a sentence: capitalised and stopped.
    static func sentence(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst() + (s.hasSuffix(".") ? "" : ".")
    }

    /// A reason without its full stop, so a sentence can go on after it.
    public static func unstopped(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix(".") ? String(t.dropLast()) : t
    }
}
