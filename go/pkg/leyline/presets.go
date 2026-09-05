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
	{"marine16", []string{"ch16", "marine"}, 156_800_000, mNFM, "marine VHF channel 16, distress and calling (156.800 MHz)"},
	{"guard", []string{"aircraft-guard", "121.5"}, 121_500_000, mAM, "aviation emergency guard frequency (121.500 MHz)"},
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
		return Preset{}, fmt.Errorf("preset: unknown name %q; did you mean %s? (ley help presets lists them all)", name, strings.Join(near, ", "))
	}
	return Preset{}, fmt.Errorf("preset: unknown name %q; ley help presets lists them all", name)
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
