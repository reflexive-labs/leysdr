package leyline

import (
	"math"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

func TestParseFrequency(t *testing.T) {
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
		got, err := ParseFrequency(c.in)
		if err != nil {
			t.Errorf("ParseFrequency(%q): %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("ParseFrequency(%q) = %d, want %d", c.in, got, c.want)
		}
	}
	for _, bad := range []string{"", "abc", "1.2.3M", "-5M", "12X", "1,296.2 MHz", "146,520,000", "146_520_000", "146_520k", "1_000.5M"} {
		if _, err := ParseFrequency(bad); err == nil {
			t.Errorf("ParseFrequency(%q): expected error", bad)
		}
	}
}

func TestFormatFrequency(t *testing.T) {
	cases := map[uint64]string{
		146_520_000:   "146.520 MHz",
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

func TestParseGainSquelchMode(t *testing.T) {
	if db, auto, err := ParseGain("auto"); err != nil || !auto || db != 0 {
		t.Errorf("ParseGain(auto) = %v %v %v", db, auto, err)
	}
	if db, auto, err := ParseGain("28.0dB"); err != nil || auto || db != 28 {
		t.Errorf("ParseGain(28.0dB) = %v %v %v", db, auto, err)
	}
	if _, _, err := ParseGain("loud"); err == nil {
		t.Error("ParseGain(loud): expected error")
	}
	if v, auto, err := ParseSquelch("off"); err != nil || auto || !math.IsNaN(v) {
		t.Errorf("ParseSquelch(off) = %v %v %v", v, auto, err)
	}
	if v, auto, err := ParseSquelch("-45 dB"); err != nil || auto || v != -45 {
		t.Errorf("ParseSquelch(-45 dB) = %v %v %v", v, auto, err)
	}
	for in, want := range map[string]leylinev1.DemodMode{
		"nfm": leylinev1.DemodMode_NFM, "AM": leylinev1.DemodMode_AM, "Wfm": leylinev1.DemodMode_WFM,
		"usb": leylinev1.DemodMode_USB, "lsb": leylinev1.DemodMode_LSB, "cw": leylinev1.DemodMode_CW,
		"raw_iq": leylinev1.DemodMode_RAW_IQ, "RAW-IQ": leylinev1.DemodMode_RAW_IQ,
	} {
		got, err := ParseMode(in)
		if err != nil || got != want {
			t.Errorf("ParseMode(%q) = %v %v, want %v", in, got, err, want)
		}
		if back, err := ParseMode(ModeName(got)); err != nil || back != got {
			t.Errorf("ModeName round-trip for %v failed: %q", got, ModeName(got))
		}
	}
	if _, err := ParseMode("dsb"); err == nil {
		t.Error("ParseMode(dsb): expected error")
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
		got := FrequencyHint(c.in, c.hz, rtl)
		if !strings.HasPrefix(got, c.want) || (c.want == "" && got != "") {
			t.Errorf("FrequencyHint(%q, %d) = %q, want prefix %q", c.in, c.hz, got, c.want)
		}
	}
	if got := FrequencyHint("2", 2_000_000, nil); got != "" {
		t.Errorf("FrequencyHint with no ranges = %q, want empty", got)
	}
	if got := FormatRanges(rtl); got != "24.000 MHz – 1.766 GHz" {
		t.Errorf("FormatRanges = %q", got)
	}
	if got := FormatRanges(nil); got != "unknown" {
		t.Errorf("FormatRanges(nil) = %q", got)
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
