package leyline

import leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"

// Band is a named slice of spectrum with the mode and bandwidth a newcomer
// would most likely want there. The table is presentation-only: it drives
// the CLI's defaults and the words it prints, never the daemon. Mode is
// UNSPECIFIED for bands where the mode depends on the exact frequency
// (HF amateur segments: USB at or above 10 MHz, LSB below, see ResolveMode).
type Band struct {
	Name        string
	MinHz       uint64
	MaxHz       uint64
	Mode        leylinev1.DemodMode
	BandwidthHz uint32
	Note        string
}

const (
	mAM  = leylinev1.DemodMode_AM
	mNFM = leylinev1.DemodMode_NFM
	mWFM = leylinev1.DemodMode_WFM
	mSSB = leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED // sideband chosen by frequency
)

// bands is ordered by frequency; ranges do not overlap. NOAA weather sits
// inside the marine VHF allocation, so it is listed first and marine VHF is
// split around it.
var bands = []Band{
	{"AM broadcast", 530_000, 1_700_000, mAM, 10_000, "medium-wave broadcast stations"},
	{"160 m amateur", 1_800_000, 2_000_000, mSSB, 2_800, "amateur radio, LSB voice"},
	{"80 m amateur", 3_500_000, 4_000_000, mSSB, 2_800, "amateur radio, LSB voice"},
	{"40 m amateur", 7_000_000, 7_300_000, mSSB, 2_800, "amateur radio, LSB voice"},
	{"20 m amateur", 14_000_000, 14_350_000, mSSB, 2_800, "amateur radio, USB voice"},
	{"15 m amateur", 21_000_000, 21_450_000, mSSB, 2_800, "amateur radio, USB voice"},
	{"CB", 26_965_000, 27_405_000, mAM, 10_000, "citizens band, channel 1 to 40"},
	{"10 m amateur", 28_000_000, 29_700_000, mSSB, 2_800, "amateur radio, USB voice"},
	{"FM broadcast", 87_500_000, 108_000_000, mWFM, 200_000, "wideband FM radio stations"},
	{"airband", 118_000_000, 137_000_000, mAM, 10_000, "aircraft and towers, AM voice"},
	{"2 m amateur", 144_000_000, 148_000_000, mNFM, 12_500, "amateur radio, FM voice and repeaters"},
	{"marine VHF", 156_000_000, 162_024_999, mNFM, 12_500, "ship and coast stations; channel 16 is 156.800"},
	{"NOAA weather", 162_400_000, 162_550_000, mNFM, 12_500, "continuous weather broadcasts, WX1 to WX7"},
	{"70 cm amateur", 420_000_000, 450_000_000, mNFM, 12_500, "amateur radio, FM voice and repeaters"},
}

// Bands returns the band table in frequency order (a copy).
func Bands() []Band {
	out := make([]Band, len(bands))
	copy(out, bands)
	return out
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
