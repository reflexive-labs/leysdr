// SPDX-License-Identifier: Apache-2.0

// The transmissions log: one channel's squelch edges paired into transmissions, folded from the
// telemetry plane with no daemon and no clock in it (docs/plans/app.md, "The M2 cut", M2-1).
// The daemon summarises a transmission on the close edge of a `SquelchTransition` (its length
// in capture samples, the peaks it reached), so the log keeps the last ones without timing
// anything itself, and the tone under each is the CTCSS `SubAudible` reported while it ran. The
// rules are `ley tune`'s (`go/internal/cli/transmission.go`: a close edge with no duration, or
// one shorter than a quarter second, is ignored; `subaudible.go`: the 1 Hz heartbeat repeats a tone and is not a new one, and a tone's
// loss is not logged), and the start of a transmission whose open edge was never seen is read back
// from the close edge the way `listenSummary.apply` does (`go/internal/cli/mcp_tools.go`), so a
// client that subscribes mid-transmission still logs it. Every time here is a `SampleTime` on
// the capture's timeline (invariant 5); `SampleClock` turns one into a wall clock, when an
// anchor covers it.

import Foundation
import LeylineProto

/// A CTCSS tone the daemon classified: `standardHz` is the EIA tone it reported, `measuredHz`
/// what it measured. A measurement two standard tones could both explain is not a tone here,
/// because picking one would be a guess (`proto/leyline/v1/telemetry.proto`, `SubAudible`).
public struct CTCSSTone: Sendable, Equatable {
    public var standardHz: Double
    public var measuredHz: Double

    public init(standardHz: Double, measuredHz: Double) {
        self.standardHz = standardHz
        self.measuredHz = measuredHz
    }

    /// The tone a `SubAudible` reports, or nil: only CTCSS, and only when it was classified.
    public init?(_ sa: Leyline_V1_SubAudible) {
        guard sa.kind == .subAudibleCtcss, sa.standardToneHz > 0 else { return nil }
        self.init(standardHz: sa.standardToneHz, measuredHz: sa.toneHz)
    }
}

/// One closed transmission: when it began on the capture's timeline, how long it ran, how loud
/// it got, and the tone under it.
public struct Transmission: Sendable, Equatable {
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
    public var tone: CTCSSTone?
}

/// A transmission in progress: the open edge's time, and the tone reported so far.
public struct OnAir: Sendable, Equatable {
    public var since: Leyline_V1_SampleTime
    public var tone: CTCSSTone?
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

    public let channelID: String
    public private(set) var closed: [Transmission] = []
    public private(set) var onAir: OnAir?
    /// The capture rate the last edge was folded at; 0 until one has been.
    public private(set) var captureRate: UInt64 = 0
    /// The tone reported since the last edge, waiting for the close edge to attach it to.
    private var tone: CTCSSTone?

    public init(channelID: String) {
        self.channelID = channelID
    }

    /// Folds one message in. `captureRate` is the capture's sample rate, which is
    /// `duration_samples`' unit; 0 means unknown, which loses the duration and nothing else.
    public mutating func fold(_ msg: Leyline_V1_TelemetryMsg, captureRate: UInt64) {
        switch msg.body {
        case .squelch(let sq) where sq.channelID == channelID:
            self.captureRate = captureRate
            if sq.open {
                onAir = OnAir(since: msg.time, tone: nil)
                tone = nil
                return
            }
            let start = onAir?.since ?? reconstructedStart(closing: msg.time, after: sq)
            let toneSeen = onAir?.tone ?? tone
            onAir = nil
            tone = nil
            // No duration means nothing was measured: a channel whose squelch was off starts open
            // and closes on its first block under a threshold, and that is not a transmission.
            guard sq.durationSamples > 0 else { return }
            let seconds =
                captureRate > 0 ? Double(sq.durationSamples) / Double(captureRate) : Double.nan
            // An unknown rate keeps it: a length nobody can read is not a short one.
            guard seconds.isNaN || seconds >= Self.shortestSeconds else { return }
            closed.insert(
                Transmission(
                    start: start, end: msg.time, seconds: seconds, peakSNRDB: sq.peakSnrDb,
                    peakAudioDBFS: sq.peakAudioDbfs, tone: toneSeen),
                at: 0)
            if closed.count > Self.capacity { closed.removeLast(closed.count - Self.capacity) }
        case .subAudible(let sa) where sa.channelID == channelID:
            // A heartbeat repeats the tone and a loss changes nothing: the tone a transmission had
            // stays with it. Only a classified CTCSS report is a tone at all.
            guard let heard = CTCSSTone(sa) else { return }
            if onAir != nil {
                onAir?.tone = heard
            } else {
                tone = heard
            }
        default:
            return
        }
    }

    /// Seconds the open transmission has run at `now`, or nil when nothing is on air, `now` is
    /// on another timeline or before the open edge, or the rate is unknown.
    public func timeOnAir(at now: Leyline_V1_SampleTime) -> Double? {
        guard let onAir, captureRate > 0, now.captureID == onAir.since.captureID,
            now.sampleIndex >= onAir.since.sampleIndex
        else { return nil }
        return Double(now.sampleIndex - onAir.since.sampleIndex) / Double(captureRate)
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
