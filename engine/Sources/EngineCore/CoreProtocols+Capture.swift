// SPDX-License-Identifier: GPL-3.0-or-later

// Part of the engine contract (CoreProtocols.swift): hand-written, never generated.
// The capture engine, its taps, and the configuration a channel is created from.

import Foundation

// MARK: - Capture engine

/// Owns one open device stream: the fan-out point for channels, the FFT ladder, and capture-level taps.
/// One device per capture (invariant 10). State transitions: created -> active -> (detached <-> active) -> stopped.
package protocol CaptureEngine: AnyObject, Sendable {
    var id: CaptureID { get }
    var deviceID: DeviceID { get }
    var snapshot: CaptureSnapshot { get async }
    var spectrum: any SpectrumLadder { get }

    /// Opens the device, starts streaming and the DSP thread. Establishes the anchor.
    func start() async throws
    /// Stops streaming, tears down channels and taps, closes the device.
    func stop() async

    func retune(centerHz: UInt64) async throws
    func setSampleRate(_ hz: UInt64) async throws
    func setGain(element: String, value: GainValue) async throws

    func addChannel(_ config: ChannelConfig) async throws -> any ChannelEngine
    func removeChannel(_ id: ChannelID) async
    func channel(id: ChannelID) async -> (any ChannelEngine)?
    var channels: [any ChannelEngine] { get async }

    /// Capture-level consumers of the full-rate cf32 stream (IQ recording, IQ bulk streams).
    func addTap(_ tap: any CaptureTap) async
    func removeTap(id: StreamID) async

    /// Enters .detached on device loss; channels pause without teardown.
    func deviceLost() async
    /// Rebinds automatically on matching-serial replug; resumes channels.
    func deviceRebound(_ device: any RadioDevice) async throws
}

package struct CaptureSnapshot: Hashable, Sendable {
    package var centerHz: UInt64
    package var sampleRate: UInt64
    package var detached: Bool
    package var anchor: CaptureAnchor
    package var gains: [GainState]

    package init(centerHz: UInt64, sampleRate: UInt64, detached: Bool, anchor: CaptureAnchor, gains: [GainState]) {
        self.centerHz = centerHz
        self.sampleRate = sampleRate
        self.detached = detached
        self.anchor = anchor
        self.gains = gains
    }
}

/// Receives the capture's full-rate stream as interleaved cf32. Hot path.
package protocol CaptureTap: AnyObject, Sendable {
    var id: StreamID { get }
    /// `iq` is interleaved cf32 (format == .cf32). Copy-or-consume; never block.
    func write(iq: SampleBuffer, at time: SampleTime)
    func closeTap() async
}

package struct ChannelConfig: Hashable, Sendable {
    /// Offset from capture center; absolute frequency = center + offset.
    package var offsetHz: Int64
    package var bandwidthHz: UInt32
    package var mode: DemodMode
    /// dBFS threshold; NaN = squelch off.
    package var squelchDB: Double
    package var agc: GainMode
    /// Survives owner disconnect; jobs set this.
    package var persistent: Bool
    /// Set by jobs: rebind target when OUT_OF_CAPTURE.
    package var requiredHz: UInt64?
    /// Watch for a sub-audible tone (CTCSS/PL). NFM only; ignored for every other mode. It never
    /// gates audio: tone squelch is a separate, later decision, because a false negative there is
    /// silence the user cannot diagnose.
    package var subAudibleDetect: Bool

    package init(offsetHz: Int64, bandwidthHz: UInt32, mode: DemodMode, squelchDB: Double = .nan,
                agc: GainMode = .auto, persistent: Bool = false, requiredHz: UInt64? = nil,
                subAudibleDetect: Bool = false) {
        self.offsetHz = offsetHz
        self.bandwidthHz = bandwidthHz
        self.mode = mode
        self.squelchDB = squelchDB
        self.agc = agc
        self.persistent = persistent
        self.requiredHz = requiredHz
        self.subAudibleDetect = subAudibleDetect
    }

    // NaN-aware equality so squelch-off compares equal to squelch-off.
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offsetHz == rhs.offsetHz && lhs.bandwidthHz == rhs.bandwidthHz && lhs.mode == rhs.mode
            && (lhs.squelchDB == rhs.squelchDB || (lhs.squelchDB.isNaN && rhs.squelchDB.isNaN))
            && lhs.agc == rhs.agc && lhs.persistent == rhs.persistent && lhs.requiredHz == rhs.requiredHz
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(offsetHz); hasher.combine(bandwidthHz); hasher.combine(mode)
        hasher.combine(squelchDB.isNaN ? 0 : squelchDB.bitPattern)
        hasher.combine(agc); hasher.combine(persistent); hasher.combine(requiredHz)
    }
}
