package leyline

import (
	"math"
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
		{"1,296.2 MHz", 1_296_200_000},
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
	for _, bad := range []string{"", "abc", "1.2.3M", "-5M", "12X"} {
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
	if v, err := ParseSquelch("off"); err != nil || !math.IsNaN(v) {
		t.Errorf("ParseSquelch(off) = %v %v", v, err)
	}
	if v, err := ParseSquelch("-45 dB"); err != nil || v != -45 {
		t.Errorf("ParseSquelch(-45 dB) = %v %v", v, err)
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
