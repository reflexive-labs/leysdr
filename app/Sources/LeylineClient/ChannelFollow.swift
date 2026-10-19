// SPDX-License-Identifier: Apache-2.0

// One radio, one picture: when another client makes a channel on the capture the window shows
// (the assistant on `ley ask`, the window's own assistant panel, a terminal's `ley tune`), the
// window follows that channel. Its readout, inspector, rail selection, transmissions log and audio
// read the new channel, the window's own channel is ended unless a recording runs on it, and the
// channel stays its maker's: when the maker ends it, the window makes a channel of its own where
// it was. A capture moved with no new channel is not followed; the out-of-capture caution covers
// it. The decision is a fold over the mirror, so it is tested without a daemon; `AppSession`
// does the RPCs it names (`docs/dev/app.md`, "The façade").

import Foundation
import LeylineProto

/// The window's side of the follow rule: the newest channel another client made on the window's
/// capture since the window's own last tune, and what following it takes. A value, stored as one
/// property of the session.
public struct ChannelFollow: Sendable, Equatable {
    /// Channels made at or below this `seq` are never followed: the window's own last tune, or the
    /// last channel it followed, is newer than them.
    public private(set) var floor: UInt64 = 0
    /// The other client's channel the window holds, as last seen in the mirror: where the window
    /// makes its own channel when the maker ends this one.
    public private(set) var followed: Leyline_V1_Channel?
    /// The window's own channel, left running because a recording runs on it, until the
    /// recording stops.
    public private(set) var kept: Kept?
    /// The window's own channel's frequency the last time it was inside its capture: a record
    /// job is matched by frequency, and the move that made the other client's channel may have
    /// taken the window's own out of the capture first, so its frequency now is not the one it
    /// was recording.
    private var ownTuning: Kept?

    /// A channel of the window's own, by id, with the frequency and mode it was listening on.
    public struct Kept: Sendable, Equatable {
        public var channelID: String
        public var hz: UInt64
        public var mode: Leyline_V1_DemodMode
    }

    /// What following a channel takes, for the session to carry out.
    public struct Step: Sendable, Equatable {
        /// The channel to hold from now on.
        public var follow: Leyline_V1_Channel
        /// The channel the window held, if any.
        public var from: String?
        /// Whether the window ends `from`: its own channel with no recording on it.
        public var endFrom: Bool
        /// Whether `from` is the window's own channel, left running for its recording.
        public var keepFrom: Bool
        /// The window's sink to detach from `from`, when `from` keeps running.
        public var detachSink: String?
        /// Whether to attach a sink on the followed channel: the window was playing `from` (or
        /// held no channel), nothing plays the new one yet, and the audio is not held for a
        /// recorded part or a sweep.
        public var attachSink: Bool
    }

    public init() {}

    /// The window tuned, made or took a channel itself at `seq` (the mirror's newest when it
    /// did): only channels made after it are candidates, so a channel the window has moved away
    /// from is not followed again.
    public mutating func tuned(at seq: UInt64) {
        floor = max(floor, seq)
    }

    /// The channel to follow, or nil: the newest by event `seq` that another client made on the
    /// capture since `floor`, other than the one held. "Another client" is any client id but
    /// `selfClientID`, both as the creation event's `caused_by` and as the channel's owner, and
    /// never a job (a recording's or a scan's channel is the job's, not a tune).
    public func candidate(
        in state: MirrorState, captureID: String?, heldChannelID: String?, selfClientID: String
    ) -> Leyline_V1_Channel? {
        guard let captureID else { return nil }
        var best: (seq: UInt64, channel: Leyline_V1_Channel)?
        for ch in state.channels(in: captureID) where ch.channelID != heldChannelID {
            guard ch.state != .unspecified, let made = state.made[ch.channelID],
                made.seq > floor
            else { continue }
            let by = made.causedBy
            guard by.clientID != selfClientID, ch.owner.clientID != selfClientID,
                by.kind != "job", ch.owner.kind != "job"
            else { continue }
            if made.seq > best?.seq ?? 0 { best = (made.seq, ch) }
        }
        return best?.channel
    }

    /// Folds one mirror state. Returns the step to take when a channel is to be followed, and
    /// nil otherwise. `held` is the window's channel as it reads it (the mirror's copy, else
    /// the RPC's), `windowSinkID` the sink the window attached, and `audioHeld` whether the live
    /// sink is detached on purpose (a recorded part plays, a sweep runs), so none is attached.
    public mutating func step(
        in state: MirrorState, captureID: String?, held: Leyline_V1_Channel?,
        windowSinkID: String?, audioHeld: Bool, selfClientID: String
    ) -> Step? {
        if let f = followed {
            if f.channelID != held?.channelID {
                followed = nil  // the window tuned elsewhere, or let the channel go
            } else if let now = state.channel(f.channelID) {
                followed = now
            }
        }
        if let held, held.owner.clientID == selfClientID, held.state == .channelActive,
            let hz = state.frequencyHz(of: held)
        {
            ownTuning = Kept(channelID: held.channelID, hz: hz, mode: held.mode)
        }
        guard
            let next = candidate(
                in: state, captureID: captureID, heldChannelID: held?.channelID,
                selfClientID: selfClientID),
            let made = state.made[next.channelID]
        else { return nil }
        floor = max(floor, made.seq)
        followed = next

        let own = held.map { $0.owner.clientID == selfClientID } ?? false
        let recording =
            held.map { own && Self.recording(on: $0, tuning: ownTuning, in: state) }
            ?? false
        if own, recording, let held {
            kept =
                ownTuning?.channelID == held.channelID
                ? ownTuning
                : Kept(
                    channelID: held.channelID, hz: state.frequencyHz(of: held) ?? 0,
                    mode: held.mode)
        }
        let endFrom = own && !recording
        let fromPlays = held.map { state.plays($0.channelID) } ?? true
        let detach = windowSinkID.flatMap { id in
            state.sinks.contains { $0.sinkID == id && $0.channelID == held?.channelID }
                ? id : nil
        }
        return Step(
            follow: next, from: held?.channelID, endFrom: endFrom, keepFrom: own && recording,
            detachSink: endFrom ? nil : detach,
            attachSink: fromPlays && !state.plays(next.channelID) && !audioHeld)
    }

    /// The window's kept channel once nothing records on it any more, for the session to end;
    /// nil while the recording runs, or when none is kept. A kept channel that has gone is
    /// forgotten.
    public mutating func keptToEnd(in state: MirrorState) -> String? {
        guard let k = kept else { return nil }
        guard let ch = state.channel(k.channelID) else {
            kept = nil
            return nil
        }
        if Self.recording(on: ch, tuning: k, in: state) { return nil }
        kept = nil
        return k.channelID
    }

    /// The held channel left the mirror: when it was the one followed, its last copy, where the
    /// window makes a channel of its own; nil for the window's own channel, which the window
    /// lets go as before.
    public mutating func lost(_ channelID: String) -> Leyline_V1_Channel? {
        guard let f = followed, f.channelID == channelID else { return nil }
        followed = nil
        return f
    }

    /// The inspector's line while the window follows another channel and its own records:
    /// "Your channel on 462.5625 MHz stays open while it records."
    public func keptWords(in state: MirrorState) -> String? {
        guard let k = kept, state.channel(k.channelID) != nil else { return nil }
        return "Your channel on \(BookmarkNaming.frequencyWords(k.hz)) stays open while it records."
    }

    /// Whether a recording runs on `channel`: an active record job that borrowed it, or one in
    /// the frequency form on its frequency and mode (the window's Record switch starts that
    /// form; `Recordings.activeJob`). `tuning` is the channel's frequency before a move took it
    /// out of the capture.
    static func recording(on channel: Leyline_V1_Channel, tuning: Kept?, in state: MirrorState)
        -> Bool
    {
        let borrowed = state.jobs.contains {
            $0.isActive && $0.recordConfig?.channelID == channel.channelID
        }
        if borrowed { return true }
        let hz =
            tuning.flatMap { $0.channelID == channel.channelID ? $0.hz : nil }
            ?? state.frequencyHz(of: channel)
        guard let hz else { return false }
        return Recordings.activeJob(in: state.jobs, frequencyHz: hz, mode: channel.mode) != nil
    }
}

extension MirrorState {
    /// Whether a system-audio sink plays `channelID`, whoever attached it.
    func plays(_ channelID: String) -> Bool {
        sinks(of: channelID).contains {
            if case .systemAudio? = $0.kind { true } else { false }
        }
    }
}
