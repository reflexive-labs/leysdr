// SPDX-License-Identifier: Apache-2.0

package bandplan

import (
	"slices"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

func TestBandFor(t *testing.T) {
	cases := []struct {
		hz   uint64
		name string
		mode leylinev1.DemodMode
		bw   uint32
	}{
		{101_100_000, "FM broadcast", leylinev1.DemodMode_WFM, 200_000},
		{87_500_000, "FM broadcast", leylinev1.DemodMode_WFM, 200_000},
		{108_000_000, "FM broadcast", leylinev1.DemodMode_WFM, 200_000},
		{1_010_000, "AM broadcast", leylinev1.DemodMode_AM, 10_000},
		{121_500_000, "airband", leylinev1.DemodMode_AM, 10_000},
		{146_520_000, "2 m amateur", leylinev1.DemodMode_NFM, 12_500},
		{446_000_000, "70 cm amateur", leylinev1.DemodMode_NFM, 12_500},
		{162_550_000, "NOAA weather", leylinev1.DemodMode_NFM, 12_500},
		{162_400_000, "NOAA weather", leylinev1.DemodMode_NFM, 12_500},
		{156_800_000, "marine VHF", leylinev1.DemodMode_NFM, 12_500},
		{27_185_000, "CB", leylinev1.DemodMode_AM, 10_000},
		{1_900_000, "160 m amateur", leylinev1.DemodMode_LSB, 2_800},
		{3_800_000, "80 m amateur", leylinev1.DemodMode_LSB, 2_800},
		{7_100_000, "40 m amateur", leylinev1.DemodMode_LSB, 2_800},
		{14_200_000, "20 m amateur", leylinev1.DemodMode_USB, 2_800},
		{21_300_000, "15 m amateur", leylinev1.DemodMode_USB, 2_800},
		{28_400_000, "10 m amateur", leylinev1.DemodMode_USB, 2_800},
		{433_000_000, "70 cm amateur", leylinev1.DemodMode_NFM, 12_500},
		{462_600_000, "GMRS 462 MHz", leylinev1.DemodMode_NFM, 20_000},
		{462_550_000, "GMRS 462 MHz", leylinev1.DemodMode_NFM, 20_000},
		{462_725_000, "GMRS 462 MHz", leylinev1.DemodMode_NFM, 20_000},
		{467_600_000, "GMRS 467 MHz", leylinev1.DemodMode_NFM, 20_000},
		{467_562_500, "GMRS 467 MHz", leylinev1.DemodMode_NFM, 20_000},
	}
	for _, c := range cases {
		b := BandFor(c.hz)
		if b == nil || b.Name != c.name {
			t.Errorf("BandFor(%d) = %v, want %q", c.hz, b, c.name)
			continue
		}
		mode, got := DefaultMode(c.hz)
		if got == nil || mode != c.mode {
			t.Errorf("DefaultMode(%d) = %v, want %v", c.hz, mode, c.mode)
		}
		if bw := BandwidthFor(c.hz, mode); bw != c.bw {
			t.Errorf("BandwidthFor(%d, %v) = %d, want %d", c.hz, mode, bw, c.bw)
		}
	}
	// The table is not a complete allocation chart, and the gap between the top
	// marine channel and the NOAA weather block is where a reader is most likely
	// to expect otherwise.
	// The gap between the two GMRS halves belongs to no band: the group spans it for a sweep,
	// but a detection at 465 MHz is not GMRS.
	for _, hz := range []uint64{0, 100_000, 60_000_000, 115_000_000, 153_200_000, 162_030_000, 300_000_000, 465_000_000, 1_000_000_000} {
		if b := BandFor(hz); b != nil {
			t.Errorf("BandFor(%d) = %q, want no band", hz, b.Name)
		}
		if mode, b := DefaultMode(hz); mode != leylinev1.DemodMode_NFM || b != nil {
			t.Errorf("DefaultMode(%d) = %v %v, want NFM and nil", hz, mode, b)
		}
	}
	// Explicit mode that differs from the band's falls back to the mode default.
	if bw := BandwidthFor(101_100_000, leylinev1.DemodMode_NFM); bw != 12_500 {
		t.Errorf("BandwidthFor(FM broadcast, NFM) = %d, want 12500", bw)
	}
}

func TestBandsOrderedAndDisjoint(t *testing.T) {
	bs := Bands()
	for i, b := range bs {
		if b.MinHz >= b.MaxHz {
			t.Errorf("band %q has min >= max", b.Name)
		}
		if i > 0 && bs[i-1].MaxHz >= b.MinHz {
			t.Errorf("bands %q and %q overlap or are out of order", bs[i-1].Name, b.Name)
		}
		if b.BandwidthHz == 0 {
			t.Errorf("band %q has no bandwidth", b.Name)
		}
	}
}

// GMRS is two halves and a group: `gmrs` is the whole service for a sweep, with the halves
// named as its parts; each half resolves by its own name and by its older aliases.
func TestResolveBandGMRS(t *testing.T) {
	for _, name := range []string{"gmrs", "GMRS"} {
		b, err := ResolveBand(name)
		if err != nil || b.MinHz != 462_537_500 || b.MaxHz != 467_737_500 || !b.IsGroup() {
			t.Errorf("ResolveBand(%q) = %+v, %v; want the whole GMRS service as a group", name, b, err)
		}
		if strings.Join(b.Parts, " ") != "gmrs-462 gmrs-467" {
			t.Errorf("ResolveBand(%q).Parts = %v", name, b.Parts)
		}
	}
	for _, name := range []string{"gmrs-462", "gmrs-out", "gmrs-simplex"} {
		if b, err := ResolveBand(name); err != nil || b.MinHz != 462_537_500 || b.MaxHz != 462_737_500 || b.IsGroup() {
			t.Errorf("ResolveBand(%q) = %+v, %v; want the 462 MHz half", name, b, err)
		}
	}
	for _, name := range []string{"gmrs-467", "gmrs-in", "gmrs-inputs"} {
		if b, err := ResolveBand(name); err != nil || b.MinHz != 467_537_500 || b.MaxHz != 467_737_500 {
			t.Errorf("ResolveBand(%q) = %+v, %v; want the 467 MHz half", name, b, err)
		}
	}
	parts := BandsWithin(462_537_500, 467_737_500)
	if len(parts) != 2 || parts[0].Name != "GMRS 462 MHz" || parts[1].Name != "GMRS 467 MHz" {
		t.Errorf("BandsWithin(the group) = %v", parts)
	}
	if !slices.Contains(bandAliases(), "gmrs") {
		t.Errorf("BandAliases lacks the group: %v", bandAliases())
	}
}

// Every band carries a tuning step, groups included: the app tunes by the band's channel step,
// so a zero would leave an arrow key doing nothing there. The step is the channel spacing and
// not the bandwidth -- airband is 10 kHz wide and spaced 25 kHz -- and fine tuning is a tenth
// of it with a 100 Hz floor.
func TestEveryBandHasAStep(t *testing.T) {
	for _, b := range append(Bands(), BandGroups()...) {
		if b.StepHz == 0 {
			t.Errorf("%s has no tuning step", b.Name)
		}
		if fine := b.FineStepHz(); fine < 100 || (b.StepHz >= 1000 && fine != b.StepHz/10) {
			t.Errorf("%s: FineStepHz = %d for a step of %d", b.Name, fine, b.StepHz)
		}
	}
	air, err := ResolveBand("air")
	if err != nil || air.StepHz != 25_000 || air.BandwidthHz != 10_000 {
		t.Errorf("airband is 10 kHz wide and spaced 25 kHz, got %+v (%v)", air, err)
	}
	// A 1 kHz step floors at 100 Hz rather than going below it.
	hf, err := ResolveBand("40m")
	if err != nil || hf.StepHz != 1_000 || hf.FineStepHz() != 100 {
		t.Errorf("40 m: step %d, fine %d (%v)", hf.StepHz, hf.FineStepHz(), err)
	}
}

// MURS is two padded halves and a group, as GMRS is, and the two amateur bands an RTL-SDR
// reaches that the table lacked are in place; the table stays ordered and disjoint around them
// (docs/design/channels.md, "The plan is data in the band table").
func TestResolveBandMURSAndNewAmateurBands(t *testing.T) {
	g, err := ResolveBand("murs")
	if err != nil || !g.IsGroup() || strings.Join(g.Parts, " ") != "murs-151 murs-154" {
		t.Fatalf("ResolveBand(murs) = %+v, %v; want the group of both halves", g, err)
	}
	if len(g.Channels) != 5 {
		t.Errorf("the murs group carries the five-channel plan, got %d", len(g.Channels))
	}
	lo, err := ResolveBand("murs-151")
	if err != nil || lo.IsGroup() || lo.MinHz > 151_820_000 || lo.MaxHz < 151_940_000 || lo.MaxHz >= 154_000_000 {
		t.Errorf("murs-151 should span the three 151 MHz channels and no more: %+v %v", lo, err)
	}
	hi, err := ResolveBand("murs-154")
	if err != nil || hi.MinHz > 154_570_000 || hi.MaxHz < 154_600_000 || hi.MinHz <= 152_000_000 {
		t.Errorf("murs-154 should span the two 154 MHz channels and no more: %+v %v", hi, err)
	}
	if b := BandFor(153_200_000); b != nil {
		t.Errorf("the spectrum between the MURS halves belongs to no band, got %q", b.Name)
	}
	for _, tc := range []struct {
		alias    string
		min, max uint64
		mode     leylinev1.DemodMode
	}{
		{"6m", 50_000_000, 54_000_000, leylinev1.DemodMode_NFM},
		{"1.25m", 222_000_000, 225_000_000, leylinev1.DemodMode_NFM},
	} {
		b, err := ResolveBand(tc.alias)
		if err != nil || b.MinHz != tc.min || b.MaxHz != tc.max || b.Mode != tc.mode || len(b.Channels) != 0 {
			t.Errorf("ResolveBand(%q) = %+v, %v", tc.alias, b, err)
		}
	}
}

// Each plan has the count the design's table gives it, and the spot frequencies checked against
// the listings named in the commit hold (docs/design/channels.md, "The plan is data in the band
// table").
func TestPlansMatchTheirListings(t *testing.T) {
	plan := func(alias string) []Channel {
		t.Helper()
		b, err := ResolveBand(alias)
		if err != nil {
			t.Fatal(err)
		}
		return b.Channels
	}
	for _, tc := range []struct {
		band  string
		count int
	}{
		{"noaa", 7},
		{"gmrs", 22},
		{"murs", 5},
		{"cb", 40},
		{"2m", 2},
		{"air", 1},
		{"marine", 110},
		{"70cm", 0},
		{"6m", 0},
		{"1.25m", 0},
		{"fm", 0},
		{"am", 0},
		{"20m", 0},
	} {
		if got := len(plan(tc.band)); got != tc.count {
			t.Errorf("%s: %d channels, want %d", tc.band, got, tc.count)
		}
	}
	find := func(alias, name string) Channel {
		t.Helper()
		for _, c := range plan(alias) {
			if c.Name == name {
				return c
			}
		}
		t.Fatalf("%s has no channel named %q", alias, name)
		return Channel{}
	}
	for _, tc := range []struct {
		band, name string
		hz         uint64
		bw         uint32
		decoder    string
	}{
		{"noaa", "WX3", 162_475_000, 0, "same"},
		{"gmrs", "ch5", 462_662_500, 0, ""},
		{"murs", "1", 151_820_000, 11_250, ""},
		{"murs", "5", 154_600_000, 20_000, ""},
		{"cb", "19", 27_185_000, 0, ""},
		{"cb", "23", 27_255_000, 0, ""},
		{"cb", "24", 27_235_000, 0, ""},
		{"marine", "16", 156_800_000, 0, ""},
		{"marine", "24", 157_200_000, 0, ""},
		{"marine", "24 coast", 161_800_000, 0, ""},
		{"marine", "22A", 157_100_000, 0, ""},
		{"marine", "87B", 161_975_000, 0, "ais"},
		{"marine", "88B", 162_025_000, 0, "ais"},
		{"2m", "aprs", 144_390_000, 0, "aprs"},
		{"2m", "calling", 146_520_000, 0, ""},
		{"air", "guard", 121_500_000, 0, ""},
	} {
		c := find(tc.band, tc.name)
		if c.Hz != tc.hz || c.BandwidthHz != tc.bw || c.Decoder != tc.decoder {
			t.Errorf("%s %s = %+v, want %d Hz, %d wide, decoder %q", tc.band, tc.name, c, tc.hz, tc.bw, tc.decoder)
		}
	}
	// CB 23 to 25 are out of frequency order in the plan, as the FCC numbers them.
	if find("cb", "23").Hz <= find("cb", "24").Hz || find("cb", "24").Hz >= find("cb", "25").Hz {
		t.Error("CB 23 sits above 24 and 25 in frequency")
	}
	// Every channel lies inside its band, and every plan entry carries its plan-prefixed alias
	// first, the form that resolves without a band.
	for _, b := range append(Bands(), BandGroups()...) {
		for _, c := range b.Channels {
			if c.Hz < b.MinHz || c.Hz > b.MaxHz {
				t.Errorf("%s: channel %s at %d is outside %d..%d", b.Name, c.Name, c.Hz, b.MinHz, b.MaxHz)
			}
			if len(c.Aliases) == 0 {
				t.Errorf("%s: channel %s has no global alias", b.Name, c.Name)
			}
		}
	}
}

// One tolerance for "on a channel", the nearest within 6 kHz, and a tie goes to the earlier
// entry in plan order: the US variant entered before the ITU entry that shares its frequency.
func TestChannelAt(t *testing.T) {
	for _, tc := range []struct {
		hz   uint64
		name string
		ok   bool
	}{
		{162_475_000, "WX3", true},
		{462_662_500, "ch5", true},
		{462_664_000, "ch5", true}, // 1.5 kHz above ch5
		{462_660_000, "ch5", true}, // 2.5 kHz below ch5
		{462_668_500, "ch5", true}, // 6 kHz above: the edge of the tolerance
		{157_100_000, "22A", true}, // the US variant, entered before ITU 22
		{161_975_000, "87B", true}, // AIS 1
		{27_185_000, "19", true},
		{151_820_000, "1", true},
		{146_520_000, "calling", true},
		{121_500_000, "guard", true},
		{156_807_000, "", false}, // 7 kHz above marine 16, 18 kHz below 17
		{101_100_000, "", false}, // FM broadcast has no plan
		{153_200_000, "", false}, // between the MURS halves
	} {
		_, c, ok := ChannelAt(tc.hz)
		if ok != tc.ok || (ok && c.Name != tc.name) {
			t.Errorf("ChannelAt(%d) = %q, %v; want %q, %v", tc.hz, c.Name, ok, tc.name, tc.ok)
		}
	}
	if b, _, ok := ChannelAt(462_662_500); !ok || b.Name != "GMRS" {
		t.Errorf("a GMRS channel answers the group the plan hangs on, got %q", b.Name)
	}
}

// A name resolves in a band's context: the radio-printed name, with or without a leading zero,
// or any alias in that band's plan, and nothing outside it. A group's part answers through the
// group's plan, since the plan hangs on the group (docs/design/channels.md, "The CLI").
func TestResolvePlanChannel(t *testing.T) {
	for _, tc := range []struct {
		band, in string
		hz       uint64
		name     string
		ok       bool
	}{
		{"marine", "16", 156_800_000, "marine16", true},
		{"marine", "06", 156_300_000, "marine6", true},
		{"marine", "6", 156_300_000, "marine6", true},
		{"marine", "22a", 157_100_000, "marine22a", true},
		{"marine", "24 coast", 161_800_000, "marine24-coast", true},
		{"marine", "marine16", 156_800_000, "marine16", true},
		{"gmrs", "5", 462_662_500, "ch5", true},
		{"gmrs", "ch5", 462_662_500, "ch5", true},
		{"gmrs", "rpt3", 462_600_000, "ch17", true},
		{"gmrs-462", "5", 462_662_500, "ch5", true},
		{"murs", "1", 151_820_000, "murs1", true},
		{"noaa", "wx3", 162_475_000, "wx3", true},
		{"noaa", "WX3", 162_475_000, "wx3", true},
		{"cb", "19", 27_185_000, "cb19", true},
		{"marine", "99", 0, "", false},
		{"marine", "wx3", 0, "", false},
		{"fm", "16", 0, "", false},
	} {
		b, err := ResolveBand(tc.band)
		if err != nil {
			t.Fatal(err)
		}
		p, ok := ResolvePlanChannel(b, tc.in)
		if ok != tc.ok || (ok && (p.Hz != tc.hz || p.Name != tc.name)) {
			t.Errorf("ResolvePlanChannel(%s, %q) = %+v, %v; want %s at %d, %v", tc.band, tc.in, p, ok, tc.name, tc.hz, tc.ok)
		}
	}
	murs, _ := ResolveBand("murs")
	if p, ok := ResolvePlanChannel(murs, "1"); !ok || p.BandwidthHz != 11_250 || p.Mode != leylinev1.DemodMode_NFM {
		t.Errorf("MURS 1 carries its own width: %+v", p)
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
