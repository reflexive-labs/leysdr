// SPDX-License-Identifier: Apache-2.0

package units

import (
	"math"
	"testing"
)

func TestParseHz(t *testing.T) {
	cases := []struct {
		in   string
		want uint64
	}{
		{"146.52M", 146_520_000},
		{"146520000", 146_520_000},
		{"1.2G", 1_200_000_000},
		{"433.92MHz", 433_920_000},
		{"7040k", 7_040_000},
		{"7.040 MHz", 7_040_000},
		{"146.52e6", 146_520_000},
		{" 96.9 mhz ", 96_900_000},
		{"500Hz", 500},
	}
	for _, c := range cases {
		got, err := ParseHz(c.in)
		if err != nil {
			t.Errorf("ParseHz(%q): %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("ParseHz(%q) = %d, want %d", c.in, got, c.want)
		}
	}
	for _, bad := range []string{"", "abc", "1.2.3M", "-5M", "12X", "1,296.2 MHz", "146,520,000", "146_520_000", "146_520k", "1_000.5M"} {
		if _, err := ParseHz(bad); err == nil {
			t.Errorf("ParseHz(%q): expected error", bad)
		}
	}
}

func TestFormatFrequency(t *testing.T) {
	cases := map[uint64]string{
		146_520_000: "146.520 MHz",
		462_612_500: "462.6125 MHz",
		// A measured centre is not a channel plan: three decimals, as its bin can carry.
		145_397_700:   "145.398 MHz",
		7_040:         "7.040 kHz",
		1_200_000_000: "1.200 GHz",
		500:           "500 Hz",
		// The unit is chosen after rounding, so a 1 GHz tuning limit a few hundred
		// Hz short of the decade does not read as "1000.000 MHz".
		999_999_999: "1.000 GHz",
		999_999_500: "1.000 GHz",
		999_999_499: "999.999 MHz",
		999_999:     "999.999 kHz",
		999:         "999 Hz",
	}
	for hz, want := range cases {
		if got := FormatFrequency(hz); got != want {
			t.Errorf("FormatFrequency(%d) = %q, want %q", hz, got, want)
		}
	}
}

func TestParseGainSquelch(t *testing.T) {
	if db, auto, err := parseGain("auto"); err != nil || !auto || db != 0 {
		t.Errorf("ParseGain(auto) = %v %v %v", db, auto, err)
	}
	if db, auto, err := parseGain("28.0dB"); err != nil || auto || db != 28 {
		t.Errorf("ParseGain(28.0dB) = %v %v %v", db, auto, err)
	}
	if _, _, err := parseGain("loud"); err == nil {
		t.Error("ParseGain(loud): expected error")
	}
	if v, auto, err := ParseSquelch("off"); err != nil || auto || !math.IsNaN(v) {
		t.Errorf("ParseSquelch(off) = %v %v %v", v, auto, err)
	}
	if v, auto, err := ParseSquelch("-45 dB"); err != nil || auto || v != -45 {
		t.Errorf("ParseSquelch(-45 dB) = %v %v %v", v, auto, err)
	}
}

func TestNearestRate(t *testing.T) {
	rates := []uint64{250_000, 1_024_000, 2_400_000}
	cases := []struct{ want, got uint64 }{
		{200_000, 250_000},
		{250_000, 250_000},
		{600_000, 250_000},
		{700_000, 1_024_000},
		{637_000, 1_024_000},
		{5_000_000, 2_400_000},
		{1_712_000, 2_400_000},
	}
	for _, c := range cases {
		if got := NearestRate(rates, c.want); got != c.got {
			t.Errorf("NearestRate(%d) = %d, want %d", c.want, got, c.got)
		}
	}
	if got := NearestRate(nil, 123); got != 123 {
		t.Errorf("empty rates should pass through, got %d", got)
	}
}
