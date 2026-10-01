// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"fmt"
	"sort"
	"strings"
	"sync"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// Preset is a named frequency a newcomer is likely to reach for: one plan
// channel of the band table, seen from the dial. The table is a view over
// the plans, never a second list, so `ley tune ch5`, the CHANNEL column and
// the app read one source (docs/design/channels.md, "The plan is data in the
// band table"). Resolving a preset is a client-side translation into the
// same tune RPC a numeric frequency uses. No probing, no wire change.
type Preset struct {
	// Name is the plan-prefixed alias (wx3, marine16, cb19, murs1; GMRS keeps
	// ch17): the one word that resolves without a band and the one every
	// table prints (the plan's KTD1).
	Name string
	// Aliases start with the name the service's radios print (WX3, 16) when
	// it differs from Name, then the entry's other names. A bare number
	// among them resolves only under --band.
	Aliases []string
	Hz      uint64
	Mode    leylinev1.DemodMode
	// BandwidthHz is the channel's own width where the plan gives one
	// (MURS 1 to 3 are 11.25 kHz), else the band's.
	BandwidthHz uint32
	// Description is the band, the channel, its note and its frequency in one
	// line, for a banner or --json; Note is the channel's note alone, for a
	// table whose other columns already say the rest.
	Description string
	Note        string
	// Band is the name of the band or group whose plan the channel is in.
	Band string
}

var (
	presetsOnce sync.Once
	presetTable []Preset
)

// presets builds the view once: one preset per channel, the bands in
// frequency order and then the groups, each plan in its own order.
func presets() []Preset {
	presetsOnce.Do(func() {
		eachChannel(func(b Band, c Channel) {
			presetTable = append(presetTable, PresetOf(b, c))
		})
	})
	return presetTable
}

// PresetOf is the dial's view of one plan entry: what `ley presets` prints
// for it and what a resolved name answers with. `ley help presets` walks the
// bands itself so it can head each plan with its band, and builds each row
// through this rather than resolving a name it already holds.
func PresetOf(b Band, c Channel) Preset {
	p := Preset{Name: c.Aliases[0], Hz: c.Hz, Mode: c.Mode, BandwidthHz: c.BandwidthHz, Note: c.Note, Band: b.Name}
	if p.Mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		p.Mode = b.Mode
		if p.Mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
			p.Mode = sidebandFor(c.Hz)
		}
	}
	if p.BandwidthHz == 0 {
		p.BandwidthHz = b.BandwidthHz
	}
	if presetKey(c.Name) != p.Name {
		p.Aliases = append(p.Aliases, c.Name)
	}
	p.Aliases = append(p.Aliases, c.Aliases[1:]...)
	desc := b.Name + " " + c.Name
	if c.Note != "" {
		desc += ", " + c.Note
	}
	p.Description = desc + " (" + FormatFrequency(c.Hz) + ")"
	return p
}

// Presets returns the preset table in help order (a copy).
func Presets() []Preset {
	ps := presets()
	out := make([]Preset, len(ps))
	copy(out, ps)
	return out
}

func presetKey(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// channelNumber reports whether a name is digits only: a radio-printed
// channel number, which resolves only in band context so that `16` is never
// ambiguous and never a frequency (docs/design/channels.md, "The plan is data
// in the band table").
func channelNumber(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// ResolvePreset looks a preset up by name or alias, case-insensitively.
// The error lists the nearest names so the user can correct a typo.
func ResolvePreset(name string) (Preset, error) {
	key := presetKey(name)
	if !channelNumber(key) {
		for _, p := range presets() {
			if key == p.Name {
				return p, nil
			}
			for _, a := range p.Aliases {
				if key == presetKey(a) {
					return p, nil
				}
			}
		}
	}
	near := NearestPresetNames(name)
	if len(near) > 0 {
		return Preset{}, fmt.Errorf("no preset called %q; did you mean %s? Check with: ley help presets", name, strings.Join(near, ", "))
	}
	return Preset{}, fmt.Errorf("no preset called %q; check with: ley help presets", name)
}

// channelKey normalises a name typed under --band: case-insensitive, and a
// leading zero dropped so `06` and `6` both reach marine channel 6, which
// radios print either way.
func channelKey(s string) string {
	key := presetKey(s)
	for len(key) > 1 && key[0] == '0' && key[1] >= '0' && key[1] <= '9' {
		key = key[1:]
	}
	return key
}

// ResolvePlanChannel looks a name up in one band's plan: the name the radio
// prints (16, WX3, 24 coast), with or without a leading zero, or any of the
// entry's aliases. This is the band-context lookup `--band` gives the dial,
// separate from ResolvePreset, which is why a channel may carry an alias
// equal to one of its band's (docs/design/channels.md, "The CLI"). A part of a
// group answers through the group's plan.
func ResolvePlanChannel(band Band, name string) (Preset, bool) {
	key := channelKey(name)
	if key == "" {
		return Preset{}, false
	}
	owner := band.planOwner()
	for _, c := range owner.Channels {
		if key == channelKey(c.Name) {
			return PresetOf(owner, c), true
		}
		for _, a := range c.Aliases {
			if key == channelKey(a) {
				return PresetOf(owner, c), true
			}
		}
	}
	return Preset{}, false
}

// NearestPresetNames returns up to three preset names (or aliases, whichever
// is closer) that look like input,
// for error hints: an exact alias first, then prefix and substring matches,
// then names within a small edit distance. Empty when nothing is close.
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
	for _, p := range presets() {
		best, bestName := -1, p.Name
		for _, n := range append([]string{p.Name}, p.Aliases...) {
			n = presetKey(n)
			if channelNumber(n) {
				// A channel number resolves only under --band, so it is no hint here.
				continue
			}
			r := -1
			switch {
			case n == key:
				r = 0
			case strings.HasPrefix(n, key) || strings.HasPrefix(key, n):
				r = 1
			case strings.Contains(n, key) || strings.Contains(key, n):
				r = 2
			default:
				if d := editDistance(n, key); d <= 2 || (len(key) >= 5 && d <= len(key)/2) {
					r = 3 + d
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
