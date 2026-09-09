package leyline

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// ParseFrequency parses a frequency string into Hz, strictly: a bare number
// is Hz, never MHz. Accepted forms: "146520000", "146.52M", "146.52MHz",
// "7040k", "7.040 MHz", "1.2G", "146.52e6". Suffixes are case-insensitive; an
// optional "Hz" is tolerated after the SI prefix and spaces are ignored.
// Digit separators are rejected ("1,296.2M", "146_520_000"): a comma is
// ambiguous between a decimal mark and a thousands separator. For the forms a
// person at a radio would type (bare MHz, a comma hint) use ParseUserFrequency.
func ParseFrequency(s string) (uint64, error) {
	orig := s
	s = strings.ToLower(strings.TrimSpace(s))
	s = strings.ReplaceAll(s, " ", "")
	if s == "" {
		return 0, fmt.Errorf("frequency: empty string")
	}
	if strings.ContainsAny(s, ",_") {
		// strconv.ParseFloat honours Go's digit separators ("146_520"), so
		// spell the rule out instead of leaving it to the number syntax.
		return 0, fmt.Errorf("frequency: cannot parse %q: digit separators are not accepted", orig)
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

// ParseUserFrequency parses a frequency the way a person at a radio would
// write it. Units are honoured as in ParseFrequency ("146.52M", "7040k",
// "1.2G", "146.52e6", "146520000Hz"); a bare number is read as MHz when it is
// below 100 000 ("146.52", "7.040", "1010" → 1010 MHz) and as Hz otherwise
// ("146520000"). Commas are rejected with a hint because "146,520" is
// ambiguous between a decimal comma and a thousands separator. Library
// callers that want Hz-strict input should use ParseFrequency.
func ParseUserFrequency(s string) (uint64, error) {
	orig := s
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("frequency: empty string; try 146.52 (MHz) or 146.52M")
	}
	if strings.Contains(s, ",") {
		return 0, fmt.Errorf("frequency: %q contains a comma; use a dot for decimals (146.52) or a unit (146520k)", orig)
	}
	if v, ok := bareNumber(s); ok {
		if v < 100_000 {
			return ParseFrequency(strconv.FormatFloat(v, 'f', -1, 64) + "M")
		}
		return ParseFrequency(s)
	}
	hz, err := ParseFrequency(s)
	if err != nil {
		return 0, fmt.Errorf("frequency: cannot read %q; try 146.52 (MHz), 7040k or 146520000", orig)
	}
	return hz, nil
}

// bareNumber reports whether s is a plain decimal number with no unit or
// exponent, returning its value.
func bareNumber(s string) (float64, bool) {
	if s == "" {
		return 0, false
	}
	for _, r := range s {
		if (r < '0' || r > '9') && r != '.' && r != '-' && r != '+' {
			return 0, false
		}
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
		return 0, false
	}
	return v, true
}

// InRanges reports whether hz falls inside any of the ranges.
func InRanges(hz uint64, ranges []*leylinev1.FrequencyRange) bool {
	for _, r := range ranges {
		if r != nil && hz >= r.GetMinHz() && hz <= r.GetMaxHz() {
			return true
		}
	}
	return false
}

// FormatRanges renders device tuning ranges as "24.000 MHz – 1.766 GHz",
// joined with ", " when there are several. Empty ranges render as "unknown".
func FormatRanges(ranges []*leylinev1.FrequencyRange) string {
	parts := make([]string, 0, len(ranges))
	for _, r := range ranges {
		if r == nil {
			continue
		}
		parts = append(parts, FormatFrequency(r.GetMinHz())+" – "+FormatFrequency(r.GetMaxHz()))
	}
	if len(parts) == 0 {
		return "unknown"
	}
	return strings.Join(parts, ", ")
}

// FrequencyHint returns a one-line hint for a frequency the device rejected as
// out of range, or "" when there is nothing useful to say. input is what the
// user typed and hz what ParseUserFrequency made of it. The rule from the CLI
// plan: when re-reading a bare number as kHz lands inside a device range or a
// known band, suggest that spelling ("did you mean 1.010 MHz (AM broadcast)?
// write 1010k"); otherwise give the honest reason ("this device cannot tune
// below 24.000 MHz; HF needs an upconverter"). Callers print the device's
// tuning range themselves; this hint never repeats it.
func FrequencyHint(input string, hz uint64, ranges []*leylinev1.FrequencyRange) string {
	if v, ok := bareNumber(strings.TrimSpace(input)); ok && v > 0 {
		khz := uint64(math.Round(v * 1e3))
		if khz != hz && (InRanges(khz, ranges) || BandFor(khz) != nil) {
			label := FormatFrequency(khz)
			if b := BandFor(khz); b != nil {
				label += " (" + b.Name + ")"
			}
			return fmt.Sprintf("did you mean %s? write %sk", label, strconv.FormatFloat(v, 'f', -1, 64))
		}
	}
	var minHz, maxHz uint64
	for _, r := range ranges {
		if r == nil {
			continue
		}
		if minHz == 0 || r.GetMinHz() < minHz {
			minHz = r.GetMinHz()
		}
		if r.GetMaxHz() > maxHz {
			maxHz = r.GetMaxHz()
		}
	}
	switch {
	case minHz > 0 && hz < minHz:
		s := "this device cannot tune below " + FormatFrequency(minHz)
		if hz < 30_000_000 {
			s += "; HF needs an upconverter or a device with direct sampling"
		}
		return s
	case maxHz > 0 && hz > maxHz:
		return "this device cannot tune above " + FormatFrequency(maxHz)
	}
	return ""
}
