package leyline

import "testing"

func TestParseUserRange(t *testing.T) {
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
		lo, hi, err := ParseUserRange(tc.in)
		if err != nil {
			t.Errorf("%q: %v", tc.in, err)
			continue
		}
		if lo != tc.min || hi != tc.max {
			t.Errorf("%q: got %d..%d want %d..%d", tc.in, lo, hi, tc.min, tc.max)
		}
	}
}

// The errors are the value: each one says what to type instead.
func TestParseUserRangeErrorsTeach(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"144M", "not a range"},
		{"2m", "--band 2m"},
		{"148M..144M", "not below"},
		{"146M..146M", "not below"},
		{"nonsense..148M", "the low end"},
		{"144M..nonsense", "the high end"},
	} {
		_, _, err := ParseUserRange(tc.in)
		if err == nil {
			t.Errorf("%q: wanted an error", tc.in)
			continue
		}
		if !contains(err.Error(), tc.want) {
			t.Errorf("%q: %q does not mention %q", tc.in, err, tc.want)
		}
	}
}

// A metre name is 2 MHz everywhere else in ley, so it must not quietly become
// a band here; the message names the flag that does take it.
func TestARangeNeverResolvesABandName(t *testing.T) {
	if _, _, err := ParseUserRange("2m..70cm"); err == nil {
		t.Fatal("2m..70cm must not parse as a band range")
	}
	// It fails on the frequency reading of 70cm, not by resolving either name.
	lo, hi, err := ParseUserRange("2m..20m")
	if err != nil {
		t.Fatalf("2m..20m reads as 2 MHz..20 MHz: %v", err)
	}
	if lo != 2_000_000 || hi != 20_000_000 {
		t.Errorf("got %d..%d, want the frequency reading 2 MHz..20 MHz", lo, hi)
	}
}
