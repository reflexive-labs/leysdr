// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// clipReadings are quarter-second readings at 600 kS/s, as the daemon sends
// them: clipped samples of 150 000 in each, the time the interval's end. The
// cases are the app's FailureHold ones
// (app/Tests/LeylineClientTests/FailureStateTests.swift), so the two clients
// hold clipping to one rule.
type clipReadings struct {
	hold    clipHold
	end     uint64
	capture string
}

const (
	clipTestRate     = 600_000
	clipTestInterval = 150_000
)

// feed folds seconds of readings with clipped samples each and returns how
// many of them raised clipping.
func (r *clipReadings) feed(clipped uint64, seconds float64) int {
	if r.capture == "" {
		r.capture = "cap_a"
	}
	raised := 0
	for range int(seconds*clipTestRate/clipTestInterval + 0.5) {
		r.end += clipTestInterval
		level := &leylinev1.CaptureLevel{ClippedSamples: clipped, TotalSamples: clipTestInterval}
		at := &leylinev1.SampleTime{CaptureId: r.capture, SampleIndex: r.end}
		if r.hold.fold(level, at, clipTestRate) {
			raised++
		}
	}
	return raised
}

func TestClipHoldABurstUnderASecondIsNeverSaid(t *testing.T) {
	var r clipReadings
	if n := r.feed(0, 1) + r.feed(150, 0.5) + r.feed(0, 3); n != 0 {
		t.Errorf("a half-second burst raised clipping %d times", n)
	}
}

func TestClipHoldASecondOfClippingIsSaidOnce(t *testing.T) {
	var r clipReadings
	if n := r.feed(150, 0.75); n != 0 {
		t.Fatalf("raised %d times before the second", n)
	}
	if n := r.feed(150, 0.25); n != 1 {
		t.Fatalf("a second of clipping raised it %d times, want once", n)
	}
	if n := r.feed(300, 5); n != 0 || !r.hold.shown {
		t.Errorf("a run that goes on raised it %d more times (shown %v)", n, r.hold.shown)
	}
}

func TestClipHoldAGapUnderTwoSecondsDoesNotClear(t *testing.T) {
	var r clipReadings
	r.feed(150, 1)
	r.feed(0, 1)
	if n := r.feed(150, 0.25); n != 0 || !r.hold.shown {
		t.Fatalf("a second's gap inside a run cleared it (raised %d, shown %v)", n, r.hold.shown)
	}
	r.feed(0, 1.75)
	if !r.hold.shown {
		t.Fatal("cleared before two seconds")
	}
	r.feed(0, 0.25)
	if r.hold.shown {
		t.Fatal("two seconds clean did not clear it")
	}
	if n := r.feed(150, 1); n != 1 {
		t.Errorf("a raise after a clear was said %d times, want once", n)
	}
}

func TestClipHoldTheExitFractionStillHolds(t *testing.T) {
	var r clipReadings
	r.feed(150, 1)
	// 10 in 150 000 is under the floor (15) and over the exit fraction (7.5): still clipping.
	r.feed(10, 3)
	if !r.hold.shown {
		t.Fatal("a reading over the exit fraction cleared the state")
	}
	untimed := r.hold.fold(&leylinev1.CaptureLevel{TotalSamples: clipTestInterval},
		&leylinev1.SampleTime{CaptureId: "cap_a", SampleIndex: r.end + 600_000}, 0)
	if untimed || !r.hold.shown {
		t.Error("an unknown rate changed the state")
	}
}

func TestClipHoldAnotherCaptureStartsAgain(t *testing.T) {
	var r clipReadings
	r.feed(150, 1)
	r.capture = "cap_b"
	if n := r.feed(150, 0.75); n != 0 || r.hold.shown {
		t.Fatalf("the hold carried over to the new capture (raised %d, shown %v)", n, r.hold.shown)
	}
	if n := r.feed(150, 0.25); n != 1 {
		t.Errorf("a second on the new capture raised it %d times, want once", n)
	}
}
