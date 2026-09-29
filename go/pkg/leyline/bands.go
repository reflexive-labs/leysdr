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
	// Channels is the band's plan: the numbered channels a service's radios
	// print, in the service's own order, or nil where the band has none. A
	// plan is always a list, never min + n × step: CB skips 20 kHz at five
	// places and numbers 23 to 25 out of frequency order, marine's duplex
	// channels have a ship and a coast entry each. A group's plan hangs off
	// the group, because GMRS numbering spans both halves
	// (docs/design/channels.md, "The plan is data in the band table").
	Channels []Channel
}

// Channel is one entry of a band's plan. Name is what the service's radios
// print (WX3, 16, 19, 1; GMRS keeps ch17); Aliases start with the
// plan-prefixed global alias (wx3, marine16, cb19, murs1), the one form that
// resolves without a band, and may go on to the other names a radio prints
// for the same slot. A bare number in Aliases is a radio-printed channel
// number and resolves only in band context, so `16` is never ambiguous and
// never a frequency (docs/design/channels.md, "The plan is data in the band
// table"). Mode and BandwidthHz are set only where they differ from the
// band's; Decoder names the daemon decoder for a data channel.
type Channel struct {
	Name        string
	Aliases     []string
	Hz          uint64
	Mode        leylinev1.DemodMode
	BandwidthHz uint32
	Note        string
	Decoder     string
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

// Plan is the channel list a name resolves against under this band: the
// band's own, or its group's when the band is a part of one, since the plan
// of a service in two places hangs off the group (`--band gmrs-462 5` is
// still GMRS channel 5).
func (b Band) Plan() []Channel { return b.planOwner().Channels }

// planOwner is the band whose plan answers for this one: the band itself, or
// the group it is a part of when it has no plan of its own.
func (b Band) planOwner() Band {
	if len(b.Channels) > 0 || len(b.Aliases) == 0 {
		return b
	}
	for _, g := range bandGroups {
		for _, part := range g.Parts {
			if part == b.Aliases[0] {
				return g
			}
		}
	}
	return b
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
//
// The plans were checked against the listings named beside each one on
// 2026-09-28; the table is US, as docs/design/channels.md says.
var bands = []Band{
	{
		Name: "AM broadcast", Aliases: []string{"am", "mw", "ambcast"},
		MinHz: 530_000, MaxHz: 1_700_000, Mode: mAM, BandwidthHz: 10_000, StepHz: 10_000,
		Note: "medium-wave broadcast stations",
	},
	{
		Name: "160 m amateur", Aliases: []string{"160m"},
		MinHz: 1_800_000, MaxHz: 2_000_000, Mode: mSSB, BandwidthHz: 2_800, StepHz: 1_000,
		Note: "amateur radio, LSB voice",
	},
	{
		Name: "80 m amateur", Aliases: []string{"80m"},
		MinHz: 3_500_000, MaxHz: 4_000_000, Mode: mSSB, BandwidthHz: 2_800, StepHz: 1_000,
		Note: "amateur radio, LSB voice",
	},
	{
		Name: "40 m amateur", Aliases: []string{"40m"},
		MinHz: 7_000_000, MaxHz: 7_300_000, Mode: mSSB, BandwidthHz: 2_800, StepHz: 1_000,
		Note: "amateur radio, LSB voice",
	},
	{
		Name: "20 m amateur", Aliases: []string{"20m"},
		MinHz: 14_000_000, MaxHz: 14_350_000, Mode: mSSB, BandwidthHz: 2_800, StepHz: 1_000,
		Note: "amateur radio, USB voice",
	},
	{
		Name: "15 m amateur", Aliases: []string{"15m"},
		MinHz: 21_000_000, MaxHz: 21_450_000, Mode: mSSB, BandwidthHz: 2_800, StepHz: 1_000,
		Note: "amateur radio, USB voice",
	},
	{
		Name: "CB", Aliases: []string{"cb", "citizens"},
		MinHz: 26_965_000, MaxHz: 27_405_000, Mode: mAM, BandwidthHz: 10_000, StepHz: 10_000,
		Note:     "citizens band, channel 1 to 40",
		Channels: cbPlan,
	},
	{
		Name: "10 m amateur", Aliases: []string{"10m"},
		MinHz: 28_000_000, MaxHz: 29_700_000, Mode: mSSB, BandwidthHz: 2_800, StepHz: 1_000,
		Note: "amateur radio, USB voice",
	},
	{
		Name: "6 m amateur", Aliases: []string{"6m"},
		MinHz: 50_000_000, MaxHz: 54_000_000, Mode: mNFM, BandwidthHz: 12_500, StepHz: 10_000,
		Note: "amateur radio, FM voice and repeaters; USB below 50.3",
	},
	{
		Name: "FM broadcast", Aliases: []string{"fm", "fmbcast", "broadcast"},
		MinHz: 87_500_000, MaxHz: 108_000_000, Mode: mWFM, BandwidthHz: 200_000, StepHz: 200_000,
		Note: "wideband FM radio stations",
	},
	{
		Name: "airband", Aliases: []string{"air", "aviation"},
		MinHz: 118_000_000, MaxHz: 137_000_000, Mode: mAM, BandwidthHz: 10_000, StepHz: 25_000,
		Note: "aircraft and towers, AM voice",
		// The rest of the band is local and unnumbered; guard is the one
		// frequency every listener knows.
		Channels: []Channel{
			{Name: "guard", Aliases: []string{"guard", "aircraft-guard", "121.5"}, Hz: 121_500_000, Note: "aviation emergency frequency"},
		},
	},
	{
		Name: "2 m amateur", Aliases: []string{"2m"},
		MinHz: 144_000_000, MaxHz: 148_000_000, Mode: mNFM, BandwidthHz: 12_500, StepHz: 5_000,
		Note: "amateur radio, FM voice and repeaters",
		Channels: []Channel{
			{Name: "aprs", Aliases: []string{"aprs"}, Hz: 144_390_000, Note: "APRS packet, North America", Decoder: "aprs"},
			{Name: "calling", Aliases: []string{"calling", "2m-calling", "simplex"}, Hz: 146_520_000, Note: "national simplex calling frequency"},
		},
	},
	// MURS is two clusters 2.6 MHz apart, so it is two bands and a group, as GMRS is: one band
	// would label the business and public-safety spectrum between them as MURS. Each half is
	// padded 10 kHz (half a 20 kHz channel) beyond its outer channels; 47 CFR 95.2763 lists the
	// channels and 95.2773 the widths (docs/design/channels.md, "The plan is data in the band
	// table").
	{
		Name: "MURS 151 MHz", Aliases: []string{"murs-151"},
		MinHz: 151_810_000, MaxHz: 151_950_000, Mode: mNFM, BandwidthHz: 11_250, StepHz: 60_000,
		Note: "MURS channels 1 to 3, licence-free, 11.25 kHz wide",
	},
	{
		Name: "MURS 154 MHz", Aliases: []string{"murs-154"},
		MinHz: 154_560_000, MaxHz: 154_610_000, Mode: mNFM, BandwidthHz: 20_000, StepHz: 30_000,
		Note: "MURS channels 4 and 5, licence-free, 20 kHz wide",
	},
	{
		Name: "marine VHF", Aliases: []string{"marine", "vhf"},
		MinHz: 156_000_000, MaxHz: 162_025_000, Mode: mNFM, BandwidthHz: 12_500, StepHz: 25_000,
		Note:     "ship and coast stations; channel 16 is 156.800",
		Channels: marinePlan,
	},
	{
		Name: "NOAA weather", Aliases: []string{"noaa", "weather", "wx"},
		MinHz: 162_400_000, MaxHz: 162_550_000, Mode: mNFM, BandwidthHz: 12_500, StepHz: 25_000,
		Note: "continuous weather broadcasts, WX1 to WX7",
		// WX1 to WX7 in the numbering the preset table always used, which is the
		// USCG channel page's; NWS lists the seven frequencies unnumbered. `noaa`
		// and `weather` stay on WX1 because scripts tune it by those words. SAME
		// alerts ride under every channel.
		Channels: []Channel{
			{Name: "WX1", Aliases: []string{"wx1", "noaa1", "noaa", "weather"}, Hz: 162_550_000, Decoder: "same"},
			{Name: "WX2", Aliases: []string{"wx2", "noaa2"}, Hz: 162_400_000, Decoder: "same"},
			{Name: "WX3", Aliases: []string{"wx3", "noaa3"}, Hz: 162_475_000, Decoder: "same"},
			{Name: "WX4", Aliases: []string{"wx4", "noaa4"}, Hz: 162_425_000, Decoder: "same"},
			{Name: "WX5", Aliases: []string{"wx5", "noaa5"}, Hz: 162_450_000, Decoder: "same"},
			{Name: "WX6", Aliases: []string{"wx6", "noaa6"}, Hz: 162_500_000, Decoder: "same"},
			{Name: "WX7", Aliases: []string{"wx7", "noaa7"}, Hz: 162_525_000, Decoder: "same"},
		},
	},
	{
		Name: "1.25 m amateur", Aliases: []string{"1.25m"},
		MinHz: 222_000_000, MaxHz: 225_000_000, Mode: mNFM, BandwidthHz: 12_500, StepHz: 20_000,
		Note: "amateur radio, FM voice and repeaters",
	},
	{
		Name: "70 cm amateur", Aliases: []string{"70cm"},
		MinHz: 420_000_000, MaxHz: 450_000_000, Mode: mNFM, BandwidthHz: 12_500, StepHz: 12_500,
		Note: "amateur radio, FM voice and repeaters",
	},
	// GMRS/FRS is one service in two places 5 MHz apart, so it is two bands and a group. The
	// edges sit half a channel outside the lowest and highest channel of each half (ch15 at
	// 462.550 to ch22 at 462.725; the repeater inputs 467.550 to 467.725, with ch8 to ch14 between).
	{
		Name:    "GMRS 462 MHz",
		Aliases: []string{"gmrs-462", "gmrs-out", "gmrs-outputs", "gmrs-simplex"},
		MinHz:   462_537_500, MaxHz: 462_737_500, Mode: mNFM, BandwidthHz: 20_000, StepHz: 12_500,
		Note: "GMRS/FRS channels 1 to 7 and 15 to 22: simplex and the repeater outputs -- scan here to find a repeater's transmit",
	},
	{
		Name:    "GMRS 467 MHz",
		Aliases: []string{"gmrs-467", "gmrs-in", "gmrs-inputs"},
		MinHz:   467_537_500, MaxHz: 467_737_500, Mode: mNFM, BandwidthHz: 20_000, StepHz: 12_500,
		Note: "GMRS/FRS channels 8 to 14 (low power) and the repeater inputs, the uplink a radio transmits to a repeater",
	},
}

// bandGroups are the services that live in more than one place. `gmrs` is the whole GMRS/FRS
// service, both halves and the 4.8 MHz between them: what a sweep should cover when somebody
// asks for "GMRS", and too wide for one capture on an RTL-SDR, so a picture or a watch is
// refused with a hint to use one half. `murs` is the same shape 2.6 MHz across.
var bandGroups = []Band{
	{
		Name:    "GMRS",
		Aliases: []string{"gmrs", "frs"},
		MinHz:   462_537_500, MaxHz: 467_737_500, Mode: mNFM, BandwidthHz: 20_000, StepHz: 12_500,
		Note:     "GMRS/FRS, the whole service: both halves 5 MHz apart; scan sweeps it, a picture or a watch takes gmrs-462 or gmrs-467",
		Parts:    []string{"gmrs-462", "gmrs-467"},
		Channels: gmrsPlan,
	},
	{
		Name:    "MURS",
		Aliases: []string{"murs"},
		MinHz:   151_810_000, MaxHz: 154_610_000, Mode: mNFM, BandwidthHz: 11_250, StepHz: 30_000,
		Note:  "MURS, the whole service: three channels near 151.9 MHz and two near 154.6 MHz; scan sweeps it, a picture or a watch takes murs-151 or murs-154",
		Parts: []string{"murs-151", "murs-154"},
		// 47 CFR 95.2763 (the channels) and 95.2773 (11.25 kHz on the three 151 MHz channels,
		// 20 kHz on the two 154 MHz channels).
		Channels: []Channel{
			{Name: "1", Aliases: []string{"murs1"}, Hz: 151_820_000, BandwidthHz: 11_250},
			{Name: "2", Aliases: []string{"murs2"}, Hz: 151_880_000, BandwidthHz: 11_250},
			{Name: "3", Aliases: []string{"murs3"}, Hz: 151_940_000, BandwidthHz: 11_250},
			{Name: "4", Aliases: []string{"murs4"}, Hz: 154_570_000, BandwidthHz: 20_000},
			{Name: "5", Aliases: []string{"murs5"}, Hz: 154_600_000, BandwidthHz: 20_000},
		},
	},
}

// gmrsPlan is GMRS by channel number, the labelling every GMRS radio shares (47 CFR 95.1763:
// the 462 MHz interstitials are 1 to 7, the 467 MHz interstitials 8 to 14, the 462 MHz main
// channels 15 to 22; the 467 MHz main channels are the repeater inputs, 5 MHz above 15 to 22).
// A channel is what you tune to LISTEN. Channels 15 to 22 are also the repeater outputs, so
// they carry every name a radio might print for the same slot: `rptN` (repeater slot 1 to 8,
// what a Baofeng shows as RPT3), `NNrp` (17RP, the channel-numbered form), and Baofeng's ch23
// to ch30. So `ley tune rpt3`, `ley tune 17rp` and `ley tune ch25` all reach ch17. Midland's
// own 1 to 8 repeater numbering is not aliased: it collides with the simplex ch1 to ch8. A
// repeater built from two independent radios can transmit on any of these, not just the one
// paired +5 MHz with its input, so `ley scan gmrs` is how you find where it actually is.
//
// `chN` stays the name and the global alias, because scripts and the MCP tool descriptions use
// it; the bare number is what the radio prints and resolves under --band gmrs.
var gmrsPlan = []Channel{
	{Name: "ch1", Aliases: []string{"ch1", "gmrs1", "1"}, Hz: 462_562_500, Note: "simplex, shared with FRS"},
	{Name: "ch2", Aliases: []string{"ch2", "gmrs2", "2"}, Hz: 462_587_500, Note: "simplex, shared with FRS"},
	{Name: "ch3", Aliases: []string{"ch3", "gmrs3", "3"}, Hz: 462_612_500, Note: "simplex, shared with FRS"},
	{Name: "ch4", Aliases: []string{"ch4", "gmrs4", "4"}, Hz: 462_637_500, Note: "simplex, shared with FRS"},
	{Name: "ch5", Aliases: []string{"ch5", "gmrs5", "5"}, Hz: 462_662_500, Note: "simplex, shared with FRS"},
	{Name: "ch6", Aliases: []string{"ch6", "gmrs6", "6"}, Hz: 462_687_500, Note: "simplex, shared with FRS"},
	{Name: "ch7", Aliases: []string{"ch7", "gmrs7", "7"}, Hz: 462_712_500, Note: "simplex, shared with FRS"},
	{Name: "ch8", Aliases: []string{"ch8", "gmrs8", "8"}, Hz: 467_562_500, Note: "simplex, low power"},
	{Name: "ch9", Aliases: []string{"ch9", "gmrs9", "9"}, Hz: 467_587_500, Note: "simplex, low power"},
	{Name: "ch10", Aliases: []string{"ch10", "gmrs10", "10"}, Hz: 467_612_500, Note: "simplex, low power"},
	{Name: "ch11", Aliases: []string{"ch11", "gmrs11", "11"}, Hz: 467_637_500, Note: "simplex, low power"},
	{Name: "ch12", Aliases: []string{"ch12", "gmrs12", "12"}, Hz: 467_662_500, Note: "simplex, low power"},
	{Name: "ch13", Aliases: []string{"ch13", "gmrs13", "13"}, Hz: 467_687_500, Note: "simplex, low power"},
	{Name: "ch14", Aliases: []string{"ch14", "gmrs14", "14"}, Hz: 467_712_500, Note: "simplex, low power"},
	{Name: "ch15", Aliases: []string{"ch15", "gmrs15", "15", "rpt1", "15rp", "ch23"}, Hz: 462_550_000, Note: "repeater slot 1 output (input +5 MHz) or simplex"},
	{Name: "ch16", Aliases: []string{"ch16", "gmrs16", "16", "rpt2", "16rp", "ch24"}, Hz: 462_575_000, Note: "repeater slot 2 output (input +5 MHz) or simplex"},
	{Name: "ch17", Aliases: []string{"ch17", "gmrs17", "17", "rpt3", "17rp", "ch25"}, Hz: 462_600_000, Note: "repeater slot 3 output (input +5 MHz) or simplex"},
	{Name: "ch18", Aliases: []string{"ch18", "gmrs18", "18", "rpt4", "18rp", "ch26"}, Hz: 462_625_000, Note: "repeater slot 4 output (input +5 MHz) or simplex"},
	{Name: "ch19", Aliases: []string{"ch19", "gmrs19", "19", "rpt5", "19rp", "ch27"}, Hz: 462_650_000, Note: "repeater slot 5 output (input +5 MHz) or simplex"},
	{Name: "ch20", Aliases: []string{"ch20", "gmrs20", "20", "rpt6", "20rp", "ch28"}, Hz: 462_675_000, Note: "repeater slot 6 output (input +5 MHz) or simplex"},
	{Name: "ch21", Aliases: []string{"ch21", "gmrs21", "21", "rpt7", "21rp", "ch29"}, Hz: 462_700_000, Note: "repeater slot 7 output (input +5 MHz) or simplex"},
	{Name: "ch22", Aliases: []string{"ch22", "gmrs22", "22", "rpt8", "22rp", "ch30"}, Hz: 462_725_000, Note: "repeater slot 8 output (input +5 MHz) or simplex"},
}

// cbPlan is CB channels 1 to 40 from the table in 47 CFR 95.963: 10 kHz apart with a 20 kHz
// gap after 3, 7, 11, 15 and 19 (the skipped slots are remote-control frequencies), and 23 to
// 25 out of frequency order because 24 and 25 were added below 23. Channel 9 is reserved for
// emergencies and traveller assistance (47 CFR 95.931).
var cbPlan = numberedPlan("cb", []numbered{
	{1, 26_965_000, ""},
	{2, 26_975_000, ""},
	{3, 26_985_000, ""},
	{4, 27_005_000, ""},
	{5, 27_015_000, ""},
	{6, 27_025_000, ""},
	{7, 27_035_000, ""},
	{8, 27_055_000, ""},
	{9, 27_065_000, "emergencies and traveller assistance"},
	{10, 27_075_000, ""},
	{11, 27_085_000, ""},
	{12, 27_105_000, ""},
	{13, 27_115_000, ""},
	{14, 27_125_000, ""},
	{15, 27_135_000, ""},
	{16, 27_155_000, ""},
	{17, 27_165_000, ""},
	{18, 27_175_000, ""},
	{19, 27_185_000, "the highway channel, by custom"},
	{20, 27_205_000, ""},
	{21, 27_215_000, ""},
	{22, 27_225_000, ""},
	{23, 27_255_000, ""},
	{24, 27_235_000, ""},
	{25, 27_245_000, ""},
	{26, 27_265_000, ""},
	{27, 27_275_000, ""},
	{28, 27_285_000, ""},
	{29, 27_295_000, ""},
	{30, 27_305_000, ""},
	{31, 27_315_000, ""},
	{32, 27_325_000, ""},
	{33, 27_335_000, ""},
	{34, 27_345_000, ""},
	{35, 27_355_000, ""},
	{36, 27_365_000, ""},
	{37, 27_375_000, ""},
	{38, 27_385_000, ""},
	{39, 27_395_000, ""},
	{40, 27_405_000, ""},
})

// numbered is one row of a plan whose radios print bare channel numbers.
type numbered struct {
	n    int
	hz   uint64
	note string
}

// numberedPlan expands rows into channels named by their number, each with the plan-prefixed
// global alias. It expands a list; it never computes one.
func numberedPlan(prefix string, rows []numbered) []Channel {
	out := make([]Channel, 0, len(rows))
	for _, r := range rows {
		n := fmt.Sprint(r.n)
		out = append(out, Channel{Name: n, Aliases: []string{prefix + n}, Hz: r.hz, Note: r.note})
	}
	return out
}

// marineRow is one channel of the VHF maritime plan: simplex when coastHz is 0, else a duplex
// pair with the ship's frequency and the coast station's.
type marineRow struct {
	name    string
	shipHz  uint64
	coastHz uint64
	note    string
	decoder string
	// alias is one more name the entry answers to: `marine` on 16, which
	// scripts tune by, and the ITU's AIS 1 and AIS 2 on the two AIS channels.
	alias string
}

// marinePlan is the ITU Appendix 18 plan with the US variants, from the two USCG Navigation
// Center tables ("U.S. VHF Channel Information" and "International VHF Marine Radio Channels
// and Frequencies", read 2026-09-28). A duplex channel is two entries, `24` (the ship's side)
// and `24 coast`; a US `A` channel, simplex on the ship's frequency of an ITU duplex channel, is
// its own entry and comes before the ITU entry that shares its frequency, so a carrier there is
// named by the US use (the plan's KTD2). Channels 87 and 88 are simplex in both tables now; the
// former 87B and 88B are AIS 1 and AIS 2, kept under the names radios print with the AIS decoder.
// 27 and 28 are the US table's duplex pairs: the ITU table has replaced them (WRC-19) and the US
// table says the FCC has not adopted that yet.
var marinePlan = expandMarine([]marineRow{
	{"1A", 156_050_000, 0, "port operations and VTS, New Orleans and the lower Mississippi", "", ""},
	{"1", 156_050_000, 160_650_000, "port operations and public correspondence, ITU", "", ""},
	{"2", 156_100_000, 160_700_000, "port operations and public correspondence, ITU", "", ""},
	{"3", 156_150_000, 160_750_000, "port operations and public correspondence, ITU", "", ""},
	{"4", 156_200_000, 160_800_000, "port operations and public correspondence, ITU", "", ""},
	{"5A", 156_250_000, 0, "port operations and VTS, Houston, New Orleans and Seattle", "", ""},
	{"5", 156_250_000, 160_850_000, "port operations and public correspondence, ITU", "", ""},
	{"6", 156_300_000, 0, "intership safety", "", ""},
	{"7A", 156_350_000, 0, "commercial", "", ""},
	{"7", 156_350_000, 160_950_000, "port operations and public correspondence, ITU", "", ""},
	{"8", 156_400_000, 0, "commercial, intership only", "", ""},
	{"9", 156_450_000, 0, "boater calling, commercial and non-commercial", "", ""},
	{"10", 156_500_000, 0, "commercial", "", ""},
	{"11", 156_550_000, 0, "commercial; VTS in some areas", "", ""},
	{"12", 156_600_000, 0, "port operations; VTS in some areas", "", ""},
	{"13", 156_650_000, 0, "bridge-to-bridge navigation safety", "", ""},
	{"14", 156_700_000, 0, "port operations; VTS in some areas", "", ""},
	{"15", 156_750_000, 0, "environmental, receive only", "", ""},
	{"16", 156_800_000, 0, "distress, safety and calling", "", "marine"},
	{"17", 156_850_000, 0, "state and local government maritime control", "", ""},
	{"18A", 156_900_000, 0, "commercial", "", ""},
	{"18", 156_900_000, 161_500_000, "port operations and public correspondence, ITU", "", ""},
	{"19A", 156_950_000, 0, "commercial", "", ""},
	{"19", 156_950_000, 161_550_000, "port operations and public correspondence, ITU", "", ""},
	{"20A", 157_000_000, 0, "port operations", "", ""},
	{"20", 157_000_000, 161_600_000, "port operations", "", ""},
	{"21A", 157_050_000, 0, "US Coast Guard only", "", ""},
	{"21", 157_050_000, 161_650_000, "port operations and public correspondence, ITU", "", ""},
	{"22A", 157_100_000, 0, "Coast Guard liaison and maritime safety broadcasts", "", ""},
	{"22", 157_100_000, 161_700_000, "port operations and public correspondence, ITU", "", ""},
	{"23A", 157_150_000, 0, "US Coast Guard only", "", ""},
	{"23", 157_150_000, 161_750_000, "port operations and public correspondence, ITU", "", ""},
	{"24", 157_200_000, 161_800_000, "public correspondence (marine operator)", "", ""},
	{"25", 157_250_000, 161_850_000, "public correspondence (marine operator)", "", ""},
	{"26", 157_300_000, 161_900_000, "public correspondence (marine operator)", "", ""},
	{"27", 157_350_000, 161_950_000, "public correspondence (marine operator)", "", ""},
	{"28", 157_400_000, 162_000_000, "public correspondence (marine operator)", "", ""},
	{"60", 156_025_000, 160_625_000, "port operations and public correspondence, ITU", "", ""},
	{"61", 156_075_000, 160_675_000, "port operations and public correspondence, ITU", "", ""},
	{"62", 156_125_000, 160_725_000, "port operations and public correspondence, ITU", "", ""},
	{"63A", 156_175_000, 0, "port operations and VTS, New Orleans and the lower Mississippi", "", ""},
	{"63", 156_175_000, 160_775_000, "port operations and public correspondence, ITU", "", ""},
	{"64", 156_225_000, 160_825_000, "port operations and public correspondence, ITU", "", ""},
	{"65A", 156_275_000, 0, "port operations", "", ""},
	{"65", 156_275_000, 160_875_000, "port operations and public correspondence, ITU", "", ""},
	{"66A", 156_325_000, 0, "port operations", "", ""},
	{"66", 156_325_000, 160_925_000, "port operations and public correspondence, ITU", "", ""},
	{"67", 156_375_000, 0, "commercial; bridge-to-bridge on the lower Mississippi", "", ""},
	{"68", 156_425_000, 0, "non-commercial", "", ""},
	{"69", 156_475_000, 0, "non-commercial", "", ""},
	{"70", 156_525_000, 0, "digital selective calling, no voice", "", ""},
	{"71", 156_575_000, 0, "non-commercial", "", ""},
	{"72", 156_625_000, 0, "non-commercial, intership only", "", ""},
	{"73", 156_675_000, 0, "port operations", "", ""},
	{"74", 156_725_000, 0, "port operations", "", ""},
	{"75", 156_775_000, 0, "port operations, low power, beside channel 16, ITU", "", ""},
	{"76", 156_825_000, 0, "port operations, low power, beside channel 16, ITU", "", ""},
	{"77", 156_875_000, 0, "port operations, intership only", "", ""},
	{"78A", 156_925_000, 0, "non-commercial", "", ""},
	{"78", 156_925_000, 161_525_000, "port operations and public correspondence, ITU", "", ""},
	{"79A", 156_975_000, 0, "commercial; non-commercial on the Great Lakes", "", ""},
	{"79", 156_975_000, 161_575_000, "port operations and public correspondence, ITU", "", ""},
	{"80A", 157_025_000, 0, "commercial; non-commercial on the Great Lakes", "", ""},
	{"80", 157_025_000, 161_625_000, "port operations and public correspondence, ITU", "", ""},
	{"81A", 157_075_000, 0, "US government only, environmental protection", "", ""},
	{"81", 157_075_000, 161_675_000, "port operations and public correspondence, ITU", "", ""},
	{"82A", 157_125_000, 0, "US government only", "", ""},
	{"82", 157_125_000, 161_725_000, "port operations and public correspondence, ITU", "", ""},
	{"83A", 157_175_000, 0, "US Coast Guard only", "", ""},
	{"83", 157_175_000, 161_775_000, "port operations and public correspondence, ITU", "", ""},
	{"84", 157_225_000, 161_825_000, "public correspondence (marine operator)", "", ""},
	{"85", 157_275_000, 161_875_000, "public correspondence (marine operator)", "", ""},
	{"86", 157_325_000, 161_925_000, "public correspondence (marine operator)", "", ""},
	{"87", 157_375_000, 0, "public correspondence (marine operator)", "", ""},
	{"88", 157_425_000, 0, "commercial, intership only", "", ""},
	{"87B", 161_975_000, 0, "AIS 1", "ais", "ais1"},
	{"88B", 162_025_000, 0, "AIS 2", "ais", "ais2"},
})

// expandMarine turns the rows into channels: `marine` + the lower-cased name as the global
// alias, and a second `N coast` entry for a duplex channel.
func expandMarine(rows []marineRow) []Channel {
	out := make([]Channel, 0, 2*len(rows))
	for _, r := range rows {
		key := strings.ToLower(r.name)
		aliases := []string{"marine" + key}
		if r.alias != "" {
			aliases = append(aliases, r.alias)
		}
		ch := Channel{Name: r.name, Aliases: aliases, Hz: r.shipHz, Note: r.note, Decoder: r.decoder}
		if r.coastHz == 0 {
			out = append(out, ch)
			continue
		}
		ch.Note = r.note + ", ship side"
		out = append(out, ch, Channel{
			Name:    r.name + " coast",
			Aliases: []string{"marine" + key + "-coast"},
			Hz:      r.coastHz,
			Note:    r.note + ", coast side",
		})
	}
	return out
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

// channelTolerance is how far a frequency may sit from a plan channel and
// still be "on" it: the one tolerance the Go and Swift lookups share, chosen
// so that CB's 10 kHz spacing and GMRS's 12.5 kHz both resolve to the nearer
// channel (the plan's KTD2).
const channelTolerance = 6_000

// ChannelAt names the plan channel nearest hz within 6 kHz, with the band or
// group whose plan holds it. Nearest, not first, because GMRS channels are
// only 12.5 kHz apart and a detection can sit inside the tolerance of two. Two
// entries at equal distance, which marine's US variants make common (22A and
// ITU 22 share 157.100 MHz), go to the earlier entry in plan order, walking
// the bands by frequency and then the groups (the plan's KTD2).
func ChannelAt(hz uint64) (Band, Channel, bool) {
	var (
		bestBand Band
		best     Channel
		found    bool
		bestDiff = int64(channelTolerance)
	)
	eachChannel(func(b Band, c Channel) {
		diff := int64(c.Hz) - int64(hz)
		if diff < 0 {
			diff = -diff
		}
		if diff < bestDiff || (diff == bestDiff && !found) {
			bestBand, best, found, bestDiff = b, c, true, diff
		}
	})
	return bestBand, best, found
}

// eachChannel visits every plan entry in the one order the tables define:
// the bands by frequency, then the groups, each plan in its own order. The
// preset view and ChannelAt's tie rule both depend on that order, so it is
// written here once.
func eachChannel(fn func(Band, Channel)) {
	for _, table := range [][]Band{bands, bandGroups} {
		for _, b := range table {
			for _, c := range b.Channels {
				fn(b, c)
			}
		}
	}
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
