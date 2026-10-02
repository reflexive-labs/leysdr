// SPDX-License-Identifier: Apache-2.0

package cli

import (
	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// Clipping comes in bursts of half a second to two seconds (a keyed handheld,
// an FM peak), and the daemon reports a CaptureLevel four times a second, so a
// line per reading repeats itself: a handheld a metre from a HackRF printed
// the clipping line seven times across one 9 s transmission, each with its own
// count. clipHold is the app's FailureHold
// (app/Sources/LeylineClient/FailureState.swift) for `ley tune`: clipping is
// raised after the fraction has been at or over clippingFloor for
// clipRaiseSeconds and cleared after it has been under clipExitFraction for
// clipClearSeconds, timed on the capture's clock from the readings'
// SampleTime and never the wall clock (AGENTS.md, invariant 5).

// clipRaiseSeconds is how long the fraction must stay at or over the floor
// before clipping is said.
const clipRaiseSeconds = 1

// clipClearSeconds is how long it must stay under the exit fraction before the
// state clears: longer than the raise, so a pause between two bursts does not
// clear and raise it again.
const clipClearSeconds = 2

// clipExitFraction is the fraction a raised state holds on to: half the
// floor, so a radio hovering at the edge does not raise and clear it four
// times a second. The app's FailureState.clippingExitFraction.
const clipExitFraction = clippingFloor / 2

// clipHold folds a capture's CaptureLevel readings into whether the radio is
// clipping. The zero value is clear, with no capture yet.
type clipHold struct {
	// shown is whether clipping has been raised and not yet cleared.
	shown bool
	// captureID is the capture the readings came from; a reading on another
	// capture starts again.
	captureID string
	// runStart is the first sample of the run of readings that would change
	// shown, valid while running is set.
	runStart uint64
	running  bool
}

// fold takes one reading and reports whether it raised clipping: true exactly
// once per raise, so the caller prints one line carrying this reading, and
// false while the state holds and when it clears. at is the reading's
// SampleTime (the end of its interval, as the daemon sends it) and rate the
// capture's sample rate; an empty interval or an unknown rate changes
// nothing, because neither can be timed.
func (h *clipHold) fold(level *leylinev1.CaptureLevel, at *leylinev1.SampleTime, rate uint64) bool {
	total := level.GetTotalSamples()
	if rate == 0 || total == 0 {
		return false
	}
	if at.GetCaptureId() != h.captureID {
		*h = clipHold{captureID: at.GetCaptureId()}
	}
	fraction := float64(level.GetClippedSamples()) / float64(total)
	over := fraction >= clippingFloor
	if h.shown {
		over = fraction >= clipExitFraction
	}
	if over == h.shown {
		h.running = false
		return false
	}
	end := at.GetSampleIndex()
	start := end - min(end, total)
	// The run is timed from the first interval's first sample, so four
	// quarter-second readings are one second; a reading from before the run's
	// start begins it again.
	from := start
	if h.running && h.runStart <= end {
		from = h.runStart
	}
	needed := float64(clipRaiseSeconds)
	if h.shown {
		needed = clipClearSeconds
	}
	if float64(end-from) >= needed*float64(rate) {
		h.shown = over
		h.running = false
		return h.shown
	}
	h.runStart, h.running = from, true
	return false
}
