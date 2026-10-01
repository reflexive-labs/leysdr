// SPDX-License-Identifier: Apache-2.0

// The window's playback of a recorded part through the daemon's speakers, from `StartPlayback` to
// the playback's tombstone. One at a time: a new part stops the one playing. The live channel's
// sink is detached while a part plays, so the part is heard alone, and attached again after the
// last part only if it was attached before the first. Play all and Play day queue parts
// (`PlayQueue`) and start each on the tombstone of the one before, so the live channel is not
// heard in the gaps.
//
// A playback the mirror lists and then drops has ended. One the mirror never lists is ended after
// a deadline: a part so short that its tombstone was folded before `StartPlayback` answered is
// never seen, and a quiet daemon may send nothing else to say so.

import Foundation
import LeylineProto

/// The playback this window started, the part it plays and the parts queued after it. A value,
/// so the app's observable session stores it as one property and a view sees every change.
public struct PartPlayback: Sendable, Equatable {
    /// What `end` did.
    public enum Ending: Sendable, Equatable {
        /// The queue's next part, already `playingURI`, for the caller to start.
        case next(String)
        /// Nothing is queued: the caller attaches the live sink again if `takeReattach` says so.
        case finished
    }

    /// The id `StartPlayback` returned, until the playback's tombstone.
    public private(set) var playbackID: String?
    /// The part playing, or about to: set before `StartPlayback` answers, and held on the next
    /// part between two parts of a queue.
    public private(set) var playingURI: String?
    /// The start of the transmission log row whose ▶ started the part, so only that row shows ■
    /// and the progress line when several rows lie inside one part; nil when the part was
    /// started anywhere else.
    public private(set) var playingRowStart: Leyline_V1_SampleTime?
    /// Play all's or Play day's parts still to play.
    public var queue = PlayQueue()
    /// Whether the mirror has listed the playback.
    public private(set) var seen = false
    /// When `StartPlayback` answered, for the never-seen deadline.
    public private(set) var startedAt = Date.distantPast
    /// Whether the live sink was attached when the first part started.
    public private(set) var reattachAfterPlayback = false

    public init() {}

    /// Before `StartPlayback`: the id of the playback this window already has, cleared first so
    /// its tombstone is not read as the new one ending, for the caller to stop. With none and
    /// nothing playing, whether the live sink is attached now is remembered for the end.
    public mutating func replace(sinkAttached: Bool) -> String? {
        if let old = playbackID {
            playbackID = nil
            return old
        }
        if playingURI == nil { reattachAfterPlayback = sinkAttached }
        return nil
    }

    /// The part about to be asked for, and the log row that asked, if one did.
    public mutating func playing(_ uri: String, row: Leyline_V1_SampleTime?) {
        playingURI = uri
        playingRowStart = row
    }

    /// `StartPlayback` answered with `id`.
    public mutating func started(id: String, at now: Date) {
        playbackID = id
        seen = false
        startedAt = now
    }

    /// `StartPlayback` was refused: nothing plays, and the queue is dropped.
    public mutating func failed() {
        playingURI = nil
        playingRowStart = nil
        queue.clear()
    }

    /// Folds one mirror state: `listed` is whether it lists the playback. Returns the playback's
    /// id when it has ended, for the caller to pass to `end`.
    public mutating func observe(listed: Bool, now: Date, dropAfter seconds: TimeInterval)
        -> String?
    {
        guard let id = playbackID else { return nil }
        if listed {
            seen = true
            return nil
        }
        guard seen || now.timeIntervalSince(startedAt) > seconds else { return nil }
        return id
    }

    /// The playback `id` ended. The queue's next part becomes the one playing, with the live sink
    /// left detached; with none queued nothing plays. Nil when `id` is not this window's.
    public mutating func end(_ id: String) -> Ending? {
        guard playbackID == id else { return nil }
        playbackID = nil
        seen = false
        playingRowStart = nil
        if let next = queue.next() {
            playingURI = next
            return .next(next)
        }
        playingURI = nil
        return .finished
    }

    /// Whether the live sink goes back on after the last part, asked once.
    public mutating func takeReattach() -> Bool {
        defer { reattachAfterPlayback = false }
        return reattachAfterPlayback
    }
}
