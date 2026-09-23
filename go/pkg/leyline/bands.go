// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"fmt"
	"sort"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// Band is a named slice of spectrum with the mode and bandwidth a newcomer
// would most likely want there. The table is presentation-only: it drives
// the CLI's defaults and the words it prints, never the daemon. Mode is
// UNSPECIFIED for bands where the mode depends on the exact frequency
// (HF amateur segments: USB at or above 10 MHz, LSB below, see ResolveMode).
type Band struct {
	Name string
	// Aliases are what a person types for this band. They exist because the
	// full names have spaces ("2 m amateur") and are unusable as arguments.
	//
	// They are not accepted where a frequency is: `2m`, `20m` and
	// `160m` already parse as 2, 20 and 160 MHz, so a band name in that
	// position would silently redefine seven of these fourteen entries. They
	// are reached through `--band`, which cannot be mistaken for a frequency.
	Aliases     []string
	MinHz       uint64
	MaxHz       uint64
	Mode        leylinev1.DemodMode
	BandwidthHz uint32
	// StepHz is how far one arrow key moves the dial here: the band's channel
	// spacing, which is not its bandwidth. Airband is 10 kHz wide per channel
	// and spaced 25 kHz, so tuning by the bandwidth would land between
	// channels twice before reaching the next one. Fine tuning is
	// FineStepHz. The app reads it from bands.json; ley uses it nowhere yet.
	StepHz uint32
	Note   string
	// Parts, when set, makes this a group: a service in more than one place,
	// spanning its parts and the spectrum between them. The parts are the
	// first aliases of the bands it is made of. A sweep takes the group whole;
	// a picture or a watch, which needs the range in one capture, is refused
	// with the parts named unless the radio captures that wide. Groups are not
	// in the frequency-ordered table, so BandFor never labels the gap between
	// two parts with the group's name.
	Parts []string
}

// IsGroup reports whether the band spans several parts.
func (b Band) IsGroup() bool { return len(b.Parts) > 0 }

// WidthHz is how much spectrum the band covers.
func (b Band) WidthHz() uint64 { return b.MaxHz - b.MinHz }

// CenterHz is the middle of the band, which is where a view showing the whole
// band puts the radio.
func (b Band) CenterHz() uint64 { return b.MinHz + b.WidthHz()/2 }

// FineStepHz is the fine tuning step: a tenth of the band's channel step, and
// never below 100 Hz. A tenth takes ten presses to cross a channel, and a held
// key still crosses one quickly; below 100 Hz a step is smaller than a voice
// channel's drift, so the readout changes with no audible difference.
func (b Band) FineStepHz() uint32 {
	if b.StepHz/10 < 100 {
		return 100
	}
	return b.StepHz / 10
}

const (
	mAM  = leylinev1.DemodMode_AM
	mNFM = leylinev1.DemodMode_NFM
	mWFM = leylinev1.DemodMode_WFM
	mSSB = leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED // sideband chosen by frequency
)

// bands is ordered by frequency; ranges are inclusive of both bounds and do not
// overlap. The table is not a complete allocation chart: spectrum between two
// entries — above the top marine VHF channel at 162.025 MHz and below the NOAA
// weather block at 162.400, say — belongs to no band, and BandFor answers nil.
var bands = []Band{
	{"AM broadcast", []string{"am", "mw", "ambcast"}, 530_000, 1_700_000, mAM, 10_000, 10_000, "medium-wave broadcast stations", nil},
	{"160 m amateur", []string{"160m"}, 1_800_000, 2_000_000, mSSB, 2_800, 1_000, "amateur radio, LSB voice", nil},
	{"80 m amateur", []string{"80m"}, 3_500_000, 4_000_000, mSSB, 2_800, 1_000, "amateur radio, LSB voice", nil},
	{"40 m amateur", []string{"40m"}, 7_000_000, 7_300_000, mSSB, 2_800, 1_000, "amateur radio, LSB voice", nil},
	{"20 m amateur", []string{"20m"}, 14_000_000, 14_350_000, mSSB, 2_800, 1_000, "amateur radio, USB voice", nil},
	{"15 m amateur", []string{"15m"}, 21_000_000, 21_450_000, mSSB, 2_800, 1_000, "amateur radio, USB voice", nil},
	{"CB", []string{"cb", "citizens"}, 26_965_000, 27_405_000, mAM, 10_000, 10_000, "citizens band, channel 1 to 40", nil},
	{"10 m amateur", []string{"10m"}, 28_000_000, 29_700_000, mSSB, 2_800, 1_000, "amateur radio, USB voice", nil},
	{"FM broadcast", []string{"fm", "fmbcast", "broadcast"}, 87_500_000, 108_000_000, mWFM, 200_000, 200_000, "wideband FM radio stations", nil},
	{"airband", []string{"air", "aviation"}, 118_000_000, 137_000_000, mAM, 10_000, 25_000, "aircraft and towers, AM voice", nil},
	{"2 m amateur", []string{"2m"}, 144_000_000, 148_000_000, mNFM, 12_500, 5_000, "amateur radio, FM voice and repeaters", nil},
	{"marine VHF", []string{"marine", "vhf"}, 156_000_000, 162_025_000, mNFM, 12_500, 25_000, "ship and coast stations; channel 16 is 156.800", nil},
	{"NOAA weather", []string{"noaa", "weather", "wx"}, 162_400_000, 162_550_000, mNFM, 12_500, 25_000, "continuous weather broadcasts, WX1 to WX7", nil},
	{"70 cm amateur", []string{"70cm"}, 420_000_000, 450_000_000, mNFM, 12_500, 12_500, "amateur radio, FM voice and repeaters", nil},
	// GMRS/FRS is one service in two places 5 MHz apart, so it is two bands and a group. The
	// edges sit half a channel outside the lowest and highest channel of each half (ch15 at
	// 462.550 to ch22 at 462.725; the repeater inputs 467.550 to 467.725, with ch8 to ch14 between).
	{
		"GMRS 462 MHz",
		[]string{"gmrs-462", "gmrs-out", "gmrs-outputs", "gmrs-simplex"},
		462_537_500, 462_737_500, mNFM, 20_000, 12_500,
		"GMRS/FRS channels 1 to 7 and 15 to 22: simplex and the repeater outputs -- scan here to find a repeater's transmit", nil,
	},
	{
		"GMRS 467 MHz",
		[]string{"gmrs-467", "gmrs-in", "gmrs-inputs"},
		467_537_500, 467_737_500, mNFM, 20_000, 12_500,
		"GMRS/FRS channels 8 to 14 (low power) and the repeater inputs, the uplink a radio transmits to a repeater", nil,
	},
}

// bandGroups are the services that live in more than one place. `gmrs` is the whole GMRS/FRS
// service, both halves and the 4.8 MHz between them: what a sweep should cover when somebody
// asks for "GMRS", and too wide for one capture on an RTL-SDR, so a picture or a watch is
// refused with a hint to use one half.
var bandGroups = []Band{
	{
		"GMRS",
		[]string{"gmrs"},
		462_537_500, 467_737_500, mNFM, 20_000, 12_500,
		"GMRS/FRS, the whole service: both halves 5 MHz apart; scan sweeps it, a picture or a watch takes gmrs-462 or gmrs-467",
		[]string{"gmrs-462", "gmrs-467"},
	},
}

// BandGroups returns the groups (a copy), in frequency order.
func BandGroups() []Band {
	out := make([]Band, len(bandGroups))
	copy(out, bandGroups)
	return out
}

// BandsWithin returns the bands that lie wholly inside the range, in frequency order: the parts
// a view or a watch can take when the whole is too wide.
func BandsWithin(minHz, maxHz uint64) []Band {
	var out []Band
	for _, b := range bands {
		if b.MinHz >= minHz && b.MaxHz <= maxHz {
			out = append(out, b)
		}
	}
	return out
}

// Bands returns the band table in frequency order (a copy).
func Bands() []Band {
	out := make([]Band, len(bands))
	copy(out, bands)
	return out
}

// bandKey normalises a band name or alias for lookup: case-insensitive, and
// spaces removed so both "2m" and "2 m amateur" reach the same entry.
func bandKey(s string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(s)), " ", "")
}

// ResolveBand looks a band up by alias or full name, case-insensitively. The
// error lists the aliases, because users cannot be expected to guess band names.
//
// This is reached only through an explicit `--band`, never where a frequency is
// accepted: `2m`, `20m` and `160m` already parse as 2, 20 and 160 MHz.
func ResolveBand(name string) (Band, error) {
	key := bandKey(name)
	if key == "" {
		return Band{}, fmt.Errorf("no band name given; try one of %s", strings.Join(BandAliases(), ", "))
	}
	for _, table := range [][]Band{bands, bandGroups} {
		for _, b := range table {
			if key == bandKey(b.Name) {
				return b, nil
			}
			for _, a := range b.Aliases {
				if key == a {
					return b, nil
				}
			}
		}
	}
	if near := NearestBandNames(name); len(near) > 0 {
		return Band{}, fmt.Errorf("no band called %q; did you mean %s? Check with: ley bands", name, strings.Join(near, ", "))
	}
	return Band{}, fmt.Errorf("no band called %q; try one of %s, or check with: ley bands", name, strings.Join(BandAliases(), ", "))
}

// BandAliases is every band's first alias, in frequency order, the groups
// after: the short list an error message can print without becoming a table.
func BandAliases() []string {
	out := make([]string, 0, len(bands)+len(bandGroups))
	for _, table := range [][]Band{bands, bandGroups} {
		for _, b := range table {
			if len(b.Aliases) > 0 {
				out = append(out, b.Aliases[0])
			}
		}
	}
	return out
}

// NearestBandNames returns up to three aliases that look like input, for error
// hints: prefix and substring matches first, then a small edit distance.
func NearestBandNames(input string) []string {
	key := bandKey(input)
	if key == "" {
		return nil
	}
	type cand struct {
		name string
		rank int
	}
	var out []cand
	for _, b := range append(Bands(), bandGroups...) {
		for _, a := range b.Aliases {
			switch {
			case strings.HasPrefix(a, key) || strings.HasPrefix(key, a):
				out = append(out, cand{a, 0})
			case strings.Contains(a, key) || strings.Contains(key, a):
				out = append(out, cand{a, 1})
			case editDistance(a, key) <= 2:
				out = append(out, cand{a, 2})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].rank < out[j].rank })
	names := make([]string, 0, 3)
	seen := map[string]bool{}
	for _, c := range out {
		if seen[c.name] {
			continue
		}
		seen[c.name] = true
		names = append(names, c.name)
		if len(names) == 3 {
			break
		}
	}
	return names
}

// BandFor returns the band containing hz, or nil when no band is recognised.
// Callers fall back to NFM and say so ("no band recognised, using NFM").
func BandFor(hz uint64) *Band {
	for i := range bands {
		if hz >= bands[i].MinHz && hz <= bands[i].MaxHz {
			b := bands[i]
			return &b
		}
	}
	return nil
}

// DefaultMode returns the mode a newcomer would want at hz: the band's mode,
// sideband-by-frequency on HF amateur segments, and NFM when no band is
// recognised. The second result reports whether a band was recognised.
func DefaultMode(hz uint64) (leylinev1.DemodMode, *Band) {
	b := BandFor(hz)
	if b == nil {
		return leylinev1.DemodMode_NFM, nil
	}
	if b.Mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		return sidebandFor(hz), b
	}
	return b.Mode, b
}

// sidebandFor applies the amateur convention: LSB below 10 MHz, USB above.
func sidebandFor(hz uint64) leylinev1.DemodMode {
	if hz >= 10_000_000 {
		return leylinev1.DemodMode_USB
	}
	return leylinev1.DemodMode_LSB
}

// BandwidthFor returns the bandwidth to use at hz for mode: the band's
// bandwidth when the band's mode matches, else the mode's default.
func BandwidthFor(hz uint64, mode leylinev1.DemodMode) uint32 {
	if b := BandFor(hz); b != nil && b.BandwidthHz > 0 {
		bm := b.Mode
		if bm == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
			bm = sidebandFor(hz)
		}
		if bm == mode {
			return b.BandwidthHz
		}
	}
	return DefaultBandwidth(mode)
}
