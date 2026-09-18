// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"slices"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
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
	for _, hz := range []uint64{0, 100_000, 50_000_000, 115_000_000, 162_030_000, 300_000_000, 465_000_000, 1_000_000_000} {
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
// named as its parts; each half answers to its own name and to what people called it before.
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
	if !slices.Contains(BandAliases(), "gmrs") {
		t.Errorf("BandAliases lacks the group: %v", BandAliases())
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
