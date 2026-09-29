// SPDX-License-Identifier: Apache-2.0

// The transmissions log: one channel's squelch edges paired into transmissions, folded from the
// telemetry plane with no daemon and no clock in it (docs/plans/app.md, "The M2 cut", M2-1).
// The daemon summarises a transmission on the close edge of a `SquelchTransition` (its length
// in capture samples, the peaks it reached), so the log keeps the last ones without timing
// anything itself, and the tone under each is the CTCSS tone or DCS code `SubAudible` reported
// while it ran. The rules are `ley tune`'s (`go/internal/cli/transmission.go`: a close edge
// with no duration, or one shorter than a quarter second, is ignored; `subaudible.go`: the 1 Hz
// heartbeat repeats a tone and is not a new one, and a tone's
// loss is not logged), and the start of a transmission whose open edge was never seen is read back
// from the close edge the way `listenSummary.apply` does (`go/internal/cli/mcp_tools.go`), so a
// client that subscribes mid-transmission still logs it. A recording's switch going on or off
// cuts the open transmission in two at that moment, a manual marker (`TransmissionLog.mark`), so
// a continuous carrier's rows start and end where its recording's parts do. Every time here is a `SampleTime` on
// the capture's timeline (invariant 5); `SampleClock` turns one into a wall clock, when an
// anchor covers it. The window keeps one log per frequency and mode for the session
// (`TransmissionLogs`), so a retune switches logs rather than emptying one.

import Foundation
import LeylineProto

/// The sub-audible signalling the daemon reported under a transmission: a CTCSS tone or a DCS
/// code (`proto/leyline/v1/telemetry.proto`, `SubAudible`).
public enum SubAudibleTone: Sendable, Equatable {
    /// `standardHz` is the EIA tone the daemon classified, `measuredHz` what it measured.
    case ctcss(standardHz: Double, measuredHz: Double)
    /// `code` is octal written as decimal, as the wire carries it (023 is 23). `inverted` is
    /// false on every report today: the daemon names an inverted code by its normal alias.
    case dcs(code: Int, inverted: Bool)

    /// The tone a `SubAudible` reports, or nil. A CTCSS measurement two standard tones could
    /// both explain is not a tone here, because picking one would be a guess; a DCS report is a
    /// code only when it names one, since `dcs_code` is 0 for every other kind.
    public init?(_ sa: Leyline_V1_SubAudible) {
        switch sa.kind {
        case .subAudibleCtcss where sa.standardToneHz > 0:
            self = .ctcss(standardHz: sa.standardToneHz, measuredHz: sa.toneHz)
        case .subAudibleDcs where sa.dcsCode > 0:
            self = .dcs(code: Int(sa.dcsCode), inverted: sa.dcsInverted)
        default:
            return nil
        }
    }

    /// `PL 100.0`, or `DCS 023` (three octal digits) with ` inverted` when the code was read
    /// from the complemented stream: `ley tune`'s words.
    public var words: String {
        switch self {
        case .ctcss(let standardHz, _):
            return String(format: "PL %.1f", standardHz)
        case .dcs(let code, let inverted):
            return String(format: "DCS %03d", code) + (inverted ? " inverted" : "")
        }
    }
}

/// One closed transmission: when it began on the capture's timeline, how long it ran, how loud
/// it got, the tone under it, and whether a recording's switch cut it.
public struct Transmission: Sendable, Equatable {
    /// A manual marker: a record job on the log's frequency started or ended while a
    /// transmission was on air, and cut it in two there (`TransmissionLog.mark`).
    public enum Marker: Sendable, Equatable {
        case recordingOn, recordingOff
    }

    /// The open edge's time; for a close edge with no open edge seen, the close time less the
    /// duration.
    public var start: Leyline_V1_SampleTime
    /// The close edge's time.
    public var end: Leyline_V1_SampleTime
    /// Seconds at the capture rate; NaN when the rate was unknown when the edge arrived.
    public var seconds: Double
    /// dB over the noise floor; NaN before the meter warms up.
    public var peakSNRDB: Double
    public var peakAudioDBFS: Double
    public var tone: SubAudibleTone?
    /// The marker that began it, when a recording's switch cut the one before it; nil when the
    /// squelch opened it.
    public var startMarker: Marker? = nil
    /// The marker that ended it, when a recording's switch cut it; nil when the squelch closed it.
    public var endMarker: Marker? = nil
}

/// A transmission in progress: the open edge's time (or the cut's, after a marker), the tone
/// reported so far, and the loudest meter readings since it began, which is what a cut piece's
/// peaks are: the daemon's peaks come on the close edge only, and cover the whole opening.
public struct OnAir: Sendable, Equatable {
    public var since: Leyline_V1_SampleTime
    public var tone: SubAudibleTone?
    /// The marker that began it; nil when an open edge did.
    public var startMarker: Transmission.Marker? = nil
    /// The highest `snr_db` and `audio_dbfs` of this channel's meters while on air; nil before a
    /// meter that measured one.
    public var peakSNRDB: Double? = nil
    public var peakAudioDBFS: Double? = nil

    /// Folds one meter's readings into the peaks; NaN is a reading nobody measured and is skipped.
    mutating func meter(_ m: Leyline_V1_Meter) {
        if !m.snrDb.isNaN { peakSNRDB = max(peakSNRDB ?? m.snrDb, m.snrDb) }
        if !m.audioDbfs.isNaN { peakAudioDBFS = max(peakAudioDBFS ?? m.audioDbfs, m.audioDbfs) }
    }
}

/// The last `capacity` closed transmissions on one channel, newest first, and the open one.
/// A value: feed it every telemetry message and read it; messages for other channels and other
/// types are ignored, so one subscription can feed a log per channel.
public struct TransmissionLog: Sendable, Equatable {
    /// How many closed transmissions are kept. A listener scans the last few minutes of a
    /// repeater; fifty is more than a screen shows and less than a day's traffic.
    public static let capacity = 50
    /// The shortest squelch opening that is logged: a squelch set near the floor opens on noise
    /// for a block or two at a time, and a log of 0.0 s rows buries the transmissions. A
    /// kerchunk runs longer. `ley tune`'s `shortestTransmissionSeconds`.
    public static let shortestSeconds = 0.25

    /// The channel whose edges are folded. A log kept for a frequency (`TransmissionLogs`) is
    /// handed to the next channel tuned there, which is why it can change.
    public private(set) var channelID: String
    public private(set) var closed: [Transmission] = []
    public private(set) var onAir: OnAir?
    /// The capture rate the last edge was folded at; 0 until one has been.
    public private(set) var captureRate: UInt64 = 0
    /// The tone reported since the last edge, waiting for the close edge to attach it to.
    private var tone: SubAudibleTone?
    /// Whether the squelch is open as far as this log can tell: the last edge's, or a newer
    /// meter's `squelch_open`. A carrier that held the squelch open before the log was listening
    /// sends no open edge, and a channel whose squelch is off is open from the start with none
    /// either, so only a meter tells a cut there is something on air to cut.
    private var squelchOpen = false

    public init(channelID: String) {
        self.channelID = channelID
    }

    /// Folds one message in. `captureRate` is the capture's sample rate, which is
    /// `duration_samples`' unit; 0 means unknown, which loses the duration and nothing else.
    public mutating func fold(_ msg: Leyline_V1_TelemetryMsg, captureRate: UInt64) {
        switch msg.body {
        case .squelch(let sq) where sq.channelID == channelID:
            self.captureRate = captureRate
            squelchOpen = sq.open
            if sq.open {
                onAir = OnAir(since: msg.time, tone: nil)
                tone = nil
                return
            }
            let was = onAir
            let start = was?.since ?? reconstructedStart(closing: msg.time, after: sq)
            let toneSeen = was?.tone ?? tone
            onAir = nil
            tone = nil
            // No duration means nothing was measured: a channel whose squelch was off starts open
            // and closes on its first block under a threshold, and that is not a transmission.
            guard sq.durationSamples > 0 else { return }
            guard let marker = was?.startMarker else {
                let length =
                    captureRate > 0 ? Double(sq.durationSamples) / Double(captureRate) : Double.nan
                insert(
                    Transmission(
                        start: start, end: msg.time, seconds: length, peakSNRDB: sq.peakSnrDb,
                        peakAudioDBFS: sq.peakAudioDbfs, tone: toneSeen))
                return
            }
            // The piece after a cut: the daemon's duration and peaks cover the whole opening,
            // the part before the cut too, so the piece's own are measured from the cut.
            insert(
                Transmission(
                    start: start, end: msg.time, seconds: seconds(from: start, to: msg.time),
                    peakSNRDB: was?.peakSNRDB ?? sq.peakSnrDb,
                    peakAudioDBFS: was?.peakAudioDBFS ?? sq.peakAudioDbfs, tone: toneSeen,
                    startMarker: marker))
        case .meter(let m) where m.channelID == channelID:
            squelchOpen = m.squelchOpen
            onAir?.meter(m)
        case .subAudible(let sa) where sa.channelID == channelID:
            // A heartbeat repeats the tone and a loss changes nothing: the tone a transmission had
            // stays with it. Only a classified CTCSS tone or a DCS code is a tone at all, and a
            // different one replaces it, the newest winning.
            guard let heard = SubAudibleTone(sa) else { return }
            if onAir != nil {
                onAir?.tone = heard
            } else {
                tone = heard
            }
        default:
            return
        }
    }

    /// A recording's switch on this frequency went on or off at `time` (docs/dev/app.md,
    /// "Transmissions and the clock"): the open transmission closes there, as long as it ran,
    /// with the peaks its meters reached and its tone, and a new one opens at the cut with no
    /// tone yet, since the squelch is still open and the tone was reported for the stream before.
    /// A continuous carrier holds the squelch open for as long as it is on the air, so without
    /// the cut its one transmission began before the recording and never ended, and no part
    /// could hold it. A squelch the meters say is open with no open edge seen (a carrier on air
    /// before the log was listening, a channel with its squelch off) has nothing to close, and
    /// the cut only opens the new one. With the squelch closed there is nothing to cut, and a
    /// cut on another timeline or before the transmission began is not one either. A piece
    /// shorter than `shortestSeconds` is dropped like any other opening. Returns whether it cut.
    @discardableResult
    public mutating func mark(
        _ marker: Transmission.Marker, at time: Leyline_V1_SampleTime, captureRate: UInt64
    ) -> Bool {
        if let was = onAir {
            guard time.captureID == was.since.captureID,
                time.sampleIndex >= was.since.sampleIndex
            else { return false }
            if captureRate > 0 { self.captureRate = captureRate }
            insert(
                Transmission(
                    start: was.since, end: time, seconds: seconds(from: was.since, to: time),
                    peakSNRDB: was.peakSNRDB ?? .nan, peakAudioDBFS: was.peakAudioDBFS ?? .nan,
                    tone: was.tone, startMarker: was.startMarker, endMarker: marker))
        } else {
            guard squelchOpen else { return false }
            if captureRate > 0 { self.captureRate = captureRate }
        }
        onAir = OnAir(since: time, tone: nil, startMarker: marker)
        tone = nil
        return true
    }

    /// Logs `t` newest first, unless it is shorter than `shortestSeconds`, keeping `capacity`.
    private mutating func insert(_ t: Transmission) {
        // An unknown rate keeps it: a length nobody can read is not a short one.
        guard t.seconds.isNaN || t.seconds >= Self.shortestSeconds else { return }
        closed.insert(t, at: 0)
        if closed.count > Self.capacity { closed.removeLast(closed.count - Self.capacity) }
    }

    /// Seconds between two times on one timeline at the last rate folded; NaN when it is unknown.
    private func seconds(from start: Leyline_V1_SampleTime, to end: Leyline_V1_SampleTime)
        -> Double
    {
        guard captureRate > 0 else { return .nan }
        return Double(end.sampleIndex - min(end.sampleIndex, start.sampleIndex))
            / Double(captureRate)
    }

    /// Drops the open transmission without logging it: its close edge will never reach this log,
    /// because the log's subscription ended or it now folds another channel.
    mutating func endUnheard() {
        onAir = nil
        tone = nil
        squelchOpen = false
    }

    /// Folds `channelID`'s edges from now on. The open transmission belonged to the old channel,
    /// whose close edge the new one's subscription does not carry, so it is dropped.
    mutating func rebind(channelID: String) {
        guard channelID != self.channelID else { return }
        self.channelID = channelID
        endUnheard()
    }

    /// Seconds the open transmission has run at `now`, or nil when nothing is on air, `now` is
    /// on another timeline or before the open edge, or the rate is unknown.
    public func timeOnAir(at now: Leyline_V1_SampleTime) -> Double? {
        guard let onAir, captureRate > 0, now.captureID == onAir.since.captureID,
            now.sampleIndex >= onAir.since.sampleIndex
        else { return nil }
        return Double(now.sampleIndex - onAir.since.sampleIndex) / Double(captureRate)
    }

    /// The tone the inspector shows as heard beside a bookmark's own (docs/design/channels.md,
    /// "Bookmarks gain three fields"): the open transmission's once it has reported one, else
    /// the newest tone among the transmissions closed at or after `since`, the time of the
    /// tune's first message on this capture's clock. A log is kept per frequency across tunes,
    /// so a tone heard there an hour ago is not "heard" now; nil `since` is a tune no message
    /// has followed yet, and only the open transmission can answer. A transmission closed on
    /// another capture's clock was heard before this capture existed.
    public func heardTone(since: Leyline_V1_SampleTime?) -> SubAudibleTone? {
        if let tone = onAir?.tone { return tone }
        guard let since else { return nil }
        return closed.first {
            $0.tone != nil && $0.end.captureID == since.captureID
                && $0.end.sampleIndex >= since.sampleIndex
        }?.tone
    }

    /// The start of a transmission whose open edge arrived before this log was listening: the
    /// close time less the duration, floored at the timeline's start.
    private func reconstructedStart(
        closing end: Leyline_V1_SampleTime, after sq: Leyline_V1_SquelchTransition
    ) -> Leyline_V1_SampleTime {
        var start = end
        start.sampleIndex = end.sampleIndex - min(end.sampleIndex, sq.durationSamples)
        return start
    }
}

/// Tells a retune of a channel from a move of its capture, so the window can switch to the
/// transmission log of the channel's new frequency (`TransmissionLogs`): a log is the
/// transmissions heard on one frequency, and one from before a retune was not heard on this
/// (plans/app.md, APP-5, "Fixed 2026-09-25" and "Fixed 2026-09-25 (second run)"). A channel
/// follows its absolute frequency when its capture moves, and the daemon publishes the capture
/// before the channel's recomputed offset, so the mirror passes through the new centre with the
/// old offset for one event. The frequency is therefore read only when the channel's own offset
/// changes, which is after the daemon has published both.
public struct ChannelFrequencyWatch: Sendable, Equatable {
    /// The channel's absolute frequency as last read; nil until the first.
    public private(set) var tunedHz: UInt64?
    private var offsetHz: Int64?

    public init() {}

    /// Folds the mirror's current offset for the channel and its capture's centre. Returns true
    /// when the channel's frequency changed from one it already had.
    public mutating func observe(offsetHz: Int64, centerHz: UInt64?) -> Bool {
        guard offsetHz != self.offsetHz, let centerHz else { return false }
        self.offsetHz = offsetHz
        let hz = Int64(centerHz) + offsetHz
        // Below 0 Hz is not a frequency (`MirrorState.frequencyHz(of:)`), and not a retune either.
        guard hz >= 0 else { return false }
        defer { tunedHz = UInt64(hz) }
        guard let before = tunedHz else { return false }
        return UInt64(hz) != before
    }
}

/// The window's transmission logs, one per frequency and mode tuned this session, so switching
/// channel and back keeps what was heard there (plans/app.md, APP-5, "Fixed 2026-09-25 (second
/// run)"). Until then the log started over on every retune and the owner lost the history.
/// Edges fold into the current log only. A retune closes the open transmission in the daemon
/// (docs/dev/engine-internals.md, "Squelch and meters"), but that close arrives on the telemetry
/// stream and the retune on the event stream, so it can reach the window after the log has
/// switched. A log left on air therefore waits for the next squelch edge: the daemon sends one
/// close per retune off an open squelch, in order and before any edge at the new frequency, so
/// the logs left waiting take the close edges in the order they were left. An open edge while
/// one waits means the daemon sent no close, and every waiting transmission is dropped rather
/// than left running.
public struct TransmissionLogs: Sendable, Equatable {
    /// How many frequencies keep a log; the least recently tuned goes first. A session that
    /// walks a band's channels one by one tunes more than this, and the oldest of them is the
    /// one least likely to be tuned again.
    public static let capacity = 32

    /// A channel by frequency and mode, the shape a recording's channel has (`RecordingChannel`).
    public struct Key: Sendable, Hashable {
        public var frequencyHz: UInt64
        public var mode: Leyline_V1_DemodMode

        public init(frequencyHz: UInt64, mode: Leyline_V1_DemodMode) {
            self.frequencyHz = frequencyHz
            self.mode = mode
        }
    }

    private var logs: [Key: TransmissionLog] = [:]
    /// Least recently tuned first.
    private var order: [Key] = []
    /// The log edges fold into and the inspector shows; nil with no channel.
    public private(set) var current: Key?
    /// The logs switched away from while their transmission was open, oldest first, each
    /// waiting for its close edge.
    private var waiting: [Key] = []

    public init() {}

    /// The current log.
    public var log: TransmissionLog? { current.flatMap { logs[$0] } }

    /// The log kept for `key`, current or not.
    public func log(for key: Key) -> TransmissionLog? { logs[key] }

    public var count: Int { logs.count }

    /// Makes `key`'s log current, creating it if this frequency and mode are new, for
    /// `channelID`'s edges. Returns whether the current log changed.
    @discardableResult
    public mutating func tune(_ key: Key, channelID: String) -> Bool {
        if current == key, logs[key]?.channelID == channelID { return false }
        if let c = current, let old = logs[c] {
            if old.channelID != channelID {
                // The new channel's subscription carries none of the old one's edges.
                endWaiting()
                logs[c]?.endUnheard()
            } else if c != key, old.onAir != nil, !waiting.contains(c) {
                waiting.append(c)
            }
        }
        var log = logs[key] ?? TransmissionLog(channelID: channelID)
        log.rebind(channelID: channelID)
        logs[key] = log
        order.removeAll { $0 == key }
        order.append(key)
        current = key
        while order.count > Self.capacity {
            let dropped = order.removeFirst()
            logs[dropped] = nil
            waiting.removeAll { $0 == dropped }
        }
        return true
    }

    /// No channel, or the subscription ended: nothing is current, and no close edge will reach
    /// any open transmission, so each is dropped. The logs are kept.
    public mutating func leave() {
        endWaiting()
        if let c = current { logs[c]?.endUnheard() }
        current = nil
    }

    /// Folds one message into the current log, after giving a close edge to the oldest log
    /// waiting for one.
    public mutating func fold(_ msg: Leyline_V1_TelemetryMsg, captureRate: UInt64) {
        // In place through the dictionary's subscript, so a meter ten times a second copies
        // nothing.
        if case .squelch(let sq)? = msg.body, let first = waiting.first,
            logs[first]?.channelID == sq.channelID
        {
            if !sq.open {
                waiting.removeFirst()
                logs[first]?.fold(msg, captureRate: captureRate)
                return
            }
            endWaiting()
        }
        guard let c = current else { return }
        logs[c]?.fold(msg, captureRate: captureRate)
    }

    /// A recording's switch on the current log's frequency went on or off at `time`: the current
    /// log's open transmission is cut there (`TransmissionLog.mark`). Returns whether it cut.
    @discardableResult
    public mutating func mark(
        _ marker: Transmission.Marker, at time: Leyline_V1_SampleTime, captureRate: UInt64
    ) -> Bool {
        guard let c = current else { return false }
        return logs[c]?.mark(marker, at: time, captureRate: captureRate) ?? false
    }

    /// Every waiting transmission dropped, except the current log's own: it is still on air here.
    private mutating func endWaiting() {
        for k in waiting where k != current { logs[k]?.endUnheard() }
        waiting = []
    }
}
