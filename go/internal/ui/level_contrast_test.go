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

// The ramp has to be legible on the terminal the reader actually has, and we
// are forbidden from asking which one that is (no OSC background query, no
// HasDarkBackground). So every stop must clear the same bar against a black
// ground and a white one. The cold end needs this most: since most of a
// spectrum is noise floor and the noise floor is the cold end, a cold end
// that fails the bar makes most of the chart invisible.
func TestLevelRampIsLegibleOnBothGrounds(t *testing.T) {
	const min = 3.0 // WCAG AA for graphical objects
	black := relLuminance(0, 0, 0)
	white := relLuminance(255, 255, 255)
	dark := relLuminance(30, 30, 30) // #1e1e1e, a common terminal ground
	light := relLuminance(250, 250, 250)
	for i, c := range levelStops {
		l := relLuminance(c[0], c[1], c[2])
		for _, g := range []struct {
			name string
			lum  float64
		}{{"#000000", black}, {"#1e1e1e", dark}, {"#ffffff", white}, {"#fafafa", light}} {
			if got := contrast(l, g.lum); got < min {
				t.Errorf("ramp stop %d (%v) is %.2f:1 against %s, want at least %.1f:1",
					i, c, got, g.name, min)
			}
		}
	}
}

// The ramp must still read cold to hot: hue sweeps even though luminance is
// held flat, so the blue end must be bluer than the red end and vice versa.
func TestLevelRampSweepsColdToHot(t *testing.T) {
	cold, hot := levelStops[0], levelStops[len(levelStops)-1]
	if cold[2] <= cold[0] {
		t.Errorf("the cold end must be blue-dominant, got %v", cold)
	}
	if hot[0] <= hot[2] {
		t.Errorf("the hot end must be red-dominant, got %v", hot)
	}
}
