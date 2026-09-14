// SPDX-License-Identifier: Apache-2.0

package ui

import (
	"fmt"
	"math"
	"strings"
	"testing"
)

// rampRGB renders one sample of the ramp at truecolor depth and returns the
// RGB the terminal would be asked for.
func rampRGB(t *testing.T, frac float64) (r, g, b int) {
	t.Helper()
	s := Style{Color: true, Profile: ProfileTrueColor}
	out := s.Level(frac, "x")
	if _, err := fmt.Sscanf(out, "\x1b[38;2;%d;%d;%dmx\x1b[0m", &r, &g, &b); err != nil {
		t.Fatalf("Level(%v) = %q, want a truecolor sequence: %v", frac, out, err)
	}
	return r, g, b
}

// hue is the HSV hue of an RGB triple in degrees, 0 at red rising through
// yellow, green and cyan to blue.
func hue(r, g, b int) float64 {
	maxv := math.Max(float64(r), math.Max(float64(g), float64(b)))
	minv := math.Min(float64(r), math.Min(float64(g), float64(b)))
	d := maxv - minv
	if d == 0 {
		return 0
	}
	var h float64
	switch maxv {
	case float64(r):
		h = math.Mod((float64(g)-float64(b))/d, 6)
	case float64(g):
		h = (float64(b)-float64(r))/d + 2
	default:
		h = (float64(r)-float64(g))/d + 4
	}
	h *= 60
	if h < 0 {
		h += 360
	}
	return h
}

// TestLevelMonotoneInHue is the ramp's contract: cold at the noise floor,
// hot at full scale, with no fold-back in between, so height and hue agree.
func TestLevelMonotoneInHue(t *testing.T) {
	const steps = 200
	prev := math.Inf(1)
	for i := 0; i <= steps; i++ {
		f := float64(i) / steps
		h := hue(rampRGB(t, f))
		// The mix is rounded to 8-bit channels, which wobbles the hue by a
		// fraction of a degree between samples. A fold-back the eye could see
		// is degrees, not tenths.
		if h > prev+0.5 {
			t.Fatalf("hue rose at frac %.3f: %.2f after %.2f, want cold to hot without fold-back", f, h, prev)
		}
		prev = h
	}
	if h := hue(rampRGB(t, 0)); h < 150 || h > 190 {
		t.Errorf("floor hue = %.1f, want teal (near 170)", h)
	}
	if h := hue(rampRGB(t, 1)); h > 20 && h < 340 {
		t.Errorf("full-scale hue = %.1f, want red (near 0)", h)
	}
}

// TestLevelClampsAndIdentity covers the edges: out of range folds in, and no
// colour means no ramp.
func TestLevelClampsAndIdentity(t *testing.T) {
	hot := Style{Color: true, Profile: ProfileTrueColor}
	if got, want := hot.Level(4, "x"), hot.Level(1, "x"); got != want {
		t.Errorf("Level above full scale = %q, want the full-scale ink %q", got, want)
	}
	for _, f := range []float64{-3, math.NaN()} {
		if got, want := hot.Level(f, "x"), hot.Level(0, "x"); got != want {
			t.Errorf("Level(%v) = %q, want the floor ink %q", f, got, want)
		}
	}
	if got := hot.Level(0.5, ""); got != "" {
		t.Errorf("Level of the empty string = %q, want it unstyled", got)
	}
	for _, s := range []Style{{}, {Unicode: true, Width: 80}, {Profile: ProfileTrueColor}} {
		for _, f := range []float64{0, 0.5, 1} {
			if got := s.Level(f, "-42.1 dBFS"); got != "-42.1 dBFS" {
				t.Errorf("%+v.Level(%v) = %q, want the input unchanged with colour off", s, f, got)
			}
		}
	}
	if got := Strip(hot.Level(0.5, "-42.1 dBFS")); got != "-42.1 dBFS" {
		t.Errorf("Strip(Level(...)) = %q, want the plain text", got)
	}
}

// TestLevelDegradesByProfile: the ramp uses the depth the terminal reports
// and nothing more, collapsing to five named colours at sixteen.
func TestLevelDegradesByProfile(t *testing.T) {
	named := map[string]bool{}
	for i := 0; i <= 100; i++ {
		out := Style{Color: true, Profile: ProfileANSI}.Level(float64(i)/100, "x")
		sgr, _, ok := strings.Cut(strings.TrimPrefix(out, "\x1b["), "m")
		if !ok {
			t.Fatalf("16-colour Level = %q, want an SGR sequence", out)
		}
		named[sgr] = true
	}
	// Cyan at the cold end for teal; bright red for the orange stop, so the
	// top two stops stay distinct at sixteen colours.
	want := map[string]bool{"36": true, "32": true, "33": true, "91": true, "31": true}
	for sgr := range named {
		if !want[sgr] {
			t.Errorf("16-colour ramp emitted %q; want only cyan, green, yellow, bright red, red", "\x1b["+sgr+"m")
		}
	}
	if len(named) != len(want) {
		t.Errorf("16-colour ramp used %d colours, want all %d stops", len(named), len(want))
	}
	// A hand-built style says Color without a depth: the named sixteen are
	// the safe floor, never truecolor.
	bare := Style{Color: true}
	sixteen := Style{Color: true, Profile: ProfileANSI}
	if got, want := bare.Level(0.5, "x"), sixteen.Level(0.5, "x"); got != want {
		t.Errorf("Level without a profile = %q, want the 16-colour ink %q", got, want)
	}
	for i := 0; i <= 100; i++ {
		out := Style{Color: true, Profile: ProfileANSI256}.Level(float64(i)/100, "x")
		if !strings.HasPrefix(out, "\x1b[38;5;") {
			t.Fatalf("256-colour Level = %q, want a cube colour", out)
		}
	}
}

// TestLevelNeverReachesMachineOutput is the ramp under --json: stdout is
// resolved with Machine set, which turns colour and depth off before any
// renderer exists.
func TestLevelNeverReachesMachineOutput(t *testing.T) {
	env := func(name string) (string, bool) {
		switch name {
		case "COLORTERM":
			return "truecolor", true
		case "TERM":
			return "xterm-256color", true
		}
		return "", false
	}
	s := Resolve(Options{Machine: true, Color: "always", StdoutTTY: true, LookupEnv: env})
	if s.Color || s.Profile != ProfileNone {
		t.Fatalf("machine stdout resolved to %+v, want colour off at no depth", s)
	}
	for i := 0; i <= 10; i++ {
		if got := s.Level(float64(i)/10, "-42.1"); strings.Contains(got, "\x1b") {
			t.Errorf("Level under --json = %q, want no escape byte", got)
		}
	}
	// stderr is resolved separately and keeps its depth.
	if e := Resolve(Options{Stderr: true, Machine: true, StderrTTY: true, LookupEnv: env}); !e.Color || e.Profile != ProfileTrueColor {
		t.Errorf("machine run resolved stderr to %+v, want colour at truecolor", e)
	}
}
