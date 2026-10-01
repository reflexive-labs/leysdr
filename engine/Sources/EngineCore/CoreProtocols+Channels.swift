// SPDX-License-Identifier: GPL-3.0-or-later

// Part of the engine contract (CoreProtocols.swift): hand-written, never generated.
// Channels, demodulators and the spectrum ladder.

import Foundation

// MARK: - Channels & DSP

/// One demod chain inside a capture: translate -> filter -> demodulate -> distribute to sinks.
package protocol ChannelEngine: AnyObject, Sendable {
    var id: ChannelID { get }
    var captureID: CaptureID { get }
    var config: ChannelConfig { get async }
    var state: ChannelState { get async }
    /// Output audio rate in Hz, fixed by the capture rate and the decimation chain.
    var audioRate: UInt32 { get }

    func update(_ config: ChannelConfig) async throws
    func attach(_ sink: any AudioSink) async throws
    func detach(_ id: SinkID) async
    var sinks: [any AudioSink] { get async }

    /// OUT_OF_CAPTURE handling: pause without teardown when the capture retunes away; resume when it returns.
    func captureMoved(newCenterHz: UInt64) async

    /// Telemetry (meters at a fixed cadence, squelch transitions edge-triggered). Every subscriber gets
    /// every message from the moment of subscription; drop-oldest under backpressure (see
    /// `telemetryDropped`). The fan-out buffer behind the stream is drop-oldest too, and every record it
    /// discards because *this* subscriber fell behind is counted in `ChannelTelemetrySubscription.dropped`
    /// (diff it between records, like `telemetryDropped`).
    func telemetrySubscription() -> ChannelTelemetrySubscription
    /// Cumulative count of telemetry records the engine evicted (drop-oldest) before any subscriber
    /// could see them. Subscribers diff it between records to surface a sequence gap.
    var telemetryDropped: Int { get }
}

package enum ChannelState: Hashable, Sendable {
    case active
    case outOfCapture
}

package enum ChannelTelemetry: Sendable {
    /// `audioDBFS`/`audioPeakDBFS` are the audio output level over the meter interval, measured on
    /// the demodulated block; NaN when there is no audio to measure (a raw-IQ channel, or before the
    /// first block). NaN means "not measured" and is not the same as 0 dBFS, which is very loud.
    /// `deviationHz`/`freqErrorHz` are the FM discriminator's peak excursion and DC over the same
    /// interval, in hertz, read ahead of de-emphasis; the DC is the tuning error, positive when
    /// the transmitter sits above the channel. NaN for every other mode, and `freqErrorHz` NaN
    /// while the squelch is closed, because noise has no tuning error.
    case meter(time: SampleTime, powerDBFS: Double, snrDB: Double, squelchOpen: Bool,
               audioDBFS: Double, audioPeakDBFS: Double, deviationHz: Double, freqErrorHz: Double)
    /// A squelch edge. `openSamples` and the two peaks summarise the transmission that just ended
    /// and are meaningful on a close edge only (`open == false`); an open edge carries 0 and NaN,
    /// because a transmission still in progress has neither a duration nor a final peak.
    case squelch(time: SampleTime, open: Bool, openSamples: UInt64, peakSNRDB: Double, peakPowerDBFS: Double)
    /// A sub-audible tone, or the absence of one. Emitted only while the channel asked for it.
    case subAudible(time: SampleTime, result: SubAudibleResult)
}

/// A demodulator that can hand out its raw discriminator output, decimated to roughly 1 kHz, for
/// sub-audible tone detection.
///
/// The tap is set once when the channel is built and never changes for the life of the DSP core, so
/// the hot path reads a reference nobody is writing. Everything the tap does is decimation into a
/// ring; every decision about what the samples mean happens in a slow task draining it.
package protocol SubAudibleSource: AnyObject {
    /// Deviation in Hz that maps to ±1.0 in the discriminator output (5 kHz NFM, 75 kHz WFM).
    var fullScaleDeviationHz: Double { get }
    /// Where to write decimated discriminator output. nil (the default) costs the hot path a single
    /// nil check per block.
    var subAudibleTap: FloatRing? { get set }
    /// The rate `subAudibleTap` is written at. Zero until `configure`.
    var subAudibleRate: Double { get }
}

/// A demodulator stage. Implementations per DemodMode, all vDSP-backed on macOS.
/// `process` is the hot path: synchronous, allocation-free, called from the capture's DSP thread.
package protocol Demodulator: AnyObject {
    var mode: DemodMode { get }
    /// `inputRate` is the channel (post-decimation) rate; output audio rate equals `inputRate` unless
    /// `outputRate` says otherwise (WFM decimates internally).
    func configure(inputRate: UInt32, bandwidthHz: UInt32) throws
    var outputRate: UInt32 { get }
    /// Maximum input samples per call the demodulator's scratch is sized for.
    var maxBlock: Int { get }
    /// `input` is interleaved cf32 at `inputRate`; `output` is real f32 mono (format == .f32) with
    /// capacity `output.count` frames on entry. Returns frames produced (output.count is not mutated).
    ///
    /// `rawOut`, when non-nil, also receives the detector's own output for the same block: the
    /// stage before any audio conditioning, which is what a scope is for. It is real f32 mono at
    /// `outputRate` with capacity `rawOut.count` on entry, and the callee sets its `count` to the
    /// frames it wrote -- the audio frame count in every mode, but reported rather than assumed,
    /// because a mode whose raw stage has its own decimator answers for its own alignment. The raw
    /// stage per mode: the discriminator before the 300 Hz high-pass for NFM and, decimated to the
    /// audio rate, before de-emphasis and the 15 kHz low-pass for WFM (both scaled so full-scale
    /// deviation reads ±1.0); the envelope including the carrier as DC for AM; the product detector
    /// before AGC for USB, LSB and CW; nothing for raw IQ, which has no detector. A call that
    /// produces no audio reports zero raw frames too, so a scope never sees the block before it.
    ///
    /// Passing nil for `rawOut` costs one branch: everything the raw stage needs was sized in
    /// `configure`, so there is never an allocation.
    func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer, rawOut: inout SampleBuffer?) -> Int
    func reset()
}

package extension Demodulator {
    /// Audio alone, for the callers -- tests, one-shot conversions -- that have no raw tap to fill.
    func process(iq input: SampleBuffer, audioOut output: inout SampleBuffer) -> Int {
        var raw: SampleBuffer?
        return process(iq: input, audioOut: &output, rawOut: &raw)
    }
}

/// The shared FFT ladder: fixed power-of-two sizes, one pass per size per tick, fanned to all
/// subscribers. Subscribers get the nearest size the ladder computes and at most the rate they ask for.
package protocol SpectrumLadder: AnyObject, Sendable {
    /// Requested `bins`/`rowsPerSecond` may be downgraded, never upgraded; the returned subscription is authoritative.
    func subscribe(bins: Int, rowsPerSecond: Double, accumulation: SpectrumAccumulation,
                   policy: DeliveryPolicy, sink: any SpectrumSink) async -> SpectrumSubscription
    func cancel(_ subscription: SpectrumSubscription) async
}

/// How a spectrum row is built from the samples it covers.
package enum SpectrumAccumulation: Sendable, Hashable {
    /// One periodogram per row, from whichever block crossed the row boundary. At 2.4 MSPS a
    /// 1024-point FFT covers 0.17% of a 250 ms row, so a burst shorter than a row shows up only
    /// sometimes. Right for a live band chart, wrong for anything reading duty cycle.
    case snapshot
    /// Power mean over the looks taken in the row: a stable floor that dilutes short bursts.
    case mean
    /// Elementwise maximum over the looks: catches bursts, and reads the noise floor a few dB high
    /// because the maximum of N draws is biased upward.
    case max
}

package struct SpectrumSubscription: Hashable, Sendable {
    package var id: StreamID
    package var actualBins: Int
    package var actualRate: Double
    package var accumulation: SpectrumAccumulation
    /// Looks the ladder takes per row. Always 1 under `.snapshot`.
    package var looksPerRow: Int

    package init(id: StreamID, actualBins: Int, actualRate: Double,
                accumulation: SpectrumAccumulation = .snapshot, looksPerRow: Int = 1) {
        self.id = id
        self.actualBins = actualBins
        self.actualRate = actualRate
        self.accumulation = accumulation
        self.looksPerRow = looksPerRow
    }
}

/// Receives FFT rows. Hot path (DSP thread): copy-or-consume, never block.
package protocol SpectrumSink: AnyObject, Sendable {
    /// `row` is `bins` dBFS values, DC-centered (fft-shifted), lowest frequency first.
    ///
    /// `looks` is how many periodograms were averaged into this row: 1 under `.snapshot`, and
    /// under `.mean` however many blocks actually arrived during the row interval, which is not
    /// the subscription's `looksPerRow` (that is a cap). Anything doing statistics on a row needs
    /// it -- an averaged bin is Gamma-distributed with that shape, so a detector that assumes 16
    /// looks and gets 2 sets its threshold about 4 dB too low and calls noise a carrier.
    func write(row: UnsafeBufferPointer<Float>, at time: SampleTime, centerHz: UInt64, spanHz: UInt64, looks: Int)
}

package enum DeliveryPolicy: Hashable, Sendable {
    case latestWins
    case gapMarked
}
