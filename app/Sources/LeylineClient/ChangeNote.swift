// SPDX-License-Identifier: Apache-2.0

// Who changed the tuned channel last, and what they changed, as one sentence for the inspector:
// "The assistant set the squelch to -45 dBFS." Every event names the client that caused it
// (`Event.caused_by`, control.proto), and the mirror keeps, for each capture and channel, the
// newest event that moved a setting together with the object as it was before, because an event
// carries the whole object and never a delta (invariant 6): the change is a diff of the two
// copies, which is presentation and leaves the wire alone. The words are `ley`'s for the same diff
// (`go/internal/cli/change.go`), so a change reads the same in the app and in a terminal
// (`docs/design/ai.md`, "The assistant"), except that the assistant is named as itself rather
// than as "an agent".

import Foundation
import LeylineProto

/// One event that moved a setting on a capture or a channel, with the object before and after it
/// and the client that caused it. Kept by `MirrorState.changes` per object id.
public struct AttributedChange: Sendable, Equatable {
    public enum Object: Sendable, Equatable {
        case capture(before: Leyline_V1_Capture, after: Leyline_V1_Capture)
        case channel(before: Leyline_V1_Channel, after: Leyline_V1_Channel)
    }

    public var causedBy: Leyline_V1_ClientInfo
    /// The event's `seq`, which orders a capture's change against its channel's.
    public var seq: UInt64
    public var object: Object

    public init(causedBy: Leyline_V1_ClientInfo, seq: UInt64, object: Object) {
        self.causedBy = causedBy
        self.seq = seq
        self.object = object
    }

    /// The change an event makes to a capture, or nil when it moved no setting a listener could
    /// act on. The activity clock, which every interactive write stamps, is not one; keeping it
    /// would replace the squelch change the same write made a moment before.
    static func capture(
        _ before: Leyline_V1_Capture, _ after: Leyline_V1_Capture,
        causedBy: Leyline_V1_ClientInfo, seq: UInt64
    ) -> AttributedChange? {
        let moved =
            before.centerHz != after.centerHz || before.sampleRate != after.sampleRate
            || before.gains != after.gains
        guard moved else { return nil }
        return AttributedChange(
            causedBy: causedBy, seq: seq, object: .capture(before: before, after: after))
    }

    /// Whether the settings this change set are still the object's, so a note never names a
    /// value something since changed without saying who (the daemon's own events carry no
    /// author and are not kept as changes).
    func isCurrent(channel: Leyline_V1_Channel, capture: Leyline_V1_Capture?) -> Bool {
        switch object {
        case .channel(_, let after):
            return after.channelID == channel.channelID && after.offsetHz == channel.offsetHz
                && after.mode == channel.mode && after.bandwidthHz == channel.bandwidthHz
                && !ChangeNote.squelchMoved(after.squelchDb, channel.squelchDb)
        case .capture(_, let after):
            guard let capture else { return false }
            return after.captureID == capture.captureID && after.centerHz == capture.centerHz
                && after.sampleRate == capture.sampleRate && after.gains == capture.gains
        }
    }

    /// The change an event makes to a channel, or nil when no setting moved (a state change
    /// alone, such as `OUT_OF_CAPTURE`, is the inspector's own line).
    static func channel(
        _ before: Leyline_V1_Channel, _ after: Leyline_V1_Channel,
        causedBy: Leyline_V1_ClientInfo, seq: UInt64
    ) -> AttributedChange? {
        let moved =
            before.offsetHz != after.offsetHz || before.mode != after.mode
            || before.bandwidthHz != after.bandwidthHz
            || ChangeNote.squelchMoved(before.squelchDb, after.squelchDb)
        guard moved else { return nil }
        return AttributedChange(
            causedBy: causedBy, seq: seq, object: .channel(before: before, after: after))
    }
}

/// The inspector's line under the channel's parameters: the newest change to the tuned channel or
/// its radio, worded with its author, shown only when the author is another client.
public struct ChangeNote: Sendable, Equatable {
    /// "The assistant set the squelch to -45 dBFS."
    public let text: String
    /// "the assistant", "another terminal": who made the change, as the sentence names them.
    public let author: String

    /// The note for `channel`, or nil when nothing attributed has moved on it or its capture, or
    /// when the newest change was this client's own (`selfClientID`, `ClientIdentity.id`): a
    /// person does not need telling what they just did, and an older change by someone else is no
    /// longer what the channel shows.
    public static func latest(
        for channel: Leyline_V1_Channel, in state: MirrorState, selfClientID: String
    ) -> ChangeNote? {
        let capture = state.capture(channel.captureID)
        let candidates = [state.changes[channel.channelID], state.changes[channel.captureID]]
            .compactMap { $0 }
            .filter { $0.isCurrent(channel: channel, capture: capture) }
        guard let newest = candidates.max(by: { $0.seq < $1.seq }),
            newest.causedBy.clientID != selfClientID
        else { return nil }
        let what = phrases(newest.object, in: state)
        guard !what.isEmpty else { return nil }
        let who = author(newest.causedBy)
        return ChangeNote(text: capitalised(who) + " " + sentence(what) + ".", author: who)
    }

    /// A readable name for a client, as `ley` names them (`whoChanged` in
    /// `go/internal/cli/change.go`): the assistant's tool server, an MCP client labelled
    /// `assistant`, as itself, and the rest by kind.
    public static func author(_ client: Leyline_V1_ClientInfo) -> String {
        if client.kind == "mcp" && client.label == "assistant" { return "the assistant" }
        switch client.kind {
        case "cli": return "another terminal"
        case "app": return "the app"
        case "mcp": return "an agent"
        case "job": return "a job"
        case "daemon": return "the daemon"
        default: return client.label.isEmpty ? "another client" : client.label
        }
    }

    /// One field that moved, split at its verb so three of them read as one clause: "set the mode
    /// to AM, the width to 25.0 kHz and the squelch to -20 dBFS".
    struct Phrase: Equatable {
        let verb: String
        let what: String
    }

    static func phrases(_ object: AttributedChange.Object, in state: MirrorState) -> [Phrase] {
        switch object {
        case .channel(let was, let now):
            var out: [Phrase] = []
            if was.offsetHz != now.offsetHz, let hz = state.frequencyHz(of: now) {
                out.append(Phrase(verb: "moved", what: "this channel to \(hzWords(hz))"))
            }
            if was.mode != now.mode {
                out.append(Phrase(verb: "set", what: "the mode to \(now.mode.word)"))
            }
            if was.bandwidthHz != now.bandwidthHz {
                out.append(
                    Phrase(verb: "set", what: "the width to \(hzWords(UInt64(now.bandwidthHz)))"))
            }
            if squelchMoved(was.squelchDb, now.squelchDb) {
                out.append(
                    now.squelchDb.isNaN
                        ? Phrase(verb: "turned", what: "the squelch off")
                        : Phrase(verb: "set", what: "the squelch to \(dbfsWords(now.squelchDb))"))
            }
            return out
        case .capture(let was, let now):
            var out: [Phrase] = []
            if was.centerHz != now.centerHz {
                out.append(Phrase(verb: "retuned", what: "the radio to \(hzWords(now.centerHz))"))
            }
            if was.sampleRate != now.sampleRate {
                out.append(
                    Phrase(verb: "set", what: "the sample rate to \(hzWords(now.sampleRate))"))
            }
            if let g = gainWords(was.gains, now.gains) {
                out.append(Phrase(verb: "set", what: g))
            }
            return out
        }
    }

    /// The first gain stage that moved, with its name on a radio with several: "the gain to
    /// 30 dB", "the gain to LNA 16 dB", "the gain to auto".
    static func gainWords(_ was: [Leyline_V1_GainState], _ now: [Leyline_V1_GainState]) -> String? {
        for g in now {
            guard let p = was.first(where: { $0.element == g.element }),
                p.auto != g.auto || p.db != g.db
            else { continue }
            var level = g.auto ? "auto" : "\(dbWords(g.db)) dB"
            if now.count > 1 { level = "\(g.element) \(level)" }
            return "the gain to \(level)"
        }
        return nil
    }

    /// A gain with a decimal only when it has one, rounded to a tenth: "49.6", "8".
    static func dbWords(_ db: Double) -> String {
        guard db.isFinite else { return Reading.absent }
        let r = (db * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// A squelch as `ley` prints it, whole decibels: "-45 dBFS".
    static func dbfsWords(_ db: Double) -> String {
        guard db.isFinite else { return Reading.absent }
        return String(format: "%.0f dBFS", db)
    }

    /// The guide's frequency words: three decimals in MHz, four on an exact half-kilohertz
    /// (`BookmarkNaming.frequencyWords`).
    static func hzWords(_ hz: UInt64) -> String { BookmarkNaming.frequencyWords(hz) }

    /// NaN is off, and NaN never equals itself, so a plain comparison would report a change on
    /// every event of a channel with its squelch off.
    static func squelchMoved(_ was: Double, _ now: Double) -> Bool {
        if was.isNaN || now.isNaN { return was.isNaN != now.isNaN }
        return was != now
    }

    static func sentence(_ what: [Phrase]) -> String {
        var clauses: [String] = []
        var i = 0
        while i < what.count {
            var j = i
            var objects: [String] = []
            while j < what.count, what[j].verb == what[i].verb {
                objects.append(what[j].what)
                j += 1
            }
            clauses.append(what[i].verb + " " + andList(objects))
            i = j
        }
        return andList(clauses)
    }

    /// "a", "a and b", "a, b and c".
    static func andList(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts[0] + " and " + parts[1]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    static func capitalised(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }
}
