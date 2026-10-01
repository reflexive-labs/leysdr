// SPDX-License-Identifier: GPL-3.0-or-later

// Part of the engine contract (CoreProtocols.swift): hand-written, never generated.
// Sinks: where a channel's audio goes.

import Foundation

// MARK: - Sinks

/// Where demodulated audio goes. Implementations: CoreAudioSink, StreamAudioSink (bulk plane),
/// FileRecorderSink, NullSink. Lossless delivery exists only in FileRecorderSink.
package protocol AudioSink: AnyObject, Sendable {
    var id: SinkID { get }
    /// Which stage of the channel's chain this sink is fed. Anything that plays or records audio
    /// takes `.audio`; `.demod` is the detector's output before conditioning, and a sink asking for
    /// it is refused on a raw-IQ channel, where there is no detector to tap.
    var tap: AudioTap { get }
    /// Hot path: synchronous, allocation-free. `audio` is real f32 mono (format == .f32).
    ///
    /// `time` is when the block this came from started at the capture, the same value for both
    /// taps of one block. It is not a claim that the taps are sample-aligned: WFM decimates its
    /// raw stage through a filter of its own, with its own reset point and group delay.
    func write(_ audio: SampleBuffer, at time: SampleTime)
    func flush() async
    func closeSink() async
}

package extension AudioSink {
    /// A sink that does not override `tap` receives `.audio`.
    var tap: AudioTap { .audio }
}

/// Which stage of a channel's chain a sink receives.
///
/// `.audio` is what a speaker gets: after the high-pass, de-emphasis, limiter and AGC, and zeros
/// while the squelch is closed. `.demod` is the detector's own output before any of that -- a
/// CTCSS tone under NFM voice, the carrier as DC under AM -- and it keeps flowing while the squelch
/// is closed. `AudioTap` in `bulk.proto` documents what that is for.
package enum AudioTap: Hashable, Sendable {
    case audio
    case demod
}
