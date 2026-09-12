// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"math"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

func TestParseUserFrequency(t *testing.T) {
	cases := []struct {
		in   string
		want uint64
		err  string
	}{
		{"146.52", 146_520_000, ""},
		{"7.040", 7_040_000, ""},
		{"1010", 1_010_000_000, ""},
		{"146520000", 146_520_000, ""},
		{"14200", 14_200_000_000, ""},
		{"99999", 99_999_000_000, ""},
		{"100000", 100_000, ""},
		{"146.52M", 146_520_000, ""},
		{"146.52 MHz", 146_520_000, ""},
		{"1010k", 1_010_000, ""},
		{"7040kHz", 7_040_000, ""},
		{"1.2G", 1_200_000_000, ""},
		{"146.52e6", 146_520_000, ""},
		{"500Hz", 500, ""},
		{"146,520", 0, "comma"},
		{"", 0, "empty"},
		{"abc", 0, "cannot read"},
		{"-5", 0, "cannot read"},
	}
	for _, c := range cases {
		got, err := ParseUserFrequency(c.in)
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("ParseUserFrequency(%q) err = %v, want containing %q", c.in, err, c.err)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("ParseUserFrequency(%q) = %d, %v; want %d", c.in, got, err, c.want)
		}
	}
}

func TestParseSquelch(t *testing.T) {
	cases := []struct {
		in   string
		db   float64
		auto bool
		off  bool
		err  string
	}{
		{"-40", -40, false, false, ""},
		{"-40dB", -40, false, false, ""},
		{"-40 dBFS", -40, false, false, ""},
		{"-5dB", -5, false, false, ""},
		{"0", 0, false, false, ""},
		{"off", 0, false, true, ""},
		{"OFF", 0, false, true, ""},
		{"auto", 0, true, false, ""},
		{"Auto", 0, true, false, ""},
		{"5", 0, false, false, "dBFS"},
		{"12 dB", 0, false, false, "0 is loudest"},
		{"-200", -200, false, false, ""},
		{"-1000", 0, false, false, "below -200 dBFS"},
		{"loud", 0, false, false, "cannot read"},
		{"", 0, false, false, "empty"},
	}
	for _, c := range cases {
		db, auto, err := ParseSquelch(c.in)
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("ParseSquelch(%q) err = %v, want containing %q", c.in, err, c.err)
			}
			continue
		}
		if err != nil || auto != c.auto || math.IsNaN(db) != c.off || (!c.off && db != c.db) {
			t.Errorf("ParseSquelch(%q) = %v %v %v; want db=%v auto=%v off=%v", c.in, db, auto, err, c.db, c.auto, c.off)
		}
	}
}

func TestParseGain(t *testing.T) {
	cases := []struct {
		in   string
		db   float64
		auto bool
		err  string
	}{
		{"auto", 0, true, ""},
		{"AGC", 0, true, ""},
		{"30", 30, false, ""},
		{"30dB", 30, false, ""},
		{"28.6 dB", 28.6, false, ""},
		{"0", 0, false, ""},
		{"-5", 0, false, "negative"},
		{"-5dB", 0, false, "negative"},
		{"loud", 0, false, "cannot read"},
		{"", 0, false, "empty"},
	}
	for _, c := range cases {
		db, auto, err := ParseGain(c.in)
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("ParseGain(%q) err = %v, want containing %q", c.in, err, c.err)
			}
			continue
		}
		if err != nil || auto != c.auto || db != c.db {
			t.Errorf("ParseGain(%q) = %v %v %v; want %v %v", c.in, db, auto, err, c.db, c.auto)
		}
	}
	el := &leylinev1.GainElement{Name: "TUNER", MinDb: 0, MaxDb: 49.6, SupportsAuto: true}
	if err := CheckGain(30, el); err != nil {
		t.Errorf("CheckGain(30) = %v", err)
	}
	if err := CheckGain(60, el); err == nil || !strings.Contains(err.Error(), "0 to 49.6") || !strings.Contains(err.Error(), "auto") {
		t.Errorf("CheckGain(60) = %v", err)
	}
	if err := CheckGain(60, nil); err != nil {
		t.Errorf("CheckGain(nil) = %v", err)
	}
}

func TestParseBandwidth(t *testing.T) {
	cases := []struct {
		in   string
		want uint32
		err  string
	}{
		{"12.5", 12_500, ""},
		{"12.5k", 12_500, ""},
		{"12.5 kHz", 12_500, ""},
		{"200k", 200_000, ""},
		{"200", 200_000, ""},
		{"12500", 12_500, ""},
		{"999", 999_000, ""},
		{"1000", 1000, ""},
		{"2.8", 2_800, ""},
		{"0.2M", 200_000, ""},
		{"0", 0, "out of range"},
		{"12,5", 0, "comma"},
		{"wide", 0, "cannot read"},
		{"", 0, "empty"},
	}
	for _, c := range cases {
		got, err := ParseBandwidth(c.in)
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("ParseBandwidth(%q) err = %v, want containing %q", c.in, err, c.err)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("ParseBandwidth(%q) = %d, %v; want %d", c.in, got, err, c.want)
		}
	}
}

func TestParseVolume(t *testing.T) {
	cases := []struct {
		in   string
		want float64
		err  string
	}{
		{"50%", 0.5, ""},
		{"0.5", 0.5, ""},
		{"1", 1, ""},
		{"0", 0, ""},
		{"100", 1, ""},
		{"100%", 1, ""},
		{"25", 0.25, ""},
		{"0%", 0, ""},
		{"150%", 0, "out of range"},
		{"101", 0, "out of range"},
		{"-1", 0, "out of range"},
		{"loud", 0, "cannot read"},
		{"", 0, "empty"},
	}
	for _, c := range cases {
		got, err := ParseVolume(c.in)
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("ParseVolume(%q) err = %v, want containing %q", c.in, err, c.err)
			}
			continue
		}
		if err != nil || math.Abs(got-c.want) > 1e-9 {
			t.Errorf("ParseVolume(%q) = %v, %v; want %v", c.in, got, err, c.want)
		}
	}
}

func TestResolveMode(t *testing.T) {
	cases := []struct {
		name   string
		hz     uint64
		want   leylinev1.DemodMode
		reason bool
	}{
		{"fm", 101_100_000, leylinev1.DemodMode_WFM, true},
		{"fm", 146_520_000, leylinev1.DemodMode_NFM, true},
		{"FM", 87_500_000, leylinev1.DemodMode_WFM, true},
		{"fm", 108_000_001, leylinev1.DemodMode_NFM, true},
		{"ssb", 7_100_000, leylinev1.DemodMode_LSB, true},
		{"ssb", 14_200_000, leylinev1.DemodMode_USB, true},
		{"ssb", 10_000_000, leylinev1.DemodMode_USB, true},
		{"nbfm", 101_100_000, leylinev1.DemodMode_NFM, false},
		{"wbfm", 146_520_000, leylinev1.DemodMode_WFM, false},
		{"nfm", 101_100_000, leylinev1.DemodMode_NFM, false},
		{"wfm", 146_520_000, leylinev1.DemodMode_WFM, false},
		{"AM", 118_000_000, leylinev1.DemodMode_AM, false},
		{"usb", 7_100_000, leylinev1.DemodMode_USB, false},
		{"raw_iq", 1, leylinev1.DemodMode_RAW_IQ, false},
	}
	for _, c := range cases {
		got, reason, err := ResolveMode(c.name, c.hz)
		if err != nil || got != c.want || (reason != "") != c.reason {
			t.Errorf("ResolveMode(%q, %d) = %v %q %v; want %v reason=%v", c.name, c.hz, got, reason, err, c.want, c.reason)
		}
	}
	if _, _, err := ResolveMode("dsb", 1); err == nil || !strings.Contains(err.Error(), "ssb") {
		t.Errorf("ResolveMode(dsb) = %v, want error mentioning aliases", err)
	}
}

// The cases mirror EngineCore's GainElement.snapped: the R820T's discrete table,
// a stepped element, and an element that quantises nowhere the client can see.
func TestSnapGain(t *testing.T) {
	table := &leylinev1.GainElement{Name: "TUNER", ValidDb: []float64{0, 3.7, 7.7, 44.5, 48.0}}
	for _, c := range []struct{ in, want float64 }{
		{6, 7.7}, {46, 44.5}, {-3, 0}, {99, 48.0}, {3.7, 3.7},
	} {
		if got := SnapGain(table, c.in); got != c.want {
			t.Errorf("SnapGain(table, %v) = %v, want %v", c.in, got, c.want)
		}
	}
	if got := GainTolerance(table); got != 0.05 {
		t.Errorf("GainTolerance(table) = %v", got)
	}

	grid := &leylinev1.GainElement{Name: "IF", MinDb: -10, MaxDb: 20, StepDb: 0.5}
	for _, c := range []struct{ in, want float64 }{
		{6.2, 6}, {6.3, 6.5}, {-30, -10}, {25, 20}, {0, 0},
	} {
		if got := SnapGain(grid, c.in); got != c.want {
			t.Errorf("SnapGain(grid, %v) = %v, want %v", c.in, got, c.want)
		}
	}
	if got := GainTolerance(grid); got != 0.3 {
		t.Errorf("GainTolerance(grid) = %v", got)
	}

	// Neither table nor step: the value survives, but the range still bounds it.
	free := &leylinev1.GainElement{Name: "LNA", MinDb: 0, MaxDb: 49.6}
	for _, c := range []struct{ in, want float64 }{{6.2, 6.2}, {-1, 0}, {60, 49.6}} {
		if got := SnapGain(free, c.in); got != c.want {
			t.Errorf("SnapGain(free, %v) = %v, want %v", c.in, got, c.want)
		}
	}
	if got := GainTolerance(free); got != 1.0 {
		t.Errorf("GainTolerance(free) = %v", got)
	}
	if got := SnapGain(nil, 6.2); got != 6.2 {
		t.Errorf("SnapGain(nil) = %v", got)
	}
}
