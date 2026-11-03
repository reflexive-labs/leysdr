// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto

/// Claims as people name them (docs/design/claims.md): who holds one and what it needs. The
/// placement names what a retune pauses with these, and the Radio inspector lists the tuned
/// capture's claims with `rows`.
public enum ClaimWords {
    /// One line of the inspector's list: who holds the claim, what it needs in words, and whether
    /// the capture no longer gives it that, with who moved it and when (`paused by the app at
    /// 14:05`). `count` folds identical claims, a client's several spectrum streams, into one
    /// line.
    public struct Row: Sendable, Equatable {
        public var who: String
        public var what: String
        public var displaced: Bool
        /// While displaced: `paused by the app at 14:05`, `paused by the scan`, or `paused` when
        /// the daemon names nobody.
        public var paused: String?
        public var count: Int

        public init(
            who: String, what: String, displaced: Bool = false, paused: String? = nil,
            count: Int = 1
        ) {
            self.who = who
            self.what = what
            self.displaced = displaced
            self.paused = paused
            self.count = count
        }
    }

    /// A capture's claims as the inspector lists them: everybody else's first, people before
    /// jobs before views, then the app's own, each kind in the order the daemon gave; identical
    /// lines once, counted.
    public static func rows(
        _ claims: [Leyline_V1_Claim], jobs: [Leyline_V1_Job], titles: [String: String],
        timeZone: TimeZone = .current
    ) -> [Row] {
        func rank(_ c: Leyline_V1_Claim) -> Int {
            let own = c.holder.kind == "app" ? 10 : 0
            switch c.priority {
            case .priorityPerson: return own + 0
            case .priorityJob: return own + 1
            default: return own + 2
            }
        }
        let ordered = claims.enumerated().sorted {
            (rank($0.element), $0.offset) < (rank($1.element), $1.offset)
        }
        var out: [Row] = []
        for (_, c) in ordered {
            let displaced = c.state == .claimDisplaced
            let row = Row(
                who: holder(c.holder, jobs: jobs, titles: titles), what: what(c),
                displaced: displaced,
                paused: displaced
                    ? paused(by: c, jobs: jobs, titles: titles, timeZone: timeZone) : nil)
            if let i = out.firstIndex(where: {
                $0.who == row.who && $0.what == row.what && $0.displaced == row.displaced
                    && $0.paused == row.paused
            }) {
                out[i].count += 1
            } else {
                out.append(row)
            }
        }
        return out
    }

    /// A displaced claim's mover and since-time, as the daemon's DEGRADED detail names the
    /// mover: `paused by the app at 14:05`, `paused by the scan at 09:30`, `paused` when the
    /// daemon names nobody, and no time when it gives none.
    public static func paused(
        by c: Leyline_V1_Claim, jobs: [Leyline_V1_Job], titles: [String: String],
        timeZone: TimeZone
    ) -> String {
        var words = "paused"
        if c.hasDisplacedBy, !c.displacedBy.clientID.isEmpty || !c.displacedBy.kind.isEmpty {
            words += " by " + mover(c.displacedBy, jobs: jobs, titles: titles)
        }
        if c.displacedSinceNs > 0 {
            let at = Date(timeIntervalSince1970: TimeInterval(c.displacedSinceNs) / 1e9)
            words += " at " + DecoderPages.clock(at, seconds: false, timeZone: timeZone)
        }
        return words
    }

    /// Who moved a capture, as a sentence names it: `the app`, `a terminal`, `an agent`, `the
    /// APRS decoder`, `the scan`, `the daemon`.
    static func mover(
        _ h: Leyline_V1_ClientInfo, jobs: [Leyline_V1_Job], titles: [String: String]
    ) -> String {
        switch h.kind {
        case "app": return "the app"
        case "cli": return "a terminal"
        case "mcp": return "an agent"
        case "job": return jobName(h.clientID, jobs: jobs, titles: titles)
        case "daemon": return "the daemon"
        default: return h.label.isEmpty ? "another client" : h.label
        }
    }

    /// Who holds a claim, short: `the app`, `a terminal`, `an agent`, `job: APRS`, `job:
    /// recording`.
    public static func holder(
        _ h: Leyline_V1_ClientInfo, jobs: [Leyline_V1_Job], titles: [String: String]
    ) -> String {
        switch h.kind {
        case "app": return "the app"
        case "cli": return "a terminal"
        case "mcp": return "an agent"
        case "job":
            guard let j = jobs.first(where: { $0.jobID == h.clientID }) else { return "a job" }
            switch j.config {
            case .decode(let d)?: return "job: \(titles[d.decoder] ?? d.decoder)"
            case .record?: return "job: recording"
            case .scan?: return "job: scan"
            case .monitor?: return "job: monitor"
            default: return "a job"
            }
        default: return h.label.isEmpty ? "another client" : h.label
        }
    }

    /// What a claim needs, in words, with the Radio's spelling of a frequency: `channel on
    /// 146.520 MHz`, `IQ centred on 1.090 GHz`, `listening`, `spectrum view`, `sweep 144.000 MHz to
    /// 148.000 MHz`.
    public static func what(_ c: Leyline_V1_Claim) -> String {
        let f = BookmarkNaming.frequencyWords
        switch (c.kind, c.need) {
        case (.claimSweep, .covers(let s)?) where s.bandwidthHz > 0:
            let half = UInt64(s.bandwidthHz / 2)
            let low = s.frequencyHz > half ? s.frequencyHz - half : 0
            return "sweep \(f(low)) to \(f(s.frequencyHz + half))"
        case (.claimIq, .centred(let s)?):
            return "IQ centred on \(f(s.frequencyHz))"
        case (.claimIq, .covers(let s)?):
            return "IQ on \(f(s.frequencyHz))"
        case (let k, .covers(let s)?):
            return "\(noun(k)) on \(f(s.frequencyHz))"
        case (let k, .centred(let s)?):
            return "\(noun(k)) centred on \(f(s.frequencyHz))"
        case (let k, nil):
            return noun(k)
        }
    }

    /// A claim as a retune's pause list names it: `your channel on 146.520 MHz`, `a terminal's
    /// channel on 146.520 MHz`, `the APRS decoder on 144.390 MHz`, `the recording on 162.550
    /// MHz`.
    public static func paused(
        _ c: Leyline_V1_Claim, jobs: [Leyline_V1_Job], selfID: String, titles: [String: String]
    ) -> String {
        let at = place(c)
        let h = c.holder
        if h.kind == "job" { return jobName(h.clientID, jobs: jobs, titles: titles) + at }
        let whose: String
        if h.clientID == selfID {
            whose = "your"
        } else {
            switch h.kind {
            case "app": whose = "the app's"
            case "cli": whose = "a terminal's"
            case "mcp": whose = "an agent's"
            default: whose = h.label.isEmpty ? "another client's" : "\(h.label)'s"
            }
        }
        return "\(whose) \(noun(c.kind))\(at)"
    }

    /// ` on 146.520 MHz` for a claim that needs a frequency covered, ` at 1090.000 MHz` for one
    /// that needs the capture centred there, empty for one that takes the capture as it is.
    static func place(_ c: Leyline_V1_Claim) -> String {
        switch c.need {
        case .covers(let s)?: return " on \(DecoderPages.frequencyWords(s.frequencyHz))"
        case .centred(let s)?: return " at \(DecoderPages.frequencyWords(s.frequencyHz))"
        case nil: return ""
        }
    }

    /// A claim's kind as a noun: `channel`, `IQ reader`.
    static func noun(_ k: Leyline_V1_ClaimKind) -> String {
        switch k {
        case .claimChannel: return "channel"
        case .claimIq: return "IQ reader"
        case .claimListen: return "listening"
        case .claimSpectrum: return "spectrum view"
        case .claimSweep: return "sweep"
        default: return "claim"
        }
    }

    /// A job as a person names it: `the APRS decoder`, `the recording`, `the scan`, `the
    /// monitor`, else `a job`.
    static func jobName(_ id: String, jobs: [Leyline_V1_Job], titles: [String: String]) -> String {
        guard let j = jobs.first(where: { $0.jobID == id }) else { return "a job" }
        switch j.config {
        case .decode(let d)?: return "the \(titles[d.decoder] ?? d.decoder) decoder"
        case .record?: return "the recording"
        case .scan?: return "the scan"
        case .monitor?: return "the monitor"
        default: return "a job"
        }
    }
}
