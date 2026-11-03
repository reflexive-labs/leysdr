// SPDX-License-Identifier: Apache-2.0

// The one question before a person moves the radio (docs/design/claims.md, "In the clients"): a
// retune that would pause a job (a decoder, a watch, a recording, a scan) asks once, naming
// them, and a view or the person's own claim is never asked about. The list comes from the
// daemon's `Control.Plan`, as `ley tune` reads it (`go/internal/cli/session_capture.go`,
// `refuseDisplacing`), so the window and the terminal name the same jobs.
//
// Whether a move needs the plan at all is read here from the capture's claims, so a click or a
// drag inside what every job needs costs no call, and a drag asks once, when it first leaves
// that, and remembers the answer for the rest of the drag (`RetuneDrag`).

import Foundation
import LeylineProto

public enum RetuneAsk {
    /// The centres a capture may move to and leave every job's claim satisfied.
    public enum Keep: Sendable, Equatable {
        /// No job needs the tuning: any centre.
        case anywhere
        /// The centres from the lower bound to the upper, inclusive.
        case within(ClosedRange<Int64>)
        /// No centre at this rate satisfies them all (a job needs another rate, or two jobs
        /// need centres too far apart).
        case nowhere

        /// Whether a capture centred on `centre` keeps every job's claim.
        public func contains(_ centre: Int64) -> Bool {
            switch self {
            case .anywhere: return true
            case .within(let r): return r.contains(centre)
            case .nowhere: return false
            }
        }

        /// The centre nearest `centre` that keeps them, else `fallback`.
        public func nearest(to centre: Int64, fallback: Int64) -> Int64 {
            switch self {
            case .anywhere: return centre
            case .within(let r): return min(max(centre, r.lowerBound), r.upperBound)
            case .nowhere: return fallback
            }
        }
    }

    /// The claims on `cap` a person is asked about before moving it: a job's, satisfied now, that
    /// needs something of the tuning. A view, a presence, a person's channel and the window's
    /// own claims are never among them.
    public static func jobClaims(on cap: Leyline_V1_Capture, selfID: String)
        -> [Leyline_V1_Claim]
    {
        cap.claims.filter {
            $0.priority == .priorityJob && $0.state != .claimDisplaced
                && $0.holder.clientID != selfID && ($0.need != nil || $0.sampleRateHz != 0)
        }
    }

    /// The centres at `rate` that keep every one of `claims` satisfied, by the daemon's fit: a
    /// covered frequency's band inside the span, a centred claim within its tolerance, and a
    /// claim's own rate, when it names one, the capture's.
    public static func keep(_ claims: [Leyline_V1_Claim], rate: UInt64) -> Keep {
        guard !claims.isEmpty else { return .anywhere }
        var lo = Int64.min
        var hi = Int64.max
        for c in claims {
            if c.sampleRateHz != 0, c.sampleRateHz != rate { return .nowhere }
            switch c.need {
            case .covers(let s)?:
                let reach = (Int64(rate) - Int64(s.bandwidthHz)) / 2
                guard reach >= 0 else { return .nowhere }
                lo = max(lo, Int64(s.frequencyHz) - reach)
                hi = min(hi, Int64(s.frequencyHz) + reach)
            case .centred(let k)?:
                lo = max(lo, Int64(k.frequencyHz) - Int64(k.toleranceHz))
                hi = min(hi, Int64(k.frequencyHz) + Int64(k.toleranceHz))
            case nil:
                continue
            }
        }
        if lo == Int64.min && hi == Int64.max { return .anywhere }
        return lo <= hi ? .within(lo...hi) : .nowhere
    }

    /// Whether moving `cap` to `centre` at `rate` would pause one of the jobs on it, and so needs
    /// the plan and perhaps the question first.
    public static func pauses(
        _ cap: Leyline_V1_Capture, centre: Int64, rate: UInt64, selfID: String
    ) -> Bool {
        !keep(jobClaims(on: cap, selfID: selfID), rate: rate).contains(centre)
    }

    /// What the plan pauses that the person is asked about: the jobs' claims among a retune's
    /// displaced, never a view, a person's or the window's own. A decline moves nothing and
    /// asks nothing: the daemon's error says why.
    public static func asked(_ plan: Leyline_V1_CapturePlan, selfID: String)
        -> [Leyline_V1_Claim]
    {
        guard case .retune(let r)? = plan.outcome else { return [] }
        return r.displaced.filter { $0.priority == .priorityJob && $0.holder.clientID != selfID }
    }

    /// The question's words: `This pauses the APRS decoder on 144.390 MHz and the recording on
    /// 146.520 MHz.` A job with two claims is named once. Nil when there is nothing to ask about.
    public static func words(
        _ claims: [Leyline_V1_Claim], jobs: [Leyline_V1_Job], titles: [String: String]
    ) -> String? {
        var names: [String] = []
        for c in claims {
            let name = ClaimWords.paused(c, jobs: jobs, selfID: "", titles: titles)
            if !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        return "This pauses \(DecoderPlacement.joinAnd(names))."
    }
}

/// One drag's question (`RetuneAsk`): the drag moves the radio freely while every job's claim is
/// kept, asks once when it would first leave them, holds the radio at the edge of what they
/// keep while the question is open or after Cancel, and goes where it is dragged after Move
/// anyway, for the rest of the drag. A new drag asks again.
public struct RetuneDrag: Sendable, Equatable {
    /// The person's answer so far.
    public enum Answer: Sendable, Equatable {
        case unasked, asking, moveAnyway, stay
    }

    /// What one frame of the drag does with the radio.
    public enum Step: Sendable, Equatable {
        /// Move the capture to this centre.
        case move(Int64)
        /// Hold the capture at this centre, the nearest that keeps every job.
        case hold(Int64)
        /// Hold it there and ask, once: the drag wanted `wanted`.
        case ask(wanted: Int64, hold: Int64)
    }

    public let keep: RetuneAsk.Keep
    /// Where the capture was when the drag began, held to when nothing keeps every job.
    public let start: Int64
    public private(set) var answer: Answer = .unasked
    /// The last centre the drag asked for, which Move anyway moves to.
    public private(set) var wanted: Int64

    public init(keep: RetuneAsk.Keep, start: Int64) {
        self.keep = keep
        self.start = start
        wanted = start
    }

    /// The drag at `centre`.
    public mutating func step(to centre: Int64) -> Step {
        wanted = centre
        if keep.contains(centre) || answer == .moveAnyway { return .move(centre) }
        let hold = keep.nearest(to: centre, fallback: start)
        if answer == .unasked {
            answer = .asking
            return .ask(wanted: centre, hold: hold)
        }
        return .hold(hold)
    }

    /// The person answered: Move anyway lets the rest of the drag go where it is dragged, Cancel
    /// holds it at the edge.
    public mutating func answered(moveAnyway: Bool) {
        answer = moveAnyway ? .moveAnyway : .stay
    }
}
