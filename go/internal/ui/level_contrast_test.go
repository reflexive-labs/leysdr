// SPDX-License-Identifier: Apache-2.0

package ui

import (
	"math"
	"testing"
)

// relLuminance is the WCAG relative luminance of an sRGB colour.
func relLuminance(r, g, b float64) float64 {
	lin := func(c float64) float64 {
		c /= 255
		if c <= 0.04045 {
			return c / 12.92
		}
		return math.Pow((c+0.055)/1.055, 2.4)
	}
	return 0.2126*lin(r) + 0.7152*lin(g) + 0.0722*lin(b)
}

func contrast(a, b float64) float64 {
	hi, lo := math.Max(a, b), math.Min(a, b)
	return (hi + 0.05) / (lo + 0.05)
}

// The ramp is tuned for a dark terminal, and ley is
// forbidden from asking which ground the reader has (no OSC background
// query, no HasDarkBackground). So the test holds two bars, not one: every
// stop clears WCAG AA for graphical objects against a black ground and
// against #1e1e1e, and no stop falls under a lower floor against white, so a
// light terminal reads faint rather than blank. The cold end matters most:
// most of a spectrum is noise floor and the noise floor is the cold end, so
// a cold end that vanishes hides most of the chart. An early {0,0,160} did
// exactly that on a dark ground at 1.2:1.
func TestLevelRampIsLegibleOnBothGrounds(t *testing.T) {
	const minDark = 3.0  // WCAG AA for graphical objects
	const minLight = 2.4 // faint, never invisible; the accepted cost
	grounds := []struct {
		name string
		lum  float64
		min  float64
	}{
		{"#000000", relLuminance(0, 0, 0), minDark},
		{"#1e1e1e", relLuminance(30, 30, 30), minDark}, // a common terminal ground
		{"#ffffff", relLuminance(255, 255, 255), minLight},
		{"#fafafa", relLuminance(250, 250, 250), minLight},
	}
	for i, c := range levelStops {
		l := relLuminance(c[0], c[1], c[2])
		for _, g := range grounds {
			got := contrast(l, g.lum)
			t.Logf("stop %d %v against %s: %.2f:1", i, c, g.name, got)
			if got < g.min {
				t.Errorf("ramp stop %d (%v) is %.2f:1 against %s, want at least %.1f:1",
					i, c, got, g.name, g.min)
			}
		}
	}
}

// The ramp must read cold to hot: the teal end must be bluer than the red
// end and vice versa.
func TestLevelRampSweepsColdToHot(t *testing.T) {
	cold, hot := levelStops[0], levelStops[len(levelStops)-1]
	if cold[2] <= cold[0] {
		t.Errorf("the cold end must be blue-dominant, got %v", cold)
	}
	if hot[0] <= hot[2] {
		t.Errorf("the hot end must be red-dominant, got %v", hot)
	}
}
