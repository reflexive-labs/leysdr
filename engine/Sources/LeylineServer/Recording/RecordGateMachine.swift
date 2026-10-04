// SPDX-License-Identifier: GPL-3.0-or-later

// The squelch gate (docs/design/recording.md, "The daemon"). It reads the squelch's own
// transitions, not the audio: the `.audio` tap is zeros while the squelch is closed, but that is
// an implementation fact rather than a contract, and the transition record carries the exact
// sample the state changed at.
//
// Everything here is on the capture's timebase and in samples, so the machine has no clock of its
// own and a test can drive it with synthetic transitions and no DSP.

import Foundation

/// A gated recording's state machine. One part per exchange: the squelch stays open through the
/// pauses between overs, every opening inside the part is listed, and the part closes when the
/// hang elapses.
struct RecordGateMachine: Sendable {
    /// What the runner should do. Returned in the order it should happen.
    enum Action: Equatable, Sendable {
        /// Open a part whose first sample is this one, pre-roll included.
        case openPart(startSample: UInt64)
        /// An over began, for the part's `squelch_opens`.
        case squelchOpened(at: UInt64)
        /// The squelch closed on its own edge at this sample, so the audio just before it is the
        /// squelch tail: the discriminator's noise between the carrier dropping and the squelch
        /// deciding it had. The runner silences it before it reaches the part
        /// (docs/design/recording.md, "The squelch tail"). Never emitted for a close the machine
        /// makes itself -- the job ending or the channel leaving the capture -- because the audio
        /// before those is whatever was on the air.
        case silenceTail(closedAt: UInt64)
        /// An over ended.
        case squelchClosed(at: UInt64)
        /// Close the open part here: the close transition plus the hang.
        case closePart(endSample: UInt64)
        /// The squelch has been closed for `stop_after_quiet_ms`; the job is over.
        case quiet
    }

    private enum State: Equatable {
        case closed
        case open
        case hanging(closedAt: UInt64)
    }

    /// Samples of audio kept from before the squelch opened.
    let preRollSamples: UInt64
    /// Samples a part stays open after the squelch closes.
    let hangSamples: UInt64
    /// Samples of closed squelch that end the job; 0 never does.
    let quietSamples: UInt64

    private var state: State = .closed
    /// Where the current stretch of silence began, for the quiet timer. The job's own start, until
    /// the first part closes.
    private var quietSince: UInt64
    private var finished = false

    init(preRollSamples: UInt64, hangSamples: UInt64, quietSamples: UInt64, startSample: UInt64) {
        self.preRollSamples = preRollSamples
        self.hangSamples = hangSamples
        self.quietSamples = quietSamples
        quietSince = startSample
    }

    var partIsOpen: Bool {
        switch state {
        case .closed: return false
        case .open, .hanging: return true
        }
    }

    /// Whether the machine holds the squelch open, as opposed to closed or hanging: what a meter's
    /// `squelch_open` is compared with to find an edge the machine never saw.
    var squelchIsOpen: Bool { state == .open }

    /// The squelch was already open when the recording started, so no transition will come: a
    /// broadcast carrier keeps it open for as long as it is on the air. The part opens at `sample`,
    /// the recording's first, with no pre-roll, since there is no audio from before the recording
    /// began (docs/design/recording.md, "The gate").
    mutating func seedOpen(at sample: UInt64) -> [Action] {
        guard !finished, state == .closed else { return [] }
        state = .open
        return [.openPart(startSample: sample), .squelchOpened(at: sample)]
    }

    /// The channel left the capture: the open part closes at `now` and the machine is closed, but
    /// the job goes on, and the next opening begins a new part. The quiet timer runs from here.
    mutating func coverageLost(at now: UInt64) -> [Action] {
        guard !finished else { return [] }
        var out: [Action] = []
        if case .open = state { out.append(.squelchClosed(at: now)) }
        if partIsOpen { out.append(.closePart(endSample: now)) }
        state = .closed
        quietSince = now
        return out
    }

    /// A squelch edge, at the sample the channel reports it at.
    mutating func squelch(open: Bool, at sample: UInt64) -> [Action] {
        guard !finished else { return [] }
        if open {
            switch state {
            case .closed:
                state = .open
                // The part's first sample is the transition's less the pre-roll: the pre-roll keeps
                // the squelch's own attack and the syllable under it.
                return [.openPart(startSample: sample >= preRollSamples ? sample - preRollSamples : 0),
                        .squelchOpened(at: sample)]
            case .hanging:
                // A re-open inside the hang continues the same part: one exchange, several overs.
                state = .open
                return [.squelchOpened(at: sample)]
            case .open:
                return []
            }
        }
        guard case .open = state else { return [] }
        state = .hanging(closedAt: sample)
        return [.silenceTail(closedAt: sample), .squelchClosed(at: sample)]
    }

    /// Time passing, as the drain reaches `now` on the capture's timeline. Hang expiry and the
    /// quiet timer both land here, so neither needs a wall clock.
    mutating func advance(to now: UInt64) -> [Action] {
        guard !finished else { return [] }
        var out: [Action] = []
        if case .hanging(let closedAt) = state {
            let end = closedAt + hangSamples
            if now >= end {
                state = .closed
                quietSince = closedAt
                out.append(.closePart(endSample: end))
            }
        }
        if case .closed = state, quietSamples > 0, now >= quietSince + quietSamples {
            finished = true
            out.append(.quiet)
        }
        return out
    }

    /// The job is ending: close whatever is open, at the sample the recording reached.
    mutating func finish(at now: UInt64) -> [Action] {
        var out: [Action] = []
        if case .open = state { out.append(.squelchClosed(at: now)) }
        if partIsOpen { out.append(.closePart(endSample: now)) }
        state = .closed
        finished = true
        return out
    }
}
