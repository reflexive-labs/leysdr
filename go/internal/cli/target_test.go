package cli

import (
	"strings"
	"testing"
)

// A point on the dial is a frequency or a preset, and both work wherever one
// does.
func TestResolveDialTargetAcceptsBoth(t *testing.T) {
	for _, tc := range []struct {
		in     string
		hz     uint64
		preset string
	}{
		{"146.52", 146_520_000, ""},
		{"1010k", 1_010_000, ""},
		{"146520000", 146_520_000, ""},
		{"noaa2", 162_400_000, "noaa2"},
		{"NOAA2", 162_400_000, "noaa2"},
		{"wx2", 162_400_000, "noaa2"},
		{"calling", 146_520_000, "calling"},
	} {
		got, err := resolveDialTarget(tc.in, "spectrum", "ley spectrum 101.1", "101.1 (MHz)")
		if err != nil {
			t.Errorf("%q: %v", tc.in, err)
			continue
		}
		if got.Hz != tc.hz {
			t.Errorf("%q = %d, want %d", tc.in, got.Hz, tc.hz)
		}
		switch {
		case tc.preset == "" && got.Preset != nil:
			t.Errorf("%q is a frequency, not preset %q", tc.in, got.Preset.Name)
		case tc.preset != "" && (got.Preset == nil || got.Preset.Name != tc.preset):
			t.Errorf("%q should resolve preset %q, got %v", tc.in, tc.preset, got.Preset)
		}
	}
}

// The two failures get different shapes, and neither staples two hints
// together: a number that will not parse is shown a readable one, and a name
// that is not a preset is offered near matches plus the frequency alternative.
func TestResolveDialTargetErrorShapes(t *testing.T) {
	_, err := resolveDialTarget("146,52", "spectrum", "usage", "101.1 (MHz)")
	if err == nil {
		t.Fatal("a comma is not a frequency")
	}
	if got := err.Error(); !strings.Contains(got, "comma") || !strings.Contains(got, "Example: 101.1 (MHz)") {
		t.Errorf("parse failure should show an example: %q", got)
	}

	_, err = resolveDialTarget("nooa2", "spectrum", "usage", "101.1 (MHz)")
	if err == nil {
		t.Fatal("nooa2 is not a preset")
	}
	got := err.Error()
	if !strings.Contains(got, "noaa2") {
		t.Errorf("a near miss should be suggested: %q", got)
	}
	if !strings.Contains(got, "or give a frequency such as") {
		t.Errorf("the frequency alternative should be offered: %q", got)
	}
	if strings.Count(got, "101.1 (MHz)") != 1 {
		t.Errorf("the example must appear once, not stapled twice: %q", got)
	}

	// No argument at all is shown whole commands, not a bare frequency.
	_, err = resolveDialTarget("", "spectrum", "ley spectrum 101.1, ley spectrum noaa", "101.1 (MHz)")
	if err == nil || !strings.Contains(err.Error(), "ley spectrum 101.1") {
		t.Errorf("an empty argument should show the shape: %v", err)
	}
}

// Bands are deliberately NOT reachable here: `2m` already means 2 MHz, and a
// band name in this position would silently redefine it.
func TestResolveDialTargetDoesNotAcceptBands(t *testing.T) {
	got, err := resolveDialTarget("2m", "spectrum", "usage", "101.1 (MHz)")
	if err != nil {
		t.Fatalf("2m is a valid frequency: %v", err)
	}
	if got.Hz != 2_000_000 {
		t.Errorf("2m must stay 2 MHz, got %d", got.Hz)
	}
	if _, err := resolveDialTarget("fm", "spectrum", "usage", "101.1 (MHz)"); err == nil {
		t.Error("a band alias is not a dial target and must not resolve here")
	}
}
