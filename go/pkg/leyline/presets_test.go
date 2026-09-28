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
		{"noaa", "wx1", 162_550_000, leylinev1.DemodMode_NFM},
		{"NOAA", "wx1", 162_550_000, leylinev1.DemodMode_NFM},
		{"noaa1", "wx1", 162_550_000, leylinev1.DemodMode_NFM},
		{"noaa2", "wx2", 162_400_000, leylinev1.DemodMode_NFM},
		{"noaa3", "wx3", 162_475_000, leylinev1.DemodMode_NFM},
		{"noaa4", "wx4", 162_425_000, leylinev1.DemodMode_NFM},
		{"noaa5", "wx5", 162_450_000, leylinev1.DemodMode_NFM},
		{"noaa6", "wx6", 162_500_000, leylinev1.DemodMode_NFM},
		{"noaa7", "wx7", 162_525_000, leylinev1.DemodMode_NFM},
		{"wx3", "wx3", 162_475_000, leylinev1.DemodMode_NFM},
		{"calling", "calling", 146_520_000, leylinev1.DemodMode_NFM},
		{"Marine16", "marine16", 156_800_000, leylinev1.DemodMode_NFM},
		{"guard", "guard", 121_500_000, leylinev1.DemodMode_AM},
		{" guard ", "guard", 121_500_000, leylinev1.DemodMode_AM},
		{"rpt3", "ch17", 462_600_000, leylinev1.DemodMode_NFM},
		{"RPT3", "ch17", 462_600_000, leylinev1.DemodMode_NFM},
		{"rpt4", "ch18", 462_625_000, leylinev1.DemodMode_NFM},
		{"17rp", "ch17", 462_600_000, leylinev1.DemodMode_NFM},
		{"ch25", "ch17", 462_600_000, leylinev1.DemodMode_NFM},
		{"18rp", "ch18", 462_625_000, leylinev1.DemodMode_NFM},
		{"ch26", "ch18", 462_625_000, leylinev1.DemodMode_NFM},
		{"ch23", "ch15", 462_550_000, leylinev1.DemodMode_NFM},
		{"ch30", "ch22", 462_725_000, leylinev1.DemodMode_NFM},
		{"ch18", "ch18", 462_625_000, leylinev1.DemodMode_NFM},
		{"ch1", "ch1", 462_562_500, leylinev1.DemodMode_NFM},
		{"ch8", "ch8", 467_562_500, leylinev1.DemodMode_NFM},
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
	// An exact alias comes first, ahead of the names it is a prefix of.
	if got := NearestPresetNames("noaa"); len(got) == 0 || got[0] != "noaa" {
		t.Errorf("NearestPresetNames(noaa) = %v", got)
	}
	if got := NearestPresetNames("marine"); len(got) == 0 || got[0] != "marine" {
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

// The words that resolve without a band are unique across every plan: preset names, and every
// alias that is not a radio-printed channel number. A channel number (`16`, `1`) repeats
// across plans and resolves only under --band; a channel may carry an alias equal to one of
// its own band's (`noaa` on WX1, `marine` on 16), because --band and the dial are separate
// lookups, and never one of another band's (docs/design/channels.md, "The CLI").
func TestPresetsTable(t *testing.T) {
	bandOf := map[string]string{}
	for _, b := range append(Bands(), BandGroups()...) {
		for _, a := range b.Aliases {
			bandOf[a] = b.Name
		}
	}
	seen := map[string]string{}
	for _, p := range Presets() {
		if p.Name != strings.ToLower(p.Name) || strings.Contains(p.Name, " ") {
			t.Errorf("preset name %q is not one lower-case word", p.Name)
		}
		for _, n := range append([]string{p.Name}, p.Aliases...) {
			key := strings.ToLower(n)
			if channelNumber(key) {
				continue
			}
			if prev, dup := seen[key]; dup {
				t.Errorf("%q resolves to both %s and %s", n, prev, p.Name)
			}
			seen[key] = p.Name
			if band, isBand := bandOf[key]; isBand && band != p.Band {
				t.Errorf("%s carries %q, an alias of the %s band, not its own", p.Name, n, band)
			}
		}
		if p.Hz == 0 || p.Mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED || p.BandwidthHz == 0 || p.Description == "" || p.Band == "" {
			t.Errorf("preset %q is incomplete: %+v", p.Name, p)
		}
	}
}

// TestPresetNamesOf20260928KeepResolving pins every name and alias the preset table carried on
// 2026-09-28, the day the literal became a view over the band table's plans, to the frequency
// and mode each stood for. Scripts and the MCP tool descriptions use these words, so the plans
// must keep answering them (docs/design/channels.md, "The CLI"; the plan's R4).
func TestPresetNamesOf20260928KeepResolving(t *testing.T) {
	pinned := []struct {
		name string
		hz   uint64
		mode leylinev1.DemodMode
	}{
		{"noaa1", 162550000, leylinev1.DemodMode_NFM},
		{"noaa", 162550000, leylinev1.DemodMode_NFM},
		{"wx1", 162550000, leylinev1.DemodMode_NFM},
		{"weather", 162550000, leylinev1.DemodMode_NFM},
		{"noaa2", 162400000, leylinev1.DemodMode_NFM},
		{"wx2", 162400000, leylinev1.DemodMode_NFM},
		{"noaa3", 162475000, leylinev1.DemodMode_NFM},
		{"wx3", 162475000, leylinev1.DemodMode_NFM},
		{"noaa4", 162425000, leylinev1.DemodMode_NFM},
		{"wx4", 162425000, leylinev1.DemodMode_NFM},
		{"noaa5", 162450000, leylinev1.DemodMode_NFM},
		{"wx5", 162450000, leylinev1.DemodMode_NFM},
		{"noaa6", 162500000, leylinev1.DemodMode_NFM},
		{"wx6", 162500000, leylinev1.DemodMode_NFM},
		{"noaa7", 162525000, leylinev1.DemodMode_NFM},
		{"wx7", 162525000, leylinev1.DemodMode_NFM},
		{"calling", 146520000, leylinev1.DemodMode_NFM},
		{"2m-calling", 146520000, leylinev1.DemodMode_NFM},
		{"simplex", 146520000, leylinev1.DemodMode_NFM},
		{"marine16", 156800000, leylinev1.DemodMode_NFM},
		{"marine", 156800000, leylinev1.DemodMode_NFM},
		{"guard", 121500000, leylinev1.DemodMode_AM},
		{"aircraft-guard", 121500000, leylinev1.DemodMode_AM},
		{"121.5", 121500000, leylinev1.DemodMode_AM},
		{"ch1", 462562500, leylinev1.DemodMode_NFM},
		{"ch2", 462587500, leylinev1.DemodMode_NFM},
		{"ch3", 462612500, leylinev1.DemodMode_NFM},
		{"ch4", 462637500, leylinev1.DemodMode_NFM},
		{"ch5", 462662500, leylinev1.DemodMode_NFM},
		{"ch6", 462687500, leylinev1.DemodMode_NFM},
		{"ch7", 462712500, leylinev1.DemodMode_NFM},
		{"ch8", 467562500, leylinev1.DemodMode_NFM},
		{"ch9", 467587500, leylinev1.DemodMode_NFM},
		{"ch10", 467612500, leylinev1.DemodMode_NFM},
		{"ch11", 467637500, leylinev1.DemodMode_NFM},
		{"ch12", 467662500, leylinev1.DemodMode_NFM},
		{"ch13", 467687500, leylinev1.DemodMode_NFM},
		{"ch14", 467712500, leylinev1.DemodMode_NFM},
		{"ch15", 462550000, leylinev1.DemodMode_NFM},
		{"rpt1", 462550000, leylinev1.DemodMode_NFM},
		{"15rp", 462550000, leylinev1.DemodMode_NFM},
		{"ch23", 462550000, leylinev1.DemodMode_NFM},
		{"ch16", 462575000, leylinev1.DemodMode_NFM},
		{"rpt2", 462575000, leylinev1.DemodMode_NFM},
		{"16rp", 462575000, leylinev1.DemodMode_NFM},
		{"ch24", 462575000, leylinev1.DemodMode_NFM},
		{"ch17", 462600000, leylinev1.DemodMode_NFM},
		{"rpt3", 462600000, leylinev1.DemodMode_NFM},
		{"17rp", 462600000, leylinev1.DemodMode_NFM},
		{"ch25", 462600000, leylinev1.DemodMode_NFM},
		{"ch18", 462625000, leylinev1.DemodMode_NFM},
		{"rpt4", 462625000, leylinev1.DemodMode_NFM},
		{"18rp", 462625000, leylinev1.DemodMode_NFM},
		{"ch26", 462625000, leylinev1.DemodMode_NFM},
		{"ch19", 462650000, leylinev1.DemodMode_NFM},
		{"rpt5", 462650000, leylinev1.DemodMode_NFM},
		{"19rp", 462650000, leylinev1.DemodMode_NFM},
		{"ch27", 462650000, leylinev1.DemodMode_NFM},
		{"ch20", 462675000, leylinev1.DemodMode_NFM},
		{"rpt6", 462675000, leylinev1.DemodMode_NFM},
		{"20rp", 462675000, leylinev1.DemodMode_NFM},
		{"ch28", 462675000, leylinev1.DemodMode_NFM},
		{"ch21", 462700000, leylinev1.DemodMode_NFM},
		{"rpt7", 462700000, leylinev1.DemodMode_NFM},
		{"21rp", 462700000, leylinev1.DemodMode_NFM},
		{"ch29", 462700000, leylinev1.DemodMode_NFM},
		{"ch22", 462725000, leylinev1.DemodMode_NFM},
		{"rpt8", 462725000, leylinev1.DemodMode_NFM},
		{"22rp", 462725000, leylinev1.DemodMode_NFM},
		{"ch30", 462725000, leylinev1.DemodMode_NFM},
	}
	for _, c := range pinned {
		p, err := ResolvePreset(c.name)
		if err != nil {
			t.Errorf("ResolvePreset(%q): %v", c.name, err)
			continue
		}
		if p.Hz != c.hz || p.Mode != c.mode {
			t.Errorf("ResolvePreset(%q) = %d %v, want %d %v", c.name, p.Hz, p.Mode, c.hz, c.mode)
		}
	}
}

// The preset table is a view over the plans: one preset per channel, named by the plan-prefixed
// alias (the plan's KTD1), with the radio-printed name first among its aliases when it differs,
// the channel's own mode and width where it has them, and the description built from the band's
// name and the channel's note.
func TestPresetsAreAViewOverThePlans(t *testing.T) {
	for _, tc := range []struct {
		in, name string
		hz       uint64
		bw       uint32
		aliases  string
		desc     string
		band     string
	}{
		{"wx3", "wx3", 162_475_000, 12_500, "noaa3", "NOAA weather WX3 (162.475 MHz)", "NOAA weather"},
		{"noaa", "wx1", 162_550_000, 12_500, "noaa1, noaa, weather", "NOAA weather WX1 (162.550 MHz)", "NOAA weather"},
		{"ch5", "ch5", 462_662_500, 20_000, "gmrs5, 5", "GMRS ch5, simplex, shared with FRS (462.6625 MHz)", "GMRS"},
		{"rpt3", "ch17", 462_600_000, 20_000, "gmrs17, 17, rpt3, 17rp, ch25", "", "GMRS"},
		{"murs1", "murs1", 151_820_000, 11_250, "1", "", "MURS"},
		{"murs5", "murs5", 154_600_000, 20_000, "5", "", "MURS"},
		{"cb19", "cb19", 27_185_000, 10_000, "19", "", "CB"},
		{"marine16", "marine16", 156_800_000, 12_500, "16, marine", "", "marine VHF"},
		{"marine24-coast", "marine24-coast", 161_800_000, 12_500, "24 coast", "", "marine VHF"},
		{"marine87b", "marine87b", 161_975_000, 12_500, "87B, ais1", "", "marine VHF"},
		{"aprs", "aprs", 144_390_000, 12_500, "", "", "2 m amateur"},
		{"calling", "calling", 146_520_000, 12_500, "2m-calling, simplex", "", "2 m amateur"},
		{"guard", "guard", 121_500_000, 10_000, "aircraft-guard, 121.5", "", "airband"},
	} {
		p, err := ResolvePreset(tc.in)
		if err != nil {
			t.Errorf("ResolvePreset(%q): %v", tc.in, err)
			continue
		}
		if p.Name != tc.name || p.Hz != tc.hz || p.BandwidthHz != tc.bw || p.Band != tc.band {
			t.Errorf("ResolvePreset(%q) = %+v; want %s at %d, %d wide, in %s", tc.in, p, tc.name, tc.hz, tc.bw, tc.band)
		}
		if got := strings.Join(p.Aliases, ", "); got != tc.aliases {
			t.Errorf("ResolvePreset(%q).Aliases = %q, want %q", tc.in, got, tc.aliases)
		}
		if tc.desc != "" && p.Description != tc.desc {
			t.Errorf("ResolvePreset(%q).Description = %q, want %q", tc.in, p.Description, tc.desc)
		}
	}
	// A bare number is never a preset without a band: `16` is 16 MHz at the dial and marine 16
	// only under --band marine (docs/design/channels.md, "The plan is data in the band table").
	for _, bare := range []string{"16", "1", "5"} {
		if p, err := ResolvePreset(bare); err == nil {
			t.Errorf("ResolvePreset(%q) = %+v, want no preset outside a band", bare, p)
		}
	}
	// The view is in table order: the bands by frequency, then the groups.
	ps := Presets()
	if ps[0].Name != "cb1" || ps[len(ps)-1].Name != "murs5" {
		t.Errorf("Presets() runs from cb1 to murs5, got %s .. %s", ps[0].Name, ps[len(ps)-1].Name)
	}
	if n := len(ps); n != 7+22+5+110+40+2+1 {
		t.Errorf("Presets() has %d rows, want one per channel", n)
	}
}
