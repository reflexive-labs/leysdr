package leyline

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// These parsers accept what people type at a radio and turn it into the
// wire's units. They are presentation-only: every result maps onto an
// existing leyline.v1 field, and every error says what to type instead.

// trimUnit strips one of the given case-insensitive suffixes (longest first)
// and surrounding spaces.
func trimUnit(s string, units ...string) string {
	t := strings.TrimSpace(s)
	lower := strings.ToLower(t)
	for _, u := range units {
		if strings.HasSuffix(lower, u) {
			return strings.TrimSpace(t[:len(t)-len(u)])
		}
	}
	return t
}

func parseNumber(s string) (float64, bool) {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	return v, true
}

// ParseSquelch parses a squelch level: "-40", "-40dB", "-40 dBFS", "off"
// (squelch disabled, returned as NaN, the wire encoding), or "auto" (the
// caller picks a level from the daemon's spectrum; auto=true, db=0). Levels
// are dBFS, where 0 is the loudest possible signal, so a positive number is
// an error that explains the scale rather than a silent threshold above
// full scale.
func ParseSquelch(s string) (db float64, auto bool, err error) {
	t := strings.ToLower(strings.TrimSpace(s))
	switch t {
	case "":
		return 0, false, fmt.Errorf("squelch: empty; try -40, auto or off")
	case "off", "none", "nan":
		return math.NaN(), false, nil
	case "auto":
		return 0, true, nil
	}
	v, ok := parseNumber(trimUnit(t, "dbfs", "db"))
	if !ok {
		return 0, false, fmt.Errorf("squelch: cannot read %q; use a dBFS level such as -40, or auto, or off", s)
	}
	if v > 0 {
		return 0, false, fmt.Errorf("squelch: %q is above full scale; levels are dBFS, 0 is loudest; try -40 or auto", s)
	}
	return v, false, nil
}

// ParseGain parses a gain setting: "auto" (agc) or a dB value with an
// optional "dB" suffix ("30", "30dB"). Negative gains are rejected. Use
// CheckGain to validate against a device's gain element.
func ParseGain(s string) (db float64, auto bool, err error) {
	t := strings.ToLower(strings.TrimSpace(s))
	switch t {
	case "":
		return 0, false, fmt.Errorf("gain: empty; try auto or a dB value such as 30")
	case "auto", "agc":
		return 0, true, nil
	}
	v, ok := parseNumber(trimUnit(t, "db"))
	if !ok {
		return 0, false, fmt.Errorf("gain: cannot read %q; use auto or a dB value such as 30", s)
	}
	if v < 0 {
		return 0, false, fmt.Errorf("gain: %q is negative; gain is amplification in dB from 0 upwards; try auto or 30", s)
	}
	return v, false, nil
}

// CheckGain reports an error when db is outside the element's range, naming
// the range (and "auto" when the element supports it). A nil element passes.
func CheckGain(db float64, el *leylinev1.GainElement) error {
	if el == nil {
		return nil
	}
	if db < el.GetMinDb() || db > el.GetMaxDb() {
		hint := ""
		if el.GetSupportsAuto() {
			hint = ", or auto"
		}
		return fmt.Errorf("gain: %g dB is outside %s's range %g to %g dB%s", db, el.GetName(), el.GetMinDb(), el.GetMaxDb(), hint)
	}
	return nil
}

// ParseBandwidth parses a channel bandwidth: a bare number below 1000 is kHz
// ("12.5" → 12 500 Hz), otherwise Hz ("12500"); units "k", "kHz", "M",
// "MHz", "Hz" are honoured ("12.5k", "200k").
func ParseBandwidth(s string) (uint32, error) {
	t := strings.ToLower(strings.TrimSpace(s))
	if t == "" {
		return 0, fmt.Errorf("bandwidth: empty; try 12.5 (kHz) or 12500")
	}
	if strings.Contains(t, ",") {
		return 0, fmt.Errorf("bandwidth: %q contains a comma; use a dot for decimals (12.5) or a unit (12500)", s)
	}
	var hz float64
	if v, ok := bareNumber(t); ok {
		if v < 1000 {
			v *= 1e3
		}
		hz = v
	} else {
		raw, err := ParseFrequency(t)
		if err != nil {
			return 0, fmt.Errorf("bandwidth: cannot read %q; try 12.5 (kHz), 12.5k or 12500", s)
		}
		hz = float64(raw)
	}
	if hz <= 0 || hz > math.MaxUint32 {
		return 0, fmt.Errorf("bandwidth: %q is out of range; try 12.5 (kHz) or 200k", s)
	}
	return uint32(math.Round(hz)), nil
}

// ParseVolume parses a playback level to a 0..1 gain: "0.5", "50%", or a
// bare 1..100 read as percent ("50" → 0.5). "1" means full volume.
func ParseVolume(s string) (float64, error) {
	t := strings.ToLower(strings.TrimSpace(s))
	if t == "" {
		return 0, fmt.Errorf("volume: empty; try 50%% or 0.5")
	}
	pct := strings.HasSuffix(t, "%")
	v, ok := parseNumber(strings.TrimSuffix(t, "%"))
	if !ok {
		return 0, fmt.Errorf("volume: cannot read %q; try 50%%, 0.5 or 100", s)
	}
	switch {
	case pct:
		v /= 100
	case v > 1:
		v /= 100
	}
	if v < 0 || v > 1 {
		return 0, fmt.Errorf("volume: %q is out of range; use 0 to 1, 0%% to 100%%, or 1 to 100", s)
	}
	return v, nil
}

// ResolveMode turns a mode name into a demodulator, using the frequency to
// settle the ambiguous names: "fm" is WFM on the FM broadcast band (87.5 to
// 108 MHz) and NFM elsewhere; "ssb" is USB at or above 10 MHz and LSB
// below; "nbfm"/"narrowfm" and "wbfm"/"widefm"/"broadcast" are aliases. Any
// other name goes through ParseMode unchanged. The returned reason is a
// short phrase explaining an inferred choice ("" when the name was explicit).
func ResolveMode(name string, hz uint64) (mode leylinev1.DemodMode, reason string, err error) {
	t := strings.ToLower(strings.TrimSpace(name))
	t = strings.ReplaceAll(t, "_", "")
	t = strings.ReplaceAll(t, "-", "")
	switch t {
	case "fm":
		if b := BandFor(hz); b != nil && b.Mode == leylinev1.DemodMode_WFM {
			return leylinev1.DemodMode_WFM, "fm on the " + b.Name + " band means WFM", nil
		}
		return leylinev1.DemodMode_NFM, "fm outside the FM broadcast band means NFM", nil
	case "ssb":
		m := sidebandFor(hz)
		if m == leylinev1.DemodMode_USB {
			return m, "ssb at or above 10 MHz means USB", nil
		}
		return m, "ssb below 10 MHz means LSB", nil
	case "nbfm", "narrowfm":
		return leylinev1.DemodMode_NFM, "", nil
	case "wbfm", "widefm", "broadcast":
		return leylinev1.DemodMode_WFM, "", nil
	}
	m, err := ParseMode(name)
	if err != nil {
		return m, "", fmt.Errorf("%w; also accepted: fm, ssb, nbfm, wbfm", err)
	}
	return m, "", nil
}
