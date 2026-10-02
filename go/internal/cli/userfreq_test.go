// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

func TestParseRange(t *testing.T) {
	for _, tc := range []struct {
		in       string
		min, max uint64
	}{
		{"144M..148M", 144_000_000, 148_000_000},
		{"144..148", 144_000_000, 148_000_000},
		{"162.4M..162.55M", 162_400_000, 162_550_000},
		{" 88 .. 108 ", 88_000_000, 108_000_000},
		{"7000k..7300k", 7_000_000, 7_300_000},
		{"902000000..928000000", 902_000_000, 928_000_000},
	} {
		lo, hi, err := parseRange(tc.in)
		if err != nil {
			t.Errorf("%q: %v", tc.in, err)
			continue
		}
		if lo != tc.min || hi != tc.max {
			t.Errorf("%q: got %d..%d want %d..%d", tc.in, lo, hi, tc.min, tc.max)
		}
	}
}

// Each error message suggests what to type instead.
func TestParseRangeErrorsTeach(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"144M", "not a range"},
		{"2m", "--band 2m"},
		{"148M..144M", "not below"},
		{"146M..146M", "not below"},
		{"nonsense..148M", "the low end"},
		{"144M..nonsense", "the high end"},
	} {
		_, _, err := parseRange(tc.in)
		if err == nil {
			t.Errorf("%q: wanted an error", tc.in)
			continue
		}
		if !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%q: %q does not mention %q", tc.in, err, tc.want)
		}
	}
}

// A metre name is 2 MHz everywhere else in ley, so it must not quietly become
// a band here; the message names the flag that does take it.
func TestARangeNeverResolvesABandName(t *testing.T) {
	if _, _, err := parseRange("2m..70cm"); err == nil {
		t.Fatal("2m..70cm must not parse as a band range")
	}
	// It fails on the frequency reading of 70cm, not by resolving either name.
	lo, hi, err := parseRange("2m..20m")
	if err != nil {
		t.Fatalf("2m..20m reads as 2 MHz..20 MHz: %v", err)
	}
	if lo != 2_000_000 || hi != 20_000_000 {
		t.Errorf("got %d..%d, want the frequency reading 2 MHz..20 MHz", lo, hi)
	}
}

func TestFrequencyHint(t *testing.T) {
	rtl := []*leylinev1.FrequencyRange{{MinHz: 24_000_000, MaxHz: 1_766_000_000}}
	cases := []struct {
		in   string
		hz   uint64
		want string
	}{
		{"1010", 1_010_000_000, "did you mean 1.010 MHz (AM broadcast)? write 1010k"},
		{"146520", 146_520_000_000, "did you mean 146.520 MHz (2 m amateur)? write 146520k"},
		{"7.1", 7_100_000, "this device cannot tune below 24.000 MHz; HF needs an upconverter"},
		{"7.1M", 7_100_000, "this device cannot tune below 24.000 MHz; HF needs an upconverter"},
		{"3000", 3_000_000_000, "this device cannot tune above 1.766 GHz"},
		{"146.52", 146_520_000, ""},
	}
	for _, c := range cases {
		got := frequencyHint(c.in, c.hz, rtl)
		if !strings.HasPrefix(got, c.want) || (c.want == "" && got != "") {
			t.Errorf("frequencyHint(%q, %d) = %q, want prefix %q", c.in, c.hz, got, c.want)
		}
	}
	if got := frequencyHint("2", 2_000_000, nil); got != "" {
		t.Errorf("frequencyHint with no ranges = %q, want empty", got)
	}
	if got := units.FormatRanges(rtl); got != "24.000 MHz – 1.766 GHz" {
		t.Errorf("FormatRanges = %q", got)
	}
	if got := units.FormatRanges(nil); got != "unknown" {
		t.Errorf("FormatRanges(nil) = %q", got)
	}
}
