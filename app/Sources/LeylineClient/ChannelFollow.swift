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
        /// Whether the window wants audio on the followed channel: it is not muted and the
        /// audio is not held for a recorded part. The sink is attached only after
        /// `attachSettle`, and only if `shouldAttach` still holds then.
        public var attachSink: Bool
    }

    /// How long the window waits after a follow before attaching its sink: the maker may attach
    /// its own a moment after making the channel (`ley tune` makes the channel, measures the
    /// squelch from one spectrum row, then attaches), and two sinks on one channel echo.
    public static let attachSettle: Duration = .seconds(1)

    public init() {}

    /// The window tuned, made or took a channel itself at `seq` (the mirror's newest when it
    /// did): only channels made after it are candidates, so a channel the window has moved away
    /// from is not followed again.
    public mutating func tuned(at seq: UInt64) {
        floor = max(floor, seq)
    }

    /// The mirror took a snapshot on connecting: the floor becomes its `seq`, since a restarted
    /// daemon counts from 0 again and a floor from before would hide every channel it makes.
    public mutating func connected(atSeq seq: UInt64) {
        floor = seq
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
    /// the RPC's), `windowSinkID` the sink the window attached, `muted` whether the person muted
    /// the window (no sink is attached then, whatever is followed), and `audioHeld` whether the live
    /// sink is detached on purpose (a recorded part plays, a sweep runs), so none is attached.
    public mutating func step(
        in state: MirrorState, captureID: String?, held: Leyline_V1_Channel?,
        windowSinkID: String?, muted: Bool, audioHeld: Bool, selfClientID: String
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
        return take(
            next, in: state, captureID: captureID, held: held, windowSinkID: windowSinkID,
            muted: muted, audioHeld: audioHeld, selfClientID: selfClientID)
    }

    /// On connecting: when the window's channel is not in its capture (gone, or out of capture
    /// because another client moved the radio while the window was away), the newest channel
    /// left on the capture is taken, the way a follow takes one. A snapshot says who made a
    /// channel but not at which `seq`, so the newest is the greatest id (channel ids are ULIDs).
    /// A job's channel is never taken.
    public mutating func stepOnConnect(
        in state: MirrorState, captureID: String?, held: Leyline_V1_Channel?,
        windowSinkID: String?, muted: Bool, audioHeld: Bool, selfClientID: String
    ) -> Step? {
        let present = held.flatMap { state.channel($0.channelID) }
        guard present?.state != .channelActive,
            let next = Self.adoptable(in: state, captureID: captureID, except: held?.channelID)
        else { return nil }
        // A held channel the mirror no longer lists is nothing to end or keep.
        return take(
            next, in: state, captureID: captureID, held: present, windowSinkID: windowSinkID,
            muted: muted, audioHeld: audioHeld, selfClientID: selfClientID)
    }

    /// The channel the window takes on a capture it adopts or reconnects to: the newest by id
    /// that is active and not a job's, other than `except`.
    public static func adoptable(in state: MirrorState, captureID: String?, except: String?)
        -> Leyline_V1_Channel?
    {
        guard let captureID else { return nil }
        return state.channels(in: captureID)
            .filter {
                $0.channelID != except && $0.state == .channelActive && $0.owner.kind != "job"
            }
            .max { $0.channelID < $1.channelID }
    }

    private mutating func take(
        _ next: Leyline_V1_Channel, in state: MirrorState, captureID: String?,
        held: Leyline_V1_Channel?, windowSinkID: String?, muted: Bool, audioHeld: Bool,
        selfClientID: String
    ) -> Step {
        followed = next.owner.clientID == selfClientID ? nil : next
        let own = held.map { $0.owner.clientID == selfClientID } ?? false
        let recording =
            held.map {
                own && Self.recording(on: $0, tuning: ownTuning, captureID: captureID, in: state)
            } ?? false
        if own, recording, let held {
            kept =
                ownTuning?.channelID == held.channelID
                ? ownTuning
                : Kept(
                    channelID: held.channelID, hz: state.frequencyHz(of: held) ?? 0,
                    mode: held.mode)
        }
        let endFrom = own && !recording
        let ownSinkOnFrom = windowSinkID.flatMap { id in
            state.sinks.contains { $0.sinkID == id && $0.channelID == held?.channelID }
                ? id : nil
        }
        // Mute is the person's intent, held by the session, not the absence of a sink: a
        // channel playing through another client's sink, or one the window reconnected to, has
        // no sink of the window's either.
        return Step(
            follow: next, from: held?.channelID, endFrom: endFrom, keepFrom: own && recording,
            detachSink: endFrom ? nil : ownSinkOnFrom, attachSink: !muted && !audioHeld)
    }

    /// Whether the window attaches its sink to `channelID` now, after the settle: it still holds
    /// the channel, it was not muted meanwhile, and nothing plays it, neither its own sink nor
    /// another client's.
    public static func shouldAttach(
        in state: MirrorState, channelID: String, held: String?, muted: Bool
    ) -> Bool {
        !muted && held == channelID && state.channel(channelID) != nil && !state.plays(channelID)
    }

    /// Whether this client attached `sink`, by the `caused_by` of its first event.
    static func isOwn(_ sink: Leyline_V1_Sink, in state: MirrorState, selfClientID: String) -> Bool
    {
        state.sinkAttachedBy[sink.sinkID]?.clientID == selfClientID
    }

    /// A sink of the window's own on the held channel, for the session to hold again when it
    /// holds none: one whose attach reply came after the never-seen limit, one left by an attach
    /// that overlapped another, or one whose detach failed. Without it such a sink would play
    /// with nothing to mute it.
    public static func ownSink(in state: MirrorState, held: String?, selfClientID: String)
        -> String?
    {
        guard let held else { return nil }
        return state.sinks(of: held).first {
            $0.isSystemAudio && isOwn($0, in: state, selfClientID: selfClientID)
        }?.sinkID
    }

    /// The window's own sinks other than the one it holds, on any channel: each plays audio the
    /// window cannot mute, so the session detaches them. Not asked while an attach is in flight,
    /// since the new sink's event can arrive before its reply.
    public static func strayOwnSinks(
        in state: MirrorState, windowSinkID: String?, selfClientID: String
    ) -> [String] {
        state.sinks.filter {
            $0.isSystemAudio && $0.sinkID != windowSinkID
                && isOwn($0, in: state, selfClientID: selfClientID)
        }.map(\.sinkID)
    }

    /// The window's sink when another client's also plays the held channel: two sinks echo, so
    /// the window's goes and the channel plays through the other. nil otherwise.
    public static func redundantSink(
        in state: MirrorState, held: String?, windowSinkID: String?, selfClientID: String
    ) -> String? {
        guard let held, let mine = windowSinkID,
            state.sinks.contains(where: { $0.sinkID == mine && $0.channelID == held })
        else { return nil }
        let others = state.sinks(of: held).contains {
            $0.sinkID != mine && $0.isSystemAudio
                && !isOwn($0, in: state, selfClientID: selfClientID)
        }
        return others ? mine : nil
    }

    /// When another client's sink plays the held channel and the window has none of its own:
    /// "The audio plays through another terminal." Mute and volume act on the window's own sink
    /// only, so they have nothing to act on then.
    public static func playsThroughWords(
        in state: MirrorState, held: String?, windowSinkID: String?, selfClientID: String
    ) -> String? {
        guard let held else { return nil }
        let all = state.sinks(of: held).filter(\.isSystemAudio)
        // A sink of the window's own, held or not, is never "another client's".
        guard !all.contains(where: { $0.sinkID == windowSinkID }) else { return nil }
        let sinks = all.filter { !isOwn($0, in: state, selfClientID: selfClientID) }
        guard !sinks.isEmpty, sinks.count == all.count else { return nil }
        // A sink in the snapshot came with no attach event to name who attached it, so the
        // channel's maker stands in (`ley tune` makes the channel and attaches its sink).
        let owner = state.channel(held).flatMap { ch in
            ch.hasOwner && ch.owner.clientID != selfClientID ? ch.owner : nil
        }
        let by = sinks.lazy.compactMap { state.sinkAttachedBy[$0.sinkID] }.first ?? owner
        let who = by.map { ChangeNote.author($0) } ?? "another client"
        return "The audio plays through \(who)."
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
        if Self.recording(on: ch, tuning: k, captureID: ch.captureID, in: state) { return nil }
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
    /// form; `Recordings.activeJob`) riding the window's capture or asking for its device. A
    /// job on another radio at the same frequency is not this channel's. `tuning` is the
    /// channel's frequency before a move took it out of the capture.
    static func recording(
        on channel: Leyline_V1_Channel, tuning: Kept?, captureID: String?, in state: MirrorState
    ) -> Bool {
        let borrowed = state.jobs.contains {
            $0.isActive && $0.recordConfig?.channelID == channel.channelID
        }
        if borrowed { return true }
        let hz =
            tuning.flatMap { $0.channelID == channel.channelID ? $0.hz : nil }
            ?? state.frequencyHz(of: channel)
        guard let hz else { return false }
        let capID = captureID ?? channel.captureID
        let device = state.capture(capID)?.deviceID
        let riding = Set(Recordings.jobs(riding: capID, in: state).map(\.jobID))
        let here = state.jobs.filter { j in
            riding.contains(j.jobID) || (device != nil && j.recordConfig?.deviceID == device)
        }
        return Recordings.activeJob(in: here, frequencyHz: hz, mode: channel.mode) != nil
    }
}

extension MirrorState {
    /// Whether a system-audio sink plays `channelID`, whoever attached it.
    public func plays(_ channelID: String) -> Bool {
        sinks(of: channelID).contains(where: \.isSystemAudio)
    }
}

extension Leyline_V1_Sink {
    /// Whether the daemon plays this sink through an audio output.
    public var isSystemAudio: Bool {
        if case .systemAudio? = kind { true } else { false }
    }
}
