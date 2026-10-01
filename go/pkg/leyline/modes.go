// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"fmt"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

var modeNames = map[string]leylinev1.DemodMode{
	"am":    leylinev1.DemodMode_AM,
	"nfm":   leylinev1.DemodMode_NFM,
	"fm":    leylinev1.DemodMode_NFM,
	"wfm":   leylinev1.DemodMode_WFM,
	"usb":   leylinev1.DemodMode_USB,
	"lsb":   leylinev1.DemodMode_LSB,
	"cw":    leylinev1.DemodMode_CW,
	"raw":   leylinev1.DemodMode_RAW_IQ,
	"iq":    leylinev1.DemodMode_RAW_IQ,
	"rawiq": leylinev1.DemodMode_RAW_IQ,
}

// ParseMode parses a demodulator name case-insensitively ("nfm", "AM", "raw_iq").
func ParseMode(s string) (leylinev1.DemodMode, error) {
	t := strings.ToLower(strings.TrimSpace(s))
	t = strings.ReplaceAll(t, "_", "")
	t = strings.ReplaceAll(t, "-", "")
	if m, ok := modeNames[t]; ok {
		return m, nil
	}
	return leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED, fmt.Errorf("%q is not a mode; one of am, nfm, wfm, usb, lsb, cw, raw_iq", s)
}

// ModeName returns the lower-case CLI name of a demod mode ("nfm", "raw_iq").
func ModeName(m leylinev1.DemodMode) string {
	switch m {
	case leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED:
		return "unspecified"
	default:
		return strings.ToLower(m.String())
	}
}

// DefaultBandwidth returns the daemon's default channel bandwidth for a mode,
// mirroring the engine's DemodMode.defaultBandwidthHz. 0 for unspecified.
func DefaultBandwidth(m leylinev1.DemodMode) uint32 {
	switch m {
	case leylinev1.DemodMode_AM:
		return 10_000
	case leylinev1.DemodMode_NFM:
		return 12_500
	case leylinev1.DemodMode_WFM:
		return 200_000
	case leylinev1.DemodMode_USB, leylinev1.DemodMode_LSB:
		return 2_800
	case leylinev1.DemodMode_CW:
		return 500
	case leylinev1.DemodMode_RAW_IQ:
		return 12_500
	default:
		return 0
	}
}

// FullScaleDeviationHz returns the deviation that +/-1.0 on an FM detector's
// output stands for, mirroring the engine's demodulators: an NFM channel scales
// to its own bandwidth, clamped to the deviations narrowband radios actually
// use, and WFM is broadcast's 75 kHz. 0 for the amplitude modes, whose samples
// are not frequency at all. The daemon answers this in the audio descriptor;
// this is the same rule for a client left without one, and the fake daemon
// answers the wire field with it, so it must round exactly as the engine does:
// bandwidth / 5 to the nearest hertz, not truncated.
func FullScaleDeviationHz(m leylinev1.DemodMode, bandwidthHz uint32) uint32 {
	switch m {
	case leylinev1.DemodMode_NFM:
		if bandwidthHz == 0 {
			bandwidthHz = DefaultBandwidth(m)
		}
		// (bw + 2) / 5 is bw / 5 rounded to nearest: a fifth never lands on
		// a half, so there is no tie to break.
		return min(5_000, max(2_500, (bandwidthHz+2)/5))
	case leylinev1.DemodMode_WFM:
		return 75_000
	default:
		return 0
	}
}
