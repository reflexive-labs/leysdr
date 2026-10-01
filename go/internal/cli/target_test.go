// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
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
		{"noaa2", 162_400_000, "wx2"},
		{"NOAA2", 162_400_000, "wx2"},
		{"wx2", 162_400_000, "wx2"},
		{"calling", 146_520_000, "calling"},
	} {
		got, err := resolveDialTarget(tc.in, "spectrum", "ley spectrum 101.1", "101.1 (MHz)", nil)
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
	_, err := resolveDialTarget("146,52", "spectrum", "usage", "101.1 (MHz)", nil)
	if err == nil {
		t.Fatal("a comma is not a frequency")
	}
	if got := err.Error(); !strings.Contains(got, "comma") || !strings.Contains(got, "Example: 101.1 (MHz)") {
		t.Errorf("parse failure should show an example: %q", got)
	}

	_, err = resolveDialTarget("nooa2", "spectrum", "usage", "101.1 (MHz)", nil)
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
	_, err = resolveDialTarget("", "spectrum", "ley spectrum 101.1, ley spectrum noaa", "101.1 (MHz)", nil)
	if err == nil || !strings.Contains(err.Error(), "ley spectrum 101.1") {
		t.Errorf("an empty argument should show the shape: %v", err)
	}
}

// Bands are not reachable here: `2m` already means 2 MHz, and a
// band name in this position would silently redefine it.
func TestResolveDialTargetDoesNotAcceptBands(t *testing.T) {
	got, err := resolveDialTarget("2m", "spectrum", "usage", "101.1 (MHz)", nil)
	if err != nil {
		t.Fatalf("2m is a valid frequency: %v", err)
	}
	if got.Hz != 2_000_000 {
		t.Errorf("2m must stay 2 MHz, got %d", got.Hz)
	}
	if _, err := resolveDialTarget("fm", "spectrum", "usage", "101.1 (MHz)", nil); err == nil {
		t.Error("a band alias is not a dial target and must not resolve here")
	}
}

// With a band, the positional is a channel name in that band's plan and nothing else: the
// numeric parse is not tried (a frequency needs no --band), and a miss names the band and its
// plan rather than offering a frequency (docs/design/channels.md, "The CLI"; the plan's KTD8).
func TestResolveDialTargetInABand(t *testing.T) {
	marine, err := leyline.ResolveBand("marine")
	if err != nil {
		t.Fatal(err)
	}
	got, err := resolveDialTarget("16", "tune", "ley tune 16 --band marine", "146.52 (MHz)", &marine)
	if err != nil || got.Hz != 156_800_000 || got.Preset == nil || got.Preset.Name != "marine16" {
		t.Errorf("16 under --band marine = %+v, %v; want marine16 at 156.800 MHz", got, err)
	}
	bare, err := resolveDialTarget("16", "tune", "ley tune 16", "146.52 (MHz)", nil)
	if err != nil || bare.Hz != 16_000_000 || bare.Preset != nil {
		t.Errorf("16 without a band = %+v, %v; want 16 MHz", bare, err)
	}
	_, err = resolveDialTarget("99", "tune", "ley tune 16 --band marine", "146.52 (MHz)", &marine)
	if err == nil {
		t.Fatal("99 is not a marine channel")
	}
	msg := err.Error()
	for _, want := range []string{"99", "marine VHF", "ley bands marine"} {
		if !strings.Contains(msg, want) {
			t.Errorf("a miss should name the band and its plan, want %q in %q", want, msg)
		}
	}
	if strings.Contains(msg, "frequency such as") {
		t.Errorf("a miss under --band must not offer a frequency: %q", msg)
	}
	// A short plan is listed whole.
	noaa, _ := leyline.ResolveBand("noaa")
	_, err = resolveDialTarget("wx9", "tune", "ley tune wx3 --band noaa", "146.52 (MHz)", &noaa)
	if err == nil || !strings.Contains(err.Error(), "WX1, WX2, WX3, WX4, WX5, WX6, WX7") {
		t.Errorf("a short plan is listed in the error: %v", err)
	}
	// No argument at all under --band asks for a channel of that plan.
	_, err = resolveDialTarget("", "tune", "ley tune 16 --band marine", "146.52 (MHz)", &marine)
	if err == nil || !strings.Contains(err.Error(), "marine VHF") {
		t.Errorf("an empty argument under --band names the band: %v", err)
	}
	// A band without a plan points back to a frequency and the command that confirms it.
	seventyCM, err := leyline.ResolveBand("70cm")
	if err != nil {
		t.Fatal(err)
	}
	_, err = resolveDialTarget("calling", "tune", "ley tune calling --band 70cm", "146.52 (MHz)", &seventyCM)
	want := "it has no channel plan, so give a frequency instead; check with: ley bands 70cm"
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Errorf("a band without a plan explains what to give instead: %v", err)
	}
}
