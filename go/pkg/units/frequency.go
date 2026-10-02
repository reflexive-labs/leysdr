// SPDX-License-Identifier: Apache-2.0

// Package units reads the values a person types at a radio (frequencies, squelch and gain
// levels, channel bandwidths, playback volumes) into the contract's units, and prints
// frequencies the way ley does. Every parser's error says what to type instead.
package units

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// ParseHz parses a frequency string into Hz, strictly: a bare number
// is Hz, never MHz. Accepted forms: "146520000", "146.52M", "146.52MHz",
// "7040k", "7.040 MHz", "1.2G", "146.52e6". Suffixes are case-insensitive; an
// optional "Hz" is tolerated after the SI prefix and spaces are ignored.
// Digit separators are rejected ("1,296.2M", "146_520_000"): a comma is
// ambiguous between a decimal mark and a thousands separator. For the forms a
// person at a radio would type (bare MHz, a comma hint) use ParseFrequency.
func ParseHz(s string) (uint64, error) {
	orig := s
	s = strings.ToLower(strings.TrimSpace(s))
	s = strings.ReplaceAll(s, " ", "")
	if s == "" {
		return 0, fmt.Errorf("no frequency given")
	}
	if strings.ContainsAny(s, ",_") {
		// strconv.ParseFloat honours Go's digit separators ("146_520"), so
		// spell the rule out instead of leaving it to the number syntax.
		return 0, fmt.Errorf("cannot read %q as a frequency; digit separators are not accepted", orig)
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
		return 0, fmt.Errorf("cannot read %q as a frequency", orig)
	}
	hz := v * mult
	if hz < 0 || hz > math.MaxUint64/2 {
		return 0, fmt.Errorf("%q is out of the range a frequency can be", orig)
	}
	return uint64(math.Round(hz)), nil
}

// FormatFrequency renders Hz with three decimals in the largest fitting SI unit:
// "146.520 MHz", "7.040 kHz", "1.200 GHz", "500 Hz".
func FormatFrequency(hz uint64) string {
	f := float64(hz)
	// The thresholds are the values that already round up to 1000 in the smaller
	// unit, so a 1 GHz tuning limit reads "1.000 GHz" and never "1000.000 MHz".
	switch {
	case f >= 999_999_500:
		return fmt.Sprintf("%.3f GHz", f/1e9)
	case f >= 999_999.5:
		// A fourth decimal for a frequency on an exact half-kilohertz: every 12.5 kHz
		// channel plan has them (GMRS channel 3 is 462.6125 MHz, and three decimals would
		// round it to a channel it is not), and no measurement lands on one by chance, so
		// a detection's centre keeps the three decimals its bin width supports.
		if hz%1_000 == 500 {
			return fmt.Sprintf("%.4f MHz", f/1e6)
		}
		return fmt.Sprintf("%.3f MHz", f/1e6)
	case f >= 999.9995:
		return fmt.Sprintf("%.3f kHz", f/1e3)
	default:
		return fmt.Sprintf("%d Hz", hz)
	}
}

// SquelchOff reports whether a squelch_db value means "squelch disabled".
func SquelchOff(db float64) bool { return math.IsNaN(db) }

// ParseFrequency parses a frequency the way a person at a radio would
// write it. Units are honoured as in ParseHz ("146.52M", "7040k",
// "1.2G", "146.52e6", "146520000Hz"); a bare number is read as MHz when it is
// below 100 000 ("146.52", "7.040", "1010" → 1010 MHz) and as Hz otherwise
// ("146520000"). Commas are rejected with a hint because "146,520" is
// ambiguous between a decimal comma and a thousands separator. Library
// callers that want Hz-strict input should use ParseHz.
func ParseFrequency(s string) (uint64, error) {
	orig := s
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("no frequency given; try 146.52 (MHz) or 146.52M")
	}
	if strings.Contains(s, ",") {
		return 0, fmt.Errorf("%q is not a frequency; use a dot for decimals (146.52) or a unit (146520k), not a comma", orig)
	}
	if v, ok := BareNumber(s); ok {
		if v < 100_000 {
			return ParseHz(strconv.FormatFloat(v, 'f', -1, 64) + "M")
		}
		return ParseHz(s)
	}
	hz, err := ParseHz(s)
	if err != nil {
		return 0, fmt.Errorf("cannot read %q as a frequency; try 146.52 (MHz), 7040k or 146520000", orig)
	}
	return hz, nil
}

// BareNumber reports whether s is a plain decimal number with no unit or
// exponent, returning its value.
func BareNumber(s string) (float64, bool) {
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

// NearestRate returns the entry of rates closest to want (a tie goes to the
// higher rate). Empty rates return want unchanged: a device that does not
// advertise its rates leaves validation to the daemon.
func NearestRate(rates []uint64, want uint64) uint64 {
	best, bestDiff := want, uint64(math.MaxUint64)
	for _, r := range rates {
		diff := r - want
		if r < want {
			diff = want - r
		}
		if diff < bestDiff || (diff == bestDiff && r > best) {
			best, bestDiff = r, diff
		}
	}
	return best
}
