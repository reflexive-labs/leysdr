// SPDX-License-Identifier: Apache-2.0

// Wall clock from the sample timebase, through a `CaptureAnchor` and nothing else (AGENTS.md,
// invariant 5: no frame carries a wall-clock field, and a time nobody anchored is never
// invented). The Swift mirror of `go/pkg/leyline/decoders.go`, `AnchorWallTime` and
// `RecordWallTime`: an anchor maps one sample index on one capture to host time at the capture's
// rate, drift applied as the anchor states it because a dongle's crystal is the reason the field
// exists, and an anchor covers a sample only on its own capture, from the sample it applies
// from, and once it is dated: a capture carries an anchor with host time 0 until its first
// block (`engine/Sources/EngineCore/Capture/CaptureDSPCore.swift`, `currentAnchor`), and `ley
// tune` gives that one no clock either (`go/internal/cli/transmission.go`, `anchorCovers`). The
// result is nil where Go reports false.

import Foundation
import LeylineProto

public enum SampleClock {
    /// The host time of `sampleIndex` on the anchor's capture: the anchor's host time plus
    /// `sampleIndex / sample_rate` seconds scaled by `1 + drift_ppm / 1e6`. Nil without a rate.
    public static func wallTime(anchor: Leyline_V1_CaptureAnchor, sampleIndex: UInt64) -> Date? {
        guard anchor.sampleRate > 0 else { return nil }
        var seconds = Double(sampleIndex) / Double(anchor.sampleRate)
        if anchor.driftPpm != 0 { seconds *= 1 + anchor.driftPpm / 1e6 }
        // Whole and fractional nanoseconds apart: a Double holds about 2^53, and nanoseconds
        // since 1970 are past that.
        let whole = Double(anchor.hostTimeNs / 1_000_000_000)
        let fraction = Double(anchor.hostTimeNs % 1_000_000_000) / 1e9
        return Date(timeIntervalSince1970: whole + fraction + seconds)
    }

    /// The wall time of `time`, or nil when `anchor` does not cover it: another capture, a
    /// sample before `fromSample` (a `RecordAnchor`'s `from_sample`; 0 for the live anchor a
    /// capture carries, whose timeline continues across device epochs), an undated anchor, or
    /// no rate.
    public static func wallTime(
        of time: Leyline_V1_SampleTime, anchor: Leyline_V1_CaptureAnchor, fromSample: UInt64 = 0
    ) -> Date? {
        guard !time.captureID.isEmpty, time.captureID == anchor.captureID,
            fromSample <= time.sampleIndex, anchor.hostTimeNs != 0
        else { return nil }
        return wallTime(anchor: anchor, sampleIndex: time.sampleIndex)
    }
}
