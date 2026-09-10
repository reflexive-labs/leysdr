package leyline

import (
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
	for _, hz := range []uint64{0, 100_000, 50_000_000, 115_000_000, 162_030_000, 300_000_000, 1_000_000_000} {
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
