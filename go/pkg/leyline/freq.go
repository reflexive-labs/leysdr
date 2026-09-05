package leyline

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// ParseFrequency parses a human frequency string into Hz. Accepted forms:
// "146520000", "146.52M", "146.52MHz", "7040k", "7.040 MHz", "1.2G", "146.52e6".
// Suffixes are case-insensitive; an optional "Hz" is tolerated after the SI prefix.
func ParseFrequency(s string) (uint64, error) {
	orig := s
	s = strings.ToLower(strings.TrimSpace(s))
	s = strings.ReplaceAll(s, " ", "")
	s = strings.ReplaceAll(s, "_", "")
	s = strings.ReplaceAll(s, ",", "")
	if s == "" {
		return 0, fmt.Errorf("frequency: empty string")
	}
	mult := 1.0
	s = strings.TrimSuffix(s, "hz")
	if n := len(s); n > 0 {
		switch s[n-1] {
		case 'k':
			mult, s = 1e3, s[:n-1]
		case 'm':
			mult, s = 1e6, s[:n-1]
		case 'g':
			mult, s = 1e9, s[:n-1]
		}
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, fmt.Errorf("frequency: cannot parse %q", orig)
	}
	hz := v * mult
	if hz < 0 || hz > math.MaxUint64/2 {
		return 0, fmt.Errorf("frequency: %q out of range", orig)
	}
	return uint64(math.Round(hz)), nil
}

// FormatFrequency renders Hz with three decimals in the largest fitting SI unit:
// "146.520 MHz", "7.040 kHz", "1.200 GHz", "500 Hz".
func FormatFrequency(hz uint64) string {
	f := float64(hz)
	switch {
	case hz >= 1_000_000_000:
		return fmt.Sprintf("%.3f GHz", f/1e9)
	case hz >= 1_000_000:
		return fmt.Sprintf("%.3f MHz", f/1e6)
	case hz >= 1_000:
		return fmt.Sprintf("%.3f kHz", f/1e3)
	default:
		return fmt.Sprintf("%d Hz", hz)
	}
}

// ParseGain parses a gain argument: "auto" (case-insensitive) yields auto=true,
// otherwise a decimal dB value with an optional "dB" suffix.
func ParseGain(s string) (db float64, auto bool, err error) {
	t := strings.ToLower(strings.TrimSpace(s))
	if t == "auto" || t == "agc" {
		return 0, true, nil
	}
	t = strings.TrimSpace(strings.TrimSuffix(t, "db"))
	v, perr := strconv.ParseFloat(t, 64)
	if perr != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false, fmt.Errorf("gain: expected \"auto\" or a dB value, got %q", s)
	}
	return v, false, nil
}

// ParseSquelch parses a squelch argument: "off" (or "none") yields NaN, which is
// the wire encoding for squelch disabled; otherwise a dBFS threshold with an
// optional "dB" suffix.
func ParseSquelch(s string) (float64, error) {
	t := strings.ToLower(strings.TrimSpace(s))
	if t == "off" || t == "none" || t == "nan" {
		return math.NaN(), nil
	}
	t = strings.TrimSpace(strings.TrimSuffix(t, "dbfs"))
	t = strings.TrimSpace(strings.TrimSuffix(t, "db"))
	v, err := strconv.ParseFloat(t, 64)
	if err != nil || math.IsInf(v, 0) {
		return 0, fmt.Errorf("squelch: expected \"off\" or a dB value, got %q", s)
	}
	return v, nil
}

// SquelchOff reports whether a squelch_db value means "squelch disabled".
func SquelchOff(db float64) bool { return math.IsNaN(db) }

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
	return leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED, fmt.Errorf("mode: unknown demodulator %q (am, nfm, wfm, usb, lsb, cw, raw_iq)", s)
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
