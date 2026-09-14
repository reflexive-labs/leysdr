// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"fmt"
	"sort"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// Preset is a named frequency a newcomer is likely to reach for. The table
// is presentation-only: resolving a preset is a client-side translation into
// the same tune RPC a numeric frequency uses. No probing, no wire change.
type Preset struct {
	Name        string
	Aliases     []string
	Hz          uint64
	Mode        leylinev1.DemodMode
	Description string
}

// presets is in the order the help topic lists them. NOAA channels follow
// the WX1..WX7 numbering.
var presets = []Preset{
	{"noaa1", []string{"noaa", "wx1", "weather"}, 162_550_000, mNFM, "NOAA weather WX1 (162.550 MHz)"},
	{"noaa2", []string{"wx2"}, 162_400_000, mNFM, "NOAA weather WX2 (162.400 MHz)"},
	{"noaa3", []string{"wx3"}, 162_475_000, mNFM, "NOAA weather WX3 (162.475 MHz)"},
	{"noaa4", []string{"wx4"}, 162_425_000, mNFM, "NOAA weather WX4 (162.425 MHz)"},
	{"noaa5", []string{"wx5"}, 162_450_000, mNFM, "NOAA weather WX5 (162.450 MHz)"},
	{"noaa6", []string{"wx6"}, 162_500_000, mNFM, "NOAA weather WX6 (162.500 MHz)"},
	{"noaa7", []string{"wx7"}, 162_525_000, mNFM, "NOAA weather WX7 (162.525 MHz)"},
	{"calling", []string{"2m-calling", "simplex"}, 146_520_000, mNFM, "2 m amateur national simplex calling frequency (146.520 MHz)"},
	{"marine16", []string{"marine"}, 156_800_000, mNFM, "marine VHF channel 16, distress and calling (156.800 MHz)"},
	{"guard", []string{"aircraft-guard", "121.5"}, 121_500_000, mAM, "aviation emergency guard frequency (121.500 MHz)"},
	// GMRS by channel number, the labelling every GMRS radio shares. Channels 1-7 and 15-22 are the
	// 462 MHz band (1-7 the low-power interstitials, 15-22 the main channels); 8-14 are the 467 MHz
	// interstitials. A preset is what you tune to LISTEN. Channels 15-22 are also the repeater
	// outputs, so they carry every name a radio might print for the same slot as aliases: `rptN`
	// (repeater slot 1-8, what a Baofeng shows as RPT3), `NNrp` (17RP, the channel-numbered form),
	// and Baofeng's ch23-30. So `ley tune rpt3`, `ley tune 17rp` and `ley tune ch25` all reach ch17.
	// Midland's own 1-8 numbering is not aliased: it collides with the simplex ch1-8 above.
	// A repeater built from two independent radios can transmit on any of these, not just the one
	// paired +5 MHz with its input, so `ley scan gmrs` is how you find where it actually is.
	{"ch1", nil, 462_562_500, mNFM, "GMRS/FRS channel 1, 462.5625 MHz (simplex, shared with FRS)"},
	{"ch2", nil, 462_587_500, mNFM, "GMRS/FRS channel 2, 462.5875 MHz (simplex, shared with FRS)"},
	{"ch3", nil, 462_612_500, mNFM, "GMRS/FRS channel 3, 462.6125 MHz (simplex, shared with FRS)"},
	{"ch4", nil, 462_637_500, mNFM, "GMRS/FRS channel 4, 462.6375 MHz (simplex, shared with FRS)"},
	{"ch5", nil, 462_662_500, mNFM, "GMRS/FRS channel 5, 462.6625 MHz (simplex, shared with FRS)"},
	{"ch6", nil, 462_687_500, mNFM, "GMRS/FRS channel 6, 462.6875 MHz (simplex, shared with FRS)"},
	{"ch7", nil, 462_712_500, mNFM, "GMRS/FRS channel 7, 462.7125 MHz (simplex, shared with FRS)"},
	{"ch8", nil, 467_562_500, mNFM, "GMRS/FRS channel 8, 467.5625 MHz (simplex, low power)"},
	{"ch9", nil, 467_587_500, mNFM, "GMRS/FRS channel 9, 467.5875 MHz (simplex, low power)"},
	{"ch10", nil, 467_612_500, mNFM, "GMRS/FRS channel 10, 467.6125 MHz (simplex, low power)"},
	{"ch11", nil, 467_637_500, mNFM, "GMRS/FRS channel 11, 467.6375 MHz (simplex, low power)"},
	{"ch12", nil, 467_662_500, mNFM, "GMRS/FRS channel 12, 467.6625 MHz (simplex, low power)"},
	{"ch13", nil, 467_687_500, mNFM, "GMRS/FRS channel 13, 467.6875 MHz (simplex, low power)"},
	{"ch14", nil, 467_712_500, mNFM, "GMRS/FRS channel 14, 467.7125 MHz (simplex, low power)"},
	{"ch15", []string{"rpt1", "15rp", "ch23"}, 462_550_000, mNFM, "GMRS channel 15, 462.550 MHz (repeater output or simplex; repeater slot 1: RPT1, 15RP, Baofeng ch23)"},
	{"ch16", []string{"rpt2", "16rp", "ch24"}, 462_575_000, mNFM, "GMRS channel 16, 462.575 MHz (repeater output or simplex; repeater slot 2: RPT2, 16RP, Baofeng ch24)"},
	{"ch17", []string{"rpt3", "17rp", "ch25"}, 462_600_000, mNFM, "GMRS channel 17, 462.600 MHz (repeater output or simplex; repeater slot 3: RPT3, 17RP, Baofeng ch25)"},
	{"ch18", []string{"rpt4", "18rp", "ch26"}, 462_625_000, mNFM, "GMRS channel 18, 462.625 MHz (repeater output or simplex; repeater slot 4: RPT4, 18RP, Baofeng ch26)"},
	{"ch19", []string{"rpt5", "19rp", "ch27"}, 462_650_000, mNFM, "GMRS channel 19, 462.650 MHz (repeater output or simplex; repeater slot 5: RPT5, 19RP, Baofeng ch27)"},
	{"ch20", []string{"rpt6", "20rp", "ch28"}, 462_675_000, mNFM, "GMRS channel 20, 462.675 MHz (repeater output or simplex; repeater slot 6: RPT6, 20RP, Baofeng ch28)"},
	{"ch21", []string{"rpt7", "21rp", "ch29"}, 462_700_000, mNFM, "GMRS channel 21, 462.700 MHz (repeater output or simplex; repeater slot 7: RPT7, 21RP, Baofeng ch29)"},
	{"ch22", []string{"rpt8", "22rp", "ch30"}, 462_725_000, mNFM, "GMRS channel 22, 462.725 MHz (repeater output or simplex; repeater slot 8: RPT8, 22RP, Baofeng ch30)"},
}

// Presets returns the preset table in help order (a copy).
func Presets() []Preset {
	out := make([]Preset, len(presets))
	copy(out, presets)
	return out
}

func presetKey(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// ResolvePreset looks a preset up by name or alias, case-insensitively.
// The error lists the nearest names so the user can correct a typo.
func ResolvePreset(name string) (Preset, error) {
	key := presetKey(name)
	for _, p := range presets {
		if key == p.Name {
			return p, nil
		}
		for _, a := range p.Aliases {
			if key == a {
				return p, nil
			}
		}
	}
	near := NearestPresetNames(name)
	if len(near) > 0 {
		return Preset{}, fmt.Errorf("no preset called %q; did you mean %s? Check with: ley help presets", name, strings.Join(near, ", "))
	}
	return Preset{}, fmt.Errorf("no preset called %q; check with: ley help presets", name)
}

// NearestPresetNames returns up to three preset names (or aliases, whichever
// is closer) that look like input,
// for error hints: prefix and substring matches first, then names within a
// small edit distance. Empty when nothing is close.
func NearestPresetNames(input string) []string {
	key := presetKey(input)
	if key == "" {
		return nil
	}
	type cand struct {
		name string
		rank int
	}
	var cands []cand
	for _, p := range presets {
		best, bestName := -1, p.Name
		for _, n := range append([]string{p.Name}, p.Aliases...) {
			r := -1
			switch {
			case strings.HasPrefix(n, key) || strings.HasPrefix(key, n):
				r = 0
			case strings.Contains(n, key) || strings.Contains(key, n):
				r = 1
			default:
				if d := editDistance(n, key); d <= 2 || (len(key) >= 5 && d <= len(key)/2) {
					r = 2 + d
				}
			}
			if r >= 0 && (best < 0 || r < best) {
				best, bestName = r, n
			}
		}
		if best >= 0 {
			cands = append(cands, cand{bestName, best})
		}
	}
	sort.SliceStable(cands, func(i, j int) bool { return cands[i].rank < cands[j].rank })
	out := make([]string, 0, 3)
	for _, c := range cands {
		if len(out) == 3 {
			break
		}
		out = append(out, c.name)
	}
	return out
}

// editDistance is the Levenshtein distance between two short strings.
func editDistance(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	prev := make([]int, len(rb)+1)
	cur := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(rb)]
}
