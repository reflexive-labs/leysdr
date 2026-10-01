// SPDX-License-Identifier: GPL-3.0-or-later

// Leyline engine — internal protocol surface. Hand-designed and never generated.
// The wire contract (leyline.v1 protos, target LeylineProto) is a separate artifact; the daemon
// target maps between the two. EngineCore never imports LeylineProto.
//
// This file and its CoreProtocols+*.swift siblings (devices, capture, channels, sinks, jobs) are the
// engine's contract. The concrete model types it references live in
// Model.swift, Identifiers.swift and Buffers.swift. Threading and ownership rules are in
// docs/dev/engine-internals.md — read that before implementing anything here.
//
// Hot-path conventions (AGENTS.md invariant 4):
//   - Sample buffers are engine-owned, preallocated, and reused. No allocation in process paths.
//   - `SampleBuffer` wraps raw memory + count + format; it is a borrow, never an owner, inside
//     processing calls. It never escapes the call it is passed to.
//   - Anything marked "hot path" is synchronous, allocation-free and non-async, and never holds a
//     lock across a call. It is invoked from the capture's DSP thread (or the device I/O thread
//     for `RadioDevice` delivery). It is not lock-free: it copies the channel and tap tables under
//     a lock once per block, and the wake-up poke to a drain task (`AsyncStream.Continuation.yield`)
//     takes the stream's short internal lock (docs/dev/engine-internals.md, "Hot-path rules").

import Foundation

// MARK: - Timebase

/// Sample-indexed time within one timeline. The engine's only clock in signal paths.
/// `captureID` scopes the timeline; comparison is only meaningful within one timeline.
package struct SampleTime: Hashable, Comparable, Sendable {
    package var captureID: CaptureID
    package var sampleIndex: UInt64

    package init(captureID: CaptureID, sampleIndex: UInt64) {
        self.captureID = captureID
        self.sampleIndex = sampleIndex
    }

    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.sampleIndex < rhs.sampleIndex }
}

/// One per capture: maps sample 0 to host time. Wall clock is derived from this, never carried per-frame.
package struct CaptureAnchor: Hashable, Sendable {
    /// CLOCK_REALTIME nanoseconds at sample index 0.
    package var hostTimeNsAtSampleZero: Int64
    package var sampleRate: UInt64
    /// Measured drift; 0 if unknown.
    package var driftPPM: Double

    package init(hostTimeNsAtSampleZero: Int64, sampleRate: UInt64, driftPPM: Double = 0) {
        self.hostTimeNsAtSampleZero = hostTimeNsAtSampleZero
        self.sampleRate = sampleRate
        self.driftPPM = driftPPM
    }

    /// Derived wall clock for a sample index on this anchor's timeline.
    package func hostTimeNs(at sampleIndex: UInt64) -> Int64 {
        guard sampleRate > 0 else { return hostTimeNsAtSampleZero }
        let ns = (Double(sampleIndex) / Double(sampleRate)) * 1e9 * (1 + driftPPM * 1e-6)
        return hostTimeNsAtSampleZero + Int64(ns)
    }
}
