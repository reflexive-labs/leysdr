// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

func TestResolvePreset(t *testing.T) {
	cases := []struct {
		in   string
		name string
		hz   uint64
		mode leylinev1.DemodMode
	}{
		{"noaa", "noaa1", 162_550_000, leylinev1.DemodMode_NFM},
		{"NOAA", "noaa1", 162_550_000, leylinev1.DemodMode_NFM},
		{"noaa1", "noaa1", 162_550_000, leylinev1.DemodMode_NFM},
		{"noaa2", "noaa2", 162_400_000, leylinev1.DemodMode_NFM},
		{"noaa3", "noaa3", 162_475_000, leylinev1.DemodMode_NFM},
		{"noaa4", "noaa4", 162_425_000, leylinev1.DemodMode_NFM},
		{"noaa5", "noaa5", 162_450_000, leylinev1.DemodMode_NFM},
		{"noaa6", "noaa6", 162_500_000, leylinev1.DemodMode_NFM},
		{"noaa7", "noaa7", 162_525_000, leylinev1.DemodMode_NFM},
		{"wx3", "noaa3", 162_475_000, leylinev1.DemodMode_NFM},
		{"calling", "calling", 146_520_000, leylinev1.DemodMode_NFM},
		{"Marine16", "marine16", 156_800_000, leylinev1.DemodMode_NFM},
		{"guard", "guard", 121_500_000, leylinev1.DemodMode_AM},
		{" guard ", "guard", 121_500_000, leylinev1.DemodMode_AM},
		{"rpt3", "rpt3", 462_600_000, leylinev1.DemodMode_NFM},
		{"RPT3", "rpt3", 462_600_000, leylinev1.DemodMode_NFM},
		{"rpt08", "rpt8", 462_725_000, leylinev1.DemodMode_NFM},
		{"rpt1", "rpt1", 462_550_000, leylinev1.DemodMode_NFM},
	}
	for _, c := range cases {
		p, err := ResolvePreset(c.in)
		if err != nil || p.Name != c.name || p.Hz != c.hz || p.Mode != c.mode {
			t.Errorf("ResolvePreset(%q) = %+v, %v; want %s %d %v", c.in, p, err, c.name, c.hz, c.mode)
		}
		if b := BandFor(p.Hz); b == nil {
			t.Errorf("preset %s at %d is not in any band", p.Name, p.Hz)
		}
	}
	if _, err := ResolvePreset("noa"); err == nil || !strings.Contains(err.Error(), "noaa1") {
		t.Errorf("ResolvePreset(noa) = %v, want hint naming noaa1", err)
	}
	if _, err := ResolvePreset("gaurd"); err == nil || !strings.Contains(err.Error(), "guard") {
		t.Errorf("ResolvePreset(gaurd) = %v, want hint naming guard", err)
	}
	if _, err := ResolvePreset("zzzzzzzz"); err == nil || strings.Contains(err.Error(), "did you mean") {
		t.Errorf("ResolvePreset(zzzzzzzz) = %v, want plain unknown error", err)
	}
	if _, err := ResolvePreset(""); err == nil {
		t.Error("ResolvePreset(\"\"): expected error")
	}
}

func TestNearestPresetNames(t *testing.T) {
	if got := NearestPresetNames("noaa"); len(got) == 0 || got[0] != "noaa1" {
		t.Errorf("NearestPresetNames(noaa) = %v", got)
	}
	if got := NearestPresetNames("marine"); len(got) == 0 || got[0] != "marine16" {
		t.Errorf("NearestPresetNames(marine) = %v", got)
	}
	if got := NearestPresetNames("caling"); len(got) == 0 || got[0] != "calling" {
		t.Errorf("NearestPresetNames(caling) = %v", got)
	}
	if got := NearestPresetNames("nooa"); len(got) == 0 || got[0] != "noaa" {
		t.Errorf("NearestPresetNames(nooa) = %v, want the noaa alias first", got)
	}
	if got := NearestPresetNames("xyzxyz"); len(got) != 0 {
		t.Errorf("NearestPresetNames(xyzxyz) = %v, want none", got)
	}
	if got := NearestPresetNames("n"); len(got) > 3 {
		t.Errorf("NearestPresetNames(n) returned %d names, want at most 3", len(got))
	}
}

func TestPresetsTable(t *testing.T) {
	seen := map[string]bool{}
	for _, p := range Presets() {
		for _, n := range append([]string{p.Name}, p.Aliases...) {
			if n != strings.ToLower(n) || seen[n] {
				t.Errorf("preset name %q is not lower-case or is duplicated", n)
			}
			seen[n] = true
		}
		if p.Hz == 0 || p.Mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED || p.Description == "" {
			t.Errorf("preset %q is incomplete: %+v", p.Name, p)
		}
	}
}
